import SwiftUI
import Core

/// 热水洗澡 in 清爽, pushed on the 日常 stack. Placeholder until its page is built.
///
/// The root pushes it when `shower.page.presented` turns true and doesn't push a second copy
/// when it is already on top. While the shower must not be left (`shower.page.presented &&
/// !shower.page.mayCollapse`: connecting, settling, a result to answer) the back button and the
/// tab bar are hidden; while water runs both show, and going back collapses the page as 暖橙's ⌄.
/// Buttons that end the page (好, 先回首页) send their page event, then `dismiss()`.
struct ClearShowerPage: View {
    @EnvironmentObject private var shower: ShowerModel

    private var locked: Bool { shower.page.presented && !shower.page.mayCollapse }

    var body: some View {
        List {
            LabeledContent("presented", value:shower.page.presented ? "yes" : "no")
            LabeledContent("phase", value:shower.page.page.map { "\($0.phase)" } ?? "—")
        }
        .navigationTitle("热水洗澡")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(locked)
        .toolbar(locked ? .hidden : .automatic, for:.tabBar)
    }
}
