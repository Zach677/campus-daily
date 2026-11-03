import SwiftUI

/// 首次设置 checklist. Placeholder until its page is built.
///
/// As the first-run sheet (`inSheet`, the default) it has its own stack and opens with `start`
/// pushed (campusdaily://login: `.account`); the root marks it seen when the sheet goes. Pushed
/// (`ClearRoute.setupChecklist`) it lives on the tab's stack. Its rows push its own step pages.
struct ClearSetupChecklist: View {
    var start: ClearSetupRow? = nil
    var inSheet = true
    @Environment(\.dismiss) private var dismiss
    @State private var row: ClearSetupRow?

    var body: some View {
        if inSheet {
            NavigationStack {
                list.toolbar {
                    ToolbarItem(placement:.confirmationAction) { Button("以后再说") { dismiss() } }
                }
            }
        } else {
            list
        }
    }

    private var list: some View {
        List(ClearSetupRow.allCases, id:\.self) { item in
            Button(String(describing:item)) { row = item }
        }
        .navigationTitle("首次设置")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item:$row) { item in Text(verbatim:String(describing:item)) }
        .onAppear { if let start, row == nil { row = start } }
    }
}
