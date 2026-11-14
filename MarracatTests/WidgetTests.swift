import Foundation
import Testing
import SwiftUI
import UIKit
import ImageIO
import WidgetKit
@testable import Marracat

/// Home Screen and Lock Screen widgets (queue item 3, 2026-10-14): what the
/// app writes into the App Group, what each widget's timeline shows for a
/// configuration, where each tap goes, that sign-out empties it, and that
/// every family renders in light, dark and the largest text size.
@MainActor
@Suite(.serialized)
struct WidgetTests {
    private func product(_ id: String, brand: String = "telfar", title: String? = nil, category: String = "bags",
                         price: Double, compareAt: Double? = nil, available: Bool = true, image: Bool = true) -> Product {
        Product(id: id, brand: brand, title: title ?? "Item \(id)", category: category, productType: nil, subs: [],
                price: price, compareAt: compareAt, images: image ? ["https://cdn.example/\(id).jpg"] : [], url: "https://b.example/\(id)",
                available: available, variants: [], tags: [], description: nil, publishedAt: nil, bestRank: nil, currency: "USD")
    }
    private func brand(_ id: String, _ name: String) -> Brand {
        Brand(id: id, name: name, domain: "\(id).example", category: "bags", tagline: "\(name) tagline",
              shopify: true, platform: "shopify", image: "https://cdn.example/\(id)-logo.jpg")
    }

    private func inputs(products: [Product], saved: [String], baselines: [String: Double] = [:], trackedAt: [String: Double] = [:],
                        checkouts: [CheckoutRecord] = [], now: Date = .now,
                        progress: @escaping (CheckoutRecord) -> (step: Int, headline: String, carrier: String?, delivered: Date?) = { _ in (0, "Ordered", nil, nil) })
        -> WidgetSnapshotBuilder.Inputs {
        let byID = Dictionary(products.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let brands = ["telfar": brand("telfar", "Telfar"), "curves": brand("curves", "Curves"), "fenty-beauty": brand("fenty-beauty", "Fenty Beauty")]
        return WidgetSnapshotBuilder.Inputs(
            saved: saved, signedIn: true, product: { byID[$0] }, brand: { brands[$0] },
            category: { $0 == "bags" ? Category(id: "bags", name: "Bags", symbol: "bag") : Category(id: $0, name: $0.capitalized, symbol: "tag") },
            brandProducts: { id in products.filter { $0.brand == id } },
            premierBrandIDs: ["telfar", "curves", "gone-brand"], featureKinds: ["curves": "tote"],
            baselines: baselines, trackedAt: trackedAt, checkouts: checkouts, progress: progress, now: now)
    }

    // MARK: Price drops

    @Test func aDropIsAgainstTheHighestOfSavedPriceAlertAndCompareAt() {
        let products = [
            product("a", price: 80),                    // saved at 100 → 20%
            product("b", price: 50, compareAt: 100),    // brand markdown → 50%
            product("c", price: 30),                    // price alert set at 40 → 25%
            product("d", price: 60),                    // went up since saved: not a drop
            product("e", price: 10, available: false), // sold out: not shown
        ]
        let drops = WidgetSnapshotBuilder.drops(saved: ["a", "b", "c", "d", "e"], product: { id in products.first { $0.id == id } },
                                                baselines: ["a": 100, "b": 50, "c": 30, "d": 50, "e": 20], trackedAt: ["c": 40])
        #expect(drops.map(\.product.id) == ["b", "c", "a"])
        #expect(drops.map(\.percent) == [50, 25, 20])
        #expect(drops.first?.was == 100)
    }

    @Test func baselinesStartAtTodaysPriceAndForgetUnsavedItems() {
        let b = WidgetSnapshotBuilder.baselines(saved: ["a", "new"], old: ["a": 100, "unsaved": 5],
                                                price: { ["a": 80, "new": 42][$0] })
        #expect(b == ["a": 100, "new": 42])
    }

    @Test func snapshotCarriesDropsDepartmentsBrandsAndThumbsButNotTheCatalog() {
        let products = [
            product("a", price: 80, compareAt: 100),
            product("h", brand: "fenty-beauty", category: "hair", price: 10, compareAt: 20),
            product("t1", brand: "curves", title: "Rug", price: 300),
            product("t2", brand: "curves", title: "Big Tote", price: 90),
            product("t3", brand: "curves", title: "Big Tote", price: 90),   // same title: one tile
            product("t4", brand: "curves", title: "Small Tote", price: 60, image: false),
        ] + (0..<40).map { product("x\($0)", price: 10) }
        let (s, thumbs) = WidgetSnapshotBuilder.build(inputs(products: products, saved: ["a", "h"]))
        #expect(s.priceDrops.map(\.id) == ["h", "a"])
        #expect(s.priceDrops[1].was == "$100.00" && s.priceDrops[1].price == "$80.00" && s.priceDrops[1].percentOff == 20)
        #expect(s.dropDepartments.map(\.name) == ["Bags", "Hair"])
        #expect(s.savedCount == 2)
        #expect(s.brands.map(\.id) == ["telfar", "curves"], "a premier brand missing from the catalog is skipped")
        #expect(s.brands[1].products.map(\.title) == ["Big Tote"], "Curves shows totes only, one per title, with photos")
        #expect(s.brands[0].products.count == WidgetSnapshotBuilder.productsPerBrand)
        #expect(Set(thumbs.keys) == s.thumbNames, "every thumbnail named has a source and nothing else is fetched")
        #expect(thumbs.values.allSatisfy { $0.hasPrefix("https://cdn.example/") })
        let bytes = try! JSONEncoder().encode(s).count
        #expect(bytes < 16_000, "the snapshot stays small (\(bytes) bytes)")
    }

    @Test func ordersAreRecentNewestFirstAndDeliveredOnesFallOff() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fresh = CheckoutRecord(brandID: "telfar", date: now.addingTimeInterval(-3600), itemCount: 2, subtotal: 100,
                                   productIDs: ["a"], orderID: "gid://shopify/Order/1042?key=abc", items: [PurchasedItem(title: "Shopping Bag", quantity: 2)])
        let delivered = CheckoutRecord(brandID: "curves", date: now.addingTimeInterval(-10 * 86_400), itemCount: 1, subtotal: 50, productIDs: [])
        let deliveredYesterday = CheckoutRecord(brandID: "fenty-beauty", date: now.addingTimeInterval(-5 * 86_400), itemCount: 1, subtotal: 20, productIDs: [])
        let old = CheckoutRecord(brandID: "telfar", date: now.addingTimeInterval(-40 * 86_400), itemCount: 1, subtotal: 10, productIDs: [])
        let (s, _) = WidgetSnapshotBuilder.build(inputs(products: [product("a", price: 10)], saved: [],
                                                        checkouts: [old, delivered, fresh, deliveredYesterday], now: now) { r in
            switch r.brandID {
            case "curves": (3, "Delivered", "UPS", now.addingTimeInterval(-5 * 86_400))
            case "fenty-beauty": (3, "Delivered", "USPS", now.addingTimeInterval(-86_400))
            default: (1, "Shipped Monday", "USPS", nil)
            }
        })
        #expect(s.orders.map(\.brandID) == ["telfar", "fenty-beauty"])
        let o = s.orders[0]
        #expect(o.item == "Shopping Bag" && o.step == 1 && o.headline == "Shipped Monday" && o.carrier == "USPS")
        #expect(o.link == "marracat://order?brand=telfar&order=1042")
        #expect(WidgetTimeline.orders(s, includeDelivered: false).map(\.brandID) == ["telfar"])
    }

