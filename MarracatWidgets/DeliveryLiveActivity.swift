import SwiftUI
import WidgetKit
import ActivityKit
import AppIntents

@main
struct MarracatWidgets: WidgetBundle {
    var body: some Widget {
        DeliveryLiveActivity()
        // Home Screen and Lock Screen widgets (HomeWidgets.swift).
        PriceDropsWidget()
        FeaturedBrandWidget()
        OrdersWidget()
    }
}

/// Today's deliveries on the Lock Screen and in the Dynamic Island.
/// Third-party Live Activities are clipped past 160 pt (Apple), so the
/// expanded island and the Lock Screen card stay to three short rows.
struct DeliveryLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DeliveryActivityAttributes.self) { context in
            LockScreenDelivery(state: context.state, activityID: context.activityID)
                .widgetURL(context.state.current?.url)
                // Dark glass (owner, 2026-10-26): a see-through black that
                // lets the wallpaper show through (Apple: set translucency
                // with opacity). Fixed dark tint, white text and white End
                // button in either appearance, so a light Lock Screen can't
                // put black text on it.
                .environment(\.colorScheme, .dark)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            let order = state.current
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    MarracatLogo(size: 34)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if !state.position.isEmpty {
                        Text(state.position)
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                            // One line: "2 of 2" broke in two in the island (2026-10-17).
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.trailing, 4)
                            .accessibilityLabel("Order \(state.position)")
                    }
                }
                // Brand on the first line, the item under it: one line of
                // both cut the item off mid-word (owner, 2026-10-26).
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(order?.brand ?? String(localized: "Your orders", comment: "Live Activity title when no order is selected"))
                            .font(.headline)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        if let item = order?.item, !item.isEmpty {
                            Text(item)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    DeliveryRow(state: state, activityID: context.activityID, compact: true)
                }
            } compactLeading: {
                IslandMark(order: order)
            } compactTrailing: {
                Text(state.openCount > 1 ? String(localized: "\(state.openCount) today", comment: "Live Activity count of today's deliveries") : (order?.shortStatus ?? ""))
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .accessibilityLabel(state.openCount > 1 ? String(localized: "\(state.openCount) deliveries today", comment: "Live Activity VoiceOver count of today's deliveries") : (order?.statusLine ?? ""))
            } minimal: {
                IslandMark(order: order)
            }
            .widgetURL(order?.url)
            .keylineTint(statusTint(order))
        }
    }
}

/// Green for delivered, orange for a problem, otherwise the system's color.
private func statusTint(_ order: DeliveryOrder?) -> Color {
    switch order?.status {
    case "delivered": .green
    case "problem": .orange
    default: .primary
    }
}

/// The app icon (MARRACAT on white) where the card names who it's from, so a
/// delivery reads as Marracat's at a glance (owner, 2026-10-17). The compact
/// and minimal island slots use the tab bar's M instead (IslandMark): ~20 pt
/// is too small for the wordmark.
struct MarracatLogo: View {
    let size: CGFloat

