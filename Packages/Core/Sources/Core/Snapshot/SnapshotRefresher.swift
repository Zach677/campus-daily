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
/// Reads the school data, reduces it into the stored snapshot and saves it. Refreshes are
/// single-flight within this process: a caller that arrives while one is running awaits that
/// same refresh and gets its report, so a pull-to-refresh during a foreground or background
/// read still ends with the fresh values (or the recorded failure). A failed read keeps the
/// last good values. Three exceptions to joining:
/// - a foreground caller that joined a background read which ended in `needsLogin` runs one
///   foreground read next (only the foreground may silently renew the school login);
/// - a caller passing `includingChanges` after `noteChange()` (new login, meter chosen) waits
///   for the older read to end and then starts, or joins, a read that sees the change;
/// - when every caller waiting on a read is cancelled (an expiring background task), the read
///   is cancelled and writes nothing.
public actor SnapshotRefresher {
    let school: SchoolReader
    let store: SnapshotStoring

    private struct Run {
        let id: Int
        let task: Task<RefreshReport, Never>
        let inBackground: Bool
        let changes: Int
        var waiters = 0
        var cancelled = 0
    }

    private var current: Run?
    private var nextRunID = 0
    /// Bumped by `noteChange()`.
    private var changes = 0
    /// Bumped by `clear()` so a refresh that was running during sign-out does not write back.
    private var generation = 0
    /// Callers that joined a running refresh (for tests).
    private(set) var joinedCount = 0
    /// Waiters whose task was cancelled (for tests).
    private(set) var cancelledWaiters = 0

    /// Times come from the school reading (`checkedAt`, `readAt`), so the refresher needs no clock.
    public init(school: SchoolReader, store: SnapshotStoring) {
        self.school = school; self.store = store
    }

    /// The stored snapshot, or `.empty`. Reading never waits for a running refresh.
    public nonisolated func latest() -> HomeSnapshot {
        ((try? store.loadSnapshot()) ?? nil) ?? .empty
    }

    /// Something the next read depends on changed (sign-in, meter choice). A refresh asked
    /// with `includingChanges` will not join a read that started before this.
    public func noteChange() { changes += 1 }

    /// Runs a refresh, or joins the one already running (see the type's rules).
    public func refresh(inBackground: Bool, includingChanges: Bool = false) async -> RefreshReport {
        while includingChanges, let run = current, run.changes != changes {
            _ = await wait(for: run.id, run.task)
        }
        if let run = current {
            joinedCount += 1
            let report = await wait(for: run.id, run.task)
            if !inBackground, run.inBackground, case .needsLogin = report.outcome, !Task.isCancelled {
                return await refresh(inBackground: false, includingChanges: includingChanges)
            }
            return report
        }
        nextRunID += 1
        let id = nextRunID
        let task = Task { () -> RefreshReport in
            let report = await self.run(inBackground: inBackground)
            await self.finished(id)
            return report
        }
        current = Run(id: id, task: task, inBackground: inBackground, changes: changes)
        return await wait(for: id, task)
    }

    /// Signed out: the shared snapshot goes back to empty. A refresh still running is dropped.
    public func clear() throws {
        generation += 1
        current = nil
        try store.saveSnapshot(SchoolSnapshotReducer.reduce(latest(), .signedOut))
    }

    private func wait(for id: Int, _ task: Task<RefreshReport, Never>) async -> RefreshReport {
        if current?.id == id { current?.waiters += 1 }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { await self.waiterCancelled(id) }
        }
    }

    private func waiterCancelled(_ id: Int) {
        cancelledWaiters += 1
        guard var run = current, run.id == id else { return }
        run.cancelled += 1
        current = run
        if run.cancelled >= run.waiters {
            run.task.cancel()
            current = nil
        }
    }

    private func finished(_ id: Int) {
        if current?.id == id { current = nil }
    }

    private func run(inBackground: Bool) async -> RefreshReport {
        let started = generation
        let reading = await school.refresh(inBackground: inBackground)
        // Signed out meanwhile, or nobody wants this read any more: write nothing.
        guard started == generation, !Task.isCancelled else {
            let outcome: RefreshReport.Outcome = started == generation ? reading.outcome : .notSignedIn
            return RefreshReport(outcome: outcome, snapshot: latest(), reexchanged: reading.reexchanged, snapshotSaved: false)
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