    // MARK: Timelines

    @Test func priceDropsFilterByDepartment() {
        var s = WidgetSnapshot()
        s.priceDrops = [WidgetProduct(id: "a", title: "A", brandName: "T", category: "bags", price: "$1"),
                        WidgetProduct(id: "b", title: "B", brandName: "T", category: "hair", price: "$1")]
        #expect(WidgetTimeline.priceDrops(s, department: nil).map(\.id) == ["a", "b"])
        #expect(WidgetTimeline.priceDrops(s, department: "hair").map(\.id) == ["b"])
        #expect(WidgetTimeline.priceDrops(s, department: "shoes").isEmpty)
    }

    @Test func featuredBrandRotatesEveryThreeHoursOrStaysPinned() {
        var s = WidgetSnapshot()
        s.brands = ["a", "b", "c"].map { WidgetBrand(id: $0, name: $0.uppercased()) }
        let t0 = Date(timeIntervalSince1970: WidgetTimeline.rotation * 300)   // slot 300 → index 0
        #expect(WidgetTimeline.featured(s, pinned: nil, at: t0)?.id == "a")
        #expect(WidgetTimeline.featured(s, pinned: nil, at: t0.addingTimeInterval(WidgetTimeline.rotation - 1))?.id == "a")
        #expect(WidgetTimeline.featured(s, pinned: nil, at: t0.addingTimeInterval(WidgetTimeline.rotation))?.id == "b")
        #expect(WidgetTimeline.featured(s, pinned: nil, at: t0.addingTimeInterval(3 * WidgetTimeline.rotation))?.id == "a")
        #expect(WidgetTimeline.featured(s, pinned: "c", at: t0)?.id == "c")
        #expect(WidgetTimeline.featured(s, pinned: "removed", at: t0)?.id == "a", "a pinned brand no longer featured falls back to the rotation")
        #expect(WidgetTimeline.featured(.empty, pinned: nil, at: t0) == nil)

        let now = t0.addingTimeInterval(1000)
        let dates = WidgetTimeline.featuredDates(pinned: false, now: now)
        #expect(dates.count == WidgetTimeline.rotationEntries)
        #expect(dates[0] == now && dates[1] == t0.addingTimeInterval(WidgetTimeline.rotation))
        #expect(zip(dates.dropFirst(), dates.dropFirst(2)).allSatisfy { $1.timeIntervalSince($0) == WidgetTimeline.rotation })
        #expect(WidgetTimeline.featuredDates(pinned: true, now: now) == [now])
    }

