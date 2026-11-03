import SwiftUI
import Core

/// 日常 tab root (清爽 home): room line, 电量和校园卡, 继续设置 while something is not set,
/// the 热水 and 洗衣 tiles, and as many 最近 rows as fit (`RecentCardFit`), so home never scrolls
/// below the accessibility sizes.
///
/// Pages open through `ClearNavigator`; the root hosts the shower page, the laundry-done sheet
/// and the sign-in sheet.
struct ClearHomeView: View {
    @EnvironmentObject var shower: ShowerModel
    @EnvironmentObject var campus: CampusModel
    @EnvironmentObject var laundry: LaundryModel
    @Environment(ClearNavigator.self) var navigator
    @Environment(\.dynamicTypeSize) var typeSize
    /// For 最近 (`recentCount`): the scroll view's visible size, the tiles' bottom, the header's
    /// height and each row's height, measured hidden at the card's width.
    @State var viewport: CGSize = .zero
    @State var tilesBottom: CGFloat = 0
    @State var recentsHeaderHeight: CGFloat = 0
    @State var recentHeights: [RecentItem.ID: CGFloat] = [:]

    static let fit = RecentCardFit.clearHome
    nonisolated static let contentSpace = "clearHomeContent"

    var body: some View {
        let data = navigator.data(campus:campus, shower:shower, laundry:laundry)
        // Not `.scrollBounceBehavior(.basedOnSize)`: content that fits must still bounce for the pull.
        ScrollView {
            content(data)
        }
        // The size between the bars: what 最近 has to fit in.
        .onGeometryChange(for:CGSize.self) { $0.size } action: { viewport = $0 }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("校日常")
        .navigationBarTitleDisplayMode(.large)
        // SwiftUI may cancel the pull's own task when the page changes under it: the read runs
        // on its own and the pull waits for it.
        .refreshable { await Task { await pull() }.value }
    }

    func content(_ data: HomeData) -> some View {
        let fit = Self.fit
        return VStack(alignment:.leading, spacing:CGFloat(fit.gapAbove)) {
            ClearRoomLine(dorm:data.signedIn ? data.dorm : nil, signedIn:data.signedIn, refreshing:data.refreshing)
            ClearBalanceCard(data:data)
            if let detail = HomeSetupCard.detail(signedIn:data.signedIn, dormSet:data.shower != .unconfigured,
                                                 laundryEnabled:data.laundryEnabled, laundryBound:data.laundryBound) {
                ClearSetupCard(detail:detail) { navigator.push(.setupChecklist) }
            }
            tiles(data)
                .onGeometryChange(for:CGFloat.self) { $0.frame(in:.named(Self.contentSpace)).maxY } action: { tilesBottom = $0 }
            recents(data)
        }
        .padding(CGFloat(fit.pagePadding))
        .coordinateSpace(name:Self.contentSpace)
        .background(alignment:.top) { recentMeasure(data) }
        .frame(maxWidth:CGFloat(fit.maxWidth))
        .frame(maxWidth:.infinity)
    }

    /// Pull to refresh: the school's numbers, then the washer.
    func pull() async {
        await campus.refresh(force:true)
        await laundry.refresh(force:true)
    }
}
