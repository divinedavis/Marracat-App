import SwiftUI
import UserNotifications

/// What a tapped shopping alert (or one of its buttons) asked for.
/// MarracatApp carries it out once the launch splash is out of the way.
struct AlertRequest: Equatable {
    let card: AlertCard
    let action: AlertCard.Action
    let id = UUID()
}

/// The shopping alerts' own banner while the app is open (owner, 2026-11-15,
/// "Marracat Alert Videos" step 3). The system banner is held back for these
/// (AppDelegate.willPresent); deliveries keep Apple's.
@MainActor
@Observable
final class InAppAlerts {
    static let shared = InAppAlerts()

    private(set) var current: AlertCard?
    var request: AlertRequest?
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    static let onScreen: Duration = .seconds(6)

    func show(_ card: AlertCard) {
        withAnimation(.spring(duration: 0.45, bounce: 0.18)) { current = card }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.onScreen)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
        Analytics.shared.track("alert_banner", ["kind": .string(card.k.rawValue)])
    }

    func dismiss() {
        hideTask?.cancel()
        withAnimation(.easeIn(duration: 0.25)) { current = nil }
    }

    /// UI tests (-UITEST_ALERT): a back-in-stock card for a Telfar bag, once
    /// the catalog is in, as if its push came while the app was open.
    func uiTestDemo(catalog: CatalogStore) {
        guard ProcessInfo.processInfo.arguments.contains("-UITEST_ALERT"),
              let p = catalog.products(for: "telfar").first(where: { $0.available }) else { return }
        var card = AlertCard(k: .restock, t: "Back in stock")
        card.s = "Telfar · your restock alert"
        card.items = [AlertCard.Item(id: p.id, t: p.title, p: Money.string(p.price, currency: p.currencyCode), img: p.images.first)]
        card.pid = p.id
        card.bid = p.brand
        card.open = AppDestination.product(p.id).url.absoluteString
        show(card)
        // Long enough for the test to read it.
        hideTask?.cancel()
    }

    func perform(_ action: AlertCard.Action, card: AlertCard) {
        dismiss()
        request = AlertRequest(card: card, action: action)
        Analytics.shared.track("alert_action", ["kind": .string(card.k.rawValue), "action": .string(action.rawValue)])
    }
}

/// The notification categories behind the press-and-hold card
/// (MarracatNotificationContent lists the same ids) and their buttons, which
/// iOS draws under the card.
enum AlertCategories {
    static let openID = "MC_OPEN", addID = "MC_ADD", followID = "MC_FOLLOW"

    static func register() {
        UNUserNotificationCenter.current().setNotificationCategories(Set(AlertCard.Kind.allCases.map(category)))
    }

    static func category(_ kind: AlertCard.Kind) -> UNNotificationCategory {
        let buttons = AlertCard(k: kind, t: "").buttons
        let actions = buttons.map { b -> UNNotificationAction in
            let title = kind == .picks ? String(localized: "See all", comment: "Alert button") : b.title
            return UNNotificationAction(identifier: identifier(b.action), title: title, options: [.foreground],
                                        icon: UNNotificationActionIcon(systemImageName: symbol(b.action)))
        }
        return UNNotificationCategory(identifier: AlertCard.category(kind), actions: actions, intentIdentifiers: [],
                                      options: [.hiddenPreviewsShowTitle])
    }

    static func identifier(_ action: AlertCard.Action) -> String {
        switch action { case .open: openID; case .add: addID; case .follow: followID }
    }

    static func symbol(_ action: AlertCard.Action) -> String {
        switch action { case .open: "arrow.up.forward.app"; case .add: "bag.badge.plus"; case .follow: "bell" }
    }

    /// A notification response's action; a plain tap opens.
    static func action(for identifier: String) -> AlertCard.Action {
        switch identifier { case addID: .add; case followID: .follow; default: .open }
    }
}

/// Local alerts with a card: the photo goes on as an attachment (the service
/// extension only sees pushes), downloaded first.
enum LocalAlert {
    static func schedule(id: String, title: String, body: String, card: AlertCard,
                         trigger: UNNotificationTrigger? = nil) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = card.category
        content.userInfo = ["card": card.userInfoValue]
        if let bid = card.bid { content.threadIdentifier = "brand-" + bid }
        if let raw = card.thumbnail, let url = URL(string: raw), url.scheme == "https",
           let attachment = await photo(url) { content.attachments = [attachment] }
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    private static func photo(_ url: URL) async -> UNNotificationAttachment? {
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("Marracat/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count > 0, data.count < 10_000_000 else { return nil }
        let type = ((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + (type.contains("png") ? ".png" : ".jpg"))
        guard (try? data.write(to: file)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: "photo", url: file, options: nil)
    }
}

/// Shopify image links at a notification's size.
enum AlertImage {
    static func small(_ url: String?, width: Int = 400) -> String? {
        guard let url, var c = URLComponents(string: url), c.scheme == "https" else { return nil }
        guard c.host?.contains("shopify") == true || c.path.contains("/cdn/shop/") else { return url }
        var items = (c.queryItems ?? []).filter { $0.name != "width" }
        items.append(URLQueryItem(name: "width", value: String(width)))
        c.queryItems = items
        return c.string ?? url
    }
}
