import Foundation

/// The school read the refresher drives (`SchoolSession` in the app, fakes in tests).
public protocol SchoolReader: Sendable {
    func refresh(inBackground: Bool) async -> SchoolReading
}

extension SchoolSession: SchoolReader {}

/// What one refresh produced.
public struct RefreshReport: Sendable, Equatable {
    public typealias Outcome = SchoolReading.Outcome
    public var outcome: Outcome
    public var snapshot: HomeSnapshot
    public var reexchanged: Bool
    public var snapshotSaved: Bool

    public init(outcome: Outcome, snapshot: HomeSnapshot, reexchanged: Bool, snapshotSaved: Bool) {
        self.outcome = outcome; self.snapshot = snapshot; self.reexchanged = reexchanged; self.snapshotSaved = snapshotSaved
    }
}

/// The only writer of the home snapshot the app and the widget read.
///
/// Reads the school data, reduces it into the stored snapshot and saves it. A failed read keeps
/// the last good values and records the failure next to them.
public actor SnapshotRefresher {
    let school: SchoolReader
    let store: SnapshotStoring
    let now: @Sendable () -> Date

    /// Bumped by `clear()` so a refresh that was running during sign-out does not write back.
    private var generation = 0

    public init(school: SchoolReader, store: SnapshotStoring, now: @escaping @Sendable () -> Date = Date.init) {
        self.school = school; self.store = store; self.now = now
    }

    /// The stored snapshot, or `.empty`. Reading never waits for a running refresh.
    public nonisolated func latest() -> HomeSnapshot {
        ((try? store.loadSnapshot()) ?? nil) ?? .empty
    }

    public func refresh(inBackground: Bool) async -> RefreshReport {
        await run(inBackground: inBackground)
    }

    /// Signed out: the shared snapshot goes back to empty. A refresh still running is dropped.
    public func clear() throws {
        generation += 1
        try store.saveSnapshot(SchoolSnapshotReducer.reduce(latest(), .signedOut))
    }

    private func run(inBackground: Bool) async -> RefreshReport {
        let started = generation
        let reading = await school.refresh(inBackground: inBackground)
        guard started == generation else {
            return RefreshReport(outcome: .notSignedIn, snapshot: latest(), reexchanged: reading.reexchanged, snapshotSaved: false)
        }
        let snapshot = Self.apply(reading, to: latest())
        let saved = (try? store.saveSnapshot(snapshot)) != nil
        return RefreshReport(outcome: reading.outcome, snapshot: snapshot, reexchanged: reading.reexchanged, snapshotSaved: saved)
    }

    /// Pure: the snapshot after one school reading.
    public static func apply(_ reading: SchoolReading, to snapshot: HomeSnapshot) -> HomeSnapshot {
        var s = snapshot
        switch reading.outcome {
        case .notSignedIn:
            s = SchoolSnapshotReducer.reduce(s, .sessionExpired(.sessionExpired(.ecykt), at: reading.checkedAt))
        case .needsLogin(let e):
            s = SchoolSnapshotReducer.reduce(s, .sessionExpired(e, at: reading.checkedAt))
        case .failed(let e):
            s = SchoolSnapshotReducer.reduce(s, .livenessFailed(e, at: reading.checkedAt))
        case .ok:
            s = SchoolSnapshotReducer.reduce(s, .livenessOK(at: reading.checkedAt))
            let at = reading.readAt ?? reading.checkedAt
            if let b = reading.balance { s = SchoolSnapshotReducer.reduce(s, .balance(b, at: at)) }
            if let m = reading.meter {
                s = SchoolSnapshotReducer.reduce(s, .meter(m, at: at))
                s = SchoolSnapshotReducer.reduce(s, .roomLabel(reading.roomLabel))
            }
        }
        return s
    }
}
