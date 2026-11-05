import XCTest
import Core
@testable import XiaoRiChang

/// Both themes' roots, hosted as the app draws them (`RootHarness`): the widget's settings link
/// opens Settings, and leaving the sample goes to one destination, the link kept from it when
/// there is one, never also the login step or the first-run setup later.
@MainActor
final class RootLinkTests: XCTestCase {
    private func harness(_ theme: AppTheme, seenSetup: Bool = true) async -> RootHarness {
        let harness = RootHarness(theme: theme, seenSetup: seenSetup)
        addTeardownBlock { @MainActor in harness.close() }
        await pause(800)
        return harness
    }

    /// campusdaily://settings: Settings in 暖橙 (its sheet), the 设置 tab at its root in 清爽.
    func testSettingsLinkOpensSettings() async {
        let warm = await harness(.warm)
        XCTAssertEqual(warm.link("campusdaily://settings"), .live)
        await pause(1200)
        XCTAssertTrue(warm.sheetShown, "暖橙: the settings sheet")
        warm.close()

        let clear = await harness(.clear)
        XCTAssertEqual(clear.link("campusdaily://settings"), .live)
        await pause(1200)
        XCTAssertEqual(clear.navigator?.tab, .settings)
        XCTAssertEqual(clear.navigator?.settingsPath, [])
        XCTAssertNil(clear.navigator?.setup)
    }

    /// From the login step into the sample, a login link and then a home link come in: the
    /// sample stays. Leaving it lands on home and stays there, well past the 600 ms the login
    /// step waits for, with or without the first-run setup seen.
    func testLeavingWithAKeptHomeLinkStaysOnHome() async {
        for theme in [AppTheme.warm, .clear] {
            for seen in [true, false] {
                let h = await harness(theme, seenSetup: seen)
                let label = "\(theme) seen: \(seen)"
                if !seen {
                    // The first-run setup opened: its login step is where the entry is.
                    if theme == .warm { XCTAssertTrue(h.coverShown, label) } else { XCTAssertNotNil(h.navigator?.setup, label) }
                }
                XCTAssertEqual(h.sample.enter(), .entered, label)
                await pause(800)
                XCTAssertEqual(h.link("campusdaily://login"), .held, label)
                XCTAssertEqual(h.link("campusdaily://home"), .held, label)
                await pause(300)
                XCTAssertTrue(h.sample.isActive, label)
                h.sample.leave()
                await pause(1500)
                XCTAssertNil(h.presented, "\(label): no login step or setup over home")
                if theme == .clear {
                    XCTAssertNil(h.navigator?.setup, label)
                    XCTAssertEqual(h.navigator?.tab, .home, label)
                }
                h.close()
            }
        }
    }

    /// In the sample, home and then settings come in: leaving opens Settings, and only that.
    func testLeavingWithAKeptSettingsLinkOpensSettings() async {
        for theme in [AppTheme.warm, .clear] {
            let h = await harness(theme)
            XCTAssertEqual(h.sample.enter(), .entered)
            await pause(800)
            XCTAssertEqual(h.link("campusdaily://home"), .held)
            XCTAssertEqual(h.link("campusdaily://settings"), .held)
            h.sample.leave()
            await pause(1500)
            if theme == .warm {
                XCTAssertTrue(h.sheetShown, "暖橙: the settings sheet, not the login step")
            } else {
                XCTAssertEqual(h.navigator?.tab, .settings)
                XCTAssertNil(h.navigator?.setup)
            }
            h.close()
        }
    }

    /// No kept link: leaving opens the login step, once (unchanged).
    func testLeavingWithoutALinkOpensTheLoginStep() async {
        for theme in [AppTheme.warm, .clear] {
            let h = await harness(theme)
            XCTAssertEqual(h.sample.enter(), .entered)
            await pause(800)
            h.sample.leave()
            await pause(1500)
            if theme == .warm {
                XCTAssertTrue(h.coverShown, "暖橙: the first-run guide on its login step")
            } else {
                XCTAssertNotNil(h.navigator?.setup, "清爽: the checklist")
            }
            h.close()
        }
    }
}
