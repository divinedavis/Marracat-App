import SwiftUI

/// The top of Home while a holiday's event runs: a row of big tiles in the
/// day's colours, one for each of its `rows` collections, each opening that
/// list. Nothing shows on other days.
///
/// Owner, 2026-11-23, of a big retailer's Home: "Target has some
/// promotional tiles that are big, we don't", and of three previews:
/// "I like #3" (the event's own colours). The tiles took the place of the
/// banner and the product rows that were here since 2026-10-27 ("a row or
/// two in the app that has products that match the event"); the products
/// are one tap away, in the list a tile opens.
///
/// The tiles follow the shopper like the rest of Home's picks (owner,
/// 2026-11-23, asked whether Black Friday's rows should: "only departments
/// they touched"): someone with a history gets a tile's photo, markdown and
/// lowest price from their departments only, and a list with too few of
/// those has no tile. When none of an event is in their departments the
/// plain banner shows, with no product on it, and opens the event's whole
/// list. A shopper with no history sees the whole event.
///
/// Built from the catalog this phone has (the bundled slice first, the
/// whole catalog once it lands), off the main thread.
struct HolidayEventRows: View {
    /// The departments this shopper has shown interest in (empty: all).
    var touched: Set<String> = []
    /// How many times Home has been pulled to refresh this launch: each pull
    /// moves every tile on to its list's next product (owner, 2026-11-25:
    /// "the refresh feature doesn't actually refresh my products").
    var round = 0
    @Environment(CatalogStore.self) private var catalog
    @State private var built: [Built] = []
    @State private var builtFor = ""

    struct Built: Identifiable {
        let holiday: Holiday
        let tiles: [Tile]
        /// What the banner opens when there are no tiles: the event's first
        /// collection with anything in it.
        let opens: HolidayCollection
        var id: String { holiday.id }
    }

    /// One collection's tile: what it says and the product it shows.
    struct Tile: Identifiable {
        let collection: HolidayCollection
        /// The collection's title without the event's name before it
        /// ("Black Friday: biggest deals" is "Biggest deals" under the
        /// "Black Friday Deals" header).
        let title: String
        /// The product pictured: the list's first pick no earlier tile shows,
        /// then the next one along for each pull to refresh.
        let photo: Product
        /// The biggest markdown in a deal list (one with `minOff`); nil for
        /// the rest. Never past the list's `maxOff`.
        let percent: Int?
        /// The lowest-priced product, "from $1.50": among those priced in
        /// dollars when there are any, since the app leads with dollars and
        /// another currency's dollar figure is only approximate.
        let lowest: Product
        let count: Int
        var id: String { collection.id }

        var isDeals: Bool { percent != nil }
    }

    /// A list needs this many products to get a tile; fewer looks broken
    /// when it opens.
    static let minimum = 4

    /// Each event's tiles for a shopper. Pure, so Home can run it off the
    /// main thread.
    static func build(_ events: [Holiday], products: [Product], touched: Set<String>, round: Int = 0) -> [Built] {
        let theirs = touched.isEmpty ? products : products.filter { touched.contains($0.category) }
        return events.compactMap { h in
            let collections = (h.rows ?? []).compactMap { HolidayCalendar.collection($0) }
            var pictured = Set<String>(), photos = Set<String>()
            let tiles = collections.compactMap { c -> Tile? in
                let all = c.ranked(from: theirs)
                guard all.count >= minimum,
                      let lowest = all.filter({ $0.currencyCode == "USD" }).min(by: { $0.price < $1.price })
                        ?? all.min(by: { $0.usdPrice < $1.usdPrice }) else { return nil }
                // One brand at a time, as the list itself opens; two lists
                // that lead with the same product don't show it twice.
                // A refresh starts each list `round` picks further along,
                // so the tile comes back with another brand's product.
                let picks = CatalogStore.spread(all, limit: 12).rotated(by: round)
                guard let photo = picks.first(where: { !pictured.contains($0.id) && !photos.contains($0.images.first ?? "") })
                        ?? picks.first(where: { !pictured.contains($0.id) }) ?? picks.first else { return nil }
                pictured.insert(photo.id)
                photos.insert(photo.images.first ?? "")
                return Tile(collection: c, title: title(c, in: h), photo: photo,
                            percent: c.minOff == nil ? nil : all.compactMap(\.percentOff).max(),
                            lowest: lowest, count: all.count)
            }
            guard let opens = tiles.first?.collection
                    ?? collections.first(where: { $0.picks(from: products, limit: minimum).count >= minimum }) else { return nil }
            return Built(holiday: h, tiles: tiles, opens: opens)
        }
    }

