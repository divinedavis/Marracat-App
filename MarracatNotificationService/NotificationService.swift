import UserNotifications

/// Puts the product photo on a shopping alert's Lock Screen banner (owner,
/// 2026-11-15: "with apples limitations"). The server marks those pushes
/// mutable-content and names the photo in `card.img` (web/server/alert-cards.js);
/// this downloads it and attaches it. Anything else, or a slow or failed
/// download, goes out exactly as it came.
final class NotificationService: UNNotificationServiceExtension {
    private var handler: ((UNNotificationContent) -> Void)?
    private var best: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        handler = contentHandler
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else { return contentHandler(request.content) }
        best = content
        let card = content.userInfo["card"] as? [String: Any]
        // One brand's alerts group together in Notification Center.
        if content.threadIdentifier.isEmpty, let brand = card?["bid"] as? String { content.threadIdentifier = "brand-" + brand }
        guard let url = Self.photoURL(card) else { return contentHandler(content) }
        Task {
            if let attachment = await Self.attachment(from: url) { content.attachments = [attachment] }
            self.finish()
        }
    }

    override func serviceExtensionTimeWillExpire() { finish() }

    private func finish() {
        guard let handler, let best else { return }
        self.handler = nil
        handler(best)
    }

    /// The card's photo: only https, and only from the stores' image hosts'
    /// kind of address (no file:, no plain http).
    static func photoURL(_ card: [String: Any]?) -> URL? {
        let raw = (card?["img"] as? String) ?? ((card?["items"] as? [[String: Any]])?.first?["img"] as? String)
        guard let raw, let url = URL(string: raw), url.scheme == "https", url.host != nil else { return nil }
        return url
    }

    static func attachment(from url: URL) async -> UNNotificationAttachment? {
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("Marracat/1.0 (iOS notification)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              data.count > 0, data.count < 10_000_000 else { return nil }
        let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let ext = type.contains("png") ? "png" : type.contains("webp") ? "webp" : type.contains("gif") ? "gif" : "jpg"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
        guard (try? data.write(to: file)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: "photo", url: file, options: nil)
    }
}
