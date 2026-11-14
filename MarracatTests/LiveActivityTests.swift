import Foundation
import Testing
@testable import Marracat

/// The delivery Live Activity (Shared/DeliveryActivity.swift): what the
/// server's pushes decode to, ‹ › stepping, and the links it opens.
struct LiveActivityTests {
    private func order(_ id: String, _ status: String = "out_for_delivery") -> DeliveryOrder {
        DeliveryOrder(id: id, brand: id.uppercased(), item: nil, status: status, carrier: nil, eta: nil, link: nil)
    }
    private func state(_ n: Int, index: Int = 0) -> DeliveryActivityAttributes.ContentState {
        .init(orders: (0..<n).map { order("o\($0)") }, index: index)
    }

    @Test(arguments: [
        (3, 0, 1, 1), (3, 2, 1, 2), (3, 0, -1, 0), (3, 1, -1, 0), (1, 0, 1, 0), (1, 0, -1, 0), (4, 9, 1, 3), (2, -3, -1, 0),
    ])
    func flippingStopsAtEitherEnd(count: Int, from: Int, step: Int, to: Int) {
        #expect(state(count, index: from).flipped(by: step).index == to)
    }

    /// Owner, 2026-10-26: no › on the last order, no ‹ on the first.
    @Test func arrowsOnlyWhereThereIsAnotherOrder() {
        #expect(!state(3, index: 0).hasPrevious && state(3, index: 0).hasNext)
        #expect(state(3, index: 1).hasPrevious && state(3, index: 1).hasNext)
        #expect(state(3, index: 2).hasPrevious && !state(3, index: 2).hasNext)
        #expect(!state(1).hasPrevious && !state(1).hasNext)
    }

    /// A list row's right-hand side (owner, 2026-10-26).
    @Test func aListRowSaysWhenOnTheRight() {
        var o = order("a")
        #expect(o.when == "Out today")
        o.eta = "By 2:30 PM"
        #expect(o.when == "By 2:30 PM")
        o.status = "problem"
        #expect(o.when == "Issue")
        #expect(order("b", "arriving").when == "Today")
    }

    @Test func theArcMovesForwardWithTheOrder() {
        let steps = ["arriving", "out_for_delivery", "nearby", "delivered"].map { order("a", $0).progress }
        #expect(steps == steps.sorted() && Set(steps).count == 4 && steps.last == 1)
    }

    /// Dismiss on a delivered order (2026-10-17): it leaves the card, which
    /// points at the order after it; the last one leaves nothing.
    @Test func dismissingAnOrderKeepsTheRestInPlace() {
        let s = state(3, index: 1)
        let next = s.removing("o1")
        #expect(next.orders.map(\.id) == ["o0", "o2"])
        #expect(next.current?.id == "o2")
        #expect(state(3, index: 2).removing("o2").current?.id == "o1", "the last one steps back")
        #expect(s.removing("nope") == s)
        #expect(state(1).removing("o0").orders.isEmpty)
    }

    @Test func noOrdersFlipsToItself() {
        let empty = DeliveryActivityAttributes.ContentState(orders: [], index: 0)
        #expect(empty.flipped(by: 1) == empty)
        #expect(empty.current == nil)
        #expect(empty.position.isEmpty)
    }

    @Test func positionAndOpenCount() {
        var s = state(3, index: 1)
        #expect(s.position == "2 of 3")
        #expect(s.current?.id == "o1")
        s.orders[2].status = "delivered"
        #expect(s.openCount == 2)
        #expect(state(1).position.isEmpty, "one order shows no 1 of 1")
        #expect(DeliveryActivityAttributes.ContentState(orders: [order("a")], index: 7).current?.id == "a", "an index out of range is clamped")
    }

