import XCTest

/// Drives the "how to use Marracat" video for TikTok (owner, 2026-10-04):
/// Home, a Shop by Style board, search by meaning, a product into the cart,
/// and checkout with address suggestions. The simulator is recorded with
/// `simctl io recordVideo` and cut by app-store/tiktok/make_tiktok.py.
/// Opt-in with TEST_RUNNER_MARRACAT_TIKTOK=1 so the release suite never runs it.
/// Each step prints "TOUR <name>" so the cut can find it.
final class TikTokTourUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MARRACAT_TIKTOK"] == "1",
                          "TikTok tour is opt-in (TEST_RUNNER_MARRACAT_TIKTOK=1)")
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-UITEST_RESET", "-CHECKOUT_STUB", "-ALLOW_MEANING", "-SPLASH_SECONDS", "1.2"]
    }

    func testTikTokTour() {
        app.launch()
        mark("start")
        XCTAssertTrue(any("productTile").waitForExistence(timeout: 40), "Home never populated")
        mark("home")
        pause(2.5)
        app.swipeUp(velocity: .slow)
        pause(1.2)

        // Shop by style: scroll Home until a board shows, open it.
        let board = any("styleBoard")
        for _ in 0..<8 where !board.isHittable { app.swipeUp(velocity: .slow); pause(0.6) }
        if board.isHittable {
            mark("style")
            pause(2)   // let the scroll settle: a tap mid-glide only stops it
            board.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            pause(3.5)
            mark("styleOpen")
            tapTab("Home")   // back to the top of Home
            pause(1)
        }

        // Search by meaning: describe it, don't name it.
        mark("search")
        search("an outfit for a summer wedding")
        let meaning = any("meaningHeader")
        _ = meaning.waitForExistence(timeout: 15)
        mark("results")
        pause(2.5)
        app.swipeUp(velocity: .slow)
        pause(1.5)

        // Open the first match by meaning: the first result below its header.
        let titles = app.descendants(matching: .any).matching(identifier: "resultTitle")
        let headerY = meaning.exists ? meaning.frame.maxY : 0
        let result = titles.allElementsBoundByIndex.first { $0.frame.minY > headerY && $0.isHittable } ?? titles.firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        result.tap()
        let add = any("addToCart")
        XCTAssertTrue(add.waitForExistence(timeout: 8))
        mark("product")
        pause(3)
        if add.isEnabled { add.tap() }
        mark("added")
        pause(1.5)

        // Checkout: details once, address suggestions fill the rest.
        tapTab("Cart")
        let all = any("cartCheckout")
        XCTAssertTrue(all.waitForExistence(timeout: 5))
        mark("cart")
        pause(2)
        all.tap()
        if any("buyerForm").waitForExistence(timeout: 5) {
            mark("details")
            for (id, text) in [("buyerFirstName", "Jordan"), ("buyerLastName", "Lee"),
                               ("buyerEmail", "jordan@example.com"), ("buyerPhone", "7185550100")] {
                let f = app.textFields[id]
                XCTAssertTrue(f.waitForExistence(timeout: 5), id)
                f.tap()
                f.typeText(text)
            }
            let street = app.textFields["buyerStreet"]
            street.tap()
            for ch in "350 5th Ave New Yo" { street.typeText(String(ch)); usleep(70_000) }
            let suggestion = app.buttons["addressSuggestion"].firstMatch
            if suggestion.waitForExistence(timeout: 12) {
                mark("suggest")
                pause(1.5)
                suggestion.tap()
                pause(2)
            }
            mark("filled")
            pause(1.5)
            let save = any("buyerSave")
            if save.isEnabled { save.tap() }
        }
        mark("checkout")
        pause(4)
        mark("end")
    }

    private func search(_ term: String) {
        tapTab("Home")
        tapTab("Home")
        let field = app.storeSearchField()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        let input = any("searchInput")
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        for ch in term { input.typeText(String(ch)); usleep(60_000) }
        input.typeText("\n")
        XCTAssertTrue(any("resultsHeader").waitForExistence(timeout: 10))
    }

    private func mark(_ name: String) { print("TOUR \(name) \(Date().timeIntervalSince1970)") }
    private func pause(_ s: Double) { usleep(useconds_t(s * 1_000_000)) }
    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func tapTab(_ name: String) {
        let tab = app.buttons["tab.\(name.lowercased())"]
        XCTAssertTrue(tab.waitForExistence(timeout: 5), "\(name) tab missing")
        tab.tap()
    }
}
