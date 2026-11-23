import SwiftUI

/// Layout for wide windows: iPhone Duo's inner display, an iPad, a resized
/// iPhone Mirroring window. Apple's rule for all of them is the space the
/// window has, never the device or its orientation (Preparing your app for
/// iPhone Duo, 2026), so everything here keys off a measured width and the
/// horizontal size class. A fold or unfold only changes those two numbers;
/// the views below keep their identity, so tabs, navigation stacks, scroll
/// positions and Home's pinned rows survive it.
enum AdaptiveLayout {
    /// Home's feed: one column of rows on a phone, two once each column still
    /// has room for two and a half tiles, three on a 13-inch iPad.
    static func feedColumns(width: CGFloat) -> Int {
        width >= 1080 ? 3 : width >= 600 ? 2 : 1
    }

    /// The sidebar takes over from the floating tab bar from this window width.
    static let sidebarMinWidth: CGFloat = 800
    static let sidebarWidth: CGFloat = 88

    /// A sidebar where it fits: a regular-width window at least 800pt wide
    /// (Duo opened in landscape, any full-screen iPad). Duo opened in portrait
    /// (669pt) keeps the floating bar and gets two feed columns instead.
    static func showsSidebar(width: CGFloat, sizeClass: UserInterfaceSizeClass?) -> Bool {
        sizeClass == .regular && width >= sidebarMinWidth
    }

    /// Where each of a feed's sections goes. Sections fill the columns left to
    /// right, a row at a time, each row as tall as its tallest section; a
    /// full-width section (the department cards, the brand circles) closes the
    /// row it would have joined and spans every column. At one column this is
    /// a VStack with `spacing`.
    static func feedFrames(count: Int, fullWidth: (Int) -> Bool, width: CGFloat, columns: Int,
                           spacing: CGFloat, height: (Int, CGFloat) -> CGFloat) -> [CGRect] {
        let columns = max(1, columns)
        let column = max(0, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        var frames = Array(repeating: CGRect.zero, count: count)
        var y: CGFloat = 0
        var row: [Int] = []
        var placedAny = false

        func flush() {
            guard !row.isEmpty else { return }
            if placedAny { y += spacing }
            var tallest: CGFloat = 0
            for (slot, i) in row.enumerated() {
                let h = height(i, column)
                frames[i] = CGRect(x: CGFloat(slot) * (column + spacing), y: y, width: column, height: h)
                tallest = max(tallest, h)
            }
            y += tallest
            placedAny = true
            row = []
        }

        for i in 0..<count {
            if columns == 1 || fullWidth(i) {
                flush()
                if placedAny { y += spacing }
                let h = height(i, columns == 1 ? column : width)
                frames[i] = CGRect(x: 0, y: y, width: columns == 1 ? column : width, height: h)
                y += h
                placedAny = true
            } else {
                row.append(i)
                if row.count == columns { flush() }
            }
        }
        flush()
        return frames
    }
}

/// Marks a feed section that spans every column (FeedColumnsLayout).
struct FeedFullWidth: LayoutValueKey {
    static let defaultValue = false
}

extension View {
    /// This section spans the whole feed in a multi-column layout.
    func feedFullWidth() -> some View { layoutValue(key: FeedFullWidth.self, value: true) }
}

/// Home's sections in `columns` columns (AdaptiveLayout.feedFrames). A Layout,
/// not a VStack swapped for a grid, so a fold or unfold re-places the same
/// views instead of building new ones.
struct FeedColumnsLayout: Layout {
    var columns: Int
    var spacing: CGFloat = 12

    private func frames(_ width: CGFloat, _ subviews: Subviews) -> [CGRect] {
        AdaptiveLayout.feedFrames(count: subviews.count, fullWidth: { subviews[$0][FeedFullWidth.self] },
                                  width: width, columns: columns, spacing: spacing) { i, w in
            subviews[i].sizeThatFits(ProposedViewSize(width: w, height: nil)).height
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let height = frames(width, subviews).map(\.maxY).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(bounds.width, subviews)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          anchor: .topLeading, proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }
}

extension EnvironmentValues {
    /// Room scroll content and floating buttons keep at the bottom for the
    /// floating tab bar; zero while the sidebar stands in for it.
    @Entry var tabBarClearance: CGFloat = FloatingTabBar.clearance
}

/// The five tabs down the leading edge of a wide window, in place of the
/// floating bar. Same buttons, same identifiers and the same tap rules
/// (AppNav.tap), so every UI test that drives the bar drives this too.
struct SidebarRail: View {
    @Environment(AppNav.self) private var nav
    @Environment(CartStore.self) private var cart

    var body: some View {
        VStack(spacing: 6) {
            ForEach(FloatingTabBar.tabs, id: \.tab) { item in
                let selected = nav.tab == item.tab
                Button { nav.tap(item.tab) } label: {
                    VStack(spacing: 4) {
                        FloatingTabBar.icon(item.tab, selected: selected, cartCount: cart.itemCount)
                            .frame(height: 26)
                        Text(item.tab.title)
                            .brandFont(.caption2.weight(selected ? .semibold : .regular))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .foregroundStyle(Color.primary.opacity(selected ? 1 : 0.8))
                    }
                    .frame(width: AdaptiveLayout.sidebarWidth - 16)
                    .frame(minHeight: 60)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.12))
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(item.tab.title)
                .accessibilityValue(item.tab == .cart && cart.itemCount > 0 ? "\(cart.itemCount) items" : "")
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                .accessibilityIdentifier("tab.\(item.label.lowercased())")
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 12)
        .frame(width: AdaptiveLayout.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(Theme.header.ignoresSafeArea())
        .overlay(alignment: .trailing) { Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1).ignoresSafeArea() }
        .sensoryFeedback(.selection, trigger: nav.tab)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar")
    }
}
