import SwiftUI

/// A home section (双余额, 洗衣, 最近) or a list under a section header: in 清爽 drawn in a
/// `group` card, radius 16, 16 in from the screen's sides; in 暖橙 left flat on the page.
/// Rows supply their own side inset (`Theme.rowInset`).
struct SectionCard: ViewModifier {
    /// Space above and below the content inside the card.
    let vertical: CGFloat

    /// Home's cards: 14 above and below.
    static let homeVertical: CGFloat = 14
    /// What a home card adds to its content's height (`RecentFit`'s chrome): nothing in 暖橙.
    static var homeChrome: CGFloat { Theme.sectionCards ? homeVertical * 2 : 0 }

    func body(content: Content) -> some View {
        if Theme.sectionCards {
            content
                .padding(.vertical,vertical)
                .background(Theme.group, in:RoundedRectangle(cornerRadius:16, style:.continuous))
                .padding(.horizontal,16)
        } else {
            content
        }
    }
}

extension View {
    /// See `SectionCard`. `vertical`: 14 on home; 0 for a list of rows.
    func sectionCard(vertical: CGFloat = SectionCard.homeVertical) -> some View {
        modifier(SectionCard(vertical:vertical))
    }
}
