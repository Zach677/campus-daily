import SwiftUI
import Core

extension ClearRootView {
    // MARK: Shower page

    /// The shower page is up and must not be left: connecting, settling, a result to answer.
    var showerLocked: Bool { shower.page.presented && !shower.page.mayCollapse }

    /// The shower model wants its page: 日常 selected, the page pushed there unless it is already
    /// on top. Whatever sheet is over the tab bar (the sign-in, the first-run checklist) closes.
    /// Called again on every start, reopen and page change.
    func followShowerPage(_ up: Bool) {
        guard up else { return }
        navigator.relogin = false; navigator.setup = nil
        showShowerPage()
    }

    func showShowerPage() {
        navigator.tab = .home
        var path = navigator.homePath
        guard path.last != .shower else { return }
        // Already lower on the stack: back to it rather than a second copy, unless that would
        // close a page being paid on.
        if let index = path.lastIndex(of:.shower), mayClosePages {
            path.removeSubrange(path.index(after:index)...)
        } else {
            path.append(.shower)
        }
        navigator.homePath = path
    }

    /// The shower page was popped (its back button, a link) while the model still has it up:
    /// while water runs that collapses it, as 暖橙's ⌄; otherwise it is put back.
    func showerPageLeft(old: [ClearRoute], new: [ClearRoute]) {
        guard old.contains(.shower), !new.contains(.shower), shower.page.presented else { return }
        if shower.page.mayCollapse { shower.pageEvent(.collapseTapped) } else { showShowerPage() }
    }

    // MARK: Pages

    /// Pages may be closed for a link or a notification tap: never a top-up page, nor the laundry
    /// page while an order is between creation and the end of the payment check, on any tab
    /// (`WidgetLink.mayClosePages`). Returning from the payment must find that page still there.
    var mayClosePages: Bool {
        let routes = navigator.homePath + navigator.recordsPath + navigator.settingsPath
        return WidgetLink.mayClosePages(rechargeOpen:routes.contains(.card) || routes.contains(.power),
                                        laundryOpen:routes.contains(.laundry), laundry:laundry.checkout?.phase)
    }

    /// 日常 showing these pages, under the shower page while that is up: as in 暖橙, they are
    /// there once it goes.
    func reveal(_ routes: [ClearRoute]) {
        let routes = shower.page.presented ? routes + [.shower] : routes
        if !shower.page.presented { navigator.tab = .home }
        navigator.homePath = routes
    }

    /// Every stack back to its root and 日常 selected (the shower page stays while it is up).
    func popAll() {
        navigator.recordsPath = []; navigator.settingsPath = []
        reveal([])
    }

    /// Another tab showing these pages; while the shower page can't be left it stays selected.
    func show(_ routes: [ClearRoute], in tab: ClearNavigator.Tab) {
        navigator.setPath(routes, tab)
        if !showerLocked { navigator.tab = tab }
    }

    /// 「去设置热水」 after an account switch: the hot-water page, or 宿舍 while there is no binding.
    func openHotWaterSetup() {
        if shower.configured { reveal([.shower]) } else { show([.dorm], in:.settings) }
    }

    /// A notification tap: the same guard as the widget's links; laundry opens its page.
    func follow(_ route: Reminders.Route) {
        guard mayClosePages else { return }
        navigator.recordsPath = []; navigator.settingsPath = []
        reveal(route == .laundry ? [.laundry] : [])
    }

    /// Nothing over home: 日常 at its root, no sheet or shower page, app in front.
    var homeClear: Bool {
        var clear = phase == .active && navigator.tab == .home && navigator.homePath.isEmpty
            && navigator.setup == nil && !navigator.relogin && navigator.panel == nil && !shower.page.presented
        #if DEBUG
        clear = clear && activityPreview == nil && widgetPreview == nil
        #endif
        return clear
    }

    /// Reset finished: back to the first-run checklist as on a fresh install, no toast.
    func afterReset() {
        navigator.setup = nil; navigator.relogin = false; navigator.panel = nil
        #if DEBUG
        navigator.demo = nil; navigator.laundryDemo = nil; navigator.recordsDemo = nil
        #endif
        popAll()
        successTick += 1
        // Let a closing sheet go first, otherwise the new one is not presented.
        Task { try? await Task.sleep(for:.milliseconds(600)); navigator.openSetup() }
    }

    func presentLaundryDone(_ done: HomeData.LaundryDone?) {
        #if DEBUG
        if navigator.demo != nil { return }
        #endif
        guard let done, done.id != laundryDoneShown, navigator.panel == nil else { return }
        laundryDoneShown = done.id
        successTick += 1
        navigator.panel = .laundryDone(amount:done.amount, detail:done.detail)
    }

    // MARK: Links

    /// The widget's links (`RootLink`); anything else is a DEBUG demo.
    func open(_ url: URL) {
        if let link = RootLink(url) {
            guard mayClosePages else { return }
            switch link {
            case .home: popAll(); return
            // A paused automatic login (widget): 设置 › 学校账号, where the pause is explained.
            case .settings(account:true): show([.account], in:.settings); return
            case .login:
                popAll()
                navigator.openSetup(at:.account)
                return
            case .settings(account:false): break
            }
        }
        #if DEBUG
        handleDemo(url)
        #endif
    }
}
