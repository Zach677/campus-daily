import Foundation
import WaterCore

/// Everything the laundry page and the home 🧺 row read, from the model or DEBUG demo data.
/// Pure value: deriving a phase never triggers a request.
struct LaundryFacts {
    var configured = false
    var snapshot: LaundrySnapshot?
    /// Local checkout record for the selected machine (any stage).
    var record: LaundryCheckoutRecord?
    var busy = false
    var progress: String?
    var issue: String?
    var checkoutIssue: String?
    var loading = false
    var mayCreate = false
    var mayCancel = false

    @MainActor init(model: LaundryModel) {
        configured = model.configured; snapshot = model.snapshot; record = model.checkout
        busy = model.checkoutBusy; progress = model.checkoutProgress
        issue = model.issue; checkoutIssue = model.checkoutIssue; loading = model.loading
        mayCreate = model.mayCreate; mayCancel = model.mayCancel
    }
    init() {}

    enum Unavailable: Equatable { case offline, broken, disabled }

    enum Phase: Equatable {
        /// No machine saved.
        case empty
        /// Machine saved, nothing read yet.
        case unknown
        case idle
        case inUse
        case unavailable(Unavailable)
        /// Order created, not paid. `payable` only while the stage still allows a payment request.
        case unpaid(payable: Bool)
        /// Paid, machine not running yet (status 20 or no remaining time).
        case starting
        case running(end: Date)
        /// Result not confirmed. `failedStart` = order 52.
        case check(failedStart: Bool)
        /// Order 50 seen recently.
        case done
    }

    /// Recent terminal outcomes still worth showing (3 hours after ordering).
    private func recent(_ record: LaundryCheckoutRecord, now: Date) -> Bool {
        now.timeIntervalSince(record.createdAt) < 3 * 3600
    }

    func phase(now: Date = Date(), acknowledgedFailure: String? = nil) -> Phase {
        guard configured else { return .empty }
        if let record, record.stage != .completed {
            switch record.stage {
            case .creating, .cancellationRequested: return .check(failedStart:false)
            case .completed: break
            case .created, .paymentRequested:
                guard let order = record.order else { return .check(failedStart:false) }
                if order.running {
                    if let seconds = order.remainTime, seconds > 0 {
                        return .running(end:(record.orderUpdatedAt ?? now).addingTimeInterval(TimeInterval(seconds)))
                    }
                    return .starting
                }
                if order.paid { return .starting }
                if ["10","17"].contains(order.status.text), order.payFlag?.text == "0" {
                    return .unpaid(payable:record.stage == .created)
                }
                return .check(failedStart:false)
            }
        }
        if let record, record.stage == .completed, let order = record.order, recent(record, now:now) {
            if order.status.text == "52", acknowledgedFailure != record.orderId { return .check(failedStart:true) }
            // 「刚刚洗完」 until ~30 minutes after the program would have ended.
            let window = TimeInterval(((recordProgram?.time ?? 60) + 30) * 60)
            if order.status.text == "50", now.timeIntervalSince(record.createdAt) < window { return snapshotPhase(doneFallback:true) }
        }
        return snapshotPhase(doneFallback:false)
    }

    private func snapshotPhase(doneFallback: Bool) -> Phase {
        guard let snapshot else { return doneFallback ? .done : .unknown }
        if doneFallback, snapshot.status == 0 { return .done }
        switch snapshot.status {
        case 8: return .unavailable(.offline)
        case 2: return .unavailable(.broken)
        case 7, 9: return .unavailable(.disabled)
        default: break
        }
        if snapshot.status == 0, snapshot.createOrderEnabled, snapshot.activeOrderId == nil { return .idle }
        if snapshot.status == 0, !snapshot.createOrderEnabled, snapshot.activeOrderId == nil { return .unavailable(.disabled) }
        return .inUse
    }

    /// Order id of a recently finished (50) order, for the once-per-order done panel.
    func doneOrderID(now: Date = Date()) -> String? {
        guard let record, record.stage == .completed, record.order?.status.text == "50", recent(record, now:now) else { return nil }
        return record.orderId
    }

    /// One-line note after a recent 51/52/53 (page shows idle plus this line).
    func outcomeNote(now: Date = Date()) -> String? {
        guard let record, record.stage == .completed, let status = record.order?.status.text, recent(record, now:now) else { return nil }
        switch status {
        case "51": return "上一笔订单付款超时，已经取消了。"
        case "52": return "机器没启动。去 U净 的订单里看看有没有扣款。"
        case "53": return "上一笔订单已取消。"
        default: return nil
        }
    }

    var machine: String? {
        guard let snapshot else { return nil }
        if let record, record.deviceId != snapshot.deviceId { return nil }
        return snapshot.deviceNo
    }
    var store: String? { snapshot.map(\.storeName).flatMap { $0.isEmpty ? nil : $0 } }
    /// Program of the current record, as listed by the machine (for its duration).
    var recordProgram: LaundryProgram? {
        guard let record else { return nil }
        return snapshot?.programs.first { $0.id == record.programId }
    }
    var amount: Decimal? { record.map { $0.order?.payPrice ?? $0.expectedPrice } }
}

enum LaundryFormat {
    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier:"en_US_POSIX"); formatter.dateFormat = "HH:mm"
        return formatter.string(from:date)
    }
    static func spokenClock(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.hour,.minute], from:date)
        return "\(parts.hour ?? 0) 点 \(parts.minute ?? 0) 分"
    }
    /// ceil(remaining / 60), never below 1 while running.
    static func minutesLeft(until end: Date, now: Date = Date()) -> Int {
        max(1, Int((end.timeIntervalSince(now) / 60).rounded(.up)))
    }
    static func machine(_ number: String) -> String { "\(number) 号机" }
    static func program(_ program: LaundryProgram) -> String { "\(program.workModelName) · \(program.time) 分钟" }
    static func spokenYuan(_ value: Decimal) -> String { Theme.yuan(value).dropFirst() + " 元" }
}
