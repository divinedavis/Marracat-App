import AppIntents
import SwiftUI
import WidgetKit

// Home Screen and Lock Screen widgets (owner-approved queue item 3,
// 2026-10-14). Each is an AppIntentConfiguration, so long-pressing it and
// choosing Edit Widget offers the options below (WidgetKit, "Making a
// configurable widget").
//
// The configuration entities answer from the App Group snapshot, not the
// catalog: the configuration UI runs its queries in this extension, which
// can't link the app or hold the catalog (BrandEntity's query in
// Marracat/AppIntents waits on the app's in-memory catalog). They use the
// same ids as the app's BrandEntity and CategoryEntity, so a choice here is
// the brand or department of the same name everywhere else.

// MARK: - Configuration

struct WidgetBrandEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Featured Brand")
    static let defaultQuery = WidgetBrandQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct WidgetBrandQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [WidgetBrandEntity] {
        let brands = WidgetStore.read().brands
        return identifiers.compactMap { id in brands.first { $0.id == id }.map { WidgetBrandEntity(id: $0.id, name: $0.name) } }
    }

    func suggestedEntities() async throws -> [WidgetBrandEntity] {
        WidgetStore.read().brands.map { WidgetBrandEntity(id: $0.id, name: $0.name) }
    }
}

struct WidgetDepartmentEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Department")
    static let defaultQuery = WidgetDepartmentQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct WidgetDepartmentQuery: EntityQuery {
    /// A department picked earlier keeps resolving after its last drop ends.
    func entities(for identifiers: [String]) async throws -> [WidgetDepartmentEntity] {
        let known = WidgetStore.read().dropDepartments
        return identifiers.map { id in
            WidgetDepartmentEntity(id: id, name: known.first { $0.id == id }?.name ?? id.replacingOccurrences(of: "-", with: " ").capitalized)
        }
    }

    func suggestedEntities() async throws -> [WidgetDepartmentEntity] {
        WidgetStore.read().dropDepartments.map { WidgetDepartmentEntity(id: $0.id, name: $0.name) }
    }
}

struct PriceDropsConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Price Drops"
    static let description = IntentDescription("Saved items that cost less than when you saved them.")

    @Parameter(title: "Department", description: "Only drops in one department. Leave empty for all.")
    var department: WidgetDepartmentEntity?

    init() {}
}

struct FeaturedBrandConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Featured Brand"
    static let description = IntentDescription("One of Marracat's featured brands, or the one you pick.")

    @Parameter(title: "Brand", description: "Leave empty to change brand every three hours.")
    var brand: WidgetBrandEntity?

    init() {}
}

struct OrdersConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Orders"
    static let description = IntentDescription("Where your Marracat orders are.")

    @Parameter(title: "Show delivered orders", default: true)
    var includeDelivered: Bool

    init() {}
}

// MARK: - Timelines

struct PriceDropsEntry: TimelineEntry {
    let date: Date
    let drops: [WidgetProduct]
    let savedCount: Int
    let signedIn: Bool
}

struct PriceDropsProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> PriceDropsEntry {
        PriceDropsEntry(date: .now, drops: WidgetSamples.drops, savedCount: 8, signedIn: true)
    }

    func snapshot(for configuration: PriceDropsConfiguration, in context: Context) async -> PriceDropsEntry {
        let entry = entry(configuration, now: .now)
        return context.isPreview && entry.drops.isEmpty ? placeholder(in: context) : entry
    }

    /// One entry; the app asks for a reload when saves or prices change, and
    /// the snapshot is re-read every six hours regardless.
    func timeline(for configuration: PriceDropsConfiguration, in context: Context) async -> Timeline<PriceDropsEntry> {
        let now = Date.now
        return Timeline(entries: [entry(configuration, now: now)], policy: .after(now.addingTimeInterval(WidgetTimeline.refresh)))
    }

    private func entry(_ c: PriceDropsConfiguration, now: Date) -> PriceDropsEntry {
        let s = WidgetStore.read()
        return PriceDropsEntry(date: now, drops: WidgetTimeline.priceDrops(s, department: c.department?.id),
                               savedCount: s.savedCount, signedIn: s.signedIn)
    }
}

struct FeaturedBrandEntry: TimelineEntry {
    let date: Date
    let brand: WidgetBrand?
}

struct FeaturedBrandProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> FeaturedBrandEntry { FeaturedBrandEntry(date: .now, brand: WidgetSamples.brand) }

    func snapshot(for configuration: FeaturedBrandConfiguration, in context: Context) async -> FeaturedBrandEntry {
        let brand = WidgetTimeline.featured(WidgetStore.read(), pinned: configuration.brand?.id, at: .now)
        return FeaturedBrandEntry(date: .now, brand: brand ?? (context.isPreview ? WidgetSamples.brand : nil))
    }

    /// A day of rotation handed over at once: no reloads needed to move on.
    func timeline(for configuration: FeaturedBrandConfiguration, in context: Context) async -> Timeline<FeaturedBrandEntry> {
        let s = WidgetStore.read(), pinned = configuration.brand?.id
        let dates = WidgetTimeline.featuredDates(pinned: pinned != nil, now: .now)
        let entries = dates.map { FeaturedBrandEntry(date: $0, brand: WidgetTimeline.featured(s, pinned: pinned, at: $0)) }
        let policy: TimelineReloadPolicy = pinned != nil ? .after(Date.now.addingTimeInterval(WidgetTimeline.refresh)) : .atEnd
        return Timeline(entries: entries, policy: policy)
    }
}

