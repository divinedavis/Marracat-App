import SwiftUI
import UserNotifications
import UserNotificationsUI

/// Press and hold a shopping alert: the full card from the mockups the owner
/// picked (AlertCardView), instead of Apple's text. iOS draws the action
/// buttons (Add to bag, Follow…) under it, from the category the app
/// registers (AlertCategories), so the card itself shows none.
final class NotificationViewController: UIViewController, UNNotificationContentExtension {
    private var host: UIHostingController<AnyView>?

    func didReceive(_ notification: UNNotification) {
        let info = notification.request.content.userInfo
        guard let card = AlertCard(userInfo: info) else { return }
        let content = AnyView(AlertCardView(card: card, buttons: false).padding(.horizontal, 2).padding(.vertical, 2))
        if let host {
            host.rootView = content
        } else {
            let host = UIHostingController(rootView: content)
            host.sizingOptions = .preferredContentSize
            host.view.backgroundColor = .clear
            addChild(host)
            host.view.translatesAutoresizingMaskIntoConstraints = false
            self.view.addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
                host.view.topAnchor.constraint(equalTo: self.view.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
            ])
            host.didMove(toParent: self)
            self.host = host
        }
        let width = self.view.bounds.width > 0 ? self.view.bounds.width : UIScreen.main.bounds.width - 16
        let size = host!.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        preferredContentSize = CGSize(width: width, height: size.height)
    }
}
