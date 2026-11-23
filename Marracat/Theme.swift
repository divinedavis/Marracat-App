import SwiftUI
import UIKit

/// Monochrome, ASOS-style. Light is the default (owner, 2026-11-22: "The app
/// needs to be all white theme as default"): a white ground, pale grey
/// surfaces, black and grey type. Dark is the look the app had until then, a
/// black ground with charcoal surfaces, kept value for value and chosen in
/// Profile > Appearance (`Appearance`). Only product photography carries
/// colour. The legacy token names (cocoa, gold, …) are kept so every screen
/// picks up the greys unchanged.
enum Theme {
    /// One colour per look. The dark value is what the token always was.
    static func pair(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
    static func grey(light: CGFloat, dark: CGFloat) -> Color {
        pair(light: UIColor(white: light, alpha: 1), dark: UIColor(white: dark, alpha: 1))
    }
    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> UIColor { UIColor(red: r, green: g, blue: b, alpha: 1) }

    // Grounds
    static let canvas = grey(light: 1, dark: 0)                                              // page (#FFF / #000)
    static let surface = pair(light: rgb(0.96, 0.96, 0.97), dark: rgb(0.11, 0.11, 0.12))     // cards, sections (#F5F5F7 / #1C1C1E)
    static let field = pair(light: rgb(0.925, 0.925, 0.937), dark: rgb(0.176, 0.180, 0.192)) // search bar, chips (#ECECEF / #2D2E31)
    static let hairline = grey(light: 0.87, dark: 0.24)                                      // strokes and dividers
    static let tile = Color(white: 0.93)                              // light well behind product photos, in both looks
    static let textSecondary = grey(light: 0.40, dark: 0.62)
    /// Grey type, in place of the system's `.secondary`. That is 60% of the
    /// label colour: fine on black, but 3.5:1 on white, which Apple's own
    /// contrast audit fails ("nearly passed") on captions. Dark keeps the
    /// system's value; light is a solid grey at 5:1 and over on every ground.
    static let secondary = pair(light: UIColor(white: 0.40, alpha: 1),
                                dark: UIColor.secondaryLabel.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)))

    /// A badge's colour as type or a glyph on the page. The badge colours are
    /// bright, chosen against black: on white they wash out (gold is 2:1), so
    /// light darkens them; dark keeps them as they are. Fills (a seal's disc,
    /// a corner tab) keep the colour itself in both looks.
    static func ink(_ color: Color) -> Color {
        let ui = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)).getRed(&r, green: &g, blue: &b, alpha: &a)
        return pair(light: UIColor(red: r * 0.55, green: g * 0.55, blue: b * 0.55, alpha: a), dark: ui)
    }

    // Former brand colours, now shades of grey
    static let cocoa = pair(light: rgb(0.925, 0.925, 0.937), dark: rgb(0.17, 0.17, 0.18))    // panels (#ECECEF / #2C2C2E)
    static let amber = grey(light: 0.45, dark: 0.56)                  // icons
    /// The primary button: black with white text in light, light grey with
    /// black text in dark. Whatever sits on it wears `onGold`.
    static let gold = grey(light: 0.09, dark: 0.90)
    static let onGold = grey(light: 1, dark: 0)
    static let orange = pair(light: rgb(0.925, 0.925, 0.937), dark: rgb(0.17, 0.17, 0.18))   // secondary button: `.primary` text
    static let deal = grey(light: 0.10, dark: 0.90)                   // markdown badges (`onGold` type) and text
    static let link = grey(light: 0.30, dark: 0.78)
    static let stock = grey(light: 0.25, dark: 0.82)
    /// The strongest ground against the page (a selected chip, a pill that
    /// floats over the page): white in dark, black in light. `onGold` on it.
    static let inverse = grey(light: 0.09, dark: 1)
    /// The Filters and Sort pill that floats over a grid.
    static let floating = grey(light: 0.09, dark: 0.95)
    /// The one colour outside the greys: the certified-organic leaf.
    static let organic = Color(red: 0.30, green: 0.69, blue: 0.31)
    /// And the second: the Marracat Clean ingredient badge, blue.
    static let clean = Color(red: 0.25, green: 0.56, blue: 0.96)
    /// Order progress: the filled steps of an order and its Delivered badge
    /// (owner, 2026-11-10, "The product, big"). iOS's own system green.
    static let delivered = Color(red: 0.19, green: 0.82, blue: 0.35)
    /// And the third: the Marracat True Metal jewelry badge, warm gold.
    static let metal = Color(red: 0.86, green: 0.68, blue: 0.30)
    /// The Marracat Clear Scent fragrance badge, soft violet.
    static let scent = Color(red: 0.66, green: 0.55, blue: 0.95)
    /// The Marracat Safer Clean household badge, fresh green.
    static let saferClean = Color(red: 0.36, green: 0.78, blue: 0.52)
    /// The Marracat Clean Food grocery badge, warm orange.
    static let cleanFood = Color(red: 0.96, green: 0.58, blue: 0.24)
    /// The Marracat Baby Safe badge, soft sky blue.
    static let babySafe = Color(red: 0.45, green: 0.72, blue: 0.96)
    /// The Marracat Natural Fiber clothing badge, flax tan.
    static let naturalFiber = Color(red: 0.84, green: 0.72, blue: 0.52)
    /// The Marracat Safe Fabric clothing badge, teal.
    static let safeFabric = Color(red: 0.30, green: 0.76, blue: 0.74)
    /// The Marracat Lab Verified wellness badge, lab violet.
    static let labVerified = Color(red: 0.64, green: 0.56, blue: 0.98)
    /// The Marracat Pet Safe badge, paw coral.
    static let petSafe = Color(red: 0.98, green: 0.52, blue: 0.48)
    /// The Marracat True Material bag badge, saddle brown.
    static let trueMaterial = Color(red: 0.78, green: 0.55, blue: 0.36)
    /// The Marracat Natural Home badge, sage green.
    static let naturalHome = Color(red: 0.60, green: 0.78, blue: 0.56)

    static let chipColors: [Color] = [
        grey(light: 0.92, dark: 0.20), grey(light: 0.90, dark: 0.24), grey(light: 0.93, dark: 0.17), grey(light: 0.88, dark: 0.28),
        grey(light: 0.91, dark: 0.22), grey(light: 0.89, dark: 0.26), grey(light: 0.93, dark: 0.19), grey(light: 0.87, dark: 0.30),
    ]

    static let header = grey(light: 1, dark: 0)
    static let headerSoft = grey(light: 0.985, dark: 0.04)

    static var headerGradient: LinearGradient {
        LinearGradient(colors: [header, headerSoft], startPoint: .top, endPoint: .bottom)
    }
}

