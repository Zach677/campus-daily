#if DEBUG
import SwiftUI

/// campusdaily://demo/widget-preview[/2] — draws the 「校日常」 widget views in the app at home-screen
/// sizes (small 170×170, medium 364×170, corner 22, 16pt margins), because widgets can't be
/// captured from the simulator CLI. Same view code as the widget; follows the system appearance.
struct WidgetPreview: View {
    struct Page: Identifiable { let number: Int; var id: Int { number } }
    /// Page 1 or 2, nil when the URL is not a widget preview.
    static func handle(_ url: URL) -> Page? {
        let parts = Array(url.pathComponents.dropFirst())
        guard url.scheme == "campusdaily", url.host == "demo", parts.first == "widget-preview" else { return nil }
        return Page(number:parts.count > 1 && parts[1] == "2" ? 2 : 1)
    }
    var page = 1
    @Environment(\.colorScheme) private var scheme
    private var updated: Date {
        Calendar.current.date(bySettingHour:10, minute:32, second:0, of:Date()) ?? Date()
    }
    private func model(power: String = "42.6", card: String = "86.50", extras: Bool = false) -> CampusWidgetModel {
        CampusWidgetModel(signedIn:true, remainingKWh:Decimal(string:power), balance:Decimal(string:card),
                          yesterdayKWh:extras ? Decimal(string:"5.1") : nil,
                          powerBalance:extras ? Decimal(string:"23.40") : nil, updated:updated)
    }
    var body: some View {
        VStack(spacing:8) {
            if page == 1 {
                HStack(spacing:24) {
                    tile(model(), caption:"小号")
                    tile(model(power:"4.8"), caption:"小号 · 电量低")
                }
                HStack(spacing:24) {
                    tile(.signedOut, caption:"没登录")
                    tile(.needsRefresh, caption:"登录了 · 还没数据")
                }
                tile(model(extras:true), medium:true, caption:"中号 · 有昨天用电和电费余额")
                tile(model(), medium:true, caption:"中号 · 只有余额")
            } else {
                tile(.signedOut, medium:true, caption:"中号 · 没登录")
                tile(.needsRefresh, medium:true, caption:"中号 · 登录了 · 还没数据")
                HStack(spacing:24) {
                    tile(model(card:"12.30"), caption:"小号 · 校园卡低")
                    tile(model(power:"4.8", card:"12.30"), caption:"小号 · 都低")
                }
            }
        }
        .padding(.top,64)
        .frame(maxWidth:.infinity, maxHeight:.infinity, alignment:.top)
        .background((scheme == .dark ? Color(red:0.13, green:0.16, blue:0.20) : Color(red:0.80, green:0.84, blue:0.88)).ignoresSafeArea())
    }
    private func tile(_ model: CampusWidgetModel, medium: Bool = false, caption: String) -> some View {
        VStack(spacing:4) {
            CampusWidgetFace(model:model, medium:medium)
                .padding(16)
                .frame(width:medium ? 364 : 170, height:170)
                .background(CampusWidgetPalette.group, in:RoundedRectangle(cornerRadius:22, style:.continuous))
            Text(caption).font(.system(size:11, weight:.medium))
                .foregroundStyle(scheme == .dark ? Color.white.opacity(0.8) : Color.black.opacity(0.6))
        }
    }
}
#endif
