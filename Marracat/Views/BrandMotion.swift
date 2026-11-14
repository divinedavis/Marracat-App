import SwiftUI
import UIKit

// Two touches on the brand page, picked by the owner from previews on
// 2026-11-10 (~/Downloads/marracat-preview.html):
//
//  * "The name, huge": pull down at the top and the space above the photo
//    fills with the brand's name in giant type, sliding by in the photo's
//    own colours, one solid line and one outline. It used to be a flat grey.
//  * "Quick return": Filters, Sort and the department chips come back pinned
//    under the top bar the moment you scroll up a little, and step out of
//    the way again while you scroll down.

/// Two light colours from a photo, for type laid over the dark page.
enum PhotoPalette {
    /// Lavender and pink: what the page shows before the photo has loaded,
    /// and for a photo with no colour to speak of.
    static let fallback: [Color] = [Color(red: 0.84, green: 0.72, blue: 0.90), Color(red: 0.94, green: 0.76, blue: 0.81)]

    @MainActor private static var cache: [String: [Color]] = [:]

    /// The two most colourful distinct hues in the photo, lifted towards pastel
    /// so they read on the dark page. Fallback when the photo is grey.
    static func colors(from image: UIImage) -> [Color] {
        let side = 12
        guard let cg = image.cgImage else { return fallback }
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return fallback }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        var swatches: [(h: CGFloat, s: CGFloat, b: CGFloat, score: CGFloat)] = []
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let c = UIColor(red: CGFloat(pixels[i]) / 255, green: CGFloat(pixels[i + 1]) / 255, blue: CGFloat(pixels[i + 2]) / 255, alpha: 1)
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            // Colourful and not near black: a shadow is no colour to show.
            swatches.append((h, s, b, s * min(1, b * 1.4)))
        }
        let ranked = swatches.sorted { $0.score > $1.score }
        guard let first = ranked.first, first.s > 0.08 else { return fallback }
        let hueGap = { (a: CGFloat, b: CGFloat) -> CGFloat in let d = abs(a - b); return min(d, 1 - d) }
        let second = ranked.first { hueGap($0.h, first.h) > 0.06 && $0.s > 0.08 } ?? (first.h + 0.08, first.s, first.b, 0)
        return [pastel(first.h, first.s), pastel(second.h.truncatingRemainder(dividingBy: 1), second.s)]
    }

    /// Light enough to read on #000, still clearly the photo's hue.
    static func pastel(_ hue: CGFloat, _ saturation: CGFloat) -> Color {
        Color(hue: hue, saturation: min(0.42, max(0.2, saturation)), brightness: 0.93)
    }

    /// The palette for a photo address: computed once, from the image the
    /// hero already loaded.
    @MainActor static func load(_ url: String?, width: Int) async -> [Color] {
        guard let u = sizedImageURL(url, width: width) else { return fallback }
        if let hit = cache[u.absoluteString] { return hit }
        guard let image = await ImageLoader.shared.load(u) else { return fallback }
        // A 12 x 12 sample: a few milliseconds, once per photo.
        let found = colors(from: image)
        cache[u.absoluteString] = found
        return found
    }
}

/// The brand's name, huge, sliding by: one solid line in the photo's colours
/// and one outlined line going the other way. Still for Reduce Motion.
struct BrandNameMarquee: View {
    let name: String
    let colors: [Color]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var width: CGFloat = 0

    static let size: CGFloat = 52
    static let height: CGFloat = size * 2 + 6

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            VStack(alignment: .leading, spacing: 6) {
                line(outlined: false).offset(x: shift(t, speed: 34))
                line(outlined: true).offset(x: shift(t, speed: 26, reverse: true))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .accessibilityHidden(true)
    }

    /// How far a line has moved: the width of one copy of the name, round and round.
    private func shift(_ t: TimeInterval, speed: Double, reverse: Bool = false) -> CGFloat {
        guard width > 0, !reduceMotion else { return 0 }
        let x = CGFloat((t * speed).truncatingRemainder(dividingBy: Double(width)))
        return reverse ? x - width : -x
    }

