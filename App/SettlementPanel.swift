import SwiftUI

/// Settlement result panel (design §4.7): custom bottom panel over a 0.2 dim.
struct SettlementPanel: View {
    let result: SettlementResult
    let dismiss: () -> Void
    var body: some View {
        VStack(spacing:0) {
            switch result {
            case .settled(let minutes, let amount):
                Mascot(size:52)
                Text("洗好了").scaledFont(15, relativeTo:.subheadline).foregroundStyle(Theme.ink2).padding(.top,10)
                if let amount {
                    // Only a server-returned amount is ever shown.
                    Text(Theme.yuan(amount)).scaledFont(44, .semibold, design:.rounded, relativeTo:.largeTitle)
                        .monospacedDigit().tracking(-1).foregroundStyle(Theme.ink)
                        .contentTransition(.numericText()).padding(.top,4)
                }
                if let line = detail(minutes:minutes, charged:amount != nil) {
                    Text(line).scaledFont(13, relativeTo:.footnote).foregroundStyle(Theme.ink2).padding(.top,4)
                }
            case .unconfirmed:
                Text("还没确认结算").scaledFont(20, .semibold, relativeTo:.title3).foregroundStyle(Theme.ink)
                Text("先别重复结束，等一下看热水记录。").scaledFont(15, relativeTo:.subheadline).foregroundStyle(Theme.ink2)
                    .multilineTextAlignment(.center).fixedSize(horizontal:false, vertical:true).padding(.top,6)
            }
            Button(action:dismiss) {
                Text("好").scaledFont(17, .semibold, relativeTo:.headline).foregroundStyle(Theme.ink)
                    .frame(maxWidth:.infinity).frame(minHeight:50)
                    .background(Theme.fill, in:Capsule())
            }
            .buttonStyle(PressScaleStyle())
            .accessibilityLabel("好，关闭")
            .padding(.top,18)
        }
        .multilineTextAlignment(.center)
        .padding(.top,26).padding(.horizontal,24).padding(.bottom,24)
        .frame(maxWidth:.infinity)
        .background(Theme.group, in:RoundedRectangle(cornerRadius:40, style:.continuous))
        .accessibilityElement(children:.contain)
        .accessibilityAddTraits(.isModal)
    }
    private func detail(minutes: Int?, charged: Bool) -> String? {
        switch (minutes, charged) {
        case (let m?, true): return "\(m) 分钟 · 已从校园卡扣款"
        case (let m?, false): return "\(m) 分钟"
        case (nil, true): return "已从校园卡扣款"
        case (nil, false): return nil
        }
    }
}

/// Dim + panel, sliding up from below.
struct SettlementOverlay: View {
    @Binding var result: SettlementResult?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack(alignment:.bottom) {
            if let value = result {
                Color.black.opacity(0.2).ignoresSafeArea()
                    .onTapGesture { result = nil }
                    .accessibilityHidden(true)
                    .transition(.opacity)
                SettlementPanel(result:value) { result = nil }
                    .padding(12)
                    .transition(reduceMotion ? .opacity : .move(edge:.bottom))
            }
        }
        .ignoresSafeArea(edges:.bottom)
        .animation(Theme.spring, value:result)
    }
}
