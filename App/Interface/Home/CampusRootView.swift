import SwiftUI

/// Single-screen root (no tab bar); settings is a sheet from the home gear. Each theme has its
/// own page tree: 暖橙's starts at `HomeView`, 清爽's at `ClearRootView`. A theme switch replaces
/// the whole tree, so it lands on home with any sheet or pushed page closed.
struct CampusRootView: View {
    var body: some View {
        Group {
            switch Theme.current {
            case .warm: HomeView()
            case .clear: ClearRootView()
            }
        }
        .tint(Theme.accentText)
        // All UI copy is Simplified Chinese: pin the CJK font cascade to PingFang SC so the
        // system language can't pick another Han font (it made some strings render lighter).
        .typesettingLanguage(Theme.typesetting)
    }
}
