import Foundation

// Hot-water session state machine (architecture §3.1). Pure: the engine persists the state a
// transition returns *before* running its effects, so every side effect is guarded by a
// stored record of "this may have happened".

public enum ShowerPhase: String, Sendable, Codable, CaseIterable {
    case idle, authorizing, writePending, running, closing, settling, done, failed
}

/// What the BLE side can report. Codable so a failure can be stored and shown after relaunch.
public enum ShowerDeviceError: String, Error, Sendable, Codable, Equatable {
    case bluetoothOff
    case notFound
    case ambiguous
    case timedOut
    case disconnected
    case malformedFrame
    case interrupted
    case busy
}

public enum ShowerFailureReason: String, Sendable, Codable, Equatable {
    /// BLE connect/probe failed before anything was sent to the server.
    case deviceUnavailable
    /// The controller answered with another machine id (before authorize).
    case wrongDevice
    /// The controller reported itself in use (`A5`) before authorize.
    case deviceBusy
    /// The server definitely refused the authorization: nothing issued.
    case authorizeRefused
    /// Authorization outcome unknown (transport/unreadable reply): may exist server-side.
    case authorizeUncertain
    /// Server said OK but the authorization is unusable (other machine, bad payload/id).
    case authorizationInvalid
    /// Close was sent but no valid consumption frame came back.
    case closeUnconfirmed
    /// Settlement explicitly refused.
    case settleRefused
    /// Settlement outcome unknown.
    case settleUncertain
    /// The app stopped while settling (relaunch) or before the request left: "结算待核对".
    case settleUnconfirmed
}

public struct ShowerFailure: Sendable, Codable, Equatable {
    public var reason: ShowerFailureReason
    /// True when something may have been issued or charged: only `resolveManually` (after the
    /// user checked the official record) clears it, and `start` stays blocked.
    public var needsReview: Bool
    public var error: ServiceError?
    public var deviceError: ShowerDeviceError?
    public init(reason: ShowerFailureReason, needsReview: Bool, error: ServiceError? = nil, deviceError: ShowerDeviceError? = nil) {
        self.reason = reason; self.needsReview = needsReview; self.error = error; self.deviceError = deviceError
    }
}

/// A non-fatal problem during an otherwise unchanged phase (e.g. 结束 tapped but the controller
/// did not answer). Shown once; the session itself is kept.
public enum ShowerNotice: Sendable, Codable, Equatable {
    case device(ShowerDeviceError)
    /// The probe showed the controller idle with our identity while we think it runs.
    case notActive
    /// The controller answered with another machine id.
    case wrongDevice
    /// The authorization write was answered with something other than the ack.
    case writeUnconfirmed
}

public struct ShowerState: Sendable, Codable, Equatable {
    public var phase: ShowerPhase
    public var machineID: String?
    /// The controller this session talks to; finish/review never use another one.
    public var peripheralID: String?
    /// Display only (timer); never used for billing.
    public var startedAt: Date?
    /// Persisted right before the authorize request leaves.
    public var authorizeSent: Bool
    public var authorizationID: String?
    /// The phase `finish` came from (to go back if the close is not sent).
    public var closingFrom: ShowerPhase?
    /// Persisted right before the close command is written.
    public var closeSent: Bool
    /// Upper-hex consumption frame to settle.
    public var consumption: String?
    public var receipt: WaterReceipt?
    public var lastReceipt: WaterReceipt?
    public var failure: ShowerFailure?
    /// The device contradicted the record (probe idle while "running"): kept for review.
    public var stateReviewRequired: Bool
    /// A review probe is in flight (phase unchanged).
    public var reviewing: Bool
    /// First tap of a manual settle retry; the second confirmation sends it.
    public var settleRetryArmed: Bool
    /// Manual settle retries made (diagnostics: idempotency unknown, G2).
    public var manualSettleAttempts: Int
    public var endedAt: Date?
    public var notice: ShowerNotice?

