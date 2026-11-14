import SwiftUI

/// The floating pill tab bar: icons only, and a lighter capsule that slides
/// behind the selected tab. It replaces the system bar, which TabRoot hides.
struct FloatingTabBar: View {
    @Environment(AppNav.self) private var nav
    @Environment(CartStore.self) private var cart
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var pill
    /// On a holiday the selected tab's pill fills with its colours, which
    /// drift for a few seconds after the app opens and after each tap, then
    /// rest; a soft glow of them trails the pill when it moves (owner,
    /// 2026-10-20, style B). Still with Reduce Motion on.
    @State private var holiday = HolidayCalendar.current()
    @State private var drift: CGFloat = 0

    static let height: CGFloat = 62
    static let compactScale: CGFloat = 0.85
    static let compactOffset: CGFloat = 6
    /// How far the bar's top edge comes down when compact (it scales from the bottom).
    static let compactDrop: CGFloat = height * (1 - compactScale) + compactOffset

    // Instagram's dark frost (owner, 2026-10-22, from a screenshot): sampled
    // off the 3x image, the body is ~#2E3236 over a light photo, so a dark
    // tint (#282C30) about 85% strong; a light rim runs along the top edge;
    // the selected pill is a lighter frosted grey.
    private static let ink = Color(red: 40 / 255, green: 44 / 255, blue: 48 / 255)
    /// Light along the top edge, fading down: the glass catching light.
    private static let rim = LinearGradient(colors: [.white.opacity(0.24), .white.opacity(0.05)],
                                            startPoint: .top, endPoint: .bottom)
    private static let disc = Color(red: 213 / 255, green: 214 / 255, blue: 215 / 255)
    private static let badge = Color.white   // monochrome app: no colour accents
    /// Space scroll content keeps clear so the last row isn't under the bar.
    static let clearance: CGFloat = height + 10

    /// `label` is the English name the accessibility identifiers ("tab.home")
    /// and UI tests key on; `AppTab.title` is what the shopper reads and hears.
    static let tabs: [(tab: AppTab, label: String)] = [
        (.home, "Home"), (.browse, "Browse"), (.cart, "Cart"), (.saved, "Saved"), (.you, "You"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Self.tabs, id: \.tab) { item in
                let selected = nav.tab == item.tab
                Button { nav.tap(item.tab) } label: {
                    Self.icon(item.tab, selected: selected, cartCount: cart.itemCount)
                        .frame(maxWidth: .infinity)
                        .frame(height: Self.height - 10)
                        .background {
                            if selected {
                                if let holiday {
                                    holidayPill(holiday)
                                } else {
                                    Capsule()
                                        .fill(LinearGradient(colors: [.white.opacity(0.20), .white.opacity(0.13)],
                                                             startPoint: .top, endPoint: .bottom))
                                        .overlay(Capsule().strokeBorder(Self.rim, lineWidth: 1))
                                        .matchedGeometryEffect(id: "pill", in: pill)
                                }
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.tab.title)
                .accessibilityValue(item.tab == .cart && cart.itemCount > 0 ? "\(cart.itemCount) items" : "")
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("tab.\(item.label.lowercased())")
            }
        }
        // Pages switch instantly like ASOS; only the selection pill slides.
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: nav.tab)
        .onAppear(perform: flow)
        .onChange(of: nav.tab) { flow() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            holiday = HolidayCalendar.current()
            flow()
        }
        .padding(5)
        .frame(height: Self.height)
        .modifier(BarSurface(ink: Self.ink, rim: Self.rim))
        .shadow(color: .black.opacity(nav.tabBarCompact ? 0.25 : 0.35), radius: 14, y: 6)
        // Five icons don't need a 13-inch bar.
        .frame(maxWidth: 480)
        .padding(.horizontal, 20)
        // Compact: the whole pill, icons and all, at 85%, settled toward the
        // bottom edge on every screen that uses MarracatChrome — Instagram's (measured off the owner's recording: the
        // pill goes from ~90% of the screen's width to ~74%). Every tab stays
        // tappable; 52 pt targets become 44 pt, Apple's minimum (82% matched the
        // recording more closely but left them at 42.6).
        .scaleEffect(nav.tabBarCompact ? Self.compactScale : 1, anchor: .bottom)
        .offset(y: nav.tabBarCompact ? Self.compactOffset : 0)
        .sensoryFeedback(.selection, trigger: nav.tab)
    }