/// Sizes that keep screens in proportion on iPad, where a window can be
/// anything from a phone's width to a 13-inch screen. Everything keys off the
/// window's width, never the device, so a narrow iPad window gets the phone layout.
enum Widths {
    /// Text-heavy pages (the product page, cart, forms) stop widening here and centre.
    static let readable: CGFloat = 720
    /// Grid tiles are at least this wide: two across on any iPhone, five or six on a big iPad.
    static let gridTile: CGFloat = 165
}

extension View {
    /// Caps the width and centres it; at phone widths this changes nothing.
    func readableWidth(_ max: CGFloat = Widths.readable) -> some View {
        frame(maxWidth: max, alignment: .leading).frame(maxWidth: .infinity)
    }
}

/// A list or form section under a title in `Theme.secondary`. The system's
/// own header grey is under 4.5:1 on the light look's grounds ("Shopping
/// alerts" in Notifications failed the contrast audit, 2026-11-22).
struct TitledSection<Content: View>: View {
    private let title: Text
    private let content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = Text(title)
        self.content = content()
    }

    /// A title that is already a string (a shopper's own words, a localized one).
    init(verbatim title: String, @ViewBuilder content: () -> Content) {
        self.title = Text(verbatim: title)
        self.content = content()
    }

    var body: some View {
        Section { content } header: { title.foregroundStyle(Theme.secondary) }
    }
}

struct PillButtonStyle: ButtonStyle {
    var color: Color
    var text: Color = Theme.onGold
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brandFont(.body)
            .foregroundStyle(isEnabled ? text : Theme.textSecondary)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity)
            .background(Capsule().fill(isEnabled ? color : Theme.field))
            .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
