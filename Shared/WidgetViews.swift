import SwiftUI
import UIKit
import WidgetKit

// The widgets' views, in Shared so the app's unit tests can render every
// family in light, dark and the largest text size (WidgetTests) — the
// extension only wraps them in WidgetKit configurations.
//
// System colors and text styles throughout, so dark mode, tinted and clear
// Home Screens, vibrant Lock Screen rendering and Dynamic Type come from iOS.
// Each tappable piece names what it opens for VoiceOver; photos are
// decorative. Saved items and orders are personal, so they're marked
// privacySensitive: iOS redacts them on a locked phone when the person has
// turned off widget data access on the Lock Screen (WidgetKit, "Creating a
// widget extension" › Hide sensitive content).

/// A pre-shrunk thumbnail from the App Group container. Decoded at the size
/// shown, never the original: a large widget holds at most a handful of
/// 240-pixel JPEGs (WidgetStore.thumbPixels).
struct WidgetThumb: View {
    let name: String?
    var symbol = "bag"
    var corner: CGFloat = 10

    var body: some View {
        Group {
            if let url = WidgetStore.thumbURL(name), let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Color(uiColor: .secondarySystemFill)
                    Image(systemName: symbol).font(.title3).foregroundStyle(.secondary)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// "−24%".
struct DropBadge: View {
    let percent: Int
    var body: some View {
        Text("−\(percent)%")
            .font(.caption2.weight(.bold).monospacedDigit())
            .padding(.horizontal, 5).padding(.vertical, 2)
            .foregroundStyle(Color(uiColor: .systemBackground))
            .background(Color.primary, in: Capsule())
            .widgetAccentable()
            .accessibilityHidden(true)
    }
}

/// A header line: icon, title, and a count on the right.
private struct WidgetHeader: View {
    let title: String
    let symbol: String
    var trailing: String? = nil
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.subheadline.weight(.semibold)).widgetAccentable().accessibilityHidden(true)
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 4)
            if let trailing { Text(trailing).font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// An empty state: what will show here and how it gets there.
private struct WidgetEmpty: View {
    let symbol: String
    let title: String
    let message: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: symbol).font(.title2).widgetAccentable().accessibilityHidden(true)
            Spacer(minLength: 0)
            Text(title).font(.headline).lineLimit(2).minimumScaleFactor(0.8)
            Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(3).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// Text follows Dynamic Type up to the largest size that still fits the
    /// widget's fixed frame: accessibility sizes past that would clip every
    /// line to "Mediu…" (WidgetTests renders each family at .accessibility5).
    @ViewBuilder func widgetTextCap(_ family: WidgetFamily) -> some View {
        switch family {
        case .accessoryCircular, .accessoryRectangular, .accessoryInline: dynamicTypeSize(...DynamicTypeSize.xxLarge)
        default: dynamicTypeSize(...DynamicTypeSize.accessibility1)
        }
    }
}

private extension View {
    /// A Link's text in the widget's own colors, not the system accent blue.
    func plainWidgetLink() -> some View { foregroundStyle(.primary).tint(.primary) }
}

// MARK: - Price drops

struct PriceDropsWidgetView: View {
    let drops: [WidgetProduct]
    let savedCount: Int
    let signedIn: Bool
    let family: WidgetFamily

    private var countLine: String { drops.count == 1 ? String(localized: "1 price drop", comment: "Price drops widget text") : String(localized: "\(drops.count) price drops", comment: "Price drops widget text") }
    /// VoiceOver's longer form.
    private var spokenCount: String { drops.count == 1 ? String(localized: "1 saved item dropped in price", comment: "Price drops widget text") : String(localized: "\(drops.count) saved items dropped in price", comment: "Price drops widget text") }
    private var emptyMessage: String {
        savedCount == 0 ? String(localized: "Save items in Marracat and their price drops show here.", comment: "Price drops widget text")
                        : String(localized: "None of your \(savedCount) saved items is lower than when you saved it.", comment: "Price drops widget text")
    }

    var body: some View { content.widgetTextCap(family) }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryInline:
            Label(drops.isEmpty ? String(localized: "No price drops", comment: "Price drops widget text") : countLine, systemImage: "tag")
                .widgetURL(drops.first?.url ?? WidgetLink.deals)
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: "tag.fill").font(.caption)
                    Text("\(drops.count)").font(.title3.weight(.semibold).monospacedDigit()).minimumScaleFactor(0.6)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(drops.isEmpty ? String(localized: "No price drops on saved items", comment: "Price drops widget VoiceOver") : spokenCount)
            .widgetURL(drops.first?.url ?? WidgetLink.deals)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text(drops.isEmpty ? String(localized: "Price drops", comment: "Price drops widget title") : countLine).font(.headline).widgetAccentable().lineLimit(1)
                if let top = drops.first {
                    Text(top.title).font(.caption).lineLimit(1)
                    Text("−\(top.percentOff)% · \(top.price)").font(.caption.weight(.semibold)).lineLimit(1)
                } else {
                    Text(savedCount == 0 ? "Save items to watch prices" : "Nothing lower yet").font(.caption).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .privacySensitive()
            .accessibilityElement(children: .combine)
            .accessibilityLabel(drops.first.map { "\(spokenCount). Top: \($0.spoken)" } ?? "No price drops on saved items")
            .widgetURL(drops.first?.url ?? WidgetLink.deals)
        case .systemMedium:
            if drops.isEmpty { empty } else {
                VStack(alignment: .leading, spacing: 8) {
                    WidgetHeader(title: String(localized: "Price drops", comment: "Widget title"), symbol: "tag.fill", trailing: "\(drops.count)")
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(drops.prefix(3)) { p in
                            Link(destination: p.url) { tile(p) }
                                .plainWidgetLink()
                                .accessibilityLabel(p.spoken)
                        }
                        ForEach(0..<max(0, 3 - drops.count), id: \.self) { _ in Color.clear }
                    }
                }
                .privacySensitive()
            }
        case .systemLarge, .systemExtraLarge:
            if drops.isEmpty { empty } else {
                VStack(alignment: .leading, spacing: 8) {
                    WidgetHeader(title: String(localized: "Price drops", comment: "Widget title"), symbol: "tag.fill", trailing: "\(drops.count)")
                    ForEach(drops.prefix(5)) { p in
                        Link(destination: p.url) { row(p) }
                            .plainWidgetLink()
                            .accessibilityLabel(p.spoken)
                    }
                    Spacer(minLength: 0)
                }
                .privacySensitive()
            }
        default:
            if let top = drops.first {
                VStack(alignment: .leading, spacing: 4) {
                    WidgetThumb(name: top.thumb, symbol: "tag")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(alignment: .topLeading) { DropBadge(percent: top.percentOff).padding(4) }
                    Text(top.title).font(.caption.weight(.semibold)).lineLimit(1)
                    priceLine(top)
                }
                .privacySensitive()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Price drop: \(top.spoken)")
                .widgetURL(top.url)
            } else { empty }
        }
    }

    private var empty: some View {
        WidgetEmpty(symbol: "tag", title: String(localized: "No price drops", comment: "Price drops widget empty state"), message: emptyMessage)
            .widgetURL(WidgetLink.deals)
    }

    private func priceLine(_ p: WidgetProduct) -> some View {
        HStack(spacing: 4) {
            Text(p.price).font(.caption.weight(.bold)).lineLimit(1)
            if let was = p.was { Text(was).font(.caption2).strikethrough().foregroundStyle(.secondary).lineLimit(1) }
        }
        .minimumScaleFactor(0.7)
    }

    private func tile(_ p: WidgetProduct) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            WidgetThumb(name: p.thumb, symbol: "tag")
                .frame(maxWidth: .infinity).frame(height: 62)
                .overlay(alignment: .topLeading) { DropBadge(percent: p.percentOff).padding(3) }
            Text(p.title).font(.caption2).lineLimit(1)
            priceLine(p)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ p: WidgetProduct) -> some View {
        HStack(spacing: 10) {
            WidgetThumb(name: p.thumb, symbol: "tag", corner: 8).frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 1) {
                Text(p.title).font(.subheadline).lineLimit(1)
                Text(p.brandName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                DropBadge(percent: p.percentOff)
                priceLine(p)
            }
        }
    }
}