    /// "Black Friday: biggest deals" → "Biggest deals": the row's header
    /// already names the event.
    static func title(_ collection: HolidayCollection, in holiday: Holiday) -> String {
        let prefix = holiday.name + ": "
        guard collection.title.lowercased().hasPrefix(prefix.lowercased()) else { return collection.title }
        let rest = collection.title.dropFirst(prefix.count)
        return rest.prefix(1).uppercased() + rest.dropFirst()
    }

    var body: some View {
        let events = HolidayCalendar.events()
        let key = events.map(\.id).joined(separator: ",") + "|\(catalog.catalog.generatedAt)|\(catalog.catalog.products.count)|"
            + touched.sorted().joined(separator: ",") + "|\(round)"
        VStack(spacing: 0) {
            ForEach(built) { b in
                if b.tiles.isEmpty {
                    EventBanner(holiday: b.holiday, route: .collection(b.opens.id))
                } else {
                    EventTileRow(holiday: b.holiday, tiles: b.tiles)
                }
            }
        }
        .task(id: key) {
            guard key != builtFor else { return }
            guard !events.isEmpty else { built = []; builtFor = key; return }
            let products = catalog.catalog.products
            let touched = touched, round = round
            built = await Task.detached(priority: .userInitiated) { Self.build(events, products: products, touched: touched, round: round) }.value
            builtFor = key
        }
    }
}

/// An event's name over its tiles, which scroll sideways one at a time: each
/// is as wide as a Home product card (four fifths of the row), so the next
/// one shows at the edge.
struct EventTileRow: View {
    let holiday: Holiday
    let tiles: [HolidayEventRows.Tile]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: holiday.event?.name ?? holiday.name, route: tiles.first.map { .collection($0.id) })
                .padding(.horizontal, 12)
            ScrollView(.horizontal, showsIndicators: false) {
                // Not lazy: an event has a tile or two, and every tile takes
                // the height of the tallest (a title on two lines).
                HStack(alignment: .top, spacing: ProductRow.spacing) {
                    ForEach(Array(tiles.enumerated()), id: \.element.id) { index, tile in
                        EventTile(holiday: holiday, tile: tile)
                            .cardWidthInRow()
                            .frame(maxHeight: .infinity)
                            .simultaneousGesture(TapGesture().onEnded {
                                Analytics.shared.tapped(row: "event", product: tile.photo, position: index)
                            })
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .scrollTargetLayout()
                .padding(.horizontal, 12)
            }
            .scrollTargetBehavior(.viewAligned)
        }
        .padding(.vertical, 14)
        .background(Theme.canvas)
        .modifier(RecRowTracking(row: "event", first: tiles.first?.photo))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("eventTiles")
    }
}

/// One big tile: the event's kicker and days, the list's name, its biggest
/// markdown and lowest price, a button, and one of its products on white.
/// The whole tile opens the list.
struct EventTile: View {
    let holiday: Holiday
    let tile: HolidayEventRows.Tile

    /// In dollars, as every price in the app leads with.
    private var price: String { Money.string(tile.lowest.usdPrice) }

    private var line: String {
        if let percent = tile.percent {
            return String(localized: "Up to \(percent)% off · from \(price)", comment: "Home event tile: the list's biggest markdown and lowest price")
        }
        return String(localized: "\(tile.count.formatted()) items · from \(price)", comment: "Home event tile: how many products the list has and its lowest price")
    }

    private var action: String {
        tile.isDeals ? String(localized: "Get the deals", comment: "Home event tile button, on a list of markdowns")
            : String(localized: "Shop now", comment: "Home event tile button")
    }

    /// The same, with the price in words: a bare "$10.00" fails the
    /// accessibility audit's human-readable check.
    private var spoken: String {
        let from = Money.spoken(tile.lowest.usdPrice)
        let name = holiday.event?.name ?? holiday.name
        if let percent = tile.percent {
            return String(localized: "\(tile.title), \(name). Up to \(percent) percent off, from \(from).", comment: "VoiceOver: a Home event tile on a list of markdowns")
        }
        return String(localized: "\(tile.title), \(name). \(tile.count.formatted()) items, from \(from).", comment: "VoiceOver: a Home event tile")
    }

