import SwiftUI
import UIKit

/// The app's type: the system's own face, San Francisco, and never bold.
///
/// Owner, 2026-11-22, on the build that set everything in Futura, the
/// wordmark's typeface: "I don't want bold and switch our font back." So the
/// face is the system's again, and the heaviest any text goes is medium:
/// what a view asks for as semibold, bold, heavy or black is drawn medium,
/// here, in one place. The wordmark itself stays Futura (LaunchAnimationView).
///
/// Views set type with `.brandFont(.subheadline.bold())` in place of
/// `.font(...)`: the same text-style names and modifiers as `Font`, so the
/// weight rule holds everywhere and the face can change in this file alone.
struct BrandFont: Equatable {
    enum Size: Equatable { case style(Font.TextStyle), fixed(CGFloat) }

    var size: Size
    var weight: Font.Weight = .regular
    var isItalic = false
    var isMonospaced = false

    /// The heaviest weight the app draws.
    static let heaviest = Font.Weight.medium

    static let largeTitle = BrandFont(size: .style(.largeTitle))
    static let title = BrandFont(size: .style(.title))
    static let title2 = BrandFont(size: .style(.title2))
    static let title3 = BrandFont(size: .style(.title3))
    /// A headline is semibold to the system; here that is medium, as all
    /// emphasis is.
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

    /// Asked for as semibold or heavier: emphasis, drawn at `heaviest`.
    var isHeavy: Bool { [Font.Weight.semibold, .bold, .heavy, .black].contains(weight) }

    /// The weight the text is drawn at: never above `heaviest`.
    var shownWeight: Font.Weight { isHeavy ? Self.heaviest : weight }

    var font: Font {
        let design: Font.Design = isMonospaced ? .monospaced : .default
        let font: Font = switch size {
        case .style(let style): .system(style, design: design, weight: shownWeight)
        case .fixed(let points): .system(size: points, weight: shownWeight, design: design)
        }
        return isItalic ? font.italic() : font
    }

    /// The same rule for UIKit's own bars and controls.
    static func ui(_ points: CGFloat, heavy: Bool = false) -> UIFont {
        .systemFont(ofSize: points, weight: heavy ? .medium : .regular)
    }

    /// Navigation titles and segmented controls are UIKit's, and bold or
    /// semibold by default: give them the app's weight too. Once, at launch.
    @MainActor static func applyToSystemControls() {
        let bar = UINavigationBar.appearance()
        bar.titleTextAttributes = (bar.titleTextAttributes ?? [:]).merging([.font: ui(17, heavy: true)]) { $1 }
        bar.largeTitleTextAttributes = (bar.largeTitleTextAttributes ?? [:]).merging([.font: ui(34, heavy: true)]) { $1 }
        let segments = UISegmentedControl.appearance()
        segments.setTitleTextAttributes([.font: ui(13)], for: .normal)
        segments.setTitleTextAttributes([.font: ui(13, heavy: true)], for: .selected)
    }
}

extension View {
    /// The app's type at a text style or size (`BrandFont`).
    func brandFont(_ font: BrandFont) -> some View { self.font(font.font) }
}

extension Text {
    /// Stays a `Text`, so it can still be joined to another or resolved in a canvas.
    func brandFont(_ font: BrandFont) -> Text { self.font(font.font) }
}

/// A screen's title in the top bar, at the app's weight. Use it in place of
/// `navigationTitle`.
///
/// The bar draws a `navigationTitle` itself, semibold, and from iOS 26 it
/// does so whatever the bar's appearance asks for (found when the app's text
/// was Futura: the search term over a page of results, "Filters" and
/// "Account settings" all stayed as the system drew them). So the title is
/// also given to the bar as a view, which takes the system title's place
/// (leading beside the back button, or centred on a sheet). The plain title
/// stays for the back button's menu, the UI tests and VoiceOver, which still
/// reads the bar's own title: the view is hidden from it, or it would say
/// every title twice. Before iOS 26 the bar takes its weight from
/// `BrandFont.applyToSystemControls`.
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
