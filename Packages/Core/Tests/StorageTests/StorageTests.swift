import XCTest
import Core

/// Scripted SecItem backend (no host Keychain).
final class FakeKeychain: KeychainBackend, @unchecked Sendable {
    struct Key: Hashable { var service: String; var group: String? }
    private let lock = NSLock()
    var items: [Key: Data] = [:]
    var accessibility: [Key: StoreKey.Accessibility] = [:]
    var groupStatus: Int32 = KeychainStatus.success
    var readStatus: Int32? = nil
    var calls: [String] = []

    func copy(service: String, account: String, accessGroup: String?) -> (status: Int32, data: Data?) {
        lock.withLock {
            calls.append("copy \(accessGroup ?? "-")")
            if let readStatus { return (readStatus, nil) }
            if accessGroup != nil, groupStatus != KeychainStatus.success { return (groupStatus, nil) }
            guard let d = items[Key(service: service, group: accessGroup)] else { return (KeychainStatus.itemNotFound, nil) }
            return (KeychainStatus.success, d)
        }
    }
    func add(service: String, account: String, accessGroup: String?, accessibility a: StoreKey.Accessibility, data: Data) -> Int32 {
        lock.withLock {
            calls.append("add \(accessGroup ?? "-")")
            if accessGroup != nil, groupStatus != KeychainStatus.success { return groupStatus }
            let k = Key(service: service, group: accessGroup)
            if items[k] != nil { return KeychainStatus.duplicateItem }
            items[k] = data; accessibility[k] = a
            return KeychainStatus.success
        }
    }
    func update(service: String, account: String, accessGroup: String?, accessibility a: StoreKey.Accessibility, data: Data) -> Int32 {
        lock.withLock {
            calls.append("update \(accessGroup ?? "-")")
            items[Key(service: service, group: accessGroup)] = data
            return KeychainStatus.success
        }
    }
    func delete(service: String, account: String, accessGroup: String?) -> Int32 {
        lock.withLock {
            calls.append("delete \(accessGroup ?? "-")")
            return items.removeValue(forKey: Key(service: service, group: accessGroup)) == nil ? KeychainStatus.itemNotFound : KeychainStatus.success
        }
    }
}

final class KeychainStoreTests: XCTestCase {
    let group = "TEAMID1234.com.beamjason.xiaorichang.shared"

    func testNames() {
        XCTAssertEqual(StoreKey.schoolEcykt.service, "com.beamjason.xiaorichang.school.ecykt.v1")
        XCTAssertEqual(StoreKey.sharedSnapshot.service, "com.beamjason.xiaorichang.shared.snapshot.v1")
        XCTAssertEqual(StoreKey.account, "default")
        XCTAssertEqual(StoreKey.schoolPortal.accessibility, .whenUnlockedThisDeviceOnly)
        XCTAssertEqual(StoreKey.schoolEcykt.accessibility, .afterFirstUnlockThisDeviceOnly)
        XCTAssertEqual(StoreKey.allCases.filter(\.isShared), [.schoolEcykt, .schoolProfile, .sharedSnapshot, .sharedReminderLines])
        XCTAssertEqual(PreferenceKey.reminder("card"), "xrc.reminder.card")
        XCTAssertEqual(PreferenceKey.laundryAckFailedOrder, "xrc.laundry.ackFailedOrder")
        XCTAssertEqual(SharedSnapshotStore.widgetKind, "XiaoRiChangBalances")
    }

    func testSharedItemsUseAccessGroupPortalTokenNever() throws {
        let kc = FakeKeychain()
        let store = KeychainSecureStore(backend: kc, accessGroup: group)
        try store.write(Data("s".utf8), for: .sharedSnapshot)
        try store.write(Data("c".utf8), for: .schoolPortal)
        XCTAssertEqual(kc.items[.init(service: StoreKey.sharedSnapshot.service, group: group)], Data("s".utf8))
        XCTAssertEqual(kc.items[.init(service: StoreKey.schoolPortal.service, group: nil)], Data("c".utf8))
        XCTAssertEqual(kc.accessibility[.init(service: StoreKey.schoolPortal.service, group: nil)], .whenUnlockedThisDeviceOnly)
        XCTAssertFalse(store.isUsingFallback)
        XCTAssertEqual(try store.read(.sharedSnapshot), Data("s".utf8))
        // Overwrite goes through update.
        try store.write(Data("s2".utf8), for: .sharedSnapshot)
        XCTAssertEqual(try store.read(.sharedSnapshot), Data("s2".utf8))
    }

    /// Re-signed IPA without the keychain-access-groups entitlement: fall back to no group.
    func testFallsBackWhenGroupWriteFails() throws {
        let kc = FakeKeychain()
        kc.groupStatus = KeychainStatus.missingEntitlement
        let store = KeychainSecureStore(backend: kc, accessGroup: group)
        try store.write(Data("s".utf8), for: .sharedSnapshot)
        XCTAssertTrue(store.isUsingFallback)
        XCTAssertEqual(kc.items[.init(service: StoreKey.sharedSnapshot.service, group: nil)], Data("s".utf8))
        XCTAssertEqual(try store.read(.sharedSnapshot), Data("s".utf8))
        // Later writes skip the group entirely.
        kc.calls = []
        try store.write(Data("t".utf8), for: .sharedReminderLines)
        XCTAssertEqual(kc.calls, ["add -"])
        try store.delete(.sharedSnapshot)
        XCTAssertNil(try store.read(.sharedSnapshot))
    }

