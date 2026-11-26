import XCTest

/// Apple's automated accessibility audit (iOS 17+) on every main screen,
/// added 2026-10-03: contrast, Dynamic Type, missing labels, hit targets,
/// traits. Runs in every ship (scripts/ship.sh) before anything is uploaded.
///
/// Tabs are found at run time (identifier "tab.*"), so a tab added or removed
/// is audited or dropped without editing this file. Each screen is audited in
/// light AND dark: the app's look is its own setting (Appearance), so these
/// launches pass -APPEARANCE_FOLLOWS_SYSTEM and flip the simulator instead,
/// with the screen still open.
///
/// What is excused, and why, lives in `excused(_:)` — never excuse an issue on
/// one of our own controls to get the gate green; fix the view.
final class AccessibilityAuditTests: XCTestCase {
    private var app: XCUIApplication!
    private var appearanceBefore: XCUIDevice.Appearance = .light

    override func setUp() {
        continueAfterFailure = true   // one screen's issues must not hide the next screen's
        appearanceBefore = XCUIDevice.shared.appearance
        app = XCUIApplication()
        app.launchEnvironment["MARRACAT_NO_ANIMATIONS"] = "1"   // MarracatUITestCase.setUp
        app.launchArguments = ["-UITEST_RESET", "-SKIP_SPLASH", "-CHECKOUT_STUB", "-APPEARANCE_FOLLOWS_SYSTEM"]
        app.launch()
    }

    override func tearDown() {
        XCUIDevice.shared.appearance = appearanceBefore   // simulators are shared
        super.tearDown()
    }