    @Test func onlyTheWidgetsWhosePartChangedReload() {
        var a = WidgetSnapshot(); a.brands = [WidgetBrand(id: "x", name: "X")]
        var b = a
        #expect(b.changedKinds(from: a).isEmpty)
        b.savedCount = 3
        #expect(b.changedKinds(from: a) == [WidgetKind.priceDrops])
        b = a; b.brands = []
        #expect(b.changedKinds(from: a) == [WidgetKind.featuredBrand])
        b = a; b.signedIn = true
        #expect(b.changedKinds(from: a) == [WidgetKind.priceDrops, WidgetKind.orders])
    }

    // MARK: Links

    @Test func everyWidgetLinkOpensItsScreen() {
        #expect(AppDestination(url: WidgetLink.product("px-studio 150")) == .product("px-studio 150"))
        #expect(AppDestination(url: WidgetLink.brand("telfar")) == .brand("telfar"))
        #expect(AppDestination(url: WidgetLink.deals) == .deals)
        #expect(DeliveryLink(WidgetLink.orders) == .orders)
        #expect(DeliveryLink(WidgetLink.order(brandID: "telfar", number: "1042")) == .tracked(brandID: "telfar", orderNumber: "1042"))
        #expect(DeliveryLink(WidgetLink.order(brandID: "telfar", number: nil)) == .tracked(brandID: "telfar", orderNumber: nil))
        let order = WidgetOrder(id: "1", brandID: "t", brandName: "T", headline: "Ordered", placed: .now, link: "https://evil.example")
        #expect(order.url == WidgetLink.orders, "only marracat:// links are opened")
    }

    // MARK: Storage

    private func withTempRoot(_ body: (URL) throws -> Void) rethrows {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("widget-tests-\(UUID().uuidString)", isDirectory: true)
        WidgetStore.rootOverride = dir
        defer { WidgetStore.rootOverride = nil; try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    @Test func snapshotRoundTripsAndSignOutErasesEverything() throws {
        try withTempRoot { dir in
            #expect(WidgetStore.read() == .empty)
            var s = WidgetSnapshot(); s.savedCount = 4; s.signedIn = true
            s.priceDrops = [WidgetProduct(id: "a", title: "A", brandName: "T", category: "bags", price: "$1", thumb: "keep.jpg")]
            try WidgetStore.write(s)
            try WidgetStore.saveThumb(Data([0xFF, 0xD8]), named: "keep.jpg")
            try WidgetStore.saveThumb(Data([0xFF, 0xD8]), named: "stale.jpg")
            #expect(WidgetStore.read() == s)
            WidgetStore.pruneThumbs(keeping: s.thumbNames)
            #expect(WidgetStore.thumbURL("keep.jpg") != nil)
            #expect(WidgetStore.thumbURL("stale.jpg") == nil)

            let defaults = UserDefaults(suiteName: "widget-tests-\(UUID().uuidString)")!
            let sync = WidgetSync(defaults: defaults)
            sync.baselines = ["a": 10]
            sync.clear()
            #expect(WidgetStore.read() == .empty)
            #expect(WidgetStore.thumbURL("keep.jpg") == nil)
            #expect(!FileManager.default.fileExists(atPath: dir.path))
            #expect(sync.baselines.isEmpty)
        }
    }

    @Test func aSnapshotFromAnotherVersionIsIgnored() throws {
        try withTempRoot { _ in
            var s = WidgetSnapshot(); s.version = 99; s.savedCount = 1
            try WidgetStore.write(s)
            #expect(WidgetStore.read() == .empty)
        }
    }

    @Test func thumbnailNamesCantLeaveTheFolder() {
        for bad in ["../snapshot.json", "a/b.jpg", "", ".hidden", String(repeating: "a", count: 65)] {
            #expect(!WidgetStore.isSafeName(bad), "\(bad)")
        }
        #expect(WidgetStore.isSafeName(WidgetSnapshotBuilder.thumbName("https://cdn.example/x.jpg")))
    }

    @Test func thumbnailsAreShrunkSmall() throws {
        let big = UIGraphicsImageRenderer(size: CGSize(width: 1600, height: 1200), format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
            .jpegData(withCompressionQuality: 0.9) { ctx in
                UIColor.systemTeal.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 1600, height: 1200))
                UIColor.black.setFill(); ctx.fill(CGRect(x: 200, y: 200, width: 400, height: 400))
            }
        let small = try #require(WidgetSync.shrink(big))
        #expect(small.count <= WidgetStore.maxThumbBytes)
        let props = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithData(small as CFData, nil)!, 0, nil) as! [CFString: Any]
        #expect(props[kCGImagePropertyPixelWidth] as? Int == WidgetStore.thumbPixels)
        #expect(props[kCGImagePropertyPixelHeight] as? Int == 180)
        #expect(WidgetSync.shrink(Data("not an image".utf8)) == nil)
    }

