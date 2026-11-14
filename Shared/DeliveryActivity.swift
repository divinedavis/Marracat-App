import Foundation
import ActivityKit
import AppIntents

/// Today's deliveries as one Live Activity (owner, 2026-10-13). Compiled into
/// the app and the widget extension (project.yml), so it uses nothing else
/// from either.
///
/// The server (web/server/live-activity.js) starts, updates and ends it with
/// ActivityKit pushes; `ContentState` must decode the JSON it sends with the
/// default decoder (Apple: no custom strategies), so plain strings only.
struct DeliveryActivityAttributes: ActivityAttributes {
    /// Always "deliveries"; the push names the type and sends this.
    var kind: String

    struct ContentState: Codable, Hashable {
        var orders: [DeliveryOrder]
        /// The order on screen; ‹ › change it on the phone (FlipDeliveryIntent).
        var index: Int

        var current: DeliveryOrder? {
            orders.isEmpty ? nil : orders[min(max(index, 0), orders.count - 1)]
        }

        /// One step through the orders, stopping at either end: no ›
        /// shows on the last one, so it mustn't wrap round either (owner,
        /// 2026-10-26: an arrow there "would suggest there's another").
        func flipped(by step: Int) -> ContentState {
            guard !orders.isEmpty else { return self }
            var next = self
            next.index = min(max(min(max(index, 0), orders.count - 1) + step, 0), orders.count - 1)
            return next
        }

        var hasPrevious: Bool { orders.count > 1 && index > 0 }
        var hasNext: Bool { orders.count > 1 && index < orders.count - 1 }

        /// Today's card without one order (Dismiss on a delivered one),
        /// still pointing at the order after it, or the last.
        func removing(_ id: String) -> ContentState {
            guard let i = orders.firstIndex(where: { $0.id == id }) else { return self }
            var next = self
            next.orders.remove(at: i)
            next.index = next.orders.isEmpty ? 0 : min(i, next.orders.count - 1)
            return next
        }

        /// "2 of 3".
        var position: String { orders.count > 1 ? String(localized: "\(min(max(index, 0), orders.count - 1) + 1) of \(orders.count)", comment: "Position among today's deliveries, like 2 of 3") : "" }

        /// Orders still on their way.
        var openCount: Int { orders.filter { $0.status != DeliveryOrder.delivered }.count }
    }
}

/// One package arriving today.
struct DeliveryOrder: Codable, Hashable, Identifiable {
    var id: String
    var brand: String
    var item: String?
    /// arriving, out_for_delivery, nearby, delivered or problem.
    var status: String
    var carrier: String?
    /// A fixed phrase ("By 5 PM", "3 stops away"), never a ticking value.
    var eta: String?
    /// marracat://order?… — opens that order in the app.
    var link: String?

    static let delivered = "delivered"

    /// "Ripl Efek · Laundry Detergent".
    var title: String { item.map { "\(brand) · \($0)" } ?? brand }

    var statusLine: String {
        switch status {
        case "out_for_delivery": String(localized: "Out for delivery", comment: "Delivery status")
        case "nearby": String(localized: "Nearby", comment: "Delivery status")
        case "delivered": String(localized: "Delivered", comment: "Delivery status")
        case "problem": String(localized: "Delivery problem", comment: "Delivery status")
        default: String(localized: "Arriving today", comment: "Delivery status")
        }
    }

    /// The compact island's one word.
    var shortStatus: String {
        switch status {
        case "out_for_delivery": String(localized: "Out", comment: "Delivery status, one short word for the Dynamic Island")
        case "nearby": String(localized: "Nearby", comment: "Delivery status, one short word for the Dynamic Island")
        case "delivered": String(localized: "Done", comment: "Delivery status, one short word for the Dynamic Island")
        case "problem": String(localized: "Issue", comment: "Delivery status, one short word for the Dynamic Island")
        default: String(localized: "Today", comment: "Delivery status, one short word for the Dynamic Island")
        }
    }

    /// How far along the card's arc the order is (0…1).
    var progress: Double {
        switch status {
        case "out_for_delivery": 0.6
        case "nearby": 0.82
        case "delivered": 1
        case "problem": 0.6
        default: 0.3
        }
    }

