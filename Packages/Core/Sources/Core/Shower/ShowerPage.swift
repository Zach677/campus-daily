import Foundation

/// The full-screen shower page: one of seven faces, read from the session record. The record
/// (`ShowerState`, driven by `ShowerReducer`) stays the only truth about money; this only
/// decides what the page shows and which taps it takes.
public enum ShowerPagePhase: String, Sendable, Equatable, CaseIterable {
    /// Connecting to the controller and getting the authorization (nothing to end yet).
    case connecting
    /// Water may flow: 结束并结算 is the way out.
    case running
    /// The close went out or the settlement runs: nothing to tap.
    case settling
    /// Settled with an answer from the platform.
    case done
    /// The controller was not reached (or was not this dorm's): nothing was issued.
    case connectFailed
    /// The platform refused, or the controller is in use: nothing was issued.
    case denied
    /// No answer after the authorization went out: something may be charged. No retry; the
    /// user checks the school's record.
    case unsure
}

/// One of the three steps 连接 · 出水 · 结算.
public enum ShowerStepMark: String, Sendable, Equatable {
    case done, current, failed, future
}

public struct ShowerPage: Sendable, Equatable {
    /// Why the start was turned down.
    public enum Denial: Sendable, Equatable {
        /// The platform said no (its own words, when it gave any).
        case refused(String?)
        /// The controller is running for someone else.
        case inUse
    }

    public var phase: ShowerPagePhase
    /// 连接, 出水, 结算.
    public var steps: [ShowerStepMark]
    public var denial: Denial?
    /// The platform's amount; only on `done`, and only when it returned one.
    public var amount: Money?
    /// Whole minutes from start to end, on `done`.
    public var minutes: Int?
    /// The timer's start on `running`.
    public var startedAt: Date?
    /// The controller didn't confirm the authorization write; shown as running on purpose.
    public var writeUnconfirmed: Bool

    /// Nil when nothing is going on (idle): the page has nothing to show.
    public init?(_ s: ShowerState) {
        denial = nil; amount = nil; minutes = nil; startedAt = s.startedAt
        writeUnconfirmed = s.phase == .writePending
        switch s.phase {
        case .idle:
            return nil
        case .authorizing:
            phase = .connecting; steps = [.current, .future, .future]
        case .writePending, .running:
            phase = .running; steps = [.done, .current, .future]
        case .closing, .settling:
            phase = .settling; steps = [.done, .done, .current]
        case .done:
            phase = .done; steps = [.done, .done, .done]
            amount = s.receipt?.amount
            if let start = s.startedAt, let end = s.endedAt {
                minutes = max(1, Int((end.timeIntervalSince(start) / 60).rounded()))
            }
        case .failed:
            let reason = s.failure?.reason ?? .settleUnconfirmed
            switch reason {
            case .deviceUnavailable, .wrongDevice:
                phase = .connectFailed; steps = [.failed, .future, .future]
            case .deviceBusy:
                phase = .denied; steps = [.done, .failed, .future]; denial = .inUse
            case .authorizeRefused:
                phase = .denied; steps = [.done, .failed, .future]
                if case .rejected(_, _, let message)? = s.failure?.error, !message.isEmpty {
                    denial = .refused(message)
                } else {
                    denial = .refused(nil)
                }
            case .authorizeUncertain, .authorizationInvalid:
                phase = .unsure; steps = [.done, .failed, .future]
            case .closeUnconfirmed, .settleRefused, .settleUncertain, .settleUnconfirmed:
                phase = .unsure; steps = [.done, .done, .failed]
            }
            // Whatever the reason: a record that may have charged is never shown as harmless.
            if s.failure?.needsReview == true, phase != .unsure {
                phase = .unsure; denial = nil
            }
        }
    }

    /// The step being worked on or the one that failed, 1-based (for 「第 2 步，共 3 步」).
    public var stepNumber: Int {
        (steps.firstIndex { $0 == .current || $0 == .failed } ?? steps.count - 1) + 1
    }
}

/// What the user did on the page, and what the record did meanwhile.
public enum ShowerPageEvent: Sendable, Equatable {
    /// 开始洗澡 on the home screen.
    case startTapped
    /// The home button in any other state (正在洗澡, 正在结算…): back to the page as it is.
    case reopen
    /// The record changed (engine update, relaunch restore).
    case record(ShowerState)
    /// 取消 while connecting.
    case cancelTapped
    /// The engine would not cancel any more (the authorize request had left).
    case cancelRefused
    /// The start request came back (whatever its outcome, or refused before anything ran).
    case startReturned
    /// 结束并结算 (also from the lock screen while the page is open).
    case endTapped
    /// The end request came back (whatever its outcome; the record says what happened).
    case endReturned
    /// 再试一次 after a connect failure.
    case retryTapped
    /// 收起 while running.
    case collapseTapped
    /// 好 (done, denied), 取消 or × (connect failed).
    case closeTapped
    /// 去核对 (unsure).
    case reviewTapped
    /// 先回首页 (unsure): the record stays for 核对.
    case homeTapped
}

