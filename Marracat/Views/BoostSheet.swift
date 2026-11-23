import SwiftUI

/// Boost, in the app (owner, 2026-10-04: "it should take me to a screen that
/// shows the payment options and what those payment options will give").
/// The four tiers and what each buys are chosen here; the card is then taken
/// on Stripe's own checkout page in an in-app browser sheet. (Paying inside
/// the app's own screens would have to be Apple's in-app purchase, which
/// Apple's guideline 3.1.3(g) names for boosts; a US app may hand off to its
/// website's checkout instead.)
struct BoostSheet: View {
    enum Target { case product(Product), brand(Brand) }
    let target: Target

    @Environment(AccountStore.self) private var account
    @Environment(\.dismiss) private var dismiss
    @State private var tier = 20
    @State private var busy = false
    @State private var error: String?
    @State private var checkout: IdentifiedURL?

    struct Tier: Identifiable {
        let dollars: Int, name: String, length: String, gives: [String]
        var id: Int { dollars }
    }
    static let tiers: [Tier] = [
        Tier(dollars: 100, name: String(localized: "Spotlight", comment: "Boost plan: name, length or what it gives"), length: String(localized: "7 days", comment: "Boost plan: name, length or what it gives"),
             gives: [String(localized: "A premier spot in the Home carousel", comment: "Boost plan: name, length or what it gives"), String(localized: "Boosted picks on Home", comment: "Boost plan: name, length or what it gives"), String(localized: "A lift in its aisle and in search", comment: "Boost plan: name, length or what it gives")]),
        Tier(dollars: 50, name: String(localized: "Big boost", comment: "Boost plan: name, length or what it gives"), length: String(localized: "7 days", comment: "Boost plan: name, length or what it gives"),
             gives: [String(localized: "Boosted picks on Home", comment: "Boost plan: name, length or what it gives"), String(localized: "A lift in its aisle and in search", comment: "Boost plan: name, length or what it gives")]),
        Tier(dollars: 20, name: String(localized: "Boost", comment: "Boost plan: name, length or what it gives"), length: String(localized: "3 days", comment: "Boost plan: name, length or what it gives"), gives: [String(localized: "Boosted picks on Home", comment: "Boost plan: name, length or what it gives")]),
        Tier(dollars: 5, name: String(localized: "Spark", comment: "Boost plan: name, length or what it gives"), length: String(localized: "24 hours", comment: "Boost plan: name, length or what it gives"), gives: [String(localized: "A lift in its aisle and in search", comment: "Boost plan: name, length or what it gives"), String(localized: "A Boosted badge", comment: "Boost plan: name, length or what it gives")]),
    ]

    private var name: String {
        switch target { case .product(let p): p.title; case .brand(let b): b.name }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Put \(name) in front of more shoppers.")
                        .brandFont(.title3.bold())
                    ForEach(Self.tiers) { t in tierCard(t) }
                    Text("Boosted spots are labeled “Sponsored”. Boosts for the same \(caseName) add up while they run, so friends can boost it together.")
                        .brandFont(.footnote).foregroundStyle(Theme.secondary)
                    if let error { Text(error).brandFont(.footnote).foregroundStyle(.red).accessibilityIdentifier("boostError") }
                }
                .padding(16)
            }
            .safeAreaInset(edge: .bottom) {
                Button { Task { await pay() } } label: {
                    Text(busy ? "Opening payment…" : "Continue to payment · $\(tier)")
                        .brandFont(.headline).frame(maxWidth: .infinity).padding(.vertical, 14)
                }
                .buttonStyle(PillButtonStyle(color: Theme.gold))
                .disabled(busy)
                .padding(.horizontal, 16).padding(.bottom, 8)
                .background(Theme.canvas)
                .accessibilityIdentifier("boostContinue")
            }
            .barTitle("Boost")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .background(Theme.canvas)
            // Stripe's checkout, in the app; its success page says it worked.
            .sheet(item: $checkout, onDismiss: { Task { await BoostStore.shared.refresh(account: account, force: true) } }) {
                SafariView(url: $0.url).ignoresSafeArea()
            }
        }
        .accessibilityIdentifier("boostSheet")
    }

    private var caseName: String { if case .product = target { "product" } else { "brand" } }

    private func tierCard(_ t: Tier) -> some View {
        let on = tier == t.dollars
        return Button { tier = t.dollars } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: on ? "largecircle.fill.circle" : "circle")
                    .brandFont(.title3).foregroundStyle(on ? Theme.gold : Theme.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("$\(t.dollars)").brandFont(.title2.bold())
                        Text("\(t.name) · \(t.length)").brandFont(.subheadline).foregroundStyle(Theme.secondary)
                    }
                    ForEach(t.gives, id: \.self) { g in
                        Label(g, systemImage: "checkmark").brandFont(.subheadline).labelStyle(.titleAndIcon)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(on ? Theme.gold : Theme.hairline, lineWidth: on ? 2 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("boostTier\(t.dollars)")
    }

    /// Asks the server for a Stripe Checkout page for this tier and opens it.
    private func pay() async {
        busy = true
        error = nil
        defer { busy = false }
        let (type, id): (String, String) = switch target {
        case .product(let p): ("product", p.id)
        case .brand(let b): ("brand", b.id)
        }
        if let url = await BoostStore.shared.checkoutURL(type: type, id: id, tier: tier, account: account) {
            checkout = IdentifiedURL(url: url)
        } else {
            error = String(localized: "Payment couldn't start. Try again in a moment.", comment: "Payment error")
        }
    }
}