    var body: some View {
        let hexes = holiday.eventColors
        NavigationLink(value: Route.collection(tile.collection.id)) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(holiday.eventKicker).brandFont(.caption2.weight(.medium)).tracking(1.2).lineLimit(2)
                    Text(tile.title).brandFont(.largeTitle.weight(.medium)).lineLimit(3).minimumScaleFactor(0.7).padding(.top, 4)
                    Text(line).brandFont(.subheadline).padding(.top, 2)
                    Text(action).brandFont(.footnote.bold()).foregroundStyle(Color(white: 0.09))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(Color.white))
                        .padding(.top, 12)
                }
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Its own height, always: sharing the tile's height with the
                // photo cut these lines short at large text sizes.
                .fixedSize(horizontal: false, vertical: true)
                // The type grows with the reader's setting as far as the
                // first accessibility size; past it a tile is taller than
                // the screen and its product is never seen.
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                Spacer(minLength: 0)
                // The product on white, as the brand shot it, whatever the theme.
                Color.white
                    .aspectRatio(1, contentMode: .fit)
                    .overlay { RemoteImage(url: tile.photo.images.first, width: 800).padding(14) }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding([.horizontal, .bottom], 12)
                    .layoutPriority(1)
                    .accessibilityHidden(true)
            }
            .frame(maxHeight: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: hexes.map(Color.init(hex:)), startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.black.opacity(Holiday.shade(over: hexes))))
            }
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(spoken)
        .accessibilityIdentifier("eventTile")
    }
}

extension Holiday {
    /// The colours of its Home tiles and banner.
    var eventColors: [String] { banner ?? tab }

    /// "SPECIAL EVENT · NOV 20 – 29": the event's badge and the days it runs.
    var eventKicker: String {
        let badge = event?.badge ?? String(localized: "Special Event", comment: "Holiday banner kicker")
        let days = eventDaysText
        return (days.isEmpty ? badge : "\(badge) · \(days)").uppercased()
    }

    /// "Nov 20 – 29": the run on now, or the next one.
    var eventDaysText: String {
        let cal = Calendar.holidays
        let year = cal.component(.year, from: .now)
        guard let range = [year - 1, year, year + 1].lazy.compactMap({ eventDays(in: $0) })
            .first(where: { $0.upperBound >= cal.startOfDay(for: .now) }) else { return "" }
        let f = DateIntervalFormatter()
        f.dateTemplate = "MMMd"
        return f.string(from: range.lowerBound, to: range.upperBound)
    }

    /// How much black goes over an event's colours so white type on them
    /// keeps 4.5:1 (WCAG AA): a quarter for most, more for the light ones
    /// (Black Friday's gold needs 35%). The lightest colour decides, since
    /// a tile's type sits where the gradient starts.
    static func shade(over hexes: [String]) -> Double {
        func linear(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        func contrast(_ hex: String, _ shade: Double) -> Double {
            let v = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
            let rgb = [16, 8, 0].map { linear(Double((v >> UInt32($0)) & 0xFF) / 255 * (1 - shade)) }
            return 1.05 / (0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2] + 0.05)
        }
        let steps = stride(from: 0.25, through: 0.6, by: 0.05)
        return steps.first { s in hexes.allSatisfy { contrast($0, s) >= 4.5 } } ?? 0.6
    }
}

/// "SPECIAL EVENT · OCT 21 – 31", the event's name and line, on the day's
/// colours: what Home shows of an event when none of it is in the
/// shopper's departments. Opens the event's whole list.
struct EventBanner: View {
    let holiday: Holiday
    let route: Route

    var body: some View {
        let colors = holiday.eventColors.map(Color.init(hex:))
        NavigationLink(value: route) {
            VStack(alignment: .leading, spacing: 4) {
                Text(holiday.eventKicker)
                    .brandFont(.caption2.weight(.bold)).tracking(1.2).opacity(0.9)
                Text(holiday.event?.name ?? holiday.name).brandFont(.title2.bold())
                if let short = holiday.event?.short { Text(short).brandFont(.subheadline) }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            // Darkened a quarter so white type keeps 4.5:1 on the light
            // colours (Halloween orange, Black Friday gold).
            .background {
                RoundedRectangle(cornerRadius: 14)
                    .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.25)))
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("eventBanner")
    }
}