    public init(phase: ShowerPhase = .idle, machineID: String? = nil, peripheralID: String? = nil, startedAt: Date? = nil,
                authorizeSent: Bool = false, authorizationID: String? = nil, closingFrom: ShowerPhase? = nil,
                closeSent: Bool = false, consumption: String? = nil, receipt: WaterReceipt? = nil,
                lastReceipt: WaterReceipt? = nil, failure: ShowerFailure? = nil, stateReviewRequired: Bool = false,
                reviewing: Bool = false, settleRetryArmed: Bool = false, manualSettleAttempts: Int = 0,
                endedAt: Date? = nil, notice: ShowerNotice? = nil) {
        self.phase = phase; self.machineID = machineID; self.peripheralID = peripheralID; self.startedAt = startedAt
        self.authorizeSent = authorizeSent; self.authorizationID = authorizationID; self.closingFrom = closingFrom
        self.closeSent = closeSent; self.consumption = consumption; self.receipt = receipt; self.lastReceipt = lastReceipt
        self.failure = failure; self.stateReviewRequired = stateReviewRequired; self.reviewing = reviewing
        self.settleRetryArmed = settleRetryArmed; self.manualSettleAttempts = manualSettleAttempts
        self.endedAt = endedAt; self.notice = notice
    }

    public static let idle = ShowerState()

    /// `start` is allowed only from idle, done, or a failure that issued nothing.
    public var canStart: Bool {
        switch phase {
        case .idle, .done: return true
        case .failed: return failure?.needsReview == false
        default: return false
        }
    }

    public var canFinish: Bool { (phase == .writePending || phase == .running) && !reviewing }

    public var canResolveManually: Bool {
        (phase == .failed && failure?.needsReview == true)
            || ((phase == .writePending || phase == .running) && stateReviewRequired && !reviewing)
    }

    public var canRetrySettle: Bool {
        phase == .failed && failure?.needsReview == true && consumption != nil
            && [ShowerFailureReason.settleRefused, .settleUncertain, .settleUnconfirmed].contains { $0 == failure?.reason }
    }

    /// The reminder ("还没结束洗澡？") runs while water may be flowing.
    public var mayBeFlowing: Bool { phase == .writePending || phase == .running }

    /// What goes to the Keychain. A failure that issued nothing leaves no record.
    public var persistable: ShowerState {
        var s = self
        s.notice = nil
        s.reviewing = false
        if phase == .failed, failure?.needsReview == false {
            return idleAfter(receipt: lastReceipt)
        }
        return s
    }

    fileprivate func idleAfter(receipt: WaterReceipt?) -> ShowerState {
        ShowerState(phase: .idle, machineID: machineID, peripheralID: peripheralID, lastReceipt: receipt)
    }
}

public enum ShowerEvent: Sendable, Equatable {
    case start(machineID: String, preferredPeripheral: String?, at: Date)
    /// Connected and probed (`AA`) before authorize.
    case connected(peripheralID: String, probe: Data)
    case connectFailed(ShowerDeviceError)
    case authorized(WaterAuthorization)
    case authorizeFailed(ServiceError)
    case writeReplied(Data)
    case writeFailed(ShowerDeviceError)
    case finish
    case review
    case probeReplied(Data)
    case probeFailed(ShowerDeviceError)
    case closeReplied(Data)
    case closeFailed(ShowerDeviceError)
    case settled(WaterReceipt, at: Date)
    case settleFailed(ServiceError)
    /// The task was cancelled after the state was persisted but before the request/write left.
    case cancelledBeforeSend
    case requestSettleRetry
    case confirmSettleRetry
    case resolveManually
    case dismiss
}

public enum ShowerEffect: Sendable, Equatable {
    /// Connect to the controller (preferring `preferred`), then write `AA` → `.connected`/`.connectFailed`.
    case connectAndProbe(machineID: String, preferred: String?)
    /// POST authorize with the identity frame → `.authorized`/`.authorizeFailed`.
    case authorize(frame: Data)
    /// Write the 15-byte authorization → `.writeReplied`/`.writeFailed`.
    case writeAuthorization(Data)
    /// Connect to exactly `peripheralID` and write `AA` → `.probeReplied`/`.probeFailed`.
    case probe(peripheralID: String?)
    /// Write the close command → `.closeReplied`/`.closeFailed`.
    case sendClose(Data)
    /// POST settle with the consumption frame → `.settled`/`.settleFailed`. Never emitted automatically twice.
    case settle(frame: Data)
    case releaseDevice
    case scheduleReminder
    case cancelReminder
    case diagnostic(String)
}

