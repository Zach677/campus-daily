import SwiftUI
import Core

/// `nav.open` for a page, in both themes: which page and from where (`DebugPage`/`DebugEntry`),
/// never what is on it. A way in that isn't a tap (a widget link, a notification, a Shortcut,
/// the Live Activity) says so first (`DebugNav.from`), and that entry wins over `entry`.
/// Off outside TestFlight and in the sample (their `debugLog` is `NoDebugLog`).
private struct DebugNavOpen: ViewModifier {
    let page: DebugPage
    let entry: DebugEntry
    /// Once per page shown (a pushed page is new each push); false: each time it appears (tabs).
    let once: Bool
    @Environment(\.campusServices) private var services
    @State private var logged = false

    func body(content: Content) -> some View {
        content.onAppear {
            guard !(once && logged) else { return }
            logged = true
            services.debugNav.opened(page, default:entry)
        }
    }
}

extension View {
    func navOpen(_ page: DebugPage, from entry: DebugEntry, once: Bool = true) -> some View {
        modifier(DebugNavOpen(page:page, entry:entry, once:once))
    }
}

extension HomeRoute {
    var debugPage: DebugPage {
        switch self {
        case .power: return .power
        case .powerSetup: return .powerSetup
        case .card: return .cardTopUp
        case .shower: return .showerDetail
        case .laundry: return .laundry
        case .washerSetup: return .washerSetup
        case .records: return .cardRecords
        }
    }
}

extension ClearRoute {
    var debugPage: DebugPage {
        switch self {
        case .shower: return .showerPage
        case .laundry: return .laundry
        case .washerSetup: return .washerSetup
        case .power: return .power
        case .powerSetup: return .powerSetup
        case .card: return .cardTopUp
        case .account: return .account
        case .dorm: return .dorm
        case .theme: return .theme
        case .advanced: return .advanced
        case .setupChecklist: return .setupChecklist
        }
    }
}

extension ClearNavigator.Tab {
    /// A page pushed on this tab's stack came from it.
    var debugEntry: DebugEntry {
        switch self {
        case .home: return .homeButton
        case .records: return .cardRecords
        case .settings: return .settings
        }
    }
    var debugPage: DebugPage {
        switch self {
        case .home: return .home
        case .records: return .records
        case .settings: return .settings
        }
    }
}

extension SettingsLink {
    var debugPage: DebugPage {
        switch self {
        case .account: return .account
        case .dorm: return .dorm
        case .meter: return .powerSetup
        case .hotWater: return .showerDetail
        case .washer: return .washerSetup
        case .theme: return .theme
        }
    }
}