    var symbol: String {
        switch status {
        case "out_for_delivery": "box.truck.fill"
        case "nearby": "mappin.and.ellipse"
        case "delivered": "checkmark.circle.fill"
        case "problem": "exclamationmark.triangle.fill"
        default: "shippingbox.fill"
        }
    }

    /// "UPS · By 5 PM". OnTrac stays off the card (owner, 2026-10-17);
    /// UPS, FedEx, USPS and the rest still show.
    var detail: String? {
        let shownCarrier = carrier.flatMap { Self.hiddenCarriers.contains($0.lowercased().filter(\.isLetter)) ? nil : $0 }
        let parts = [shownCarrier, eta].compactMap { $0?.isEmpty == false ? $0 : nil }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static let hiddenCarriers: Set<String> = ["ontrac"]

    /// The right-hand side of a list row: the carrier's time ("By 2:30 PM")
    /// when it gave one, else the step in a word or two.
    var when: String {
        if status == "problem" { return String(localized: "Issue", comment: "Delivery status, one short word for the Dynamic Island") }
        if let eta, !eta.isEmpty { return eta }
        switch status {
        case "out_for_delivery": return String(localized: "Out today", comment: "Live Activity row: out for delivery, no time given")
        case "nearby": return String(localized: "Nearby", comment: "Delivery status")
        default: return String(localized: "Today", comment: "Delivery status, one short word for the Dynamic Island")
        }
    }

    var url: URL? { link.flatMap(URL.init(string:)).flatMap { $0.scheme == "marracat" ? $0 : nil } }

    /// What VoiceOver reads for the card.
    var spoken: String { [title, statusLine, detail].compactMap { $0 }.joined(separator: ", ") }
}

/// ‹ and › in the Live Activity. Apple gives Live Activities no swipe
/// gesture of their own: only Button and Toggle with an App Intent are
/// interactive (WidgetKit, "Adding interactivity to widgets and Live
/// Activities"), and a sideways swipe on the island belongs to the system.
/// A LiveActivityIntent runs in the app's process, which updates the
/// activity locally (no push, no budget).
struct FlipDeliveryIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Show another delivery"
    static var isDiscoverable = false

    @Parameter(title: "Activity") var activityID: String
    @Parameter(title: "Step") var step: Int

    init() {}
    init(activityID: String, step: Int) {
        self.activityID = activityID
        self.step = step
    }

    func perform() async throws -> some IntentResult {
        for activity in ActivityKit.Activity<DeliveryActivityAttributes>.activities where activity.id == activityID {
            let next = activity.content.state.flipped(by: step)
            await activity.update(ActivityContent(state: next, staleDate: activity.content.staleDate))
        }
        return .result()
    }
}

/// "Dismiss" on a delivered order in the Live Activity (owner, 2026-10-17:
/// "give users the ability [to dismiss] the dynamic island per delivered
/// item"). Runs in the app's process like ‹ ›: takes the order off the card
/// at once (the last one ends it) and tells the server, which keeps it off
/// for the rest of the day.
struct DismissDeliveryIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Dismiss a delivered order"
    static var isDiscoverable = false

    @Parameter(title: "Activity") var activityID: String
    @Parameter(title: "Order") var orderID: String

    init() {}
    init(activityID: String, orderID: String) {
        self.activityID = activityID
        self.orderID = orderID
    }

    func perform() async throws -> some IntentResult {
        for activity in ActivityKit.Activity<DeliveryActivityAttributes>.activities where activity.id == activityID {
            let next = activity.content.state.removing(orderID)
            if next.orders.isEmpty {
                await activity.end(ActivityContent(state: next, staleDate: nil), dismissalPolicy: .immediate)
            } else {
                await activity.update(ActivityContent(state: next, staleDate: activity.content.staleDate))
            }
        }
        await DeliveryDismissal.report?(orderID)
        return .result()
    }
}

/// Set by the app at launch (it holds the device key the server knows this
/// phone by); nil in the widget extension, where the intent never runs.
enum DeliveryDismissal {
    nonisolated(unsafe) static var report: (@Sendable (String) async -> Void)?
}
