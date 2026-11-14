import XCTest
@testable import Marracat

/// A carrier-reported problem, explained on the order (owner, 2026-10-21).
final class DeliveryProblemTests: XCTestCase {
    private func tracked(_ status: String?, _ detail: String? = nil) -> TrackedOrder {
        TrackedOrder(brandID: "bask", checkoutID: "c", orderID: nil, permalink: nil, state: "shipped", carrier: "UPS",
                     trackingNumber: "1Z", trackingURL: nil, created: 0, updated: nil, trackingStatus: status, trackingDetail: detail)
    }

    func testProblemsAreReadFromTheCarriersStatus() throws {
        let p = try XCTUnwrap(DeliveryProblem.of(tracked: tracked("failure", "No access"), events: [], brand: "Bask & Lather Co."))
        XCTAssertEqual(p.kind, .failed)
        XCTAssertEqual(p.carrierSaid, "No access")
        XCTAssertEqual(DeliveryProblem.of(tracked: tracked("return_to_sender"), events: [], brand: "B")?.kind, .returning)
        XCTAssertEqual(DeliveryProblem.of(tracked: tracked("error"), events: [], brand: "B")?.kind, .stopped)
        XCTAssertNil(DeliveryProblem.of(tracked: tracked("in_transit"), events: [], brand: "B"), "moving along is no problem")
        XCTAssertTrue(p.whatToDo.contains("Bask & Lather Co."), "the advice names the brand")
    }

    func testAnOrderEmailsTrackingCountsToo() throws {
        let data = #"{"id":1,"received":0,"kind":"shipped","carrier":"USPS","trackingStatus":"return_to_sender","trackingDetail":"Returned"}"#.data(using: .utf8)!
        let event = try JSONDecoder().decode(RelayEvent.self, from: data)
        let p = try XCTUnwrap(DeliveryProblem.of(tracked: nil, events: [event], brand: "KOBA"))
        XCTAssertEqual(p.kind, .returning)
        XCTAssertEqual(p.carrierSaid, "Returned")
    }

    func testTheServersFieldsDecode() throws {
        let data = #"{"brandID":"b","checkoutID":"c","created":0,"trackingStatus":"failure","trackingDetail":"x"}"#.data(using: .utf8)!
        let t = try JSONDecoder().decode(TrackedOrder.self, from: data)
        XCTAssertEqual(t.trackingStatus, "failure")
        XCTAssertEqual(t.trackingDetail, "x")
    }
}
