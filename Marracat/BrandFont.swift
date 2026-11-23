import SwiftUI
import UIKit

/// The app's type: Futura, the typeface of the MARRACAT wordmark (owner,
/// 2026-11-22: "use our logo's font throughout the app for all text").
/// iOS ships Futura in two upright weights, Medium and Bold, so regular and
/// medium text is Futura Medium and semibold and heavier is Futura Bold.
///
/// Views set type with `.brandFont(.subheadline.bold())` in place of
/// `.font(...)`: the same text-style names and modifiers as `Font`, sized
/// from the same points and still scaling with Dynamic Type. Receipts keep
/// their monospaced print face, and codes asked for as `.monospaced()` keep
/// the system's.
struct BrandFont: Equatable {
    enum Size: Equatable { case style(Font.TextStyle), fixed(CGFloat) }

    var size: Size
    var weight: Font.Weight = .regular
    var isItalic = false
    var isMonospaced = false

    static let medium = "Futura-Medium", bold = "Futura-Bold", mediumItalic = "Futura-MediumItalic"

    static let largeTitle = BrandFont(size: .style(.largeTitle))
    static let title = BrandFont(size: .style(.title))
    static let title2 = BrandFont(size: .style(.title2))
    static let title3 = BrandFont(size: .style(.title3))
    /// A headline is semibold, as the system's is.
    static let headline = BrandFont(size: .style(.headline), weight: .semibold)
    static let subheadline = BrandFont(size: .style(.subheadline))
    static let body = BrandFont(size: .style(.body))
    static let callout = BrandFont(size: .style(.callout))
    static let footnote = BrandFont(size: .style(.footnote))
    static let caption = BrandFont(size: .style(.caption))
    static let caption2 = BrandFont(size: .style(.caption2))

    /// A fixed size, as `Font.system(size:)` is: it does not follow Dynamic Type.
    static func system(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> BrandFont {
        BrandFont(size: .fixed(size), weight: weight, isMonospaced: design == .monospaced)
    }

    func bold() -> BrandFont { weight(.bold) }
    func weight(_ weight: Font.Weight) -> BrandFont { var f = self; f.weight = weight; return f }
    func italic() -> BrandFont { var f = self; f.isItalic = true; return f }
    func monospaced() -> BrandFont { var f = self; f.isMonospaced = true; return f }

    /// The points each text style has at the default text size (Apple's
    /// Large), which `Font.custom(_:size:relativeTo:)` scales from.
    static func points(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: 34
        case .title: 28
        case .title2: 22
        case .title3: 20
        case .headline, .body: 17
        case .callout: 16
        case .subheadline: 15
        case .footnote: 13
        case .caption: 12
        case .caption2: 11
        @unknown default: 17
        }
    }

    /// Semibold and heavier is Futura Bold; everything lighter is Futura Medium.
    var isHeavy: Bool { [Font.Weight.semibold, .bold, .heavy, .black].contains(weight) }

    var face: String { isHeavy ? Self.bold : isItalic ? Self.mediumItalic : Self.medium }

    var font: Font {
        if isMonospaced {
            switch size {
            case .style(let style): return Font.system(style, design: .monospaced).weight(weight)
            case .fixed(let points): return Font.system(size: points, weight: weight, design: .monospaced)
            }
        }
        switch size {
        case .style(let style): return Font.custom(face, size: Self.points(style), relativeTo: style)
        case .fixed(let points): return Font.custom(face, fixedSize: points)
        }
    }

    /// The same face for UIKit's own bars and controls.
    static func ui(_ points: CGFloat, heavy: Bool = false) -> UIFont {
        UIFont(name: heavy ? bold : medium, size: points) ?? .systemFont(ofSize: points, weight: heavy ? .bold : .regular)
    }

    /// Navigation titles and segmented controls are UIKit's: give them the
    /// face too. Once, at launch.
    @MainActor static func applyToSystemControls() {
        let bar = UINavigationBar.appearance()
        bar.titleTextAttributes = (bar.titleTextAttributes ?? [:]).merging([.font: ui(17, heavy: true)]) { $1 }
        bar.largeTitleTextAttributes = (bar.largeTitleTextAttributes ?? [:]).merging([.font: ui(34, heavy: true)]) { $1 }
        let segments = UISegmentedControl.appearance()
        segments.setTitleTextAttributes([.font: ui(13)], for: .normal)
        segments.setTitleTextAttributes([.font: ui(13, heavy: true)], for: .selected)
        UIBarButtonItem.appearance().setTitleTextAttributes([.font: ui(17)], for: .normal)
    }
}

extension View {
    /// The app's typeface at a text style or size (`BrandFont`).
    func brandFont(_ font: BrandFont) -> some View { self.font(font.font) }
}

extension Text {
    /// Stays a `Text`, so it can still be joined to another or resolved in a canvas.
    func brandFont(_ font: BrandFont) -> Text { self.font(font.font) }
}

/// A screen's title in the top bar, in the app's typeface. Use it in place
/// of `navigationTitle`.
///
/// The bar draws a `navigationTitle` itself, and from iOS 26 it does so in
/// the system face whatever the bar's appearance asks for: the search term
/// over a page of results, "Filters" and "Account settings" all stayed in
/// San Francisco. So the title is also given to the bar as a view, which
/// takes the system title's place (leading beside the back button, or
/// centred on a sheet). The plain title stays for the back button's menu,
/// the UI tests and VoiceOver, which still reads the bar's own title: the
/// view is hidden from it, or it would say every title twice. Before iOS 26
/// the bar takes its face from `BrandFont.applyToSystemControls`.
private struct BarTitle: ViewModifier {
    let text: Text
    let isEmpty: Bool

    func body(content: Content) -> some View {
        content
            .navigationTitle(text)
            .toolbar {
                if #available(iOS 26.0, *), !isEmpty {
                    ToolbarItem(placement: .title) {
                        text.brandFont(.headline).lineLimit(1).accessibilityHidden(true)
                    }
                }
            }
    }
}

extension View {
    func barTitle(_ title: LocalizedStringKey) -> some View { modifier(BarTitle(text: Text(title), isEmpty: false)) }
    func barTitle(_ title: Text) -> some View { modifier(BarTitle(text: title, isEmpty: false)) }
    @_disfavoredOverload
    func barTitle<S: StringProtocol>(_ title: S) -> some View { modifier(BarTitle(text: Text(title), isEmpty: title.isEmpty)) }
}
