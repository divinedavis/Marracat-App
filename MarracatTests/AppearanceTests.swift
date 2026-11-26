import XCTest
import SwiftUI
@testable import Marracat

/// The app's look (owner, 2026-11-22): light unless the shopper chose dark,
/// and dark is the black look the app had before, value for value.
final class AppearanceTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "appearance-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    func testANewShopperGetsLight() {
        XCTAssertEqual(Appearance.stored(in: defaults()), .light)
        XCTAssertEqual(Appearance.light.scheme, .light)
    }

    func testDarkIsKeptOnceChosen() {
        let d = defaults()
        d.set(Appearance.dark.rawValue, forKey: Appearance.key)
        XCTAssertEqual(Appearance.stored(in: d), .dark)
        XCTAssertEqual(Appearance.dark.scheme, .dark)
    }

    func testAnUnknownStoredLookFallsBackToLight() {
        let d = defaults()
        d.set("sepia", forKey: Appearance.key)
        XCTAssertEqual(Appearance.stored(in: d), .light)
        d.set(3, forKey: Appearance.key)
        XCTAssertEqual(Appearance.stored(in: d), .light)
    }

    private func white(_ color: Color, _ style: UIUserInterfaceStyle) -> CGFloat {
        var w: CGFloat = 0, a: CGFloat = 0
        UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style)).getWhite(&w, alpha: &a)
        return w
    }

    private func rgb(_ color: Color, _ style: UIUserInterfaceStyle) -> [Int] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style)).getRed(&r, green: &g, blue: &b, alpha: &a)
        return [r, g, b].map { Int(($0 * 255).rounded()) }
    }

    /// Light: a white page, pale surfaces, a black primary button with white type.
    func testLightIsAWhitePageWithABlackPrimaryButton() {
        XCTAssertEqual(white(Theme.canvas, .light), 1, accuracy: 0.001)
        XCTAssertGreaterThan(white(Theme.surface, .light), 0.94)
        XCTAssertGreaterThan(white(Theme.field, .light), 0.9)
        XCTAssertLessThan(white(Theme.gold, .light), 0.15)
        XCTAssertEqual(white(Theme.onGold, .light), 1, accuracy: 0.001)
        XCTAssertLessThan(white(Theme.textSecondary, .light), 0.45, "grey type must stay readable on white")
    }

    /// Dark is the look the app shipped with until 2026-11-22: the same values.
    func testDarkKeepsTheValuesTheAppAlwaysHad() {
        XCTAssertEqual(rgb(Theme.canvas, .dark), [0, 0, 0])
        XCTAssertEqual(rgb(Theme.surface, .dark), [28, 28, 31])
        XCTAssertEqual(rgb(Theme.field, .dark), [45, 46, 49])
        XCTAssertEqual(rgb(Theme.cocoa, .dark), [43, 43, 46])
        XCTAssertEqual(white(Theme.hairline, .dark), 0.24, accuracy: 0.005)
        XCTAssertEqual(white(Theme.textSecondary, .dark), 0.62, accuracy: 0.005)
        XCTAssertEqual(white(Theme.gold, .dark), 0.90, accuracy: 0.005)
        XCTAssertEqual(white(Theme.onGold, .dark), 0, accuracy: 0.001)
        XCTAssertEqual(white(Theme.deal, .dark), 0.90, accuracy: 0.005)
        XCTAssertEqual(white(Theme.link, .dark), 0.78, accuracy: 0.005)
        XCTAssertEqual(white(Theme.inverse, .dark), 1, accuracy: 0.001)
    }

    private func contrast(_ a: Color, _ b: Color, _ style: UIUserInterfaceStyle) -> CGFloat {
        func luminance(_ c: Color) -> CGFloat {
            var r: CGFloat = 0, g: CGFloat = 0, bl: CGFloat = 0, al: CGFloat = 0
            UIColor(c).resolvedColor(with: UITraitCollection(userInterfaceStyle: style)).getRed(&r, green: &g, blue: &bl, alpha: &al)
            // Over black or white for the see-through system grey.
            let under: CGFloat = style == .dark ? 0 : 1
            let lin = [r, g, bl].map { $0 * al + under * (1 - al) }.map { $0 <= 0.03928 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2]
        }
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// Grey type and badge-coloured type clear 4.5:1 on the page, a card and
    /// a field in light (the system grey is 3.5:1 on white; gold was 2:1),
    /// and dark keeps the system grey and the badge colours themselves.
    func testGreyAndBadgeTypeReadOnEveryLightGround() {
        let badges = [Theme.clean, Theme.organic, Theme.metal, Theme.scent, Theme.saferClean, Theme.cleanFood, Theme.babySafe,
                      Theme.naturalFiber, Theme.safeFabric, Theme.labVerified, Theme.petSafe, Theme.trueMaterial, Theme.naturalHome, Theme.delivered]
        for ground in [Theme.canvas, Theme.surface, Theme.field] {
            XCTAssertGreaterThanOrEqual(contrast(Theme.secondary, ground, .light), 4.5)
            XCTAssertGreaterThanOrEqual(contrast(Theme.textSecondary, ground, .light), 4.5)
            for (i, badge) in badges.enumerated() {
                XCTAssertGreaterThanOrEqual(contrast(Theme.ink(badge), ground, .light), 4.5, "badge \(i)")
            }
        }
        XCTAssertEqual(rgb(Theme.ink(Theme.clean), .dark), rgb(Theme.clean, .dark))
        XCTAssertEqual(UIColor(Theme.secondary).resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)),
                       UIColor.secondaryLabel.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)))
    }

    /// Type on the primary button and on the selected chip is the opposite
    /// of its ground in both looks, and the photo well is light in both.
    func testButtonTypeOpposesItsGroundInBothLooks() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            XCTAssertGreaterThan(abs(white(Theme.gold, style) - white(Theme.onGold, style)), 0.8)
            XCTAssertGreaterThan(abs(white(Theme.inverse, style) - white(Theme.onGold, style)), 0.8)
            XCTAssertGreaterThan(abs(white(Theme.floating, style) - white(Theme.onGold, style)), 0.8)
            XCTAssertEqual(white(Theme.tile, style), 0.93, accuracy: 0.005)
        }
    }
}
