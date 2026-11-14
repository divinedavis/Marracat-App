import Testing
import CoreGraphics
@testable import Marracat

/// Wide windows (iPhone Duo opened, iPad, a resized iPhone Mirroring window):
/// how many feed columns, when the sidebar replaces the floating bar, and
/// where each Home section lands. Widths are the windows' points: Duo's outer
/// display 466, its inner display 669 portrait and 951 landscape (Apple's
/// screenshot sizes 1398x2034 and 2007x2853 at 3x).
@Suite("Adaptive layout")
struct AdaptiveLayoutTests {
    @Test("Feed columns follow the window's width", arguments: [
        (CGFloat(320), 1), (402, 1), (440, 1), (466, 1),   // phones and Duo's outer display
        (669, 2), (744, 2), (834, 2), (951, 2),             // Duo inner, iPad mini, iPad 11" portrait
        (1080, 3), (1194, 3), (1376, 3),                    // iPad landscape
    ])
    func feedColumns(width: CGFloat, columns: Int) {
        #expect(AdaptiveLayout.feedColumns(width: width) == columns)
    }

    @Test("The sidebar only where it fits: regular width and 800pt or more")
    func sidebar() {
        #expect(!AdaptiveLayout.showsSidebar(width: 466, sizeClass: .compact), "Duo closed")
        #expect(!AdaptiveLayout.showsSidebar(width: 669, sizeClass: .regular), "Duo opened in portrait keeps the bar")
        #expect(AdaptiveLayout.showsSidebar(width: 951, sizeClass: .regular), "Duo opened in landscape")
        #expect(AdaptiveLayout.showsSidebar(width: 1032, sizeClass: .regular), "iPad 13\" portrait")
        #expect(!AdaptiveLayout.showsSidebar(width: 1000, sizeClass: .compact), "a compact window never does")
        #expect(!AdaptiveLayout.showsSidebar(width: 0, sizeClass: .regular), "not measured yet")
        #expect(!AdaptiveLayout.showsSidebar(width: 900, sizeClass: nil))
    }

    @Test("One column stacks every section like a VStack")
    func oneColumn() {
        let frames = AdaptiveLayout.feedFrames(count: 3, fullWidth: { $0 == 1 }, width: 402, columns: 1, spacing: 12) { i, w in
            #expect(w == 402)
            return [100, 50, 80][i]
        }
        #expect(frames == [CGRect(x: 0, y: 0, width: 402, height: 100),
                           CGRect(x: 0, y: 112, width: 402, height: 50),
                           CGRect(x: 0, y: 174, width: 402, height: 80)])
    }

    @Test("Two columns pair rows, each pair as tall as its tallest")
    func twoColumns() {
        let frames = AdaptiveLayout.feedFrames(count: 3, fullWidth: { _ in false }, width: 672, columns: 2, spacing: 12) { i, w in
            #expect(w == 330)
            return [200, 240, 210][i]
        }
        #expect(frames[0] == CGRect(x: 0, y: 0, width: 330, height: 200))
        #expect(frames[1] == CGRect(x: 342, y: 0, width: 330, height: 240))
        #expect(frames[2] == CGRect(x: 0, y: 252, width: 330, height: 210), "an odd row out starts the next line")
    }

    @Test("A full-width section closes the row and spans every column")
    func fullWidthBreaksTheRow() {
        let full: Set<Int> = [1]
        let frames = AdaptiveLayout.feedFrames(count: 4, fullWidth: { full.contains($0) }, width: 900, columns: 3, spacing: 10) { i, _ in
            [100, 300, 120, 140][i]
        }
        #expect(frames[0].origin == .zero && frames[0].width == (900 - 20) / 3)
        #expect(frames[1] == CGRect(x: 0, y: 110, width: 900, height: 300))
        #expect(frames[2].minY == 420 && frames[3].minY == 420 && frames[3].minX > frames[2].maxX)
    }

    @Test("Nothing to place, nothing placed")
    func empty() {
        #expect(AdaptiveLayout.feedFrames(count: 0, fullWidth: { _ in false }, width: 600, columns: 2, spacing: 12) { _, _ in 0 } == [])
    }
}

/// The floating bar and the sidebar share one set of tap rules (AppNav.tap).
@MainActor
@Suite("Tab taps")
struct TabTapTests {
    @Test("A tap selects; a tap on the selected tab pops it to its root")
    func selectAndReselect() {
        let nav = AppNav()
        nav.tap(.saved)
        #expect(nav.tab == .saved)
        nav.tap(.saved)
        #expect(nav.reselected[.saved] == 1)
    }

    @Test("Browse: first tap lands on the page, the second opens search, from a pushed screen it pops first")
    func browse() {
        let nav = AppNav(), router = Router()
        nav.routers[.browse] = router
        nav.tap(.browse)
        #expect(nav.tab == .browse && nav.search == nil)
        router.path = [.deals]
        nav.tap(.browse)
        #expect(nav.reselected[.browse] == 1 && nav.search == nil)
        router.path = []
        nav.tap(.browse)
        #expect(nav.search?.tab == .browse)
    }
}
