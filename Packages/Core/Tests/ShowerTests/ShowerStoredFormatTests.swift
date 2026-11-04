import XCTest
@testable import Core
import CoreTestSupport

/// The binding and session this build writes read back unchanged on the next launch, and a
/// read never writes or deletes anything.
final class ShowerStoredFormatTests: XCTestCase {
    /// Counts writes and deletes per key.
    final class TouchCountingStore: SecureStore, @unchecked Sendable {
        let inner = InMemorySecureStore()
        private let lock = NSLock()
        private var touched: [StoreKey: Int] = [:]
        func read(_ key: StoreKey) throws -> Data? { try inner.read(key) }
        func write(_ data: Data, for key: StoreKey) throws {
            try inner.write(data, for: key); lock.withLock { touched[key, default: 0] += 1 }
        }
        func delete(_ key: StoreKey) throws { try inner.delete(key); lock.withLock { touched[key, default: 0] += 1 } }
        var touches: Int { lock.withLock { touched.values.reduce(0, +) } }
    }

    static let binding = ShowerBinding(studentId: "S1234567", schoolId: "20021", machineId: "11223344", roomId: "R1",
                                       roomLabel: "99栋 991", machineName: "99-991", peripheralID: "P-SYNTH-1")

    func testTheCurrentBindingReadsBackWithoutAWrite() throws {
        let store = TouchCountingStore()
        try store.inner.write(try JSONEncoder().encode(Self.binding), for: .showerBinding)
        let vault = StoredShowerVault(store: store)
        XCTAssertEqual(try vault.binding(), Self.binding)
        XCTAssertEqual(try vault.binding(), Self.binding)
        XCTAssertEqual(store.touches, 0)
    }

    func testTheCurrentSessionRestoresWithoutAWrite() throws {
        let water = Date(timeIntervalSince1970: 1_800_000_000)
        var running = ShowerState.idle
        running.phase = .running; running.machineID = "11223344"; running.peripheralID = "P-SYNTH-1"
        running.startedAt = water; running.authorizeSent = true; running.authorizationID = "001122FF"
        let store = TouchCountingStore()
        try store.inner.write(try JSONEncoder().encode(running), for: .showerSession)
        let read = try XCTUnwrap(try StoredShowerVault(store: store).showerState())
        XCTAssertEqual(read, running)
        let restored = ShowerReducer.restore(read)
        XCTAssertEqual(restored.phase, .running)
        XCTAssertEqual(restored.startedAt, water, "the timer counts from the water")
        XCTAssertEqual(store.touches, 0)
    }

    /// An imported config's folder is kept out of backups when it is made.
    func testTheFolderOfAnImportIsKeptOutOfBackups() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let water = ShowerImportFolder.url(in: root)
        try ShowerImportFolder.prepare(for: water.appendingPathComponent("imported.waterconfig"))
        var fresh = water; fresh.removeAllCachedResourceValues()
        XCTAssertEqual(try fresh.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }
}
