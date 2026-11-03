import SwiftUI
import Core

/// 外观 › 主题.
struct SettingsAppearanceSection<Link: View>: View {
    let link: (SettingsLink, SettingsRow) -> Link

    var body: some View {
        Section("外观") {
            link(.theme, SettingsRow(symbol:"paintpalette", title:"主题", value:Theme.current.name))
                .accessibilityLabel(Theme.current.settingsRowLabel)
                .accessibilityIdentifier("themeRow")
        }.listRowBackground(Theme.group)
    }
}
