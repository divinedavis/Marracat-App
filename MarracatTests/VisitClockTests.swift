import Foundation
import Testing
@testable import Marracat

/// Home's refresh on a new visit and "New since your last visit" (owner,
/// 2026-11-08). VisitClock.
@MainActor
struct VisitClockTests {
    private func defaults() -> UserDefaults {
        let name = "VisitClockTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private func product(_ id: String, brand: String, published: String?, available: Bool = true) -> Product {
        Product(id: id, brand: brand, title: id, category: "beauty", productType: nil, subs: [], price: 20, compareAt: nil,
                images: [], url: "https://b.example/\(id)", available: available, variants: [], tags: [], description: nil,
                publishedAt: published, bestRank: nil, attrs: nil)
    }

    @Test func aFirstLaunchIsAVisitWithNothingToCompareTo() {
        let d = defaults()
        #expect(VisitClock.arrived(at: Date(timeIntervalSince1970: 1_000_000), defaults: d))
        #expect(VisitClock.since(defaults: d) == nil)
    }

    @Test func aQuickTripAwayIsTheSameVisit() {
        let d = defaults()
        let t = Date(timeIntervalSince1970: 1_000_000)
        VisitClock.arrived(at: t, defaults: d)
        VisitClock.left(at: t.addingTimeInterval(60), defaults: d)
        #expect(!VisitClock.arrived(at: t.addingTimeInterval(60 + 29 * 60), defaults: d))
        #expect(VisitClock.since(defaults: d) == nil)
    }

    @Test func comingBackAfterHalfAnHourIsANewVisitSinceTheLastOneEnded() {
        let d = defaults()
        let t = Date(timeIntervalSince1970: 1_000_000)
        VisitClock.arrived(at: t, defaults: d)
        let left = t.addingTimeInterval(600)
        VisitClock.left(at: left, defaults: d)
        #expect(VisitClock.arrived(at: left.addingTimeInterval(VisitClock.gap), defaults: d))
        #expect(VisitClock.since(defaults: d) == left)
    }

    /// Home asks on every return to its tab; only the first ask after
    /// coming to the front can start a visit (2026-11-11: each Home tap had
    /// been a "new visit" and a 400 ms rebuild).
    @Test func askingAgainInTheSameTimeInFrontIsNotAnotherVisit() {
        let d = defaults()
        let t = Date(timeIntervalSince1970: 1_000_000)
        #expect(VisitClock.arrived(at: t, defaults: d))
        #expect(!VisitClock.arrived(at: t.addingTimeInterval(5), defaults: d), "a tab switch, seconds later")
        #expect(!VisitClock.arrived(at: t.addingTimeInterval(VisitClock.gap * 3), defaults: d),
                "still in front an hour and a half later")
        let left = t.addingTimeInterval(VisitClock.gap * 3)
        VisitClock.left(at: left, defaults: d)
        #expect(VisitClock.arrived(at: left.addingTimeInterval(VisitClock.gap), defaults: d), "back after half an hour")
        #expect(!VisitClock.arrived(at: left.addingTimeInterval(VisitClock.gap + 5), defaults: d))
    }

    @Test func readsTheCatalogsDateFormats() {
        #expect(VisitClock.date("2026-11-07T09:50:13+01:00") != nil)
        #expect(VisitClock.date("2026-11-07T09:50:13Z") != nil)
        #expect(VisitClock.date("2026-11-07T09:50:13.123-05:00") != nil)
        #expect(VisitClock.date("yesterday") == nil)
    }

    @Test func onlyWhatWasAddedSinceInStockAndNotHiddenFavouredBrandsFirst() {
        let since = VisitClock.date("2026-11-07T00:00:00Z")!
        let items = [
            product("old", brand: "a", published: "2026-11-06T23:00:00Z"),
            product("new-a1", brand: "a", published: "2026-11-07T10:00:00Z"),
            product("new-a2", brand: "a", published: "2026-11-07T11:00:00Z"),
            product("new-b", brand: "b", published: "2026-11-07T12:00:00+01:00"),
            product("new-fav", brand: "fav", published: "2026-11-07T09:00:00Z"),
            product("sold-out", brand: "c", published: "2026-11-07T09:00:00Z", available: false),
            product("hidden", brand: "d", published: "2026-11-07T09:00:00Z"),
            product("undated", brand: "e", published: nil),
        ]
        let row = VisitClock.newSince(since, candidates: items, favoredBrands: ["fav"], hidden: ["hidden"])
        let ids = row.map(\.id)
        #expect(ids.first == "new-fav")
        #expect(Set(ids) == ["new-fav", "new-a1", "new-a2", "new-b"])
        #expect(VisitClock.newSince(since, candidates: items, favoredBrands: [], hidden: [], limit: 2).count == 2)
    }
}