    /// The widget reads the school session and profile through the same access group.
    func testSchoolSessionAndProfileUseTheSharedGroup() throws {
        let kc = FakeKeychain()
        let store = KeychainSecureStore(backend: kc, accessGroup: group)
        let vault = StoredSchoolVault(store: store)
        try vault.saveEcyktSession(EcyktSession(token: "t", syscustid: "s"))
        try vault.saveProfile(SchoolProfile(residence: PortalResidence(raw: "示例校区9栋9号1层199房")))
        try vault.savePortalToken(PortalToken("p"))
        XCTAssertNotNil(kc.items[.init(service: StoreKey.schoolEcykt.service, group: group)])
        XCTAssertNotNil(kc.items[.init(service: StoreKey.schoolProfile.service, group: group)])
        XCTAssertEqual(kc.accessibility[.init(service: StoreKey.schoolEcykt.service, group: group)], .afterFirstUnlockThisDeviceOnly,
                       "background and widget reads work while the phone is locked")
        XCTAssertNil(kc.items[.init(service: StoreKey.schoolPortal.service, group: group)])
        for key in [StoreKey.waterBinding, .waterSession, .laundryAccount, .laundryCheckout] { XCTAssertFalse(key.isShared, key.rawValue) }
        // A second store in the same group (the widget process) reads the same session.
        let widget = StoredSchoolVault(store: KeychainSecureStore(backend: kc, accessGroup: group))
        XCTAssertEqual(try widget.ecyktSession()?.syscustid, "s")
    }

    /// An item the app wrote before it was pinned to the group (default group) is still read.
    func testSchoolSessionWrittenWithoutGroupStillReads() throws {
        let kc = FakeKeychain()
        kc.items[.init(service: StoreKey.schoolEcykt.service, group: nil)] = try JSONEncoder().encode(EcyktSession(token: "t", syscustid: "old"))
        let vault = StoredSchoolVault(store: KeychainSecureStore(backend: kc, accessGroup: group))
        XCTAssertEqual(try vault.ecyktSession()?.syscustid, "old")
    }

    /// The group the store uses is the one both entitlements files list.
    func testAccessGroupMatchesBothEntitlements() throws {
        XCTAssertEqual(SharedKeychain.groupIdentifier, "com.beamjason.xiaorichang.shared")
        XCTAssertEqual(SharedKeychain.accessGroup(teamPrefixedFrom: "TEAMID1234.com.beamjason.xiaorichang"), group)
        XCTAssertEqual(SharedKeychain.accessGroup(teamPrefixedFrom: "TEAMID1234.com.beamjason.xiaorichang.shared"), group)
        XCTAssertNil(SharedKeychain.accessGroup(teamPrefixedFrom: "nodot"))
        XCTAssertNil(SharedKeychain.accessGroup(teamPrefixedFrom: ".leadingdot"))
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for path in ["App/Resources/App.entitlements", "Widget/Widget.entitlements"] {
            let data = try Data(contentsOf: root.appendingPathComponent(path))
            let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], path)
            let groups = try XCTUnwrap(plist["keychain-access-groups"] as? [String], path)
            XCTAssertEqual(groups, ["$(AppIdentifierPrefix)" + SharedKeychain.groupIdentifier], path)
        }
    }

    func testReadErrorsThrow() {
        let kc = FakeKeychain()
        kc.readStatus = -25308 // errSecInteractionNotAllowed (locked device)
        let store = KeychainSecureStore(backend: kc, accessGroup: nil)
        XCTAssertThrowsError(try store.read(.schoolEcykt)) { XCTAssertEqual(($0 as? StorageError)?.status, -25308) }
    }
}

final class SchoolStoresTests: XCTestCase {
    func testVaultRoundTrip() throws {
        let vault = StoredSchoolVault(store: InMemorySecureStore())
        XCTAssertNil(try vault.ecyktSession())
        let s = EcyktSession(token: "t", syscustid: "s", custid: "c", cardUnionID: "u")
        try vault.saveEcyktSession(s)
        XCTAssertEqual(try vault.ecyktSession(), s)
        try vault.savePortalToken(PortalToken("p"))
        XCTAssertEqual(try vault.portalToken(), PortalToken("p"))
        let profile = SchoolProfile(residence: PortalResidence(raw: "示例校区9栋9号1层199房"),
                                    meter: MeterBinding(nodeID: "n", comAddress: "a", label: "9栋 199", nodeIsRoom: true))
        try vault.saveProfile(profile)
        XCTAssertEqual(try vault.profile(), profile)
        try vault.saveEcyktSession(nil)
        XCTAssertNil(try vault.ecyktSession())
        XCTAssertFalse("\(s)".contains("\"t\""))
        XCTAssertFalse(String(describing: PortalToken("secret-portal")).contains("secret-portal"))
    }

    func testWriteFailuresSurface() {
        let mem = InMemorySecureStore()
        mem.failWrites(to: .schoolEcykt)
        let vault = StoredSchoolVault(store: mem)
        XCTAssertThrowsError(try vault.saveEcyktSession(EcyktSession(token: "t", syscustid: "s")))
    }

    func testSnapshotStoreNotifiesAndCapsSize() throws {
        let counter = Counter()
        let store = SharedSnapshotStore(store: InMemorySecureStore(), didWrite: { counter.bump() })
        var snap = HomeSnapshot.empty
        snap.card.succeed(Money(fen: 790), at: Date(timeIntervalSince1970: 100))
        try store.saveSnapshot(snap)
        XCTAssertEqual(try store.loadSnapshot()?.card.value, Money(fen: 790))
        XCTAssertEqual(counter.value, 1)
        snap.roomLabel = String(repeating: "x", count: HomeSnapshot.maxEncodedBytes)
        XCTAssertThrowsError(try store.saveSnapshot(snap))
        XCTAssertEqual(counter.value, 1)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}
