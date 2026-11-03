import SwiftUI

/// 日常 tab root (清爽 home). Placeholder until its page is built: one button per page it opens.
///
/// From the root it gets `ClearNavigator` (`@Environment(ClearNavigator.self)`): `push(_:)` for
/// its pages (or `NavigationLink(value:ClearRoute)`), `select(.records)` for 「全部 ›」,
/// `openSetup()` signed out, `signInAgain(_:)` for the expired-login line, `data(...)` for what
/// it shows. The root also hosts the shower page presentation, the laundry-done sheet and the
/// sign-in sheet; home only asks for them.
struct ClearHomeView: View {
    @EnvironmentObject private var shower: ShowerModel
    @EnvironmentObject private var campus: CampusModel
    @EnvironmentObject private var laundry: LaundryModel
    @Environment(ClearNavigator.self) private var navigator

    private let routes: [(ClearRoute, String)] = [
        (.shower, "shower"), (.laundry, "laundry"), (.washerSetup, "washerSetup"), (.power, "power"),
        (.powerSetup, "powerSetup"), (.card, "card"), (.account, "account"), (.setupChecklist, "setupChecklist"),
    ]

    var body: some View {
        List {
            Section {
                ForEach(routes, id:\.0) { route, name in
                    Button(name) { navigator.push(route) }
                }
            }
            Section {
                Button("records tab") { navigator.select(.records) }
                Button("setup sheet") { navigator.openSetup() }
            }
        }
        .navigationTitle("校日常")
        .navigationBarTitleDisplayMode(.large)
        .refreshable { await campus.refresh(force:true); await laundry.refresh(force:true) }
    }
}