    /// A tab's glyph, shared with the sidebar (SidebarRail).
    /// The day's colours as a pill: a gradient twice the pill's width that
    /// repeats, slid one period while it flows and set back unseen after.
    private func holidayPill(_ holiday: Holiday) -> some View {
        let colors = holiday.tabColors
        let band = LinearGradient(colors: colors + colors + [colors.first ?? .white], startPoint: .leading, endPoint: .trailing)
        return ZStack {
            Capsule()
                .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                .blur(radius: 8)
                .opacity(0.5)
                .matchedGeometryEffect(id: "trail", in: pill)
                .animation(.spring(response: 0.7, dampingFraction: 0.85), value: nav.tab)
            GeometryReader { geo in
                band
                    .frame(width: geo.size.width * 2)
                    .offset(x: -geo.size.width * drift)
            }
            .clipShape(Capsule())
            .overlay(Capsule().fill(Color.black.opacity(0.18)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
            .matchedGeometryEffect(id: "pill", in: pill)
        }
        .accessibilityHidden(true)
    }

    private func flow() {
        guard holiday != nil, !reduceMotion else { return }
        drift = 0
        withAnimation(.easeInOut(duration: 4)) {
            drift = 1
        } completion: {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { drift = 0 }
        }
    }

    @ViewBuilder
    static func icon(_ tab: AppTab, selected: Bool, cartCount: Int) -> some View {
        switch tab {
        case .home:
            // Just the Marracat M, stroked at the same weight as the other
            // glyphs — the wordmark was unreadable at tab-bar size.
            MarracatMark()
                .stroke(Color.white.opacity(selected ? 1 : 0.94),
                        style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                .frame(width: 24, height: 22)
        case .browse:
            symbol("text.magnifyingglass", selected: selected)
        case .cart:
            symbol(selected ? "bag.fill" : "bag", selected: selected)
                .overlay(alignment: .topTrailing) {
                    if cartCount > 0 {
                        Text("\(min(cartCount, 99))")
                            // Scales with the text size, capped so the
                            // badge stays a badge on the 21 pt bag.
                            .font(.caption2.weight(.bold))
                            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                            .foregroundStyle(.black)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(Capsule().fill(Self.badge))
                            .offset(x: 10, y: -7)
                            .accessibilityHidden(true)   // the tab's value says "N items"
                    }
                }
        case .saved:
            symbol(selected ? "heart.fill" : "heart", selected: selected)
        case .you:
            symbol(selected ? "person.fill" : "person", selected: selected)
        }
    }

    private static func symbol(_ name: String, selected: Bool) -> some View {
        Image(systemName: name)
            .font(.system(size: 21, weight: .regular))
            // White in both states, like ASOS — selection is shown by the pill alone.
            .foregroundStyle(Color.white.opacity(selected ? 1 : 0.94))
    }
}

extension AppTab {
    var title: String {
        switch self {
        case .home: String(localized: "Home", comment: "Tab bar: the Home tab")
        case .browse: String(localized: "Browse", comment: "Tab bar: browse departments")
        case .cart: String(localized: "Cart", comment: "Tab bar: shopping cart")
        case .saved: String(localized: "Saved", comment: "Tab bar: saved products")
        case .you: String(localized: "You", comment: "Tab bar: the shopper's own account and orders")
        }
    }
}


/// The bar itself: the medium tint the owner picked on 2026-10-24 from
/// simulator renders (Liquid Glass tinted with the dark ink at 60%), drawn as
/// a blur with the ink at 60% and the light rim, so photos and names show
/// through as they scroll under it. Real `glassEffect` is not used here: on
/// this bar, wrapped around the tabs or as a layer behind them, it left tab
/// taps doing nothing in six UI tests (2026-10-24 nightly), while the same
/// tests pass with this. The search bar keeps real Liquid Glass.
private struct BarSurface: ViewModifier {
    let ink: Color
    let rim: LinearGradient

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    Capsule().fill(.ultraThinMaterial)
                    Capsule().fill(ink.opacity(0.6))
                }
                .environment(\.colorScheme, .dark)
            }
            .overlay(Capsule().strokeBorder(rim, lineWidth: 1))
    }
}


extension View {
    /// Shrinks the floating tab bar while this scroll view is dragged down
    /// its content and grows it back when the shopper scrolls up or nears the
    /// top (owner, 2026-11-05: Instagram's bar). Only the shopper's own
    /// scrolling counts, not layout jumps. iOS 18+; on 17 the bar stays full.
    func minimizesTabBarOnScroll() -> some View { modifier(MinimizesTabBarOnScroll()) }
}

private struct MinimizesTabBarOnScroll: ViewModifier {
    @Environment(AppNav.self) private var nav
    @State private var userScrolling = false
    /// Where the current run in one direction began.
    @State private var anchor: CGFloat = 0

    /// How far one way the feed must move before the bar changes, and how
    /// near the top it is always full.
    static let travel: CGFloat = 24
    static let nearTop: CGFloat = 60

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                .onScrollPhaseChange { _, phase in
                    userScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
                }
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, y in
                    if y < Self.nearTop { anchor = y; nav.setTabBarCompact(false); return }
                    guard userScrolling else { anchor = y; return }
                    let moved = y - anchor
                    if nav.tabBarCompact {
                        // Shrunk: the lowest point reached is where going back up counts from.
                        if moved > 0 { anchor = y } else if -moved > Self.travel { nav.setTabBarCompact(false); anchor = y }
                    } else {
                        if moved < 0 { anchor = y } else if moved > Self.travel { nav.setTabBarCompact(true); anchor = y }
                    }
                }
        } else {
            content
        }
    }
}
