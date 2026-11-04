import SwiftUI
import Core

extension ClearRootView {
    /// The sample on (「先看看示例」 on 学校账号, or 主题 picked in it): the checklist closes and
    /// every tab is on the sample's data (`HomeData.sample`), the washer idle, 记录 on its four
    /// weeks. Off (去登录): the live models again.
    func followSample(_ active: Bool) {
        if active {
            navigator.setup = nil; navigator.relogin = false; navigator.panel = nil
            navigator.demo = HomeData.sample()
            navigator.laundryDemo = LaundryDemo.make(.idle)
            navigator.recordsDemo = .list
            popAll()
            return
        }
        // Launched outside the sample: nothing to undo.
        guard navigator.demo != nil || navigator.laundryDemo != nil || navigator.recordsDemo != nil else { return }
        navigator.demo = nil; navigator.laundryDemo = nil; navigator.recordsDemo = nil
        navigator.panel = nil
        popAll()
    }

    /// 去登录: 学校账号 on the checklist, on this root or on the one shown after the sample's
    /// theme went.
    func openLoginAfterSample(_ due: Bool) {
        guard due, sample.takeLogin() else { return }
        // Let a closing sheet go first, otherwise the new one is not presented.
        Task { try? await Task.sleep(for:.milliseconds(600)); navigator.openSetup(at:.account) }
    }
}
