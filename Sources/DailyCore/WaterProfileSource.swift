import Foundation

/// The shared hot-water platform parameters (not personal). Never logged, never in the repo.
public struct WaterPlatformProfile: Sendable, Equatable, Codable, CustomStringConvertible, CustomDebugStringConvertible {
    public var secret: String
    public var sid: String
    public var bleName: String
    public var typeId: String
    public var version: String
    public init(secret: String, sid: String, bleName: String, typeId: String, version: String) {
        self.secret = secret; self.sid = sid; self.bleName = bleName; self.typeId = typeId; self.version = version
    }
    public var isComplete: Bool {
        ![secret, sid, bleName, typeId, version].contains { $0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
    public var description: String { "WaterPlatformProfile(<redacted>, typeId: \(typeId), version: \(version))" }
    public var debugDescription: String { description }
}

/// Where the platform profile comes from:
/// - `bundled`: staged into the app bundle at build time (`tools/stage_platform_profile.py`);
/// - `imported`: a `.waterconfig` file the user imported.
public enum WaterProfileSource: Sendable, Equatable, Codable {
    case bundled
    case imported(fileName: String)
}

/// What a source resolves to.
public enum WaterPlatformAccess: Sendable, Equatable {
    case local(WaterPlatformProfile, source: WaterProfileSource)
}

public enum WaterProfileError: Error, Equatable, Sendable {
    case missing(WaterProfileSource)
    case incomplete(WaterProfileSource)
    case unreadable(WaterProfileSource)
}

/// Resolves a source to usable access. Implemented in App (bundle/file I/O) and in tests.
public protocol WaterProfileProviding: Sendable {
    func resolve(_ source: WaterProfileSource) async throws -> WaterPlatformAccess
}

/// Picks the first usable source in the user's order of preference.
public enum WaterProfileResolver {
    public static func firstUsable(_ sources: [WaterProfileSource], provider: some WaterProfileProviding) async -> Result<WaterPlatformAccess, WaterProfileError> {
        var last: WaterProfileError = .missing(.bundled)
        for source in sources {
            do {
                let access = try await provider.resolve(source)
                if case .local(let p, _) = access, !p.isComplete { last = .incomplete(source); continue }
                return .success(access)
            } catch let e as WaterProfileError {
                last = e
            } catch {
                last = .unreadable(source)
            }
        }
        return .failure(last)
    }

    /// Decodes a `.waterconfig` / bundled profile JSON (`secret, sid, ble_name|bleName,
    /// typeID|type_id|typeId, version`; numbers accepted for `type_id`/`version`). Personal fields
    /// in a `.waterconfig` (student/machine) are ignored here.
    public static func decodeProfile(_ data: Data, source: WaterProfileSource) throws -> WaterPlatformProfile {
        guard let root = try? JSONValue.parse(data), let o = root.object else { throw WaterProfileError.unreadable(source) }
        func field(_ keys: String...) -> String { keys.lazy.compactMap { o[$0]?.text }.first ?? "" }
        let p = WaterPlatformProfile(secret: field("secret"), sid: field("sid"), bleName: field("bleName", "ble_name"),
                                     typeId: field("typeID", "typeId", "type_id"), version: field("version"))
        guard p.isComplete else { throw WaterProfileError.incomplete(source) }
        return p
    }
}