public enum ShowerReducer {
    /// Errors that are a definite "no" from the service (nothing was issued/charged).
    public static func isDefiniteRefusal(_ e: ServiceError) -> Bool {
        switch e {
        case .rejected, .badRequest, .sessionExpired: return true
        default: return false
        }
    }

    public static func reduce(_ state: ShowerState, _ event: ShowerEvent) -> (ShowerState, [ShowerEffect]) {
        var s = state
        s.notice = nil
        switch (state.phase, event) {

        // MARK: start
        case (_, .start(let machine, let preferred, let at)) where state.canStart:
            let n = ShowerState(phase: .authorizing, machineID: machine.uppercased(), peripheralID: nil, startedAt: at,
                                lastReceipt: state.phase == .done ? state.receipt : state.lastReceipt)
            return (n, [.connectAndProbe(machineID: machine.uppercased(), preferred: preferred)])

        case (.authorizing, .connected(let peripheral, let probe)) where !state.authorizeSent:
            s.peripheralID = peripheral
            switch WaterFrames.classify(probe) {
            case .idle(let id) where id == state.machineID:
                s.authorizeSent = true
                return (s, [.authorize(frame: probe)])
            case .idle:
                return (failed(s, .wrongDevice, review: false), [.releaseDevice])
            case .active:
                return (failed(s, .deviceBusy, review: false), [.releaseDevice])
            case .unreadable:
                return (failed(s, .deviceUnavailable, review: false, device: .malformedFrame), [.releaseDevice])
            }

        case (.authorizing, .connectFailed(let e)) where !state.authorizeSent:
            return (failed(s, .deviceUnavailable, review: false, device: e), [.releaseDevice])

        case (.authorizing, .cancelledBeforeSend) where state.authorizeSent:
            // Persisted "sent" but the request never left: nothing issued.
            s.authorizeSent = false
            return (failed(s, .deviceUnavailable, review: false, device: .interrupted), [.releaseDevice])

        case (.authorizing, .authorized(let auth)) where state.authorizeSent:
            guard auth.machineID.uppercased() == state.machineID,
                  auth.payload.count == WaterFrames.authorizationLength,
                  WaterFrames.closeCommand(authorizationID: auth.authorizationID) != nil else {
                return (failed(s, .authorizationInvalid, review: true), [.releaseDevice])
            }
            s.phase = .writePending
            s.authorizationID = auth.authorizationID.uppercased()
            return (s, [.scheduleReminder, .writeAuthorization(auth.payload)])

        case (.authorizing, .authorizeFailed(let e)) where state.authorizeSent:
            if isDefiniteRefusal(e) {
                return (failed(s, .authorizeRefused, review: false, error: e), [.releaseDevice])
            }
            return (failed(s, .authorizeUncertain, review: true, error: .uncertain(.lxt6)), [.releaseDevice])

        // MARK: authorization write
        case (.writePending, .writeReplied(let frame)) where !state.reviewing:
            if WaterFrames.isAck(frame) {
                s.phase = .running
                // The official client keeps the link after authorization.
                return (s, [])
            }
            s.notice = .writeUnconfirmed
            return (s, [.releaseDevice])

        case (.writePending, .writeFailed(let e)):
            s.notice = .device(e)
            return (s, [.releaseDevice])

        // MARK: finish / review
        case (.writePending, .finish), (.running, .finish):
            guard state.canFinish else { return (state, []) }
            s.phase = .closing
            s.closingFrom = state.phase
            s.closeSent = false
            return (s, [.probe(peripheralID: state.peripheralID)])

        case (.writePending, .review), (.running, .review):
            guard !state.reviewing else { return (state, []) }
            s.reviewing = true
            return (s, [.probe(peripheralID: state.peripheralID)])

        case (.writePending, .probeReplied(let frame)), (.running, .probeReplied(let frame)):
            guard state.reviewing else { return (state, []) }
            s.reviewing = false
            switch WaterFrames.classify(frame) {
            case .active:
                s.phase = .running
                s.stateReviewRequired = false
                return (s, [])
            case .idle(let id) where id == state.machineID:
                s.stateReviewRequired = true
                s.notice = .notActive
            case .idle:
                s.notice = .wrongDevice
            case .unreadable:
                s.notice = .device(.malformedFrame)
            }
            return (s, [.releaseDevice])

        case (.writePending, .probeFailed(let e)), (.running, .probeFailed(let e)):
            guard state.reviewing else { return (state, []) }
            s.reviewing = false
            s.notice = .device(e)
            return (s, [.releaseDevice])

        case (.closing, .probeReplied(let frame)) where !state.closeSent:
            let from = state.closingFrom ?? .running
            switch WaterFrames.classify(frame) {
            case .active:
                guard let id = state.authorizationID, let command = WaterFrames.closeCommand(authorizationID: id) else {
                    return (back(s, to: from, notice: .writeUnconfirmed), [.releaseDevice])
                }
                s.closeSent = true
                s.stateReviewRequired = false
                return (s, [.sendClose(command)])
            case .idle(let id) where id == state.machineID:
                if from == .writePending {
                    // The authorization never took effect: no water, no charge.
                    return (state.idleAfter(receipt: state.lastReceipt), [.cancelReminder, .releaseDevice, .diagnostic("finish.writeNeverApplied")])
                }
                var b = back(s, to: from, notice: .notActive)
                b.stateReviewRequired = true
                return (b, [.releaseDevice])
            case .idle:
                return (back(s, to: from, notice: .wrongDevice), [.releaseDevice])
            case .unreadable:
                return (back(s, to: from, notice: .device(.malformedFrame)), [.releaseDevice])
            }

        case (.closing, .probeFailed(let e)) where !state.closeSent:
            return (back(s, to: state.closingFrom ?? .running, notice: .device(e)), [.releaseDevice])

        case (.closing, .cancelledBeforeSend) where state.closeSent:
            s.closeSent = false
            return (back(s, to: state.closingFrom ?? .running, notice: .device(.interrupted)), [.releaseDevice])

        case (.closing, .closeReplied(let frame)) where state.closeSent:
            guard WaterFrames.identity(frame) == state.machineID else {
                return (failed(s, .closeUnconfirmed, review: true, device: .malformedFrame), [.cancelReminder, .releaseDevice])
            }
            s.phase = .settling
            s.consumption = HexCoding.upper(frame)
            return (s, [.cancelReminder, .releaseDevice, .settle(frame: frame)])

        case (.closing, .closeFailed(let e)) where state.closeSent:
            return (failed(s, .closeUnconfirmed, review: true, device: e), [.cancelReminder, .releaseDevice])

        // MARK: settle
        case (.settling, .settled(let receipt, let at)):
            s.phase = .done
            s.receipt = receipt
            s.lastReceipt = receipt
            s.endedAt = at
            s.failure = nil
            return (s, [])

        case (.settling, .settleFailed(let e)):
            let reason: ShowerFailureReason = isDefiniteRefusal(e) ? .settleRefused : .settleUncertain
            return (failed(s, reason, review: true, error: e), [])

        case (.settling, .cancelledBeforeSend):
            return (failed(s, .settleUnconfirmed, review: true), [])

        case (.failed, .requestSettleRetry) where state.canRetrySettle:
            s.settleRetryArmed = true
            return (s, [])

        case (.failed, .confirmSettleRetry) where state.canRetrySettle && state.settleRetryArmed:
            guard let hex = state.consumption, let frame = HexCoding.data(hex) else { return (state, []) }
            s.phase = .settling
            s.settleRetryArmed = false
            s.manualSettleAttempts += 1
            s.failure = nil
            return (s, [.diagnostic("settle.manualRetry#\(s.manualSettleAttempts)"), .settle(frame: frame)])

        // MARK: leaving
        case (_, .resolveManually) where state.canResolveManually:
            return (state.idleAfter(receipt: state.lastReceipt), [.cancelReminder, .releaseDevice, .diagnostic("resolvedManually.\(state.phase.rawValue)")])

        case (.done, .dismiss):
            return (state.idleAfter(receipt: state.receipt), [])

        case (.failed, .dismiss) where state.failure?.needsReview == false:
            return (state.idleAfter(receipt: state.lastReceipt), [])

        default:
            return (state, [])
        }
    }

