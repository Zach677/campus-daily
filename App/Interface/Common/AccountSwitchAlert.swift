import SwiftUI

/// After a login turned out to be a different person (B2): the old school data, and maybe the
/// hot-water binding, were cleared. Shown once, by the top-most screen.
struct AccountSwitchNotice: Equatable, Identifiable {
    let id = UUID()
    /// The hot-water binding was the previous person's and was removed.
    var hotWaterCleared: Bool

    // Copy: Camo campus-r3-flow-copy 「第二段审查 B2」.
    static let title = "换了账号，上一个账号的宿舍和电表已经清掉。"
    static let hotWater = "热水要重新设置。"
    static let openHotWater = "去设置热水"
}

/// Screens that may show the account-switch alert register here; only the last one shows it.
/// A login sheet registers as a blocker, so the alert waits until the sheet has closed and then
/// appears on the screen the login returned to.
@MainActor final class AccountNoticeHosts: ObservableObject {
    static let shared = AccountNoticeHosts()
    struct Host: Equatable { let id: UUID; let blocks: Bool }
    @Published private(set) var stack: [Host] = []
    func add(_ id: UUID, blocks: Bool) { stack.removeAll { $0.id == id }; stack.append(Host(id:id, blocks:blocks)) }
    func remove(_ id: UUID) { stack.removeAll { $0.id == id } }
    func isTop(_ id: UUID) -> Bool { stack.last?.id == id && stack.last?.blocks == false }
}

private struct AccountSwitchAlert: ViewModifier {
    /// 「去设置热水」 from this screen; nil = this screen is a login sheet (blocks, shows nothing).
    let openHotWater: (() -> Void)?
    @EnvironmentObject private var campus: CampusModel
    @ObservedObject private var hosts = AccountNoticeHosts.shared
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { hosts.add(id, blocks:openHotWater == nil) }
            .onDisappear { hosts.remove(id) }
            .alert(AccountSwitchNotice.title, isPresented:presented, presenting:campus.switchNotice) { notice in
                if notice.hotWaterCleared, let openHotWater {
                    // No .defaultAction: on iOS 27 it becomes a blue fill that the accent tint can't read on.
                    Button(AccountSwitchNotice.openHotWater) { campus.switchNotice = nil; openHotWater() }
                    Button("好", role:.cancel) { campus.switchNotice = nil }
                } else {
                    Button("好") { campus.switchNotice = nil }
                }
            } message: { notice in
                if notice.hotWaterCleared { Text(AccountSwitchNotice.hotWater) }
            }
    }

    private var presented: Binding<Bool> {
        Binding(get:{ campus.switchNotice != nil && openHotWater != nil && hosts.isTop(id) },
                // Only the buttons clear it: a presentation that failed (a sheet still closing)
                // also reports false here, and the notice must survive for the next screen.
                set:{ _ in })
    }
}

extension View {
    /// This screen may show the account-switch alert (when nothing is presented above it).
    func accountSwitchAlert(openHotWater: @escaping () -> Void) -> some View {
        modifier(AccountSwitchAlert(openHotWater:openHotWater))
    }
    /// A login sheet: the account-switch alert waits until it has closed.
    func holdsAccountSwitchAlert() -> some View { modifier(AccountSwitchAlert(openHotWater:nil)) }
}
