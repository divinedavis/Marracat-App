import SwiftUI

/// A member card across the top of Home for a shopper with no account
/// (owner, 2026-11-22, with a recording of a retailer's welcome strip: "if
/// someone isn't signed up put a sign up banner at the top of the app"; from
/// five looks drawn on Home he picked "#5 member card"): what an account
/// gives, a Sign up button and a close.
///
/// A card to tap, never a prompt: nothing opens by itself. The card opens
/// the sign-in buttons in Account settings; the close puts it away for a
/// week (`snooze`), and it is gone for good once they have an account.
struct SignUpBanner: View {
    @Environment(AccountStore.self) private var account
    @AppStorage(SignUpBanner.closedKey) private var closedAt = 0.0

    /// When the card was last closed, seconds since 1970.
    static let closedKey = "signUpBanner.closedAt"
    /// How long a close keeps it away.
    static let snooze: TimeInterval = 7 * 24 * 3600
    /// The card's height at the default text size, for the launch outline.
    static let outlineHeight: CGFloat = 123

    static func isSnoozed(closedAt: Double, now: Date = .now) -> Bool {
        closedAt > 0 && now.timeIntervalSince1970 - closedAt < snooze
    }

    /// Whether the launch outline should leave the card's room: the last
    /// launch ended as a guest and the card isn't put away (LaunchSkeleton,
    /// which draws before the session is read).
    static func expected(_ defaults: UserDefaults = .standard, now: Date = .now) -> Bool {
        defaults.bool(forKey: AccountStore.guestKey) && !isSnoozed(closedAt: defaults.double(forKey: closedKey), now: now)
    }

    var body: some View {
        if account.isGuest, !Self.isSnoozed(closedAt: closedAt) {
            NavigationLink(value: Route.accountSettings) { card }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded { Analytics.shared.track("sign_up_banner_tap") })
                .accessibilityIdentifier("signUpBanner")
                .overlay(alignment: .topTrailing) { close }
                .padding(.horizontal, 12).padding(.top, 8)
                .frame(maxWidth: .infinity)
                .background(Theme.header)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Make Marracat yours", comment: "Home sign-up card title").brandFont(.title3.weight(.medium))
                Text("Free with Apple or Google", comment: "Home sign-up card subtitle").brandFont(.subheadline).opacity(0.75)
            }
            // Room for the close, which sits over the corner.
            .padding(.trailing, 36)
            // Side by side where they fit; at large text the button drops
            // under what an account gives.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { perks; Spacer(minLength: 0); button }
                VStack(alignment: .leading, spacing: 12) { perks; button }
                VStack(alignment: .leading, spacing: 12) { VStack(alignment: .leading, spacing: 6) { perkList }; button }
            }
        }
        .foregroundStyle(Theme.onGold)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.gold))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var perks: some View { HStack(spacing: 12) { perkList } }

    @ViewBuilder private var perkList: some View {
        perk("heart", Text("Likes", comment: "Home sign-up card: saved items are kept with an account"))
        perk("shippingbox", Text("Orders", comment: "Home sign-up card: orders are kept with an account"))
        perk("tag", Text("Price drops", comment: "Home sign-up card: price-drop alerts come with an account"))
    }

    private func perk(_ symbol: String, _ name: Text) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).accessibilityHidden(true)
            name
        }
        .brandFont(.footnote)
        .fixedSize()
    }

    /// Drawn as a button; the whole card is the link.
    private var button: some View {
        Text("Sign up", comment: "Home sign-up card button").brandFont(.subheadline.weight(.medium)).foregroundStyle(Theme.gold)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 18).padding(.vertical, 9)
            .background(Capsule().fill(Theme.onGold))
    }

    private var close: some View {
        Button {
            Analytics.shared.track("sign_up_banner_close")
            closedAt = Date.now.timeIntervalSince1970
        } label: {
            Image(systemName: "xmark").brandFont(.footnote.weight(.medium)).foregroundStyle(Theme.onGold).opacity(0.75)
                .frame(width: 44, height: 44)   // Apple's 44 pt hit target
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Close", comment: "Closes the Home sign-up card"))
        .accessibilityIdentifier("signUpBannerClose")
    }
}
