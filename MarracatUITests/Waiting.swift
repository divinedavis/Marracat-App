import XCTest

extension XCUIElement {
    /// waitForExistence without its first one-second poll. On Xcode 26.6 it
    /// takes ~1 s even when the element is already there, and 598 of a ship
    /// run's 654 waits were that (2026-10-18). `exists` is one ~0.05 s look;
    /// only an element not there yet is waited for.
    func appears(timeout: TimeInterval) -> Bool {
        exists || waitForExistence(timeout: timeout)
    }

    /// waitForNonExistence, likewise: an element already gone returns at once.
    func disappears(timeout: TimeInterval) -> Bool {
        !exists || waitForNonExistence(timeout: timeout)
    }
}

extension XCTestCase {
    /// Polls a condition every 0.1 s instead of sleeping a fixed second for
    /// a scroll or zoom to finish (2026-10-18).
    @discardableResult
    func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            usleep(100_000)
        }
        return true
    }
}

extension XCUIApplication {
    /// Store search lives on Browse, floating above the tab bar (owner,
    /// 2026-10-20, after IMDb); Home has none. This goes to Browse unless the
    /// bar is already on screen, then returns it.
    func storeSearchField() -> XCUIElement {
        let field = descendants(matching: .any).matching(identifier: "searchField").firstMatch
        if field.exists { return field }
        let browse = buttons["tab.browse"]
        // On Browse a second tap opens search outright, so only when it's
        // elsewhere (or on a screen pushed over Browse, which the tap pops).
        // The first tap shows Browse; if a screen is still pushed there (the
        // last search's results), a second one pops back to the bar.
        for _ in 0..<2 where browse.appears(timeout: 15) && !field.exists {
            browse.tap()
            if field.appears(timeout: 3) { break }
        }
        return field
    }

    /// The launch is over: the cover or splash has lifted on a storefront
    /// that's ready (MarracatApp.readyMarker). Wait on this when a test only
    /// needs the app up; it doesn't move when a screen's layout does.
    func appReady() -> XCUIElement {
        descendants(matching: .any).matching(identifier: "app.ready").firstMatch
    }

    /// Home has drawn (its hero carousel): for tests about Home itself.
    func homeReady() -> XCUIElement {
        descendants(matching: .any).matching(identifier: "heroBrand").firstMatch
    }
}