    /// Relaunch: what a persisted record means now. Nothing is re-sent automatically.
    public static func restore(_ persisted: ShowerState?) -> ShowerState {
        guard var s = persisted else { return .idle }
        s.notice = nil
        s.reviewing = false
        s.settleRetryArmed = false
        switch s.phase {
        case .idle, .done, .writePending, .running:
            return s
        case .failed:
            return s.failure?.needsReview == false ? s.idleAfter(receipt: s.lastReceipt) : s
        case .authorizing:
            // Not sent: nothing issued. Sent: the authorization may exist.
            return s.authorizeSent ? failed(s, .authorizeUncertain, review: true, error: .uncertain(.lxt6))
                                   : s.idleAfter(receipt: s.lastReceipt)
        case .closing:
            if s.closeSent { return failed(s, .closeUnconfirmed, review: true, device: .interrupted) }
            return back(s, to: s.closingFrom ?? .running, notice: nil)
        case .settling:
            return failed(s, .settleUnconfirmed, review: true)
        }
    }

    private static func failed(_ s: ShowerState, _ reason: ShowerFailureReason, review: Bool,
                               error: ServiceError? = nil, device: ShowerDeviceError? = nil) -> ShowerState {
        var f = s
        f.phase = .failed
        f.reviewing = false
        f.settleRetryArmed = false
        f.failure = ShowerFailure(reason: reason, needsReview: review, error: error, deviceError: device)
        return f
    }

