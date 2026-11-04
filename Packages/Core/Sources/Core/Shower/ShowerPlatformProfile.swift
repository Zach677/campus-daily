import Foundation

/// The shared hot-water platform parameters (not personal). Never logged, never in the repo.
public struct ShowerPlatformProfile: Sendable, Equatable, Codable, CustomStringConvertible, CustomDebugStringConvertible {
    public var secret: String
    public var sid: String
    public var bleName: String
    public var typeId: String
    public var version: String
    public init(secret: String, sid: String, bleName: String, typeId: String, version: String) {
        self.secret = secret; self.sid = sid; self.bleName = bleName; self.typeId = typeId; self.version = version
    }
    public var description: String { "WaterPlatformProfile(<redacted>, typeId: \(typeId), version: \(version))" }
    public var debugDescription: String { description }
}

/// Why a `.waterconfig` (or the bundled profile) was refused.
public enum ShowerProfileError: Error, Equatable, Sendable {
    case incomplete
    case unreadable
}
