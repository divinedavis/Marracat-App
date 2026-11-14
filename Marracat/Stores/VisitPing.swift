import Foundation

/// One anonymous visit a day for the owner dashboard's actives, returning
/// visitors and retention (server/visits.js; owner, 2026-10-04). It carries the
/// app's random install key (the one restock alerts use), the build in the user
/// agent, and the account when signed in. Never sent by UI tests or previews.
enum VisitPing {
    private static let dayKey = "visit.lastDay"

    @MainActor
    static func send(account: AccountStore) {
        let args = ProcessInfo.processInfo.arguments
        guard !args.contains("-UITEST_RESET"), !args.contains("-OFFLINE_CATALOG") else { return }
        let today = Calendar.current.startOfDay(for: .now).timeIntervalSince1970
        guard UserDefaults.standard.double(forKey: dayKey) != today else { return }
        var request = URLRequest(url: URL(string: "https://marracat.com/api/visit")!)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AppChannel.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(RestockStore.installKey, forHTTPHeaderField: "X-Marracat-Device")
        account.authorize(&request)
        Task {
            let response = try? await URLSession.shared.data(for: request).1 as? HTTPURLResponse
            // Only a counted visit marks the day; a failure tries again next time.
            if response?.statusCode == 204 { UserDefaults.standard.set(today, forKey: dayKey) }
        }
    }
}
