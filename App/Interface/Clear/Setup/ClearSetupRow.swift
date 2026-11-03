import Foundation

/// A row of 清爽's 首次设置 checklist, in order. The checklist can open with one of them pushed
/// (campusdaily://login opens `.account`).
enum ClearSetupRow: Hashable, CaseIterable {
    /// 学校账号.
    case account
    /// 宿舍.
    case dorm
    /// 学校洗衣机.
    case laundry
    /// 水控 (only when a controller is bound).
    case controller
}
