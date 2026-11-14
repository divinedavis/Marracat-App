import Contacts
import ContactsUI
import SwiftUI

extension BuyerDetails {
    /// Everything a picked contact card has: name, email, phone and its US
    /// address (home first). What the card leaves blank stays as typed; a
    /// card whose only address is outside the US fills no address, since
    /// checkouts ship to the 50 states (owner, 2026-10-19: autofill the
    /// details form when buying signed out).
    func filling(contact c: CNContact) -> BuyerDetails {
        var d = self
        func set(_ value: String, _ key: WritableKeyPath<BuyerDetails, String>) {
            let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty { d[keyPath: key] = v }
        }
        set(c.givenName, \.firstName)
        set(c.familyName, \.lastName)
        if let email = c.emailAddresses.map({ $0.value as String }).first(where: { $0.contains("@") && $0.contains(".") }) {
            set(email, \.email)
        }
        if let phone = c.phoneNumbers.first?.value.stringValue { set(phone, \.phone) }
        let us = c.postalAddresses.filter { a in
            let code = a.value.isoCountryCode.lowercased(), country = a.value.country.lowercased()
            return code == "us" || (code.isEmpty && (country.isEmpty || ["us", "usa", "united states"].contains(country)))
        }
        if let a = (us.first { $0.label == CNLabelHome } ?? us.first)?.value {
            let lines = a.street.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            d = d.applying(FoundAddress(street: lines.first ?? "", city: a.city, region: a.state, postalCode: a.postalCode, country: "US"))
            if lines.count > 1 { set(lines.dropFirst().joined(separator: ", "), \.extended) }
        }
        return d
    }
}

/// Apple's contact picker. It runs outside the app: the shopper sees every
/// card, Marracat gets only the one picked, and no Contacts permission is
/// asked. Presented from a host view because the picker can't be the root of
/// a SwiftUI sheet (it dismisses itself as soon as it appears).
struct ContactPicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onPick: (CNContact) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }

    func updateUIViewController(_ host: UIViewController, context: Context) {
        context.coordinator.parent = self
        guard isPresented, host.presentedViewController == nil else { return }
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        DispatchQueue.main.async { host.present(picker, animated: true) }
    }

    final class Coordinator: NSObject, CNContactPickerDelegate {
        var parent: ContactPicker
        init(_ parent: ContactPicker) { self.parent = parent }
        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            parent.onPick(contact)
            parent.isPresented = false
        }
        func contactPickerDidCancel(_ picker: CNContactPickerViewController) { parent.isPresented = false }
    }
}
