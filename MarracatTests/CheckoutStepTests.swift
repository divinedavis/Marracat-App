import Testing
@testable import Marracat

/// Which step a brand's checkout reached, from Checkout Kit's standard pixel
/// events (owner, 2026-11-08: "lets find which step"). BrandCheckout.
struct CheckoutStepTests {
    typealias Step = BrandCheckout.CheckoutStep

    @Test func readsCheckoutKitsStandardEvents() {
        #expect(Step(pixel: "checkout_started") == .started)
        #expect(Step(pixel: "checkout_contact_info_submitted") == .contact)
        #expect(Step(pixel: "checkout_address_info_submitted") == .address)
        #expect(Step(pixel: "checkout_shipping_info_submitted") == .shipping)
        #expect(Step(pixel: "payment_info_submitted") == .payment)
        #expect(Step(pixel: "page_viewed") == nil)
        #expect(Step(pixel: "checkout_completed") == nil, "completion is checkout_complete, not a step")
    }

    @Test func stepsOnlyMoveForwardAndMatchTheServersNames() {
        #expect(Step.opened < .started && .started < .contact && .contact < .address && .address < .shipping && .shipping < .payment)
        // web/server/events.js CHECKOUT_STEPS
        #expect([Step.opened, .started, .contact, .address, .shipping, .payment].map(\.id)
                == ["opened", "started", "contact", "address", "shipping", "payment"])
    }
}
