import SwiftUI

extension PurchasedItem {
    /// What was bought, for the Shipped notification: Checkout Kit's own item
    /// titles, else the catalog's for the lines sent to the brand.
    @MainActor static func titles(_ items: [PurchasedItem]?, lines: [CartLine], catalog: CatalogStore) -> [String] {
        if let items, !items.isEmpty { return items.map(\.title) }
        return lines.compactMap { catalog.product($0.productID)?.title }
    }
}

/// The one form: name, contact and shipping address. Opened from You ›
/// Shipping address; checkout no longer asks for it first (owner,
/// 2026-11-02): the first store's checkout collects the address and the
/// app saves it from the order (BrandCheckout).
struct BuyerDetailsForm: View {
    @Environment(BuyerStore.self) private var buyer
    @Environment(AccountStore.self) private var account
    @Environment(\.dismiss) private var dismiss
    @State private var d = BuyerDetails()
    @State private var addresses = AddressCompleter()
    @FocusState private var focus: Field?
    /// A picked suggestion writes the street itself; that edit isn't a search.
    @State private var picking = false
    @State private var pickingContact = false
    var onSaved: (() -> Void)? = nil

    private enum Field { case street, apt }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("First name", text: $d.firstName).textContentType(.givenName).accessibilityIdentifier("buyerFirstName")
                    TextField("Last name", text: $d.lastName).textContentType(.familyName).accessibilityIdentifier("buyerLastName")
                    TextField("Email", text: $d.email).textContentType(.emailAddress).keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never).accessibilityIdentifier("buyerEmail")
                    TextField("Phone", text: $d.phone).textContentType(.telephoneNumber).keyboardType(.phonePad).accessibilityIdentifier("buyerPhone")
                } header: {
                    // One tap fills everything from a contact card, so signed-out
                    // shoppers (no account name or email) needn't type it all;
                    // the keyboard's own AutoFill still works on each field. In
                    // the header, not a row: a row above pushed the street's
                    // Apple Maps suggestions under the keyboard.
                    HStack {
                        Text("Contact").foregroundStyle(Theme.secondary)
                        Spacer()
                        Button { pickingContact = true } label: {
                            Label("Fill from Contacts", systemImage: "person.crop.circle")
                        }
                        .brandFont(.subheadline)
                        .textCase(nil)
                        .accessibilityIdentifier("buyerFillFromContacts")
                    }
                }
                TitledSection("Shipping address") {
                    TextField("Street address", text: $d.street).textContentType(.streetAddressLine1).accessibilityIdentifier("buyerStreet")
                        .focused($focus, equals: .street)
                        // Return closes the suggestions and moves on, as when
                        // the shopper doesn't want any of them.
                        .submitLabel(.next)
                        .onSubmit { addresses.clear(); focus = .apt }
                        .onChange(of: d.street) { _, text in
                            if picking { picking = false } else if focus == .street { addresses.search(text) }
                        }
                    // Apple Maps suggestions while the street is being typed;
                    // picking one fills city, state and ZIP too.
                    if focus == .street {
                        ForEach(addresses.suggestions, id: \.self) { s in
                            Button {
                                Task {
                                    guard let found = await addresses.resolve(s) else { return }
                                    picking = true
                                    d = d.applying(found)
                                    addresses.clear()
                                    focus = .apt
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.title).foregroundStyle(.primary)
                                    if !s.subtitle.isEmpty { Text(s.subtitle).brandFont(.footnote).foregroundStyle(Theme.secondary) }
                                }
                            }
                            .accessibilityIdentifier("addressSuggestion")
                        }
                    }
                    TextField("Apt, suite (optional)", text: $d.extended).textContentType(.streetAddressLine2)
                        .focused($focus, equals: .apt)
                    TextField("City", text: $d.city).textContentType(.addressCity).accessibilityIdentifier("buyerCity")
                    TextField("State", text: $d.region).textContentType(.addressState).accessibilityIdentifier("buyerRegion")
                    TextField("ZIP", text: $d.postalCode).textContentType(.postalCode).keyboardType(.numbersAndPunctuation).accessibilityIdentifier("buyerPostal")
                    Text("United States").foregroundStyle(Theme.secondary)
                }
                Section {
                    Text("Saved on this phone only, from your first order or typed here. Each brand's store receives it when its checkout is built, as it would from its own form.")
                        .brandFont(.footnote).foregroundStyle(Theme.secondary)
                }
                if buyer.details != nil {
                    Section {
                        Button("Forget these details", role: .destructive) { buyer.clear(); dismiss() }
                            .accessibilityIdentifier("buyerForget")
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .background(ContactPicker(isPresented: $pickingContact) { d = d.filling(contact: $0) })
            .barTitle("Your details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { buyer.save(d); dismiss(); onSaved?() }
                        .disabled(!d.isComplete)
                        .accessibilityIdentifier("buyerSave")
                }
            }
            .onAppear { d = (buyer.details ?? d).filling(name: account.user?.name, email: account.user?.email) }
        }
        .accessibilityIdentifier("buyerForm")
    }
}
