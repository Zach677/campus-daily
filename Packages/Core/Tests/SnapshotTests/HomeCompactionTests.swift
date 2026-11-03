import XCTest
import Core

/// 清爽 home on a short screen: the first step whose page fits between the bars, so home never
/// scrolls below the accessibility sizes.
final class HomeCompactionTests: XCTestCase {
    let padding = RecentCardFit.clearHome.pagePadding
    let gap = RecentCardFit.clearHome.gapAbove

    func step(_ viewport: Double, _ sections: HomeCompaction.Sections, ax: Bool = false) -> HomeCompaction {
        HomeCompaction.choose(viewport: viewport, sections: sections, pagePadding: padding, gap: gap, accessibilitySize: ax)
    }

    /// Each step keeps what the ones before it did.
    func testStepsAddUp() {
        XCTAssertFalse(HomeCompaction.full.hidesRoomLine)
        XCTAssertTrue(HomeCompaction.noRoomLine.hidesRoomLine)
        XCTAssertFalse(HomeCompaction.noRoomLine.usesInlineTitle)
        XCTAssertTrue(HomeCompaction.inlineTitle.hidesRoomLine)
        XCTAssertTrue(HomeCompaction.inlineTitle.usesInlineTitle)
        XCTAssertFalse(HomeCompaction.inlineTitle.tightensCards)
        XCTAssertTrue(HomeCompaction.tightCards.hidesRoomLine)
        XCTAssertTrue(HomeCompaction.tightCards.usesInlineTitle)
        XCTAssertTrue(HomeCompaction.tightCards.tightensCards)
    }

    /// The large title until the inline one replaces it, padding above and below the sections
    /// shown, and a gap between each two.
    func testContentHeight() {
        let sections = HomeCompaction.Sections(title: 52, roomLine: 20, balance: 200, balanceTight: 190, setup: 60, tiles: 150,
                                               tilesTight: 130)
        XCTAssertEqual(HomeCompaction.full.contentHeight(sections, pagePadding: 20, gap: 18), 576,
                       "52 + 40 + 20 + 200 + 60 + 150 + 3 × 18")
        XCTAssertEqual(HomeCompaction.noRoomLine.contentHeight(sections, pagePadding: 20, gap: 18), 538)
        XCTAssertEqual(HomeCompaction.inlineTitle.contentHeight(sections, pagePadding: 20, gap: 18), 486)
        XCTAssertEqual(HomeCompaction.tightCards.contentHeight(sections, pagePadding: 20, gap: 18), 456)
        var noSetup = sections; noSetup.setup = 0
        XCTAssertEqual(HomeCompaction.inlineTitle.contentHeight(noSetup, pagePadding: 20, gap: 18), 408,
                       "继续设置 not shown: no section and no gap for it")
    }

    /// Stops at the first step that fits; half a point over still fits.
    func testFirstStepThatFits() {
        let sections = HomeCompaction.Sections(title: 52, roomLine: 20, balance: 200, balanceTight: 190, setup: 0, tiles: 150,
                                               tilesTight: 130)
        // full 498, without the room line 460, inline title 408, tight 378.
        XCTAssertEqual(step(498, sections), .full)
        XCTAssertEqual(step(497.6, sections), .full, "half a point")
        XCTAssertEqual(step(497, sections), .noRoomLine)
        XCTAssertEqual(step(459, sections), .inlineTitle)
        XCTAssertEqual(step(407, sections), .tightCards)
        XCTAssertEqual(step(200, sections), .tightCards, "nothing fits: the shortest page")
    }

    /// Accessibility sizes scroll anyway, and before the screen is measured nothing compresses.
    func testAccessibilitySizesAndUnmeasured() {
        let sections = HomeCompaction.Sections(title: 0, roomLine: 40, balance: 600, balanceTight: 590, setup: 0, tiles: 400,
                                               tilesTight: 380)
        XCTAssertEqual(step(510, sections, ax: true), .full)
        XCTAssertEqual(step(0, sections), .full)
    }

    // Device metrics, measured in 清爽 home: the height between the inline bar and the tab bar's
    // safe area, the large title 52 under the bar, sections at the card's width.

    /// iPhone SE (375 × 667), 510 between the bars, default size, signed in: dropping the room
    /// line is enough (532, then 496).
    func testSEDefaultDropsTheRoomLine() {
        let sections = HomeCompaction.Sections(title: 52, roomLine: 18, balance: 219, balanceTight: 209, setup: 0, tiles: 167,
                                               tilesTight: 141)
        XCTAssertEqual(HomeCompaction.full.contentHeight(sections, pagePadding: padding, gap: gap), 532)
        XCTAssertEqual(step(510, sections), .noRoomLine)
    }

    /// SE, default size, signed out (继续设置 shown): the inline title too (531, then 479).
    func testSEDefaultSignedOutUsesTheInlineTitle() {
        let sections = HomeCompaction.Sections(title: 52, roomLine: 0, balance: 167, balanceTight: 157, setup: 69, tiles: 167,
                                               tilesTight: 141)
        XCTAssertEqual(step(510, sections), .inlineTitle)
    }

    /// SE at xxxLarge, signed in: the inline title fits with a point to spare (509); tiles a
    /// little taller and the cards tighten (481).
    func testSEXXXLarge() {
        let sections = HomeCompaction.Sections(title: 52, roomLine: 25, balance: 255, balanceTight: 245, setup: 0, tiles: 196,
                                               tilesTight: 170)
        XCTAssertEqual(step(510, sections), .inlineTitle)
        var taller = sections; taller.tiles += 8
        XCTAssertEqual(step(510, taller), .tightCards, "517 under the inline title, 481 tightened")
    }

    /// SE at xxxLarge, signed out: even tightened the page is 532 for 510; the shortest page.
    func testSEXXXLargeSignedOutIsTheShortestPage() {
        let sections = HomeCompaction.Sections(title: 52, roomLine: 0, balance: 189, balanceTight: 179, setup: 107, tiles: 196,
                                               tilesTight: 170)
        XCTAssertEqual(HomeCompaction.tightCards.contentHeight(sections, pagePadding: padding, gap: gap), 532)
        XCTAssertEqual(step(510, sections), .tightCards)
    }

    /// iPhone 18 Pro (402 × 874), 675 between the bars: as designed at the default size and at
    /// xxxLarge, signed in or out.
    func testEighteenProAsDesigned() {
        let normal = HomeCompaction.Sections(title: 52, roomLine: 18, balance: 218, balanceTight: 208, setup: 0, tiles: 167,
                                             tilesTight: 141)
        let normalXXXL = HomeCompaction.Sections(title: 52, roomLine: 25, balance: 255, balanceTight: 245, setup: 0, tiles: 195,
                                                 tilesTight: 170)
        let signedOut = HomeCompaction.Sections(title: 52, roomLine: 0, balance: 167, balanceTight: 157, setup: 69, tiles: 167,
                                                tilesTight: 141)
        let signedOutXXXL = HomeCompaction.Sections(title: 52, roomLine: 0, balance: 188, balanceTight: 178, setup: 84, tiles: 195,
                                                    tilesTight: 170)
        XCTAssertEqual(step(675, normal), .full)
        XCTAssertEqual(step(675, normalXXXL), .full)
        XCTAssertEqual(step(675, signedOut), .full)
        XCTAssertEqual(step(675, signedOutXXXL), .full)
    }
}
