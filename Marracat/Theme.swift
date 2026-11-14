import SwiftUI

/// Monochrome, ASOS-style: a black ground, charcoal surfaces, white and grey
/// type. Only product photography carries colour. The legacy token names
/// (cocoa, gold, …) are kept so every screen picks up the greys unchanged.
enum Theme {
    // Grounds
    static let canvas = Color.black                                   // page (#000)
    static let surface = Color(red: 0.11, green: 0.11, blue: 0.12)    // cards, sections (#1C1C1E)
    static let field = Color(red: 0.176, green: 0.180, blue: 0.192)   // search bar, chips (#2D2E31, sampled from ASOS)
    static let hairline = Color(white: 0.24)                          // strokes and dividers
    static let tile = Color(white: 0.93)                              // light well behind product photos
    static let textSecondary = Color(white: 0.62)

    // Former brand colours, now shades of grey
    static let cocoa = Color(red: 0.17, green: 0.17, blue: 0.18)      // panels (#2C2C2E)
    static let amber = Color(white: 0.56)                             // icons (#8E8E93)
    static let gold = Color(white: 0.90)                              // primary button: light grey, black text
    static let orange = Color(red: 0.17, green: 0.17, blue: 0.18)     // secondary button: charcoal, white text
    static let deal = Color(white: 0.90)                              // markdown badges and text
    static let link = Color(white: 0.78)
    static let stock = Color(white: 0.82)
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
        Color(white: 0.20), Color(white: 0.24), Color(white: 0.17), Color(white: 0.28),
        Color(white: 0.22), Color(white: 0.26), Color(white: 0.19), Color(white: 0.30),
    ]

    static let header = Color.black
    static let headerSoft = Color(white: 0.04)

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

struct PillButtonStyle: ButtonStyle {
    var color: Color
    var text: Color = .black
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body)
            .foregroundStyle(isEnabled ? text : Theme.textSecondary)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity)
            .background(Capsule().fill(isEnabled ? color : Theme.field))
            .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
