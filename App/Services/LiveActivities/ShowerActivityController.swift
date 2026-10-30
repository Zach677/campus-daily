import Foundation
import ActivityKit
import Core

/// Mirrors `ShowerState` into a single Live Activity.
/// Driven from WaterModel (engine updates); never talks to the water controller itself.
@MainActor final class ShowerActivityController {
    static let shared = ShowerActivityController()
    /// Short dorm label shown on the activity; set by the app from CampusModel.room.
    var dorm = ""
    private var activity: Activity<ShowerActivityAttributes>?
    private init() {
        // Reuse an activity left over from a previous launch; drop any duplicates.
        let existing = Activity<ShowerActivityAttributes>.activities.filter { $0.activityState == .active }
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

    /// Reconcile with the engine's current state.
    func sync(state: ShowerState) {
        switch state.phase {
        case .idle:
            // Dismissed, or closed by hand after checking the official record: nothing to show.
            endNow()
        case .authorizing:
            break
        case .writePending, .running:
            // Write-pending shows as 洗澡中 too (water may be running), with the unconfirmed line.
            guard let started = state.startedAt else { return }
            startOrResume(started, writeUnconfirmed:state.phase == .writePending)
        case .closing, .settling:
            guard let started = state.startedAt, var next = activity?.content.state else { return }
            next.startedAt = started; next.phase = .settling
            if let activity, activity.content.state != next {
                Task { await activity.update(ActivityContent(state:next, staleDate:nil)) }
            }
        case .done:
            guard activity != nil, let started = state.startedAt else { return endNow() }
            let ended = state.endedAt ?? Date()
            let minutes = max(1, Int((ended.timeIntervalSince(started) / 60).rounded()))
            // amountYuan comes only from the platform receipt; nil means "not reported", never an estimate.
            end(.init(startedAt:started, phase:.settled, durationMinutes:minutes,
                      amountYuan:state.receipt?.amount?.yuan), after:Date().addingTimeInterval(4))
        case .failed:
            guard let started = state.startedAt else { return endNow() }
            end(.init(startedAt:started, phase:.unconfirmed), after:Date().addingTimeInterval(15 * 60))
        }
    }

    private func startOrResume(_ startedAt: Date, writeUnconfirmed: Bool = false) {
        let state = ShowerActivityAttributes.ContentState(startedAt:startedAt, phase:.active,
                                                          writeUnconfirmed:writeUnconfirmed ? true : nil)
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
