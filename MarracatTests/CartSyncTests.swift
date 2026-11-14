import Foundation
import Testing
@testable import Marracat

/// The cart shared with marracat.com (CartSync; owner, 2026-10-05).
@MainActor
struct CartSyncTests {
    @Test func mergeKeepsTheLargerQuantity() {
        let a = [CartLine(productID: "p1", variantID: 1, quantity: 1), CartLine(productID: "p2", variantID: 2, quantity: 3)]
        let b = [CartLine(productID: "p1", variantID: 1, quantity: 2), CartLine(productID: "p3", variantID: 3, quantity: 1)]
        let merged = CartStore.merge(a, b)
        #expect(merged.map(\.id) == ["p1#1", "p2#2", "p3#3"])
        #expect(merged.map(\.quantity) == [2, 3, 1])
    }

    @Test func linesSurviveTheTripToTheServerAndBack() {
        let line = CartLine(productID: "p1", variantID: 43145898492085, quantity: 2, option: "M", unitPrice: 19, currency: "USD")
        let back = CartSync.fromServer(CartSync.toServer([line]))
        #expect(back == [line])
        // The website allows 99 of a thing; the app's menu goes to 10.
        #expect(CartSync.fromServer([.init(productID: "p", variantID: "9", quantity: 40)]).first?.quantity == 10)
        #expect(CartSync.fromServer([.init(productID: "p", variantID: "x", quantity: 1)]).isEmpty)
    }

    @Test func aRemoteCartIsNotSentBackButALocalChangeIs() {
        let defaults = UserDefaults(suiteName: "CartSyncTests-\(UUID())")!
        let cart = CartStore(defaults: defaults)
        cart.activate("acct")
        #expect(cart.syncState.dirty == false, "switching accounts isn't a change")
        cart.applyRemote([CartLine(productID: "p1", variantID: 1, quantity: 1)])
        #expect(cart.syncState.dirty == false, "the account's own cart isn't sent back")
        cart.add(productID: "p2", variantID: 2)
        #expect(cart.syncState.dirty == true, "a change made here waits to be sent")
    }
}

/// The order page's arrival line (owner, 2026-10-05).
struct ArrivalLabelTests {
    @Test func namesTheDay() {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
        let now = f.date(from: "2026-10-05")!.addingTimeInterval(9 * 3600)
        #expect(OrderDetailView.arrivalLabel("2026-10-05", now: now) == "Arriving today")
        #expect(OrderDetailView.arrivalLabel("2026-10-06", now: now) == "Arriving tomorrow")
        #expect(OrderDetailView.arrivalLabel("2026-10-09", now: now)?.hasPrefix("Arriving Friday") == true)
        #expect(OrderDetailView.arrivalLabel("2026-10-01", now: now) == nil, "a past day isn't shown")
    }
}
