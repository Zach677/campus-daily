import SwiftUI

/// 洗衣 in 清爽, pushed on the 日常 stack. Placeholder until its page is built.
/// DEBUG demos put their laundry state in `navigator.laundryDemo`. The root keeps this page up
/// for links and notification taps while an order is being paid (`WidgetLink.mayClosePages`).
struct ClearLaundryPage: View {
    @EnvironmentObject private var laundry: LaundryModel
    @Environment(ClearNavigator.self) private var navigator

    var body: some View {
        List {
            Button("washerSetup") { navigator.push(.washerSetup) }
        }
        .navigationTitle("洗衣")
        .navigationBarTitleDisplayMode(.inline)
    }
}
