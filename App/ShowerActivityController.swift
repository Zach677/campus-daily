import Foundation
import ActivityKit
import WaterCore

/// Mirrors the persisted WaterSession into a single Live Activity.
/// Driven from WaterModel.refresh()/show(); never talks to the water controller itself.
@MainActor final class ShowerActivityController {
    static let shared = ShowerActivityController()
    /// Short dorm label shown on the activity; set by the app from CampusModel.room.
    var dorm = ""
    private var activity: Activity<ShowerActivityAttributes>?
    private init() {
        // Reuse an activity left over from a previous launch; drop any duplicates.
        let existing = Activity<ShowerActivityAttributes>.activities
        activity = existing.first
        for extra in existing.dropFirst() { Task { await extra.end(nil, dismissalPolicy:.immediate) } }
    }

    private var label: String {
        let value = dorm.trimmingCharacters(in:.whitespaces)
        return value.isEmpty || value == "未配置" ? "宿舍" : value
    }

    /// Called right before finish is sent to the water controller.
    func settling() {
        guard let activity else { return }
        var state = activity.content.state
        state.phase = .settling
        Task { await activity.update(ActivityContent(state:state, staleDate:nil)) }
    }

    /// Reconcile with the current persisted session (called from WaterModel.refresh()).
    func sync(session: WaterSession?) {
        guard let session else { return endNow() }
        switch session.stage {
        case .active, .authorizationWritePending:
            // Only a confirmed .active session creates an activity; a write-pending one may keep it.
            if session.stage == .active || activity != nil { startOrResume(session.startedAt) }
        case .closeWritePending, .settlementPending:
            // Close was sent but not confirmed (refresh only sees this after a failed finish or a relaunch).
            end(.init(startedAt:session.startedAt, phase:.unconfirmed), after:Date().addingTimeInterval(15 * 60))
        case .settled:
            guard activity != nil else { return }
            // Closed by hand after checking the official record: no duration or amount to show.
            if session.resolvedManually == true { return endNow() }
            let ended = session.endedAt ?? Date()
            let minutes = max(1, Int((ended.timeIntervalSince(session.startedAt) / 60).rounded()))
            // amountYuan comes only from the server receipt; nil means "not reported", never an estimate.
            end(.init(startedAt:session.startedAt, phase:.settled, durationMinutes:minutes,
                      amountYuan:session.receipt?.amountYuan), after:Date().addingTimeInterval(4))
        case .authorizationPending, .authorizationIssued:
            break
        }
    }

    private func startOrResume(_ startedAt: Date) {
        let state = ShowerActivityAttributes.ContentState(startedAt:startedAt, phase:.active)
        if let activity {
            // E.g. a failed finish that left the session active: show the button again.
            guard activity.content.state != state else { return }
            Task { await activity.update(ActivityContent(state:state, staleDate:nil)) }
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        activity = try? Activity.request(attributes:ShowerActivityAttributes(dorm:label),
                                         content:ActivityContent(state:state, staleDate:nil), pushType:nil)
    }

    private func end(_ state: ShowerActivityAttributes.ContentState, after date: Date) {
        guard let current = activity else { return }
        activity = nil
        Task { await current.end(ActivityContent(state:state, staleDate:nil), dismissalPolicy:.after(date)) }
    }

    private func endNow() {
        guard let current = activity else { return }
        activity = nil
        Task { await current.end(nil, dismissalPolicy:.immediate) }
    }
}