    /// The JSON web/server/live-activity.js puts in "content-state", decoded
    /// the way the system does (default decoder, no custom strategies).
    @Test func decodesTheServersContentState() throws {
        let json = """
        {"orders":[{"id":"t12","brand":"Ripl Efek","item":"Laundry Detergent","status":"out_for_delivery","carrier":"UPS","eta":null,"link":"marracat://order?brand=ripl&order=1417"},
                   {"id":"demo-koba","brand":"KOBA","status":"nearby","eta":"2 stops away","link":"marracat://orders"}],"index":1}
        """
        let s = try JSONDecoder().decode(DeliveryActivityAttributes.ContentState.self, from: Data(json.utf8))
        #expect(s.orders.count == 2)
        #expect(s.current?.brand == "KOBA")
        #expect(s.current?.item == nil && s.current?.carrier == nil)
        #expect(s.orders[0].title == "Ripl Efek · Laundry Detergent")
        #expect(s.orders[0].detail == "UPS")
        #expect(s.orders[1].detail == "2 stops away")
        var withBoth = s.orders[0]
        withBoth.eta = "By 5 PM"
        #expect(withBoth.detail == "UPS · By 5 PM")
        for ontrac in ["OnTrac", "ONTRAC", "On Trac"] {
            withBoth.carrier = ontrac
            #expect(withBoth.detail == "By 5 PM", "OnTrac never shows on the card")
            withBoth.eta = nil
            #expect(withBoth.detail == nil)
            withBoth.eta = "By 5 PM"
        }
        #expect(s.orders[0].url?.absoluteString == "marracat://order?brand=ripl&order=1417")
    }

    @Test(arguments: [
        ("arriving", "Arriving today", "Today"), ("out_for_delivery", "Out for delivery", "Out"), ("nearby", "Nearby", "Nearby"),
        ("delivered", "Delivered", "Done"), ("problem", "Delivery problem", "Issue"), ("something_new", "Arriving today", "Today"),
    ])
    func statusWords(status: String, line: String, short: String) {
        let o = order("a", status)
        #expect(o.statusLine == line)
        #expect(o.shortStatus == short)
        #expect(!o.symbol.isEmpty)
    }

    @Test func voiceOverReadsTheWholeCard() {
        let o = DeliveryOrder(id: "a", brand: "Telfar", item: "Medium Shopping Bag", status: "nearby", carrier: "FedEx", eta: "Next stop", link: nil)
        #expect(o.spoken == "Telfar · Medium Shopping Bag, Nearby, FedEx · Next stop")
    }

    @Test func onlyMarracatLinksOpen() {
        #expect(DeliveryOrder(id: "a", brand: "A", status: "nearby", link: "https://evil.example/x").url == nil)
        #expect(DeliveryOrder(id: "a", brand: "A", status: "nearby", link: "marracat://orders").url != nil)
    }

    @Test func deliveryLinksParse() {
        let u = { (s: String) in URL(string: s)! }
        #expect(DeliveryLink(u("marracat://order?brand=ripl&order=1417")) == .tracked(brandID: "ripl", orderNumber: "1417"))
        #expect(DeliveryLink(u("marracat://order?brand=ripl")) == .tracked(brandID: "ripl", orderNumber: nil))
        #expect(DeliveryLink(u("marracat://order?brand=ripl&order=1417%2F..")) == .tracked(brandID: "ripl", orderNumber: nil), "only digits")
        #expect(DeliveryLink(u("marracat://order?domain=telfar.net&name=%2388")) == .email(brandDomain: "telfar.net", orderName: "#88"))
        #expect(DeliveryLink(u("marracat://orders")) == .orders)
        #expect(DeliveryLink(u("marracat://order")) == .orders)
        #expect(DeliveryLink(u("marracat://wipe")) == nil)
        #expect(DeliveryLink(u("https://marracat.com/p/1")) == nil)
        #expect(DeliveryLink(u("com.googleusercontent.apps.1:/oauth")) == nil)
    }

    @Test func tokensAreHexAndRememberedOnlyByFingerprint() {
        #expect(LiveActivityStore.hex(Data([0x00, 0xab, 0xff])) == "00abff")
        let f = LiveActivityStore.fingerprint("abc")
        #expect(f.count == 64 && !f.contains("abc"))
        #expect(f == LiveActivityStore.fingerprint("abc"), "stable across launches")
    }
}
