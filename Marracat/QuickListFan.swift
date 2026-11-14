import SwiftUI

/// Hold Add to List: the page dims and the shopper's lists fan out above the
/// chip as round photo bubbles, the way X's compose button opens (owner,
/// 2026-10-05, from a screen recording of X). The four lists used last, one
/// for the product's department (or a new one named for it), and All lists.
/// Tapping a bubble adds the item (or takes it out) and closes the fan; the
/// dimmed page or the × closes it without a change.
struct QuickListFan: View {
    struct Choice: Identifiable {
        enum Kind { case list(SavedList), newList(String), all }
        let kind: Kind
        var id: String {
            switch kind { case .list(let l): l.id; case .newList(let n): "new:\(n)"; case .all: "all" }
        }
    }

    let product: Product
    /// The Add to List chip, in the page's coordinates.
    let anchor: CGRect
    let choices: [Choice]
    let pick: (Choice) -> Void
    let close: () -> Void
    @Environment(CatalogStore.self) private var catalog
    @State private var open = false

    private static let bubble: CGFloat = 60
    private static let radius: CGFloat = 132
    /// Widest a bubble's caption gets (the Text's maxWidth below).
    private static let labelWidth: CGFloat = 96
    /// The arc runs from 150° to 30°: the top half-circle, left to right.
    private static let arcStart = Double.pi * 0.83, arcEnd = Double.pi * 0.17
    private var bubble: CGFloat { Self.bubble }

    /// Where each of `count` bubbles sits when the fan is open. The arc's
    /// center sits on the chip, nudged in from the edges so every bubble and
    /// its caption lands on screen: the outermost bubbles sit cos(30°)·radius
    /// to each side, and the caption is wider than the bubble. (radius/2 +
    /// bubble left a chip at the left edge with its first bubble half off
    /// screen, 2026-10-06.)
    static func layout(anchor: CGRect, in size: CGSize, count: Int) -> (center: CGPoint, bubbles: [CGPoint]) {
        let reach = count > 1 ? abs(cos(arcStart)) * radius : 0
        let margin = reach + max(bubble, labelWidth) / 2 + 12
        let center = CGPoint(x: min(max(anchor.midX, margin), size.width - margin),
                             y: max(anchor.midY, radius + bubble + 20))
        let bubbles = (0..<count).map { i -> CGPoint in
            let angle = count > 1 ? arcStart + (arcEnd - arcStart) * Double(i) / Double(count - 1) : .pi / 2
            return CGPoint(x: center.x + cos(angle) * radius, y: center.y - sin(angle) * radius)
        }
        return (center, bubbles)
    }

    var body: some View {
        GeometryReader { geo in
            let spot = Self.layout(anchor: anchor, in: geo.size, count: choices.count)
            ZStack {
                Color.black.opacity(open ? 0.72 : 0)
                    .ignoresSafeArea()
                    .onTapGesture { dismiss() }
                    .accessibilityHidden(true)
                ForEach(Array(choices.enumerated()), id: \.element.id) { i, choice in
                    bubbleView(choice)
                        .position(open ? spot.bubbles[i] : spot.center)
                        .scaleEffect(open ? 1 : 0.2)
                        .opacity(open ? 1 : 0)
                        .animation(.spring(response: 0.38, dampingFraction: 0.72).delay(Double(i) * 0.03), value: open)
                }
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.title3.weight(.semibold)).foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(Circle().fill(Theme.field))
                        .overlay(Circle().stroke(Theme.hairline))
                }
                .position(x: anchor.midX, y: anchor.midY)
                .opacity(open ? 1 : 0)
                .accessibilityLabel("Close lists")
                .accessibilityIdentifier("quickListsClose")
            }
        }
        .onAppear { withAnimation { open = true } }
        .sensoryFeedback(.impact(weight: .medium), trigger: open) { _, now in now }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("quickListFan")
        .accessibilityAddTraits(.isModal)
    }

    private func dismiss() {
        withAnimation(.easeOut(duration: 0.18)) { open = false }
        Task { try? await Task.sleep(for: .milliseconds(180)); close() }
    }

    @ViewBuilder
    private func bubbleView(_ choice: Choice) -> some View {
        let (title, a11y): (String, String) = switch choice.kind {
        case .list(let l): (l.name, l.name)
        case .newList(let n): (String(localized: "New: \(n)", comment: "Save-to-list option; the argument is a new list name (short label, then VoiceOver label)"), String(localized: "New list: \(n)", comment: "Save-to-list option; the argument is a new list name (short label, then VoiceOver label)"))
        case .all: (String(localized: "All lists", comment: "Save-to-list option showing every list"), String(localized: "All lists…", comment: "Save-to-list option showing every list"))
        }
        let inList: Bool = { if case .list(let l) = choice.kind { return l.items.contains(product.id) }; return false }()
        Button { pick(choice); dismiss() } label: {
            VStack(spacing: 6) {
                ZStack(alignment: .bottomTrailing) {
                    face(choice)
                        .frame(width: bubble, height: bubble)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(inList ? Color.pink : Color.white.opacity(0.9), lineWidth: inList ? 3 : 2))
                        .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
                    if inList {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 20)).foregroundStyle(.white, .pink)
                            .offset(x: 4, y: 4)
                    }
                }
                Text(title)
                    .font(.caption.weight(.semibold)).foregroundStyle(.white)
                    .lineLimit(2).multilineTextAlignment(.center)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.black.opacity(0.75)))
                    .frame(maxWidth: Self.labelWidth)
            }
        }
        .buttonStyle(ActionChipStyle())
        .accessibilityLabel(a11y)
        .accessibilityValue(inList ? "in list" : "")
        .accessibilityIdentifier("quickList")
    }

    @ViewBuilder
    private func face(_ choice: Choice) -> some View {
        switch choice.kind {
        case .list(let l):
            if let id = l.items.last, let url = catalog.product(id)?.images.first {
                ProductImageWell(url: url, width: 160, padding: 4)
            } else {
                symbol("folder.fill", Color.blue)
            }
        case .newList: symbol("folder.badge.plus", Color.green)
        case .all: symbol("square.grid.2x2.fill", Color.orange)
        }
    }

    private func symbol(_ name: String, _ tint: Color) -> some View {
        ZStack {
            Circle().fill(tint)
            Image(systemName: name).font(.title2.weight(.semibold)).foregroundStyle(.white)
        }
    }
}
