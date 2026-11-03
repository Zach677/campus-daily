import SwiftUI

/// 衣服洗好了, the sheet the root shows once per finished laundry order (`navigator.panel`;
/// the root gives it the medium detent and drag indicator). Placeholder until its page is built.
struct ClearLaundryDonePanel: View {
    @Environment(ClearNavigator.self) private var navigator

    var body: some View {
        VStack(spacing:16) {
            if case .laundryDone(let amount, let detail)? = navigator.panel {
                Text("衣服洗好了")
                if let amount { Text(Theme.yuan(amount)) }
                Text(detail)
            }
            Button("好") { navigator.panel = nil }
        }
        .padding(24)
    }
}
