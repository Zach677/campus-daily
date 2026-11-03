import SwiftUI

/// 设置 tab root. Placeholder until its page is built: one row per page it opens.
struct ClearSettingsTab: View {
    @Environment(ClearNavigator.self) private var navigator

    private let routes: [(ClearRoute, String)] = [
        (.setupChecklist, "setupChecklist"), (.account, "account"), (.dorm, "dorm"), (.powerSetup, "powerSetup"),
        (.washerSetup, "washerSetup"), (.theme, "theme"), (.advanced, "advanced"),
    ]

    var body: some View {
        List {
            ForEach(routes, id:\.0) { route, name in
                NavigationLink(name, value:route)
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
    }
}