    // MARK: Rendering

    private static let sizes: [(WidgetFamily, CGSize)] = [
        (.systemSmall, CGSize(width: 170, height: 170)), (.systemMedium, CGSize(width: 364, height: 170)),
        (.systemLarge, CGSize(width: 364, height: 382)), (.accessoryCircular, CGSize(width: 76, height: 76)),
        (.accessoryRectangular, CGSize(width: 172, height: 76)), (.accessoryInline, CGSize(width: 257, height: 26)),
    ]

    private func render(_ view: some View, size: CGSize, scheme: ColorScheme, type: DynamicTypeSize) -> UIImage? {
        let r = ImageRenderer(content: view.frame(width: size.width, height: size.height)
            .background(Color(uiColor: .systemBackground))
            .environment(\.colorScheme, scheme).environment(\.dynamicTypeSize, type))
        r.scale = 2
        return r.uiImage
    }

    @Test func everyFamilyRendersInLightDarkAndTheLargestTextSize() throws {
        let drops = [WidgetProduct(id: "a", title: "Medium Shopping Bag", brandName: "Telfar", category: "bags", price: "$150.00", was: "$202.00", percentOff: 26)]
        let brand = WidgetBrand(id: "telfar", name: "Telfar", tagline: "Not for you, for everyone.", products: drops)
        let orders = [WidgetOrder(id: "1", brandID: "telfar", brandName: "Telfar", item: "Medium Shopping Bag", step: 2,
                                  headline: "Out for delivery", carrier: "UPS", placed: .now, link: WidgetLink.orders.absoluteString)]
        for (family, size) in Self.sizes {
            var views: [AnyView] = [
                AnyView(PriceDropsWidgetView(drops: drops, savedCount: 3, signedIn: true, family: family)),
                AnyView(PriceDropsWidgetView(drops: [], savedCount: 0, signedIn: false, family: family)),
                AnyView(OrdersWidgetView(orders: orders, signedIn: true, family: family)),
                AnyView(OrdersWidgetView(orders: [], signedIn: false, family: family)),
            ]
            if family != .accessoryCircular {
                views += [AnyView(FeaturedBrandWidgetView(brand: brand, family: family)), AnyView(FeaturedBrandWidgetView(brand: nil, family: family))]
            }
            // TEST_RUNNER_WIDGET_RENDER_DIR=/some/dir writes each render out to look at.
            let out = ProcessInfo.processInfo.environment["WIDGET_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
            for (n, v) in views.enumerated() {
                for type in [DynamicTypeSize.large, .accessibility5] {
                    let light = try #require(render(v, size: size, scheme: .light, type: type))
                    let dark = try #require(render(v, size: size, scheme: .dark, type: type))
                    if let out {
                        try? light.pngData()?.write(to: out.appendingPathComponent("\(family)-\(n)-\(type)-light.png"))
                        try? dark.pngData()?.write(to: out.appendingPathComponent("\(family)-\(n)-\(type)-dark.png"))
                    }
                    #expect(light.size == size, "\(family)")
                    #expect(light.pngData() != dark.pngData(), "\(family) looks the same in dark mode")
                }
            }
        }
    }
}
