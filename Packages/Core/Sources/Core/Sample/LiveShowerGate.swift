import Foundation
import Observation

/// The one place that decides between 「先看看示例」 and a real shower start, so the two never
/// overlap: the sample opens only while the real shower record is known to be at rest and no
/// start is under way, and a real start is refused while the sample is shown. Both decisions
/// are made here, on the main actor, each in one step with nothing awaited between the check
/// and the claim (`claimSample`, `claimStart`).
@MainActor @Observable public final class LiveShowerGate {
    /// What the live hot-water side knows of its record.
    public enum Record: Equatable, Sendable {
        /// Not read yet (the launch is still loading it).
        case notLoaded
        /// It could not be read (Keychain error, a record another build wrote, a failed write).
        case unreadable
        case known(ShowerState)
    }

    /// The live record as of now. Set by the live hot-water model; until then nothing is known.
    @ObservationIgnored public var record: @MainActor () -> Record
    /// The sample is shown (claimed by `claimSample`, given back by `sampleLeft`).
    public private(set) var sampleShown = false
    /// Real starts between `claimStart` and `startEnded`.
    public private(set) var startsUnderWay = 0

    public init(record: @escaping @MainActor () -> Record = { .notLoaded }) {
        self.record = record
    }

    /// The sample may open now: the record is at rest and no start is under way.
    public var sampleAllowed: Bool {
        !sampleShown && startsUnderWay == 0 && Self.allowsSample(record())
    }

    /// The record is at rest: idle, or done (settled), or a failure that issued nothing. Any
    /// session under way or waiting for its check, and any record not known, refuses.
    public static func allowsSample(_ record: Record) -> Bool {
        guard case .known(let state) = record, !state.stateReviewRequired else { return false }
        switch state.phase {
        case .idle, .done: return true
        case .failed: return state.failure?.needsReview == false
        case .authorizing, .writePending, .running, .closing, .settling: return false
        }
    }

    /// The sample opens: true when it may (and from now on no real start begins).
    func claimSample() -> Bool {
        guard sampleAllowed else { return false }
        sampleShown = true
        return true
    }

    /// The sample was left: real starts may begin again.
    func sampleLeft() { sampleShown = false }

    /// A real start begins: true when it may (the sample is not shown); then `startEnded` must
    /// follow once the start returned and its record is known here.
    public func claimStart() -> Bool {
        guard !sampleShown else { return false }
        startsUnderWay += 1
        return true
    }

    public func startEnded() { startsUnderWay = max(0, startsUnderWay - 1) }
}