struct OrdersEntry: TimelineEntry {
    let date: Date
    let orders: [WidgetOrder]
    let signedIn: Bool
}

struct OrdersProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> OrdersEntry { OrdersEntry(date: .now, orders: WidgetSamples.orders, signedIn: true) }

    func snapshot(for configuration: OrdersConfiguration, in context: Context) async -> OrdersEntry {
        let entry = entry(configuration, now: .now)
        return context.isPreview && entry.orders.isEmpty ? placeholder(in: context) : entry
    }

    func timeline(for configuration: OrdersConfiguration, in context: Context) async -> Timeline<OrdersEntry> {
        let now = Date.now
        return Timeline(entries: [entry(configuration, now: now)], policy: .after(now.addingTimeInterval(WidgetTimeline.refresh)))
    }

    private func entry(_ c: OrdersConfiguration, now: Date) -> OrdersEntry {
        let s = WidgetStore.read()
        return OrdersEntry(date: now, orders: WidgetTimeline.orders(s, includeDelivered: c.includeDelivered), signedIn: s.signedIn)
    }
}

/// What the widget gallery shows before the app has written anything.
enum WidgetSamples {
    static let drops = [
        WidgetProduct(id: "sample-1", title: "Gloss Bomb", brandName: "Fenty Beauty", category: "makeup", price: "$16.00", was: "$21.00", percentOff: 24),
        WidgetProduct(id: "sample-2", title: "Silk Press Serum", brandName: "Sienna Naturals", category: "hair", price: "$24.00", was: "$30.00", percentOff: 20),
        WidgetProduct(id: "sample-3", title: "Everyday Tote", brandName: "Curves", category: "bags", price: "$68.00", was: "$80.00", percentOff: 15),
    ]
    static let brand = WidgetBrand(id: "sample", name: "Telfar", tagline: "Not for you, for everyone.", products: drops)
    static let orders = [
        WidgetOrder(id: "sample-1", brandID: "ripl-efek", brandName: "Ripl Efek", item: "Laundry Detergent", step: 2,
                    headline: String(localized: "Out for delivery", comment: "Order status"), carrier: "UPS", placed: .now, link: "marracat://orders"),
        WidgetOrder(id: "sample-2", brandID: "koba-skincare", brandName: "KOBA", item: "Headband", step: 1,
                    headline: String(localized: "Shipped Monday", comment: "Order status in the widget gallery sample"), carrier: "USPS", placed: .now, link: "marracat://orders"),
    ]
}

// MARK: - Widgets

private let homeFamilies: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge]

/// The widget background: the system's own, so it follows light and dark.
private extension View {
    func marracatWidgetBackground() -> some View {
        containerBackground(for: .widget) { Color(uiColor: .systemBackground) }
    }
}

struct PriceDropsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetKind.priceDrops, intent: PriceDropsConfiguration.self, provider: PriceDropsProvider()) { entry in
            PriceDropsEntryView(entry: entry)
        }
        .configurationDisplayName("Price Drops")
        .description("Saved items that cost less than when you saved them.")
        .supportedFamilies(homeFamilies + [.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct PriceDropsEntryView: View {
    let entry: PriceDropsEntry
    @Environment(\.widgetFamily) private var family
    var body: some View {
        PriceDropsWidgetView(drops: entry.drops, savedCount: entry.savedCount, signedIn: entry.signedIn, family: family)
            .marracatWidgetBackground()
    }
}

/// No circular size: a brand name doesn't fit a 70-point circle.
struct FeaturedBrandWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetKind.featuredBrand, intent: FeaturedBrandConfiguration.self, provider: FeaturedBrandProvider()) { entry in
            FeaturedBrandEntryView(entry: entry)
        }
        .configurationDisplayName("Featured Brand")
        .description("A featured Marracat brand, changing through the day, or one you pick.")
        .supportedFamilies(homeFamilies + [.accessoryRectangular, .accessoryInline])
    }
}

struct FeaturedBrandEntryView: View {
    let entry: FeaturedBrandEntry
    @Environment(\.widgetFamily) private var family
    var body: some View {
        FeaturedBrandWidgetView(brand: entry.brand, family: family).marracatWidgetBackground()
    }
}

struct OrdersWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetKind.orders, intent: OrdersConfiguration.self, provider: OrdersProvider()) { entry in
            OrdersEntryView(entry: entry)
        }
        .configurationDisplayName("Orders")
        .description("Where your Marracat orders are, from ordered to delivered.")
        .supportedFamilies(homeFamilies + [.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct OrdersEntryView: View {
    let entry: OrdersEntry
    @Environment(\.widgetFamily) private var family
    var body: some View {
        OrdersWidgetView(orders: entry.orders, signedIn: entry.signedIn, family: family).marracatWidgetBackground()
    }
}
