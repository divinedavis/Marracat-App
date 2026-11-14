import XCTest

/// A slow walk through a feature for the owner's preview video, recorded with
/// `xcrun simctl io <sim> recordVideo`. Skipped unless the runner is given
/// PREVIEW_TOUR=1 (xcodebuild: TEST_RUNNER_PREVIEW_TOUR=1), so the suite never
/// spends time on it. Each step prints "TOUR <name> <time>" so the recording
/// can be cut into captioned clips.
final class PreviewTourUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PREVIEW_TOUR"] == "1", "preview tours run only on request")
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments = ["-UITEST_RESET", "-SPLASH_SECONDS", "0"]
    }

    private func pause(_ s: TimeInterval) { Thread.sleep(forTimeInterval: s) }
    private func mark(_ name: String) { print("TOUR \(name) \(Date().timeIntervalSince1970)") }
    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    /// Brand page → Filters › Type as photos (2026-11-08; the brand search
    /// left the page 2026-11-09).
    func testBrandTypeFilterTour() {
        app.launch()
        XCTAssertTrue(app.storeSearchField().appears(timeout: 60))
        app.storeSearchField().tap()
        XCTAssertTrue(any("searchInput").appears(timeout: 5))
        any("searchInput").typeText("Fear of God pants\n")
        XCTAssertTrue(any("resultTitle").appears(timeout: 10))
        any("resultTitle").tap()
        XCTAssertTrue(any("visitStore").appears(timeout: 5))
        any("visitStore").tap()

        mark("brand")
        XCTAssertTrue(any("filtersButton").appears(timeout: 10))
        pause(2.5)
        app.swipeUp(velocity: .slow)
        pause(1.2)
        app.swipeDown(velocity: .slow)
        pause(1.5)

        mark("filters")
        let filters = any("filtersButton")
        if !filters.isHittable { app.swipeDown(velocity: .fast); pause(0.6) }
        XCTAssertTrue(filters.appears(timeout: 5))
        filters.tap()
        let type = app.buttons.matching(NSPredicate(format: "identifier == 'filterGroup' AND label BEGINSWITH 'Type'")).firstMatch
        XCTAssertTrue(type.appears(timeout: 5))
        pause(1.0)
        type.tap()
        mark("types")
        pause(3.0)
        let hoodies = app.buttons.matching(NSPredicate(format: "identifier == 'filterOption' AND label BEGINSWITH 'Hoodies'")).firstMatch
        if hoodies.appears(timeout: 3) { hoodies.tap(); pause(2.0) }
        let show = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Show '")).firstMatch
        if show.appears(timeout: 3) { show.tap() }
        mark("done")
        pause(3.0)
    }
    /// How long a tap on Home keeps the app busy (owner, 2026-11-11: "i think
    /// there is a delay when i touch on the home button on the tab bar").
    /// XCUITest's tap returns once the app is idle again, so the time around
    /// it is the main thread's work. Prints "TABTAP <case> <ms>".
    func testHomeTabTapTiming() {
        app.launch()
        XCTAssertTrue(app.homeReady().appears(timeout: 60))
        pause(8)  // the whole catalog lands and Home finishes building
        func tap(_ name: String, _ label: String) {
            let tab = app.buttons["tab.\(name)"]
            XCTAssertTrue(tab.appears(timeout: 5))
            let t = Date()
            tab.tap()
            print("TABTAP \(label) \(Int(Date().timeIntervalSince(t) * 1000))")
            pause(1.5)
        }
        for i in 1...3 {
            tap("saved", "away\(i)")
            tap("home", "home-plain\(i)")
        }
        tap("home", "home-reselect")
        for (i, q) in ["shea butter", "hoodie", "candle"].enumerated() {
            tap("browse", "browse\(i)")
            app.storeSearchField().tap()
            XCTAssertTrue(any("searchInput").appears(timeout: 5))
            any("searchInput").typeText(q + "\n")
            XCTAssertTrue(any("resultsHeader").appears(timeout: 15))
            pause(1)
            let close = app.buttons.matching(NSPredicate(format: "identifier == 'searchClose' OR label == 'Close' OR label == 'Back'")).firstMatch
            if close.appears(timeout: 2) { close.tap(); pause(1) }
            tap("home", "home-after-search\(i)")
        }
    }

    /// Every filter group as photo tiles (owner, 2026-11-11): Fear of God's
    /// page, then a skincare search for the brand-said groups. One screenshot
    /// per group, kept as attachments.
    func testEveryFilterGroupAsPhotosTour() {
        app.launch()
        XCTAssertTrue(app.storeSearchField().appears(timeout: 60))
        func shot(_ name: String) {
            let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
        }
        func walkGroups(_ prefix: String) {
            let groups = app.buttons.matching(identifier: "filterGroup")
            XCTAssertTrue(groups.firstMatch.appears(timeout: 10))
            let labels = groups.allElementsBoundByIndex.map(\.label)
            for label in labels {
                let g = app.buttons.matching(NSPredicate(format: "identifier == 'filterGroup' AND label == %@", label)).firstMatch
                guard g.appears(timeout: 3) else { continue }
                g.tap()
                pause(3.5)  // the tiles' photos load
                shot("\(prefix) – \(label)")
            }
        }
        app.storeSearchField().tap()
        XCTAssertTrue(any("searchInput").appears(timeout: 5))
        any("searchInput").typeText("Fear of God pants\n")
        XCTAssertTrue(any("resultTitle").appears(timeout: 10))
        any("resultTitle").tap()
        XCTAssertTrue(any("visitStore").appears(timeout: 5))
        any("visitStore").tap()
        XCTAssertTrue(any("filtersButton").appears(timeout: 10))
        pause(1.5)
        any("filtersButton").tap()
        walkGroups("Fear of God")
        let close = app.buttons.matching(NSPredicate(format: "identifier == 'filtersClose' OR label == 'Close'")).firstMatch
        if close.appears(timeout: 3) { close.tap() } else { app.swipeDown(velocity: .fast) }
        pause(1.0)

        let field = app.storeSearchField()
        if field.appears(timeout: 5) {
            field.tap()
            XCTAssertTrue(any("searchInput").appears(timeout: 5))
            any("searchInput").typeText("serum\n")
            XCTAssertTrue(any("resultsHeader").appears(timeout: 10))
            any("filtersButton").tap()
            walkGroups("Search “serum”")
        }
    }

    /// Shopper profiles (2026-11-08): look at skincare and at sneakers, add a
    /// sized hoodie to the bag, then You › Your taste and Home's "Something new
    /// to try". Screenshots kept as attachments.
    func testShopperProfilesTour() {
        app.launchArguments += ["-ALLOW_MEANING"]
        app.launch()
        XCTAssertTrue(app.storeSearchField().appears(timeout: 60))
        func shot(_ name: String) {
            let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
        }
        func browse(_ query: String, count: Int) {
            app.storeSearchField().tap()
            XCTAssertTrue(any("searchInput").appears(timeout: 5))
            any("searchInput").typeText(query + "\n")
            for i in 0..<count {
                let results = app.descendants(matching: .any).matching(identifier: "resultTitle")
                XCTAssertTrue(results.firstMatch.appears(timeout: 10))
                guard i < results.count else { break }
                results.element(boundBy: i).tap()
                pause(6)
                let back = app.navigationBars.buttons.matching(NSPredicate(format: "identifier == 'BackButton' OR label == 'Back'")).firstMatch
                if back.exists { back.tap() } else { app.swipeRight() }
                pause(1)
            }
        }
        browse("shea butter", count: 4)
        shot("After skincare")
        app.buttons["tab.home"].tap(); pause(1)
        browse("sneakers", count: 4)
        app.buttons["tab.home"].tap(); pause(1)
        app.storeSearchField().tap()
        any("searchInput").typeText("Fear of God hoodie\n")
        XCTAssertTrue(any("resultTitle").appears(timeout: 10))
        any("resultTitle").tap()
        let addButton = app.buttons["addToCart"]
        if addButton.appears(timeout: 10) { pause(4); addButton.tap(); pause(1) }

        app.buttons["tab.you"].tap()
        XCTAssertTrue(any("yourTasteRow").appears(timeout: 10))
        any("yourTasteRow").tap()
        pause(6)
        shot("Your taste")
        app.swipeUp(velocity: .slow); pause(2)
        shot("Your taste, lower")

        app.buttons["tab.home"].tap()
        pause(2)
        for _ in 0..<8 where !any("pickedForYou").isHittable { app.swipeUp(velocity: .slow); pause(0.8) }
        if any("pickedForYou").isHittable { pause(3); shot("Picked for you") }
        for _ in 0..<25 where !any("exploreRow").isHittable { app.swipeUp(velocity: .slow); pause(0.6) }
        XCTAssertTrue(any("exploreRow").isHittable, "no Something new to try row")
        pause(3); shot("Something new to try")
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// Brand page (2026-11-10): pull down for the brand's name, huge, then
    /// scroll down and back up for the quick-return filter shelf.
    func testBrandMotionTour() {
        app.launchArguments += ["-SKIP_SPLASH", "-OFFLINE_CATALOG"]
        app.launch()
        app.open(URL(string: "marracat://brand/telfar")!)
        XCTAssertTrue(any("brandHero").appears(timeout: 30))
        pause(2)
        shot("01 brand page")
        mark("pull")
        let w = app.windows.firstMatch
        let from = w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        from.press(forDuration: 0.1, thenDragTo: w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62)),
                   withVelocity: .slow, thenHoldForDuration: 2.5)
        pause(1.5)
        mark("scroll")
        app.swipeUp(velocity: .slow)
        pause(0.6)
        app.swipeUp(velocity: .slow)
        pause(1)
        shot("03 scrolled down")
        mark("back")
        w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
            .press(forDuration: 0.05, thenDragTo: w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)))
        pause(1)
        shot("04 scrolled back up")
        pause(2)
    }
}