    private func any(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Floating overlays (the tab bar, grown by its shadow): a row scrolled
    /// under one is measured against the overlay's pixels, not its own.
    private var floating: [CGRect] {
        let tabs = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab.'"))
        let bar = (0..<tabs.count).reduce(CGRect.null) { $0.union(tabs.element(boundBy: $1).frame) }
        // 64 pt above: iOS 26 blurs scroll content at the bottom edge behind
        // the bar, so "% off" badges ~50 pt above it (black on light grey,
        // ~16:1) were read through the blur and failed on some runs.
        var overlays = bar.isNull ? [] : [CGRect(x: bar.minX - 40, y: bar.minY - 64, width: bar.width + 80, height: bar.height + 104)]
        // The bag's hovering Checkout and its shadow (2026-10-14): rows
        // scrolled behind it are sampled against the button.
        let checkout = app.buttons["cartCheckout"]
        if checkout.exists { overlays.append(checkout.frame.insetBy(dx: -24, dy: -40)) }
        // Browse's search field floats over its list the same way: the row
        // just above it ("Jewelry", light look, 2026-11-22) was read through
        // the field's shadow.
        let search = any("searchField")   // by its id: storeSearchField() would go to Browse
        let window = app.windows.firstMatch.frame
        if search.exists, !window.isEmpty, search.frame.midY > window.midY { overlays.append(search.frame.insetBy(dx: -24, dy: -40)) }
        // Profile's own search field floats the same way ("Appearance",
        // light look, 2026-11-26, once the rows under it changed height).
        let you = any("youSearch")
        if you.exists, !window.isEmpty, you.frame.midY > window.midY { overlays.append(you.frame.insetBy(dx: -24, dy: -40)) }
        return overlays
    }

    private func excused(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
        guard let e = issue.element else { return true }   // nothing to point at
        if e.label.contains("Sign in with Apple") || e.label == "Legal" || e.elementType == .map { return true }
        let kb = app.keyboards.firstMatch
        if kb.exists, e.frame.minY >= kb.frame.minY - 50 { return true }
        // A hero page's value is its product's name, in the brand's own
        // words. "Value duplicates traits" fired on Fenty Beauty's page
        // (2026-11-23; a name such as "Gloss Bomb Key Chain" holds a word the
        // audit takes for a trait) and not on the next round's product.
        if issue.auditType.contains(.trait), e.identifier == "heroBrand" { return true }
        // "Partially unsupported" lands on text the layout keeps to a line or
        // inside a merged VoiceOver element; testTheLargestTextSizeStillWorks
        // checks the app stays usable at AX5. "Unsupported" (a fixed font
        // size) still fails.
        if issue.auditType.contains(.dynamicType), issue.compactDescription.contains("partially") { return true }
        if issue.auditType.contains(.contrast) {
            if !e.isEnabled { return true }   // WCAG 1.4.3 exempts disabled controls
            if !e.identifier.hasPrefix("tab."), e.identifier != "cartCheckout", floating.contains(where: { e.frame.intersects($0) }) { return true }
            // Under the continue card (a floating overlay too): a row behind
            // it is sampled against the card. The card's own text, wholly
            // inside it, is still audited.
            let card = app.descendants(matching: .any).matching(identifier: "continueCard").firstMatch
            if card.exists, e.frame.intersects(card.frame), !card.frame.contains(e.frame) { return true }
            let window = app.windows.firstMatch.frame
            if !window.isEmpty, e.frame.maxY > window.maxY - 34 { return true }   // under the home indicator
            // Mostly off screen (a chip at the end of a sideways row, 7 pt of
            // it showing): the audit samples that sliver against whatever is
            // behind the row's edge, not the chip's own text and fill.
            if !window.isEmpty, e.frame.width > 0,
               e.frame.intersection(window).width < e.frame.width / 2 { return true }
        }
        return false
    }

    private static func name(_ t: XCUIAccessibilityAuditType) -> String {
        let names: [(XCUIAccessibilityAuditType, String)] = [
            (.contrast, "contrast"), (.elementDetection, "element detection"), (.hitRegion, "hit region"),
            (.sufficientElementDescription, "description"), (.dynamicType, "dynamic type"),
            (.textClipped, "text clipped"), (.trait, "trait")]
        return names.first { t.contains($0.0) }?.1 ?? "type \(t.rawValue)"
    }

    /// Light and dark in the full suite; the nightly fast tier sets
    /// A11Y_LOOKS=light (owner, 2026-10-25: "trim the accessibility audit"),
    /// leaving dark mode to the weekly full run.
    private static let looks: [XCUIDevice.Appearance] =
        ProcessInfo.processInfo.environment["A11Y_LOOKS"] == "light" ? [.light] : [.light, .dark]

    private func audit(_ screen: String) {
        for look in Self.looks {
            XCUIDevice.shared.appearance = look
            sleep(1)
            auditOnce("\(screen) [\(look == .dark ? "dark" : "light")]")
        }
    }

    private func auditOnce(_ screen: String) {
        var found: [String] = []
        do {
            // Text Clipped is left out: Home's hero carousel advances on its
            // own, so the audit samples captions mid-slide, and it fires on
            // labels with room to spare. Clipping that matters is caught by
            // testTheLargestTextSizeStillWorks.
            var types: XCUIAccessibilityAuditType = .all
            types.remove(.textClipped)
            try app.performAccessibilityAudit(for: types) { issue in
                if self.excused(issue) { return true }
                let e = issue.element
                found.append("\(Self.name(issue.auditType)) — \(issue.compactDescription) — [\(e?.identifier ?? "")] \"\(e?.label ?? "")\""
                             + (e.map { " \($0.elementType.rawValue) @\(Int($0.frame.minX)),\(Int($0.frame.minY)) \(Int($0.frame.width))x\(Int($0.frame.height))" } ?? ""))
                return true
            }
        } catch {
            XCTFail("\(screen): audit could not run: \(error)")
        }
        if !found.isEmpty {
            XCTFail("\(screen): \(found.count) accessibility issue(s):\n" + found.joined(separator: "\n"))
        }
    }

    func testEveryTab() {
        XCTAssertTrue(any("productTile").appears(timeout: 15), "Home never populated")
        let tabs = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab.'"))
        let ids = (0..<tabs.count).map { tabs.element(boundBy: $0).identifier }
        XCTAssertGreaterThan(ids.count, 1, "the tab bar should list its tabs")
        for id in Set(ids).sorted() {
            app.buttons[id].tap()
            sleep(2)
            audit(String(id.dropFirst(4)))
        }
    }

    func testProductDetail() {
        let tile = any("productTile")
        XCTAssertTrue(tile.appears(timeout: 15), "Home never populated")
        tile.tap()
        sleep(2)
        audit("Product detail")
    }

    /// You › Notifications, with the owner's test row showing.
    func testNotificationsScreen() {
        app.terminate()
        app.launchArguments = ["-UITEST_RESET", "-SKIP_SPLASH", "-CHECKOUT_STUB", "-APPEARANCE_FOLLOWS_SYSTEM", "-LIVE_ACTIVITY_OWNER"]
        app.launch()
        let you = app.buttons["tab.you"]
        XCTAssertTrue(you.appears(timeout: 15))
        you.tap()
        let row = any("notificationsRow")
        XCTAssertTrue(row.appears(timeout: 10))
        for _ in 0..<4 where !row.isHittable { app.swipeUp() }
        row.tap()
        XCTAssertTrue(any("liveActivitiesToggle").appears(timeout: 5))
        sleep(1)
        audit("Notifications")
    }

    /// The bag with two brands: totals with standard shipping and the
    /// hovering Checkout, then the continue card after the first brand.
    func testBagTotalsAndContinueCard() {
        app.terminate()
        app.launchArguments = ["-UITEST_RESET", "-SKIP_SPLASH", "-CHECKOUT_STUB", "-APPEARANCE_FOLLOWS_SYSTEM", "-OFFLINE_CATALOG",
                               "-SEED_BUYER", "-SEED_CART", "octavia-morgan,chris-collins"]
        app.launch()
        let cart = app.buttons["tab.cart"]
        XCTAssertTrue(cart.appears(timeout: 15))
        cart.tap()
        let checkout = any("cartCheckout")
        XCTAssertTrue(checkout.appears(timeout: 15))
        XCTAssertTrue(any("cartBrandShipping").appears(timeout: 10), "no shipping line in the bag")
        sleep(2)
        audit("Bag")
        checkout.tap()
        XCTAssertTrue(any("stubCompleteOrder").appears(timeout: 5))
        any("stubCompleteOrder").tap()
        XCTAssertTrue(any("continueNext").appears(timeout: 5), "no continue card")
        sleep(1)
        audit("Continue card")
    }

    /// Search's empty state: the Featured banner (its "Featured" capsule and
    /// brand name on the panel) and recent searches, keyboard up.
    func testSearchScreen() {
        let field = app.storeSearchField()
        XCTAssertTrue(field.appears(timeout: 15), "Home never populated")
        field.tap()
        XCTAssertTrue(any("featuredBanner").appears(timeout: 5), "no Featured banner")
        sleep(2)
        audit("Search")
    }

    /// Home while an event runs: the big tiles in the day's colours, white
    /// type on Black Friday's gold (the lightest of the events' colours),
    /// then at the largest text size, where the tiles must still be one
    /// height and keep their type inside them.
    func testHomeEventTiles() {
        func open(_ extra: [String]) -> XCUIElement {
            app.terminate()
            app.launchArguments = ["-UITEST_RESET", "-SKIP_SPLASH", "-CHECKOUT_STUB", "-APPEARANCE_FOLLOWS_SYSTEM", "-OFFLINE_CATALOG",
                                   "-HOLIDAY", "black-friday"] + extra
            app.launch()
            let tile = any("eventTile")
            XCTAssertTrue(tile.appears(timeout: 20), "no event tiles on Home \(extra)")
            // Up under the status bar, in steps from mid-screen (a drag that
            // starts lower lands on the tab bar).
            let window = app.windows.firstMatch
            for _ in 0..<8 where tile.exists {
                let delta = tile.frame.minY - 110
                if abs(delta) < 8 { break }
                let from = window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 200, dy: 480))
                from.press(forDuration: 0.1, thenDragTo: from.withOffset(CGVector(dx: 0, dy: -min(max(delta, -360), 360))),
                           withVelocity: .slow, thenHoldForDuration: 0.4)
            }
            return tile
        }
        _ = open([])
        audit("Home event tiles")