public enum ShowerPageEffect: Sendable, Equatable {
    case start
    /// Ask the engine to stop the start (`ShowerEngine.cancelStart`).
    case cancelStart
    case finish
    /// Clear a finished or harmless record (`ShowerEngine.dismiss`).
    case dismissRecord
    /// The 核对 screen.
    case openReview
}

/// The page's own state: whether it is up, and the taps still waiting on the engine.
public struct ShowerPageFlow: Sendable, Equatable {
    public var record: ShowerState
    public var presented: Bool
    /// 开始洗澡 or 再试一次 was tapped and the engine has not returned yet.
    public var starting: Bool
    /// 取消 was tapped and the engine has not answered yet / the start is winding down.
    public var cancelling: Bool
    /// 结束并结算 was tapped and the engine has not returned yet.
    public var ending: Bool
    /// 取消 came before the engine took up the start: it is sent once the start runs.
    public var cancelWaiting: Bool
    /// The engine refused this start's cancel: 取消 stays off until the next start.
    public var cancelRefused: Bool

    /// After a relaunch the page starts closed; the home button shows where the record stands.
    public init(record: ShowerState, presented: Bool = false) {
        self.record = record; self.presented = presented; starting = false; cancelling = false; ending = false
        cancelWaiting = false; cancelRefused = false
    }

    /// What the page shows. A start just tapped shows 连接 at once, before the record moves
    /// off the previous shower's result.
    public var page: ShowerPage? {
        let shown = ShowerPage(record)
        if starting, record.canStart {
            return ShowerPage(ShowerState(phase: .authorizing, startedAt: record.startedAt))
        }
        return shown
    }

    /// Swipe-down closes the page only while water runs (as 收起 does).
    public var mayCollapse: Bool { page?.phase == .running }
    public var mayCancel: Bool { page?.phase == .connecting && !cancelling && !cancelRefused }
    public var mayEnd: Bool { page?.phase == .running && record.canFinish && !ending }

    public static func reduce(_ flow: ShowerPageFlow, _ event: ShowerPageEvent) -> (ShowerPageFlow, [ShowerPageEffect]) {
        var f = flow
        switch event {
        case .startTapped:
            guard flow.record.canStart else {
                // Something is going on already: show it.
                f.presented = flow.page != nil
                return (f, [])
            }
            f.presented = true; f.starting = true; f.cancelling = false; f.ending = false
            f.cancelWaiting = false; f.cancelRefused = false
            // A finished record is cleared by the start itself.
            return (f, [.start])

        case .startReturned:
            f.starting = false
            if flow.cancelWaiting {
                // The start was refused before it ran: there is nothing left to cancel.
                f.cancelWaiting = false; f.cancelling = false
            }
            if f.presented, f.page == nil { f.presented = false }
            return (f, [])

        case .reopen:
            f.presented = flow.page != nil
            return (f, [])

        case .record(let next):
            f.record = next
            if flow.cancelWaiting {
                guard next.phase == .authorizing else { return (f, []) }
                f.cancelWaiting = false
                return (f, [.cancelStart])
            }
            if flow.cancelling, next.phase != .authorizing {
                f.cancelling = false
                if next.phase == .failed, next.failure?.needsReview == false {
                    // The start stopped as asked: back home, no failure face, no record.
                    f.presented = false
                    return (f, [.dismissRecord])
                }
            }
            if next.phase != .writePending, next.phase != .running, next.phase != .closing { f.ending = false }
            // Ended with the page down (from the lock screen or the Dynamic Island): the result
            // comes up, so the amount or the 不确定 face is seen.
            let wasOn = [ShowerPhase.writePending, .running, .closing, .settling].contains(flow.record.phase)
            if !flow.presented, wasOn, next.phase == .done || next.phase == .failed { f.presented = true }
            // Nothing left to show (resolved elsewhere, an authorization that never applied).
            if f.presented, !f.starting, f.page == nil { f.presented = false }
            return (f, [])

        case .cancelTapped:
            guard flow.mayCancel else { return (flow, []) }
            f.cancelling = true
            // Tapped before the engine took up the start: the engine would see no start to stop.
            guard flow.record.phase == .authorizing else { f.cancelWaiting = true; return (f, []) }
            return (f, [.cancelStart])

        case .cancelRefused:
            f.cancelling = false; f.cancelRefused = true
            return (f, [])

        case .endTapped:
            guard flow.mayEnd else { return (flow, []) }
            f.ending = true
            return (f, [.finish])

        case .endReturned:
            f.ending = false
            return (f, [])

        case .retryTapped:
            guard flow.page?.phase == .connectFailed, flow.record.canStart, !flow.starting else { return (flow, []) }
            f.starting = true; f.cancelRefused = false
            return (f, [.start])

        case .collapseTapped:
            guard flow.mayCollapse else { return (flow, []) }
            f.presented = false
            return (f, [])

        case .closeTapped:
            switch flow.page?.phase {
            case .done?, .denied?, .connectFailed?:
                f.presented = false
                return (f, [.dismissRecord])
            default:
                return (flow, [])
            }

        case .reviewTapped:
            guard flow.page?.phase == .unsure else { return (flow, []) }
            f.presented = false
            return (f, [.openReview])

        case .homeTapped:
            guard flow.page?.phase == .unsure else { return (flow, []) }
            f.presented = false
            return (f, [])
        }
    }
}
