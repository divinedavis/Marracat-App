import SwiftUI

/// What the card after a paid brand says: who took the order, its number,
/// and the next brand still waiting in the cart (owner, 2026-10-13).
struct PlacedOrder: Equatable {
    let brandName: String
    /// The number at the end of Checkout Kit's `orderDetails.id`
    /// (gid://shopify/OrderIdentity/…); nil when the event didn't carry one.
    let orderNumber: String?
    /// The next brand to pay, "2 of 3"; nil when nothing is left.
    let next: Next?

    struct Next: Equatable {
        let brandID: String
        let brandName: String
        let position: Int
        let total: Int
    }

    var title: String {
        String(localized: "Order placed with \(brandName)", comment: "Card shown after an order; the argument is a brand name") + (orderNumber.map { " · #\($0)" } ?? "")
    }
}

/// Counts the brands paid one after another in one sitting, for "2 of 3".
/// The run starts at the first order with brands left behind it and ends
/// when the cart has none left or the shopper chooses Later.
struct CheckoutRun: Equatable {
    private(set) var paid = 0
    private(set) var total = 0

    /// Records one paid brand with `remaining` brands still in the cart and
    /// returns where the next one stands, or nil when that was the last.
    mutating func paid(remaining: Int) -> (position: Int, total: Int)? {
        paid += 1
        total = max(total, paid + remaining)
        guard remaining > 0 else { self = CheckoutRun(); return nil }
        return (paid + 1, total)
    }

    mutating func reset() { self = CheckoutRun() }

    /// The card for an order just placed, given the brands left in the cart.
    mutating func placed(brand: String, orderID: String?, remaining: [Brand]) -> PlacedOrder {
        let number = ShopifyIDs.number(orderID)
        guard let next = remaining.first, let spot = paid(remaining: remaining.count) else {
            reset()
            return PlacedOrder(brandName: brand, orderNumber: number, next: nil)
        }
        return PlacedOrder(brandName: brand, orderNumber: number,
                           next: .init(brandID: next.id, brandName: next.name, position: spot.position, total: spot.total))
    }
}

/// "✓ Order placed with <Brand> · #<order>" with Continue to the next brand
/// and Later, which leaves the rest in the cart. It sits over the bottom of
/// the screen the checkout sheet closes onto, so it appears as that sheet
/// goes; a sheet of its own would race the closing one.
struct ContinueCard: View {
    let order: PlacedOrder
    var busy = false
    let onContinue: () -> Void
    let onLater: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // The mark is decoration; VoiceOver reads the words alone.
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.stock).accessibilityHidden(true)
                Text(order.title).accessibilityIdentifier("continueTitle")
            }
            .font(.subheadline.bold())
            if let next = order.next {
                Button(action: onContinue) {
                    HStack(spacing: 8) {
                        if busy { ProgressView() }
                        Text("Continue to \(next.brandName) (\(next.position) of \(next.total))")
                            .font(.subheadline).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle(color: Theme.gold))
                .disabled(busy)
                .accessibilityIdentifier("continueNext")
                Button(action: onLater) {
                    Text("Later").font(.subheadline).frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                }
                .accessibilityHint("Keeps the other brands in your cart")
                .accessibilityIdentifier("continueLater")
            }
        }
        .padding(16)
        // The shadow is the card's, not its text's: a shadow on the whole
        // view blurred every glyph and failed the contrast audit.
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.surface).shadow(color: .black.opacity(0.35), radius: 12, y: 4))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.hairline))
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("continueCard")
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