    var body: some View {
        Image("MarracatLogo")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// The tab bar's Marracat M for the compact and minimal Dynamic Island,
/// tinted green when delivered and orange on a problem.
struct IslandMark: View {
    let order: DeliveryOrder?

    var body: some View {
        MarracatMark()
            .stroke(statusTint(order), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .frame(width: 20, height: 18)
            .accessibilityElement()
            .accessibilityLabel(order?.statusLine ?? String(localized: "Deliveries", comment: "Live Activity VoiceOver fallback"))
    }
}

/// The Lock Screen card, after River's (owner, 2026-10-26: "can we have our
/// live notification look like this?"): logo and position on top, the order
/// in grey, the status large and centred, then an arc from ordered to your
/// door with a dot where the package is now. ‹ › sit either side of the
/// status and only where there is another order.
struct LockScreenDelivery: View {
    let state: DeliveryActivityAttributes.ContentState
    let activityID: String

    var body: some View {
        if state.orders.count > 1 {
            DeliveryList(state: state, activityID: activityID)
        } else {
            single
        }
    }

    private var single: some View {
        let order = state.current
        return VStack(spacing: 4) {
            HStack(spacing: 6) {
                MarracatLogo(size: 20)
                Text(verbatim: "MARRACAT")
                    .font(.caption.weight(.bold))
                    .kerning(1.2)
                    .accessibilityHidden(true)
                Spacer(minLength: 4)
                if !state.position.isEmpty {
                    Text(state.position)
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .accessibilityLabel("Order \(state.position)")
                }
            }
            // Brand, then the item under it (owner, 2026-10-26).
            Text(order?.brand ?? String(localized: "Your orders", comment: "Live Activity title when no order is selected"))
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let item = order?.item, !item.isEmpty {
                Text(item)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 4) {
                FlipButton(activityID: activityID, step: -1, shown: state.hasPrevious)
                Text(order?.statusLine ?? "")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(order?.status == "problem" ? Color.orange : Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity)
                FlipButton(activityID: activityID, step: 1, shown: state.hasNext)
            }
            .accessibilityElement(children: .contain)
            if let order {
                DeliveryArc(order: order, activityID: activityID)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// Two or more orders today: a row each, its time on the right (owner,
/// 2026-10-26, after a "2 running" card with a row per task). Every order
/// shows at once, so the Lock Screen needs no ‹ ›. Up to three rows fit
/// Apple's 160 pt; more say "+N more".
struct DeliveryList: View {
    let state: DeliveryActivityAttributes.ContentState
    let activityID: String
    static let maxRows = 3

    var body: some View {
        let open = state.openCount
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                MarracatLogo(size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(open > 0 ? String(localized: "\(open) arriving today", comment: "Live Activity header: how many orders are still coming today")
                                  : String(localized: "All delivered", comment: "Live Activity header when every order today has arrived"))
                        .font(.headline)
                    HStack(spacing: 5) {
                        Circle().fill(headlineTint).frame(width: 7, height: 7)
                        Text(headline)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            // Three rows fit; a fourth or more shows two and "+N more".
            let shown = state.orders.count > Self.maxRows ? Self.maxRows - 1 : Self.maxRows
            ForEach(state.orders.prefix(shown)) { order in
                Link(destination: order.url ?? URL(string: "marracat://orders")!) {
                    DeliveryListRow(order: order, activityID: activityID)
                }
            }
            if state.orders.count > Self.maxRows {
                Text(String(localized: "+\(state.orders.count - shown) more", comment: "Live Activity: orders that don't fit on the card"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// The step the furthest-along open order is at ("Out for delivery").
    private var lead: DeliveryOrder? {
        state.orders.filter { $0.status != DeliveryOrder.delivered }.max { $0.progress < $1.progress }
    }

    private var headline: String {
        if state.orders.contains(where: { $0.status == "problem" }) { return String(localized: "Delivery problem", comment: "Delivery status") }
        return lead?.statusLine ?? String(localized: "Delivered", comment: "Delivery status")
    }

    private var headlineTint: Color {
        if state.orders.contains(where: { $0.status == "problem" }) { return .orange }
        return lead == nil ? .green : .blue
    }
}

/// One order: a status mark, the brand over the item, and when on the right.
struct DeliveryListRow: View {
    let order: DeliveryOrder
    let activityID: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: order.symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(statusTint(order) == .primary ? Color.secondary : statusTint(order))
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white.opacity(0.12)))
            // Brand, then the item under it (owner, 2026-10-26).
            VStack(alignment: .leading, spacing: 0) {
                Text(order.brand)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                if let item = order.item, !item.isEmpty {
                    Text(item)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if order.status == DeliveryOrder.delivered {
                Button(intent: DismissDeliveryIntent(activityID: activityID, orderID: order.id)) {
                    Text(String(localized: "Dismiss", comment: "Live Activity button: take a delivered order off the card"))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).frame(height: 22)
                        .background(Capsule().fill(.white.opacity(0.18)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss \(order.title)")
            } else {
                Text(order.when)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(order.status == "problem" ? Color.orange : Color.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(order.spoken)
    }
}

/// ‹ or ›, or the same space empty at either end.
struct FlipButton: View {
    let activityID: String
    let step: Int
    let shown: Bool

    var body: some View {
        if shown {
            Button(intent: FlipDeliveryIntent(activityID: activityID, step: step)) {
                Image(systemName: step < 0 ? "chevron.left" : "chevron.right")
                    .font(.body.weight(.semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(step < 0 ? "Previous order" : "Next order")
        } else {
            Color.clear.frame(width: 28, height: 28).accessibilityHidden(true)
        }
    }
}

/// The curve from ordered to your door: solid behind the package, dotted
/// ahead, a dot where it is with the carrier and time under it, and a house
/// at the end (or Dismiss once it's delivered).
struct DeliveryArc: View {
    let order: DeliveryOrder
    let activityID: String

    var body: some View {
        let t = order.progress
        let tint = statusTint(order) == .primary ? Color.white : statusTint(order)
        HStack(alignment: .bottom, spacing: 6) {
            GeometryReader { geo in
                let curve = ArcCurve()
                let dot = ArcCurve.point(at: t, in: geo.size)
                ZStack(alignment: .topLeading) {
                    curve
                        .trim(from: t, to: 1)
                        .stroke(.white.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [0.5, 5]))
                    curve
                        .trim(from: 0, to: t)
                        .stroke(LinearGradient(colors: [tint.opacity(0.15), tint], startPoint: .leading, endPoint: .trailing),
                                style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    Circle()
                        .fill(tint)
                        .frame(width: 9, height: 9)
                        .position(dot)
                    if let detail = order.detail {
                        Text(detail)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                            .fixedSize()
                            .position(x: min(max(dot.x, 50), geo.size.width - 50), y: dot.y + 13)
                    }
                }
            }
            .frame(height: 34)
            .accessibilityElement()
            .accessibilityLabel(order.spoken)
            if order.status == DeliveryOrder.delivered {
                Button(intent: DismissDeliveryIntent(activityID: activityID, orderID: order.id)) {
                    Text(String(localized: "Dismiss", comment: "Live Activity button: take a delivered order off the card"))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).frame(height: 26)
                        .background(Capsule().fill(.white.opacity(0.18)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss \(order.title)")
            } else {
                Image(systemName: "house")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 12)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// A gentle rise and fall across the card (a quadratic curve).
struct ArcCurve: Shape {
    static func ends(in size: CGSize) -> (CGPoint, CGPoint, CGPoint) {
        (CGPoint(x: 4, y: size.height * 0.62), CGPoint(x: size.width / 2, y: -size.height * 0.2),
         CGPoint(x: size.width - 4, y: size.height * 0.5))
    }

    static func point(at t: Double, in size: CGSize) -> CGPoint {
        let (a, c, b) = ends(in: size)
        let u = 1 - t
        return CGPoint(x: u * u * a.x + 2 * u * t * c.x + t * t * b.x, y: u * u * a.y + 2 * u * t * c.y + t * t * b.y)
    }

    func path(in rect: CGRect) -> Path {
        let (a, c, b) = Self.ends(in: rect.size)
        var p = Path()
        p.move(to: a)
        p.addQuadCurve(to: b, control: c)
        return p
    }
}

/// Status, carrier and ETA, with ‹ › when there's another order that way
/// (the expanded Dynamic Island).
struct DeliveryRow: View {
    let state: DeliveryActivityAttributes.ContentState
    let activityID: String
    let compact: Bool

    var body: some View {
        let order = state.current
        HStack(spacing: 8) {
            if state.orders.count > 1 { FlipButton(activityID: activityID, step: -1, shown: state.hasPrevious) }
            VStack(alignment: .leading, spacing: 2) {
                Text(order?.statusLine ?? "")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(statusTint(order))
                    .lineLimit(1)
                if let detail = order?.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(order.map { "\($0.spoken)\(state.position.isEmpty ? "" : ", order \(state.position)")" } ?? "")
            if let order, order.status == "delivered" {
                Button(intent: DismissDeliveryIntent(activityID: activityID, orderID: order.id)) {
                    Text(String(localized: "Dismiss", comment: "Live Activity button: take a delivered order off the card"))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).frame(height: 28)
                        .background(Capsule().fill(.white.opacity(0.18)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss \(order.title)")
            }
            if state.orders.count > 1 { FlipButton(activityID: activityID, step: 1, shown: state.hasNext) }
        }
        .padding(.horizontal, compact ? 4 : 0)
    }
}

#Preview("Lock Screen", as: .content, using: DeliveryActivityAttributes(kind: "deliveries")) {
    DeliveryLiveActivity()
} contentStates: {
    DeliveryActivityAttributes.ContentState(orders: [
        DeliveryOrder(id: "a", brand: "Ripl Efek", item: "Laundry Detergent", status: "out_for_delivery", carrier: "UPS", eta: "By 2:30 PM", link: nil),
        DeliveryOrder(id: "b", brand: "KOBA", item: "Keep It Together Headband", status: "nearby", carrier: "USPS", eta: "2 stops away", link: nil),
    ], index: 0)
}
