import SwiftUI
import Core

/// 「10:32 更新」, 「正在更新…」 or, after a failed read, 「没更新上，下拉再试 · 数字是 10:32 的」;
/// an expired login says 「登录过期了，点这里重新登录 · …」 and opens the sign-in on tap.
struct HomeUpdateLineView: View {
    let line: HomeUpdateLine
    var now = Date()
    var signIn: () -> Void = {}

    var body: some View {
        let text = line.text(now:now, calendar:.current) ?? ""
        switch line {
        case .hidden:
            EmptyView()
        case .refreshing:
            HStack(spacing:6) {
                ProgressView().controlSize(.mini).frame(width:12, height:12).accessibilityHidden(true)
                Text(text)
            }
            .scaledFont(13, relativeTo:.footnote).foregroundStyle(Theme.ink2)
            .accessibilityElement(children:.combine)
        case .updated:
            Text(text).scaledFont(13, relativeTo:.footnote).foregroundStyle(Theme.ink2)
        case .failed:
            problem(text)
        case .expired:
            Button(action:signIn) { problem(text).contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("homeLoginExpired")
        }
    }

    func problem(_ text: String) -> some View {
        HStack(alignment:.firstTextBaseline, spacing:5) {
            Image(systemName:"exclamationmark.circle.fill").accessibilityHidden(true)
            Text(text).fixedSize(horizontal:false, vertical:true)
        }
        .scaledFont(13, relativeTo:.footnote).foregroundStyle(Theme.accentText)
        .accessibilityElement(children:.combine)
    }
}