    private static func back(_ s: ShowerState, to phase: ShowerPhase, notice: ShowerNotice?) -> ShowerState {
        var b = s
        b.phase = phase
        b.closingFrom = nil
        b.closeSent = false
        b.notice = notice
        return b
    }
}

// MARK: - Presentation (UI + Live Activity mirror)

public struct ShowerDisplay: Sendable, Equatable {
    public enum Phase: String, Sendable, Codable { case idle, starting, running, ending, settling, done, failed }
    public var phase: Phase
    public var title: String
    public var hint: String?
    public var startedAt: Date?
    /// The controller did not confirm the authorization write (shown as running on purpose).
    public var writeUnconfirmed: Bool
    public var amountYuan: String?
    public var needsReview: Bool

    public static let writeUnconfirmedHint = "水控没回应，有热水就照常洗"

    public init(_ s: ShowerState) {
        startedAt = s.startedAt
        writeUnconfirmed = s.phase == .writePending
        amountYuan = nil
        hint = nil
        needsReview = s.failure?.needsReview ?? false
        switch s.phase {
        case .idle: phase = .idle; title = "开水"
        case .authorizing: phase = .starting; title = "正在开水…"
        case .writePending: phase = .running; title = "洗澡中"; hint = Self.writeUnconfirmedHint
        case .running: phase = .running; title = "洗澡中"
        case .closing: phase = .ending; title = "正在结束…"
        case .settling: phase = .settling; title = "正在结算…"
        case .done:
            phase = .done
            amountYuan = s.receipt?.amount?.yuanText
            title = amountYuan.map { "本次 ¥\($0)" } ?? "已结算"
        case .failed:
            phase = .failed
            title = Self.failureTitle(s.failure)
            if needsReview { hint = "去看热水记录" }
        }
    }

    public static func failureTitle(_ f: ShowerFailure?) -> String {
        guard let f else { return "出了点问题" }
        switch f.reason {
        case .deviceUnavailable: return "没连上水控，靠近一点再试。"
        case .wrongDevice: return "这不是你宿舍的水控。"
        case .deviceBusy: return "水控正在使用中。"
        case .authorizeRefused:
            if case .rejected(_, _, let m)? = f.error, !m.isEmpty { return m }
            return "热水平台没同意开水。"
        case .authorizeUncertain, .authorizationInvalid: return "开水结果未确认"
        case .closeUnconfirmed: return "结束指令未确认"
        case .settleRefused, .settleUncertain: return "结算未确认"
        case .settleUnconfirmed: return "结算待核对"
        }
    }
}
