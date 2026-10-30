import Foundation

/// What the app clears when someone else signs in on this iPhone: the previous person's numbers
/// (the shared snapshot) and their hot-water binding. The binding is never dropped while the
/// shower may still need it (a shower running or not yet settled): then the new person is asked
/// to check the dorm instead, and so too when deleting it failed.
public enum AccountSwitch {
    public enum HotWater: Sendable, Equatable {
        /// There was no binding.
        case none
        /// The binding is gone.
        case cleared
        /// Kept (a shower may still need it, or deleting failed): the dorm needs a look.
        case keptForReview
        /// Whether the switch notice mentions hot water.
        public var noticed: Bool { self != .none }
    }

    /// `mayClear`: no shower running or waiting to be settled. `delete` removes the binding.
    public static func clearHotWater(hasBinding: Bool, mayClear: Bool, delete: () throws -> Void) -> HotWater {
        guard hasBinding else { return .none }
        guard mayClear else { return .keptForReview }
        do { try delete() } catch { return .keptForReview }
        return .cleared
    }

    /// The order of the clean-up: the snapshot first (so no screen or widget shows the previous
    /// person's balance), then hot water. A failed snapshot write still goes on to hot water.
    /// Runs in the caller's isolation (the app's main actor), so the closures may touch its models.
    public static func clearPreviousPerson(isolation: isolated (any Actor)? = #isolation,
                                           snapshot: () async throws -> Void, hotWater: () -> HotWater) async -> HotWater {
        try? await snapshot()
        return hotWater()
    }
}