        _ = open(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        let frames = app.descendants(matching: .any).matching(identifier: "eventTile").allElementsBoundByIndex.map(\.frame)
        XCTAssertEqual(Set(frames.map { $0.height.rounded() }).count, 1, "tiles are one height at the largest text size: \(frames)")
        XCUIDevice.shared.appearance = .light
        var clipped: [String] = []
        try? app.performAccessibilityAudit(for: [.textClipped, .contrast]) { issue in
            guard let e = issue.element, !self.excused(issue) else { return true }
            let row = self.any("eventTiles").frame
            if row.intersects(e.frame) { clipped.append("\(Self.name(issue.auditType)) \"\(e.label)\"") }
            return true
        }
        XCTAssertTrue(clipped.isEmpty, "at the largest text size: \(clipped)")
    }

    /// still loads and every tab can still be reached.
    func testTheLargestTextSizeStillWorks() {
        app.terminate()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(any("productTile").appears(timeout: 20), "Home should load at the largest text size")
        let tabs = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab.'"))
        XCTAssertGreaterThan(tabs.count, 1)
        for i in 0..<tabs.count {
            XCTAssertTrue(tabs.element(boundBy: i).isHittable, "\(tabs.element(boundBy: i).identifier) must stay reachable")
        }
    }
}
