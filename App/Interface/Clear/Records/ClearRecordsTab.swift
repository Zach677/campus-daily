import SwiftUI

/// 记录 tab root. Placeholder until its page is built. The root pops this tab to its root when
/// the signed-in person changes; the page reloads then (`campus.personChanges`). DEBUG demos put
/// their pages in `navigator.recordsDemo`.
struct ClearRecordsTab: View {
    @EnvironmentObject private var campus: CampusModel
    @Environment(ClearNavigator.self) private var navigator

    var body: some View {
        List {
            Button("shower") { navigator.push(.shower) }
            Button("laundry") { navigator.push(.laundry) }
        }
        .navigationTitle("记录")
        .navigationBarTitleDisplayMode(.large)
    }
}
