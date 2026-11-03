import SwiftUI

/// 2.4, 最近一次用水: the last settled shower, when the record still has it.
struct ClearShowerLastCard: View {
    let ended: Date
    let cost: Decimal?

    var body: some View {
        VStack(alignment:.leading, spacing:14) {
            Text("最近一次用水").font(.subheadline).foregroundStyle(.secondary)
            HStack {
                VStack(alignment:.leading, spacing:6) {
                    Text("已结算").font(.subheadline)
                    Text(ended.formatted(date:.abbreviated, time:.shortened)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let cost { Text(Theme.yuan(cost)).font(.subheadline).monospacedDigit() }
            }
            .accessibilityElement(children:.combine)
        }
        .padding(18)
        .frame(maxWidth:.infinity, alignment:.leading)
        .background(NativeTheme.surface, in:RoundedRectangle(cornerRadius:16, style:.continuous))
    }
}
