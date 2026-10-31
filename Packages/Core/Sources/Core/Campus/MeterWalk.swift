import Foundation

/// A level of the electricity directory, as the picker walks it.
public enum MeterLevel: String, Sendable, Equatable, Codable, CaseIterable {
    case campus, apartment, building, floor, room
}

/// Where the automatic meter lookup stopped: the levels above matched the dorm (`path`), this
/// one did not match exactly once. The meter page opens here with `options` (this level's rows
/// as read); `suggested` are the rows that matched (several), or the dorm's own room when it
/// reports no meter; empty when nothing matched.
public struct MeterWalkStop: Sendable, Equatable {
    public var level: MeterLevel
    public var path: [PowerNode]
    public var options: [PowerNode]
    public var suggested: [String]

    public init(level: MeterLevel, path: [PowerNode], options: [PowerNode], suggested: [String] = []) {
        self.level = level; self.path = path; self.options = options; self.suggested = suggested
    }
}
