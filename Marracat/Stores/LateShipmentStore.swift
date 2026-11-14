import Foundation
import Observation
import os

/// "Late shipment" on an order (owner, 2026-10-01). Each tap reports the brand
/// to web/server/late-shipments.js so the owner dashboard can show which brands
/// ship late often; tapping again takes it back. Keyed by the per-install key
/// like restock alerts and order tracking, so it works signed out. The server
/// keeps the order only as a hash.
@MainActor
@Observable
final class LateShipmentStore {
    static let shared = LateShipmentStore()

    /// Your Orders records (CheckoutRecord ids) reported late on this phone.
    private(set) var reported: Set<String> = []

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let stubbed = ProcessInfo.processInfo.arguments.contains("-CHECKOUT_STUB")
    @ObservationIgnored private let log = Logger(subsystem: "com.divinedavis.marracat", category: "late")
    private static let defaultsName = "lateShipments.v1"

    init(defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.defaults = defaults
        self.session = session
        reported = Set(defaults.stringArray(forKey: Self.defaultsName) ?? [])
    }

    func isReported(_ record: CheckoutRecord) -> Bool { reported.contains(record.id.uuidString) }

    /// Reports the order late, or takes the report back. The tap shows at once;
    /// a failed call puts it back the way it was.
    func toggle(_ record: CheckoutRecord, account: AccountStore?) async {
        let id = record.id.uuidString
        let report = !reported.contains(id)
        if report { reported.insert(id) } else { reported.remove(id) }
        save()
        guard !stubbed else { return }
        var body: [String: String] = ["order": id]
        if report { body["brandID"] = record.brandID }
        let ok: Bool
        if let data = try? JSONSerialization.data(withJSONObject: body),
           let status = try? await call(method: report ? "POST" : "DELETE", body: data, account: account) {
            ok = status == 201 || status == 200
            log.info("late: \(report ? "reported" : "withdrew", privacy: .public) \(record.brandID, privacy: .public), HTTP \(status)")
        } else {
            ok = false
            log.error("late: couldn't reach the server for \(record.brandID, privacy: .public)")
        }
        if !ok {
            if report { reported.remove(id) } else { reported.insert(id) }
            save()
        }
    }

    /// Deleting the account forgets this phone's reports, here and on the server.
    func clear() {
        reported = []
        defaults.removeObject(forKey: Self.defaultsName)
        guard !stubbed, let data = try? JSONSerialization.data(withJSONObject: ["all": true]) else { return }
        Task { _ = try? await call(method: "DELETE", body: data, account: nil) }
    }

    private func save() { defaults.set(Array(reported), forKey: Self.defaultsName) }

    private func call(method: String, body: Data, account: AccountStore?) async throws -> Int {
        guard AppChannel.reachesOrderServer else { throw URLError(.cancelled) }
        var request = URLRequest(url: URL(string: "https://marracat.com/api/orders/late")!)
        request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AppChannel.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(RestockStore.installKey, forHTTPHeaderField: "X-Marracat-Device")
        account?.authorize(&request)
        let (_, response) = try await session.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }
}
