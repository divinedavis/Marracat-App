import SwiftUI

struct AccountPanel: View {
    @Environment(AccountStore.self) private var account
    @Environment(ShopperStore.self) private var shopper
    @State private var importGuest = false
    @State private var deleteConfirmation = false
    @State private var clearConfirmation = false
    @State private var privacy = false
    /// Mirrors Analytics.shared.isEnabled (stored in UserDefaults, not observed).
    @State private var shareUsage = Analytics.shared.isEnabled
    @AppStorage(HolidayIcon.settingKey) private var holidayIcons = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let user = account.user {
                Label(user.name ?? String(localized: "Your account", comment: "Fallback when the account has no name"), systemImage: "person.crop.circle.fill").font(.title3.bold())
                if let email = user.email { Text(email).font(.caption).foregroundStyle(.secondary) }
                Text("Your saved items, activity and checkout records sync with this account.").font(.subheadline).foregroundStyle(.secondary)
                if account.needsAuthentication {
                    if user.usesApple {
                        AppleAccountButton { Task { await account.signInWithApple(importGuest: false) } }
                            .frame(height: AccountButtonMetrics.height)
                    } else {
                        GoogleAccountButton { Task { await account.signIn(importGuest: false) } }
                    }
                } else {
                    Button { Task { await account.sync() } } label: {
                        Label(account.syncing ? "Syncing…" : "Sync account", systemImage: "arrow.triangle.2.circlepath")
                    }.disabled(account.syncing)
                    if let date = account.lastSynced { Text("Last synced \(date.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                }
                Button("Sign out") { Task { await account.signOut() } }.accessibilityIdentifier("signOut")
            } else {
                Label("Make Marracat yours", systemImage: "person.crop.circle").font(.title3.bold())
                Text("Sign in to keep your likes, searches and checkout history across devices. You can keep shopping as a guest.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Toggle("Bring this device's saved items and history", isOn: $importGuest).font(.subheadline)
                // Same width, height and shape, one above the other (owner, 2026-10-02):
                // Google's own SwiftUI button kept its fixed size beside Apple's.
                VStack(spacing: 12) {
                    AppleAccountButton { Task { await account.signInWithApple(importGuest: importGuest) } }
                        .frame(height: AccountButtonMetrics.height)
                        .accessibilityIdentifier("appleSignIn")
                    GoogleAccountButton { Task { await account.signIn(importGuest: importGuest) } }
                        .accessibilityIdentifier("googleSignIn")
                }
                .padding(.top, 4)
            }
            if account.busy { ProgressView().accessibilityLabel("Updating account") }
            if let message = account.message { Text(message).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("accountMessage") }
            Divider()
            Toggle("Personalized recommendations", isOn: Binding(get: { shopper.personalizationEnabled }, set: { shopper.setPersonalization($0) }))
                .accessibilityIdentifier("personalizationToggle")
            // Owner, 2026-10-10: a settings switch only, on by default, never asked on entry.
            Toggle("Share usage analytics", isOn: Binding(get: { shareUsage }, set: { shareUsage = $0; Analytics.shared.isEnabled = $0 }))
                .accessibilityIdentifier("analyticsToggle")
            // Owner, 2026-10-20: the Home Screen icon in the day's colours on
            // holidays, on by default; turning it off puts the everyday one back.
            Toggle("Holiday app icons", isOn: Binding(get: { holidayIcons }, set: { on in
                holidayIcons = on
                HolidayIcon.apply()
            }))
            .accessibilityIdentifier("holidayIconsToggle")
            Button("Clear search and viewing history") { clearConfirmation = true }.accessibilityIdentifier("clearPersonalHistory")
            if !shopper.hidden.isEmpty { Button("Reset hidden recommendations") { shopper.resetHidden() } }
            Button("Privacy & your data") { privacy = true }.accessibilityIdentifier("privacyPolicy")
            if account.user != nil {
                Button("Delete account", role: .destructive) { deleteConfirmation = true }.accessibilityIdentifier("deleteAccount")
            }
        }
        .font(.subheadline)
        .padding(16)
        .background(Theme.surface)
        .disabled(account.busy)
        .alert("Clear your history?", isPresented: $clearConfirmation) {
            Button("Clear history", role: .destructive) { shopper.clearHistory(); FreshCatalog.shared.forget() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Removes your searches and product-view history. Your saved items and checkout records stay available.") }
        .alert("Delete your Marracat account?", isPresented: $deleteConfirmation) {
            Button("Delete my account", role: .destructive) { Task { await account.deleteAccount() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Sign in to the same \(account.user?.deletionProviderName ?? "sign-in") account to confirm. Your Marracat account, saved items, history and synced checkout records will be deleted. This does not cancel orders or delete information held by brands.") }
        .sheet(isPresented: $privacy) { AccountPrivacyView() }
    }
}

struct AccountPrivacyView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Your data in Marracat").font(.title2.bold())
                    Text("Last updated: October 14, 2026").font(.footnote).foregroundStyle(.secondary)
                    Text("You can browse and shop without a Marracat account. Guest activity, your cart and the checkout details you enter are stored on this device.")
                    Text("When you sign in with Apple or Google, Marracat receives your provider account identifier, name and email when provided. Apple lets you hide your email address. Apple and Google accounts remain separate. We verify your identity on our server and store your session in your device's Keychain. We never receive your password or your mail, contacts or activity from other apps.")
                    Text("While signed in, your saved items and lists, searches, recently viewed products, hidden recommendations, personalization setting and checkout records sync to Marracat's server. List cover photos from your library stay on this device. Recommendations use your activity within Marracat; we do not infer sensitive personal traits or use cross-app advertising tracking. With “Share usage analytics” on, the app also tells Marracat which screens, products, searches and recommendations you use (no names, emails or addresses) so we can improve it; turn it off any time and nothing more is sent. You can turn personalization off, clear history, reset hidden recommendations, sign out or delete your account in the You tab.")
                    Text("Marracat keeps up to 500 saved items, 100 recent product views, 30 recent searches, 500 hidden recommendations and 200 checkout records per profile, until you remove them or delete your account. We do not sell your information or use it for advertising.")
                    Text("Comments, profiles and friends").font(.headline)
                    Text("Your profile is a display name and @handle that anyone can see; your email is never shown. Comments are public on the product page with your name and handle, and you can delete yours at any time. Your friends list and requests are visible only to you. Blocking is private and hides you from each other everywhere. Before you post, you agree to the community guidelines, and we record when.")
                    Text("Products you send to friends are end-to-end encrypted: this device's private key stays in its Keychain, and our server stores only who sent what to whom and when, plus encrypted data it cannot read. Comments and names pass an automatic word filter; no outside service or AI reads them.")
                    Text("You can report a comment, person or share. A reported comment is hidden until the Marracat team reviews it, aiming to act within 24 hours; we may remove content or stop an account from posting. Reporting a share sends us the product and note your device decrypted.")
                    Text("Checkout and logs").font(.headline)
                    Text("Brand checkouts collect payment and shipping details under their own privacy policies; card details never reach Marracat. Checking out several brands at once sends your name, email, phone and address from this phone straight to each brand. When a checkout completes, Marracat stores the brand, products, date, quantities, displayed subtotal and, when Shopify provides them, the order reference, total and currency — never card details or shipping addresses. Where the Marracat order email is on for your account, brands get a private u-…@orders.marracat.com address instead of your email; their emails are forwarded to you, and Marracat keeps the order number and tracking read from them (tracking numbers go to 17TRACK for delivery updates). Deleting your account deletes the address and what it received. Signed out, brands can get a private address tied to a random key for this install (Marracat stores only a one-way hash of it), not an account: there's no inbox to forward to, so Marracat reads the same order details, updates Your Orders, notifies this iPhone and keeps each email at most three days in case you sign in; signing in on this iPhone moves the address and what it received to your account (an account that has an address keeps it, and the other one still receives that order's emails), and one that receives nothing for 180 days is deleted. For checkouts the app builds, Marracat's server also keeps the checkout and order reference (tied to a random key for this install, not your account) and reads the brand's order status page for progress and tracking, until delivery or 30 days. Recommendations, search by meaning, styles, restock reminders and your written interests are worked out on this iPhone; what you browse, search and write for them stays here, and Personalized recommendations turns them off. So you can find them from Spotlight and Siri, your saved items, the brands you follow and, with Personalized recommendations on, products you viewed recently are added to this iPhone's own search index, along with Marracat's featured brands; that index stays on this iPhone, nothing from it is sent to Marracat, and signing out or deleting your account removes your items from it. Home Screen and Lock Screen widgets read a small copy the app keeps on this iPhone, in storage shared only with its own widgets: price drops on your saved items, Marracat's featured brands and your recent orders' delivery status, with small product photos. Nothing in it is sent to Marracat, and signing out or deleting your account erases it. Products added to a cart or bought together are sent with this install's random key so Marracat can show pairs at least three installs have made. Restock alerts are kept with your account: when an item is back Marracat emails your account's address and notifies each iPhone signed in to it, and signing out stops the notifications on that iPhone. Live Activities for today's deliveries send Marracat the tokens Apple issues for them, tied to the same install key, and Marracat sends Apple each order's brand, item, status and carrier to show; turn them off under You › Notifications. Marking an order \"Late shipment\" sends the brand and a one-way hash of that order, tied to the same key, so Marracat can see which brands ship late.")
                    Text("Our server logs each request's IP address, time, path and app version to keep Marracat running and secure and to count visits in total; logs are deleted after about two weeks. Catalog, image and sign-in providers also receive normal network information under their own policies.")
                    Text("Deleting your account removes your account, synced activity, checkout records, profile, friends, blocks, device keys, shares and the reports you made, and erases your comments. It does not cancel orders or delete data held by brands, Apple or Google. To request a copy of your data or ask a question, including under CCPA or GDPR, email privacy@marracat.com.")
                    Link("Apple Privacy Policy", destination: URL(string: "https://www.apple.com/legal/privacy/")!)
                    Link("Google Privacy Policy", destination: URL(string: "https://policies.google.com/privacy")!)
                    Link("Full privacy policy", destination: URL(string: "https://marracat.com/#/privacy")!)
                }.padding(20)
            }
            .navigationTitle("Privacy")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

enum AccountButtonMetrics {
    static let height: CGFloat = 50
}

/// "Sign in with Google", drawn to match Apple's white button: full width,
/// the same height and capsule, Google's "G" and a light outline, as Google's
/// branding guidelines allow for a custom button.
struct GoogleAccountButton: View {
    var action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image("GoogleG").resizable().scaledToFit().frame(width: 18, height: 18)
                Text("Sign in with Google").font(.system(size: 19, weight: .medium))
            }
            .foregroundStyle(Color.black)
            .frame(maxWidth: .infinity)
            .frame(height: AccountButtonMetrics.height)
            .background(Capsule().fill(Color.white))
            .overlay(Capsule().stroke(Color.black.opacity(0.15), lineWidth: 1))
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sign in with Google")
    }
}
