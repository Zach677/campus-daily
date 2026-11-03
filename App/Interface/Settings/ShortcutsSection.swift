import SwiftUI

/// 「快捷指令 ›」 (opens the Shortcuts app) and how to find 校日常's actions there.
struct ShortcutsSection: View {
    var body: some View {
        Section {
            Link(destination:URL(string:"shortcuts://")!) { ChevronRow(title:"快捷指令") }
        } footer: {
            Text("在「快捷指令」App 里搜「校日常」，就能把「开始洗澡」和「结束并结算」加到主屏幕或操作按钮上。")
        }.listRowBackground(Theme.group)
    }
}
