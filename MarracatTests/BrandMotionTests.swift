import SwiftUI
import Testing
import UIKit
@testable import Marracat

/// The brand page's Filters pill that steps aside and the photo colours behind
/// its pull-down name (owner, 2026-11-10, picked from previews).
@MainActor
struct BrandMotionTests {
    @Test func theFiltersStepAsideOnTheWayDownAndComeBackOnTheWayUp() {
        var q = QuickReturn()
        // At the top of the page: shown, whichever way you scroll.
        #expect(q.shown)
        for y in stride(from: 0, through: 40, by: 10) { q.update(offset: CGFloat(y)) }
        #expect(q.shown)
        // Scrolling down: the room is the products'.
        for y in stride(from: 40, through: 900, by: 20) { q.update(offset: CGFloat(y)) }
        #expect(!q.shown)
        // A small scroll up brings it back...
        q.update(offset: 894)
        #expect(!q.shown, "a jitter of 6 pt is not a scroll up")
        q.update(offset: 880)
        #expect(q.shown)
        // ...and a little more down is not enough to send it away...
        q.update(offset: 900)
        #expect(q.shown)
        // ...a real scroll down is.
        q.update(offset: 930)
        #expect(!q.shown)
        // Back at the top it shows, even mid-way down a scroll.
        q.update(offset: 30)
        #expect(q.shown)
        q.update(offset: 38)
        #expect(q.shown)
    }

    private func image(_ colors: [UIColor]) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { ctx in
            for (i, c) in colors.enumerated() {
                c.setFill()
                ctx.fill(CGRect(x: CGFloat(i) * 40 / CGFloat(colors.count), y: 0, width: 40 / CGFloat(colors.count), height: 40))
            }
        }
    }

    private func hsb(_ c: Color) -> (h: CGFloat, s: CGFloat, b: CGFloat) {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(c).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return (h, s, b)
    }

    @Test func thePhotosOwnHuesLightenedToReadOnTheDarkPage() {
        // A lavender and pink photo, like Fenty's, with a dark shadow in it.
        let colors = PhotoPalette.colors(from: image([UIColor(red: 0.70, green: 0.55, blue: 0.85, alpha: 1),
                                                      UIColor(red: 0.95, green: 0.62, blue: 0.75, alpha: 1),
                                                      UIColor(red: 0.08, green: 0.05, blue: 0.10, alpha: 1)]))
        #expect(colors.count == 2)
        let hues = colors.map { hsb($0).h }
        #expect(hues.contains { (0.70...0.82).contains($0) }, "the lavender: \(hues)")
        #expect(hues.contains { $0 > 0.88 || $0 < 0.02 }, "the pink: \(hues)")
        for c in colors {
            #expect(hsb(c).b > 0.85, "light enough to read on black")
            #expect(hsb(c).s <= 0.43, "pastel, not neon")
        }
    }

    @Test func aGreyPhotoGetsTheDefaultColours() {
        let colors = PhotoPalette.colors(from: image([.gray, .darkGray, .lightGray]))
        #expect(colors == PhotoPalette.fallback)
    }
}