// MARK: - Featured brand

struct FeaturedBrandWidgetView: View {
    let brand: WidgetBrand?
    let family: WidgetFamily

    var body: some View { content.widgetTextCap(family) }

    @ViewBuilder private var content: some View {
        if let brand { content(brand) } else {
            switch family {
            case .accessoryInline: Label("Marracat brands", systemImage: "star").widgetURL(WidgetLink.deals)
            case .accessoryRectangular, .accessoryCircular:
                Text("Open Marracat to load brands").font(.caption).widgetURL(WidgetLink.deals)
            default:
                WidgetEmpty(symbol: "star", title: String(localized: "Featured brands", comment: "Featured brands widget empty state"), message: String(localized: "Open Marracat once to load them.", comment: "Featured brands widget empty state"))
                    .widgetURL(WidgetLink.deals)
            }
        }
    }

    @ViewBuilder
    private func content(_ b: WidgetBrand) -> some View {
        switch family {
        case .accessoryInline:
            Label("Featured: \(b.name)", systemImage: "star").widgetURL(b.url)
        case .accessoryRectangular, .accessoryCircular:
            VStack(alignment: .leading, spacing: 1) {
                Text("Featured").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Text(b.name).font(.headline).widgetAccentable().lineLimit(1).minimumScaleFactor(0.7)
                if let t = b.tagline { Text(t).font(.caption).lineLimit(1) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(spoken(b))
            .widgetURL(b.url)
        case .systemMedium:
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Featured brand").font(.caption.weight(.semibold)).foregroundStyle(.secondary).widgetAccentable()
                    Text(b.name).font(.headline).lineLimit(2).minimumScaleFactor(0.75)
                    if let t = b.tagline { Text(t).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(spoken(b))
                ForEach(tiles(b, 2)) { p in
                    Link(destination: p.url) {
                        VStack(alignment: .leading, spacing: 3) {
                            WidgetThumb(name: p.thumb).frame(width: 84).frame(maxHeight: .infinity)
                            Text(p.price).font(.caption2.weight(.semibold)).lineLimit(1)
                        }
                        .frame(width: 84)
                    }
                    .plainWidgetLink()
                    .accessibilityLabel(p.spoken)
                }
            }
            .widgetURL(b.url)
        case .systemLarge, .systemExtraLarge:
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    WidgetThumb(name: b.thumb, symbol: "star").frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Featured brand").font(.caption.weight(.semibold)).foregroundStyle(.secondary).widgetAccentable()
                        Text(b.name).font(.title3.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                        if let t = b.tagline { Text(t).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(spoken(b))
                Spacer(minLength: 0)
                HStack(alignment: .top, spacing: 8) {
                    ForEach(tiles(b, 3)) { p in
                        Link(destination: p.url) {
                            VStack(alignment: .leading, spacing: 3) {
                                WidgetThumb(name: p.thumb).aspectRatio(1, contentMode: .fit).frame(maxWidth: .infinity)
                                Text(p.title).font(.caption2).lineLimit(2)
                                Text(p.price).font(.caption2.weight(.semibold)).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .plainWidgetLink()
                        .accessibilityLabel(p.spoken)
                    }
                }
            }
            .widgetURL(b.url)
        default:
            VStack(alignment: .leading, spacing: 4) {
                WidgetThumb(name: b.thumb, symbol: "star").frame(maxWidth: .infinity, maxHeight: .infinity)
                Text("Featured").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).widgetAccentable()
                Text(b.name).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken(b))
            .widgetURL(b.url)
        }
    }

    private func tiles(_ b: WidgetBrand, _ n: Int) -> [WidgetProduct] { Array(b.products.prefix(n)) }

    private func spoken(_ b: WidgetBrand) -> String {
        [String(localized: "Featured brand", comment: "VoiceOver: Featured brand"), b.name, b.tagline].compactMap { $0 }.joined(separator: ", ")
    }
}

// MARK: - Orders

struct OrdersWidgetView: View {
    let orders: [WidgetOrder]
    let signedIn: Bool
    let family: WidgetFamily

    var body: some View { content.widgetTextCap(family) }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryInline:
            if let o = orders.first { Label("\(o.brandName): \(o.shortStatus)", systemImage: o.symbol).widgetURL(o.url) }
            else { Label("No orders", systemImage: "shippingbox").widgetURL(WidgetLink.orders) }
        case .accessoryCircular:
            if let o = orders.first {
                Gauge(value: Double(o.step), in: 0...3) {
                    Image(systemName: o.symbol)
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .accessibilityLabel(o.spoken)
                .privacySensitive()
                .widgetURL(o.url)
            } else {
                ZStack { AccessoryWidgetBackground(); Image(systemName: "shippingbox") }
                    .accessibilityLabel("No orders")
                    .widgetURL(WidgetLink.orders)
            }
        case .accessoryRectangular:
            if let o = orders.first {
                VStack(alignment: .leading, spacing: 1) {
                    Label(o.headline, systemImage: o.symbol).font(.headline).widgetAccentable().lineLimit(1).minimumScaleFactor(0.7)
                    Text(o.title).font(.caption).lineLimit(1)
                    if let c = o.carrier { Text(c).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .privacySensitive()
                .accessibilityElement(children: .combine)
                .accessibilityLabel(o.spoken)
                .widgetURL(o.url)
            } else {
                Text("No orders on their way").font(.caption).widgetURL(WidgetLink.orders)
            }
        case .systemMedium:
            if orders.isEmpty { empty } else {
                VStack(alignment: .leading, spacing: 8) {
                    WidgetHeader(title: String(localized: "Orders", comment: "Widget title"), symbol: "shippingbox.fill")
                    ForEach(orders.prefix(2)) { o in
                        Link(destination: o.url) { row(o) }.plainWidgetLink().accessibilityLabel(o.spoken)
                    }
                    Spacer(minLength: 0)
                }
                .privacySensitive()
                .widgetURL(WidgetLink.orders)
            }
        case .systemLarge, .systemExtraLarge:
            if orders.isEmpty { empty } else {
                VStack(alignment: .leading, spacing: 8) {
                    WidgetHeader(title: String(localized: "Orders", comment: "Widget title"), symbol: "shippingbox.fill")
                    ForEach(orders.prefix(5)) { o in
                        Link(destination: o.url) { row(o) }.plainWidgetLink().accessibilityLabel(o.spoken)
                    }
                    Spacer(minLength: 0)
                }
                .privacySensitive()
                .widgetURL(WidgetLink.orders)
            }
        default:
            if let o = orders.first {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: o.symbol).font(.title3).widgetAccentable()
                        Spacer()
                        WidgetThumb(name: o.thumb, symbol: "shippingbox", corner: 8).frame(width: 40, height: 40)
                    }
                    Spacer(minLength: 0)
                    Text(o.headline).font(.subheadline.weight(.semibold)).lineLimit(2).minimumScaleFactor(0.75)
                    Text(o.title).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                .privacySensitive()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(o.spoken)
                .widgetURL(o.url)
            } else { empty }
        }
    }

    private var empty: some View {
        WidgetEmpty(symbol: "shippingbox", title: String(localized: "No orders yet", comment: "Orders widget empty state"),
                    message: String(localized: "Orders you check out in Marracat show their delivery status here.", comment: "Orders widget empty state"))
            .widgetURL(WidgetLink.orders)
    }

    private func row(_ o: WidgetOrder) -> some View {
        HStack(spacing: 10) {
            WidgetThumb(name: o.thumb, symbol: "shippingbox", corner: 8).frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(o.headline).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                Text(o.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: o.symbol).foregroundStyle(o.delivered ? Color.green : Color.primary).accessibilityHidden(true)
        }
    }
}
