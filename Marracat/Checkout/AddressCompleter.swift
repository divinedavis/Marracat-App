import Foundation
import MapKit

/// The parts of a looked-up address the details form needs.
struct FoundAddress: Equatable {
    var street = ""
    var city = ""
    var region = ""
    var postalCode = ""
    var country = ""
}

extension BuyerDetails {
    /// Fills the address from a suggestion the shopper picked; the apartment
    /// line is left as typed, since Apple's suggestions don't carry one.
    func applying(_ a: FoundAddress) -> BuyerDetails {
        var d = self
        if !a.street.isEmpty { d.street = a.street }
        if !a.city.isEmpty { d.city = a.city }
        if !a.region.isEmpty { d.region = a.region }
        if !a.postalCode.isEmpty { d.postalCode = a.postalCode }
        return d
    }
}

/// Address suggestions as the shopper types the street, from Apple Maps on the
/// phone (MKLocalSearchCompleter: no key, no Marracat server), and the full
/// address once one is picked (owner, 2026-10-04: "as users type, they should
/// get autofill and autofill should fill in the remaining address details").
@MainActor
@Observable
final class AddressCompleter: NSObject, MKLocalSearchCompleterDelegate {
    private(set) var suggestions: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = .address
        // Checkouts ship to the US: bias suggestions to the 50 states.
        completer.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 39.5, longitude: -98.35),
            span: MKCoordinateSpan(latitudeDelta: 50, longitudeDelta: 120))
    }

    func search(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard q.count >= 3 else {
            completer.cancel()
            suggestions = []
            return
        }
        completer.queryFragment = q
    }

    func clear() {
        completer.cancel()
        suggestions = []
    }

    /// The full address behind a suggestion, or nil when Apple has none or it
    /// isn't in the US.
    func resolve(_ suggestion: MKLocalSearchCompletion) async -> FoundAddress? {
        let response = try? await MKLocalSearch(request: MKLocalSearch.Request(completion: suggestion)).start()
        guard let p = response?.mapItems.first?.placemark else { return nil }
        let found = FoundAddress(
            street: [p.subThoroughfare, p.thoroughfare].compactMap { $0 }.joined(separator: " "),
            city: p.locality ?? "",
            region: p.administrativeArea ?? "",
            postalCode: p.postalCode ?? "",
            country: p.isoCountryCode ?? "")
        return found.country.isEmpty || found.country == "US" ? found : nil
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = Array(completer.results.prefix(5))
        MainActor.assumeIsolated { suggestions = results }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        MainActor.assumeIsolated { suggestions = [] }
    }
}
