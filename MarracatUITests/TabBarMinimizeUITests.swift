import XCTest

/// The floating tab bar shrinks while Home is scrolled down and grows back on
/// the way up, like Instagram's (owner, 2026-11-05, from a screen recording).
/// Every tab stays tappable while it's small. Screenshots are attached for the
/// owner's preview; each step prints "TOUR <name>" so a recording can be cut.
final class TabBarMinimizeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-UITEST_RESET", "-SPLASH_SECONDS", "0"]
    }

    private func pause(_ s: TimeInterval) { Thread.sleep(forTimeInterval: s) }
    private func mark(_ name: String) { print("TOUR \(name) \(Date().timeIntervalSince1970)") }
    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
    private var tab: XCUIElement { app.buttons["tab.saved"] }

    func testTabBarShrinksOnScrollDownAndGrowsOnScrollUp() throws {
        guard #available(iOS 18.0, *) else { throw XCTSkip("the bar stays full on iOS 17") }
        app.launch()
        XCTAssertTrue(app.homeReady().appears(timeout: 60), "Home never drew")
        XCTAssertTrue(tab.appears(timeout: 5))
        pause(1.5)
        let full = tab.frame.width
        mark("full"); shot("01 Tab bar full")

        app.swipeUp(velocity: .slow)
        pause(0.6)
        app.swipeUp(velocity: .slow)
        pause(1.2)
        let compact = tab.frame.width
        mark("compact"); shot("02 Scrolled down: tab bar minimized")
        XCTAssertLessThan(compact, full * 0.9, "the bar shrinks on the way down")

        app.swipeUp(velocity: .slow)
        pause(1.2)
        XCTAssertLessThan(tab.frame.width, full * 0.9, "and stays small while going down")
        shot("03 Still scrolling down: stays minimized")

        app.swipeDown(velocity: .slow)
        pause(1.2)
        mark("back"); shot("04 Scrolled up: tab bar full again")
        XCTAssertEqual(tab.frame.width, full, accuracy: 1, "it grows back on the way up")

        app.swipeUp(velocity: .slow)
        pause(1.2)
        XCTAssertLessThan(tab.frame.width, full * 0.9)
        mark("compact2")
        // Small, and still a working tab: tapping it switches and grows the bar.
        tab.tap()
        pause(1.2)
        mark("tapped"); shot("05 Tab tapped while minimized: switches, bar full")
        XCTAssertTrue(tab.isSelected)
        XCTAssertEqual(tab.frame.width, full, accuracy: 1, "a tab change grows it back")
        pause(1)
    }

    /// Every screen with the shared chrome does it, not just Home: Browse here.
    func testBrowseShrinksTheTabBarToo() throws {
        guard #available(iOS 18.0, *) else { throw XCTSkip("the bar stays full on iOS 17") }
        app.launch()
        XCTAssertTrue(app.appReady().appears(timeout: 60))
        app.buttons["tab.browse"].tap()
        let search = app.descendants(matching: .any).matching(identifier: "searchField").firstMatch
        XCTAssertTrue(search.appears(timeout: 5))
        pause(1.5)
        let full = tab.frame.width, searchFull = search.frame.width
        app.swipeUp(velocity: .slow)
        pause(1.2)
        shot("06 Browse scrolled down: tab bar and search bar minimized")
        XCTAssertLessThan(tab.frame.width, full * 0.9, "Browse shrinks the bar")
        XCTAssertLessThan(search.frame.width, searchFull * 0.95, "the search bar shrinks a little too")
        XCTAssertLessThan(search.frame.maxY, tab.frame.minY, "still above the tab bar")
        app.swipeDown(velocity: .slow)
        pause(1.2)
        XCTAssertEqual(tab.frame.width, full, accuracy: 1, "and grows it back on the way up")
        XCTAssertEqual(search.frame.width, searchFull, accuracy: 1)

        // Small, the search bar still opens search (owner, 2026-11-05).
        app.swipeUp(velocity: .slow)
        pause(1.2)
        XCTAssertLessThan(search.frame.width, searchFull * 0.95)
        search.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "searchInput").firstMatch.appears(timeout: 5),
                      "a tap on the minimized search bar opens search")
        shot("07 Tapped the minimized search bar: search opens")
    }

    /// You types straight into its bar: tapped while small, it grows and takes the typing.
    func testMinimizedLocalSearchBarStartsTyping() throws {
        guard #available(iOS 18.0, *) else { throw XCTSkip("the bar stays full on iOS 17") }
        app.launch()
        XCTAssertTrue(app.appReady().appears(timeout: 60))
        app.buttons["tab.you"].tap()
        let field = app.textFields["youSearch"]
        XCTAssertTrue(field.appears(timeout: 10))
        pause(1.5)
        let full = tab.frame.width
        app.swipeUp(velocity: .slow)
        pause(1.2)
        try XCTSkipUnless(tab.frame.width < full * 0.9, "You was too short to scroll on this device")
        field.tap()
        field.typeText("icon")
        pause(0.8)
        shot("08 Tapped the minimized You search: full size, typing")
        XCTAssertEqual(field.value as? String, "icon", "the tap went to the field and it took the typing")
        let result = app.buttons.matching(NSPredicate(format: "identifier == 'youResult'")).firstMatch
        XCTAssertTrue(result.appears(timeout: 5))
    }
}
