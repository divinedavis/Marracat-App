import Foundation
import MetricKit
import os

/// Real-device performance (owner, 2026-10-02): iOS hands the app a daily
/// MetricKit report of its own launches, hangs, memory and CPU on this
/// iPhone, and diagnostics when it hangs or crashes. Each report goes to
/// marracat.com as Apple writes it (counts and timings, no personal data),
/// under the same per-install key restock alerts use; the owner dashboard
/// summarises them by build. Simulator numbers were all we had before.
final class MetricsReporter: NSObject, MXMetricManagerSubscriber {
    static let shared = MetricsReporter()
    private let log = Logger(subsystem: "com.divinedavis.marracat", category: "metrics")

    /// Read on the main actor at start; reports arrive on a background queue.
    private var deviceKey = ""

    @MainActor
    func start() {
        guard !ProcessInfo.processInfo.arguments.contains("-UITEST_RESET") else { return }
        deviceKey = RestockStore.installKey
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads { send(kind: "metric", payload.jsonRepresentation()) }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads { send(kind: "diagnostic", payload.jsonRepresentation()) }
    }

    private func send(kind: String, _ json: Data) {
        // The server caps a report at 512 KB; a larger diagnostic is skipped.
        guard json.count <= 512 * 1024,
              let body = try? JSONSerialization.data(withJSONObject: [
                  "kind": kind,
                  "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
                  "report": String(decoding: json, as: UTF8.self),
              ]) else { return }
        var request = URLRequest(url: URL(string: "https://marracat.com/api/app-metrics")!)
        request.httpMethod = "POST"; request.httpBody = body; request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AppChannel.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(deviceKey, forHTTPHeaderField: "X-Marracat-Device")
        Task.detached(priority: .background) { [log] in
            let status = (try? await URLSession.shared.data(for: request)).flatMap { ($0.1 as? HTTPURLResponse)?.statusCode } ?? 0
            log.info("metrics: sent \(kind, privacy: .public) report, HTTP \(status)")
        }
    }
}
