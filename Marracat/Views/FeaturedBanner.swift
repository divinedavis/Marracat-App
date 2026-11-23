import SwiftUI

/// Search's Featured banner (owner, 2026-10-12: "instead of deals for you, can
/// we show one banner thats centered … make it a brand that is one of our
/// premier brands, cycle them through, and show a 'featured' label on the top
/// left"). One page per premier brand that has something in stock, in Home's
/// premier order; it moves on by itself every few seconds, swipes by hand, and
/// a tap opens the brand's store.
///
/// It stops moving on its own while a finger is on it, and for good when
/// Reduce Motion or VoiceOver is on: then it changes only by a swipe, or, for
/// VoiceOver, by swiping up and down on it as one adjustable element.
struct FeaturedBanner: View {
    struct Slide: Identifiable {
        let brand: Brand
        /// The premier brand's featured product photo (Curves: a tote), or
        /// the brand's own art when it has none.
        let image: String?
        var id: String { brand.id }
    }

    let slides: [Slide]
    let open: (String) -> Void

    /// How long a page stays before the next one slides in.
    static let interval: Duration = .seconds(4)
    /// The banner's height: about the old "Deals for you" cards', so recent
    /// searches still sit above the keyboard on an iPhone SE.
    static let compactHeight: CGFloat = 150
    static let regularHeight: CGFloat = 190
    /// On a wide iPad window the banner stops widening and centres.
    static let maxWidth: CGFloat = 640
    static let imageWidth = 500

    /// The brand the last banner was showing, so the next search opens on
    /// the one after it instead of the same brand every time.
    @MainActor private static var lastShown: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var current: String?
    @State private var pressed = false
    @State private var dragging = false
    /// Brands whose page has been on screen this time search was opened.
    @State private var seen: Set<String> = []

    /// Premier brands in Home's premier order for this launch, each only if
    /// the catalog has something of theirs in stock.
    @MainActor
    static func slides(_ catalog: CatalogStore, mix: BrandMix = BrandMix()) -> [Slide] {
        mix.premierOrder(catalog.premierBrands, id: \.id).compactMap { b in
            let products = catalog.products(for: b.id)
            guard products.contains(where: \.available) else { return nil }
            let shown = mix.featured(products, brand: b.id)
            return Slide(brand: b, image: shown?.images.first ?? b.image)
        }
    }

    /// Where a banner opens: the brand after the one shown last time.
    @MainActor
    static func start(in slides: [Slide], after last: String?) -> String? {
        guard let last, let i = slides.firstIndex(where: { $0.id == last }) else { return slides.first?.id }
        return slides[(i + 1) % slides.count].id
    }

    /// Whether the banner moves on by itself: never under Reduce Motion or
    /// VoiceOver, and not with a single brand to show.
    static func autoAdvances(reduceMotion: Bool, voiceOver: Bool, slides: Int) -> Bool {
        !reduceMotion && !voiceOver && slides > 1
    }
    private var autoAdvances: Bool { Self.autoAdvances(reduceMotion: reduceMotion, voiceOver: voiceOver, slides: slides.count) }
    private var height: CGFloat { sizeClass == .regular ? Self.regularHeight : Self.compactHeight }
    private var index: Int { slides.firstIndex { $0.id == current } ?? 0 }
    private var shown: Slide? { slides.indices.contains(index) ? slides[index] : nil }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 0) {
                ForEach(Array(slides.enumerated()), id: \.element.id) { i, slide in
                    Button { tap(slide) } label: { page(slide, at: i) }
                        .buttonStyle(PressReporting(pressed: $pressed))
                        .frame(maxWidth: Self.maxWidth)
                        .padding(.horizontal, 16)
                        .containerRelativeFrame(.horizontal)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $current)
        .modifier(ReportsDragging(dragging: $dragging))
        .frame(height: height)
        // One element for VoiceOver: what's featured, which of how many, and
        // swipe up or down to move through the brands.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shown.map { "Featured: \($0.brand.name)" } ?? "Featured")
        .accessibilityValue("\(index + 1) of \(slides.count)")
        .accessibilityHint("Opens this brand's store. Swipe up or down for other featured brands.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(1)
            case .decrement: step(-1)
            @unknown default: break
            }
        }
        .accessibilityAction { if let shown { tap(shown) } }
        .accessibilityIdentifier("featuredBanner")
        .onAppear {
            if current == nil { current = Self.start(in: slides, after: Self.lastShown) }
            viewed()
        }
        .onChange(of: slides.map(\.id)) {
            if !slides.contains(where: { $0.id == current }) { current = slides.first?.id }
        }
        .onChange(of: current) { viewed() }
        // The next page after `interval`; a swipe, a press or a drag starts
        // the wait again (the id changes), so it never moves under a finger.
        .task(id: "\(current ?? "")|\(pressed)|\(dragging)|\(autoAdvances)") {
            guard autoAdvances, !pressed, !dragging else { return }
            try? await Task.sleep(for: Self.interval)
            guard !Task.isCancelled else { return }
            step(1)
        }
    }

    /// Text on a solid panel, the product on its light well, as on Home's
    /// hero — never text over a photo.
    private func page(_ slide: Slide, at i: Int) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Featured")
                    .brandFont(.caption2.weight(.bold))
                    .foregroundStyle(Theme.onGold)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Theme.gold))
                Text(slide.brand.name)
                    .brandFont(.title3.bold())
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                HStack(spacing: 2) {
                    Text("Shop now")
                    Image(systemName: "chevron.right")
                }
                .brandFont(.footnote.weight(.semibold))
                .foregroundStyle(.primary)
                if slides.count > 1 { dots(at: i) }
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.cocoa)
            ZStack {
                Theme.tile
                if let image = slide.image {
                    RemoteImage(url: image, width: Self.imageWidth).padding(10)
                } else {
                    BrandArtwork(brand: slide.brand, size: height - 30)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    private func dots(at i: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(slides.indices, id: \.self) { j in
                Circle()
                    .fill(Color.primary.opacity(j == i ? 1 : 0.4))
                    .frame(width: 5, height: 5)
            }
        }
    }

    private func step(_ by: Int) {
        guard !slides.isEmpty else { return }
        let next = slides[(index + by + slides.count) % slides.count].id
        if reduceMotion { current = next } else { withAnimation(.easeInOut(duration: 0.35)) { current = next } }
    }

    private func viewed() {
        guard let shown else { return }
        Self.lastShown = shown.id
        if seen.insert(shown.id).inserted {
            Analytics.shared.track("banner_view", ["kind": .string("featured_banner"), "brand": .string(shown.id)])
        }
    }

    private func tap(_ slide: Slide) {
        Analytics.shared.track("banner_tap", ["kind": .string("featured_banner"), "brand": .string(slide.id)])
        open(slide.id)
    }
}

/// A plain button that says when a finger is down on it, so the banner can
/// hold still under the finger.
private struct PressReporting: ButtonStyle {
    @Binding var pressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.85 : 1)
            .onChange(of: configuration.isPressed) { _, now in pressed = now }
    }
}

/// While a thumb drags or flings the banner (iOS 18 reports the scroll
/// phase; on 17 the page change itself restarts the wait).
private struct ReportsDragging: ViewModifier {
    @Binding var dragging: Bool

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollPhaseChange { _, phase in
                dragging = phase == .tracking || phase == .interacting || phase == .decelerating
            }
        } else {
            content
        }
    }
}