    private func line(outlined: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<4, id: \.self) { i in
                word(outlined: outlined)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { if i == 0, !outlined { width = $0 } }
            }
        }
        .fixedSize()
    }

    @ViewBuilder private func word(outlined: Bool) -> some View {
        let text = Text(name.uppercased() + "  ").font(.system(size: Self.size, weight: .black)).tracking(-1)
        if outlined {
            // An outline: the page's own colour, edged in the second colour.
            let edge = colors.last ?? PhotoPalette.fallback[1]
            text.foregroundStyle(Color.black)
                .shadow(color: edge, radius: 0, x: 1, y: 0).shadow(color: edge, radius: 0, x: -1, y: 0)
                .shadow(color: edge, radius: 0, x: 0, y: 1).shadow(color: edge, radius: 0, x: 0, y: -1)
                .opacity(0.75)
        } else {
            text.foregroundStyle(LinearGradient(colors: colors + [colors.first ?? .white], startPoint: .leading, endPoint: .trailing))
        }
    }
}

/// When the Filters / Sort pill above the tab bar shows (owner, 2026-11-10,
/// picked "Two pills by your thumb"): at the top of the page, and after a
/// short scroll up; it steps aside after a scroll down, so the products get
/// the room.
struct QuickReturn: Equatable {
    var shown = true
    private var last: CGFloat?
    private var travel: CGFloat = 0

    static let hideAfter: CGFloat = 24
    static let showAfter: CGFloat = 10
    /// Within this of the top it always shows.
    static let top: CGFloat = 40

    /// `offset`: how far the page has scrolled (down is positive).
    mutating func update(offset: CGFloat) {
        defer { last = offset }
        guard offset > Self.top else { shown = true; travel = 0; return }
        guard let last else { return }
        let d = offset - last
        // A change of direction starts the count again.
        travel = (d > 0) == (travel > 0) ? travel + d : d
        if travel > Self.hideAfter { shown = false }
        if travel < -Self.showAfter { shown = true }
    }
}

/// A product page's scroll (brand pages and the category grids), kept out of
/// the page's own state: writing it on every scroll frame would redraw the
/// whole page (1,000+ products) each frame. Only the two small views that read `pull` and `filtersShown` redraw.
@Observable @MainActor
final class BrandScroll {
    /// How far the page is pulled down past its top.
    private(set) var pull: CGFloat = 0
    /// The Filters / Sort pill is up above the tab bar.
    private(set) var filtersShown = true
    @ObservationIgnored private var quick = QuickReturn()

    /// `y`: where the page's top is (above 0: pulled down; below: scrolled).
    func top(at y: CGFloat) {
        let p = max(0, y)
        if p != pull { pull = p }
        quick.update(offset: -y)
        if quick.shown != filtersShown { withAnimation(.snappy(duration: 0.25)) { filtersShown = quick.shown } }
    }
}

/// The space above the photo when the page is pulled down.
struct BrandPullSpace: View {
    let scroll: BrandScroll
    let name: String
    let colors: [Color]

    var body: some View {
        ZStack(alignment: .top) {
            Theme.surface
            if scroll.pull > 4 {
                BrandNameMarquee(name: name, colors: colors)
                    .frame(height: BrandNameMarquee.height)
                    .offset(y: scroll.pull - BrandNameMarquee.height - 12)
                    .opacity(Double(min(1, scroll.pull / 80)))
            }
        }
        .ignoresSafeArea()
    }
}

/// The Filters / Sort pill, floating just above the tab bar while
/// `scroll.filtersShown`. The sheet hangs off this container, which is always
/// there, so it isn't torn down if the page scrolls behind it.
struct BottomFilters: View {
    let scroll: BrandScroll
    let products: [Product]
    @Binding var filters: ProductFilters
    @State private var showSheet = false

    var body: some View {
        VStack(spacing: 0) {
            if scroll.filtersShown || showSheet {
                FilterPill(filters: $filters) { showSheet = true }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 10)
        .onChange(of: filters) { old, new in FilterBar.track(from: old, to: new) }
        .sheet(isPresented: $showSheet) {
            FilterSheet(products: products, filters: $filters)
        }
    }
}
