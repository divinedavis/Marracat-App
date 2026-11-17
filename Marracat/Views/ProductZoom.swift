import SwiftUI

/// A product opens by zooming out of the photo that was tapped and closes back
/// into it (owner, 2026-11-15: "can we have this animation when people touch
/// on a product"). Apple's zoom navigation transition (iOS 18): swipe down
/// from the top of the product page, or from the left edge, and it shrinks
/// back into its tile as the finger moves. iOS 17 keeps the usual slide.
///
/// Only a product whose photo is on screen zooms: a product opened from a
/// link, a search suggestion or a notification has no tile to grow out of,
/// so it slides in as before (ProductZoom.sources is what's on screen).
extension EnvironmentValues {
    /// The tab's NavigationStack namespace for zooms (TabRoot).
    @Entry var productZoom: Namespace.ID? = nil
}

@MainActor
enum ProductZoom {
    /// Product ids whose zoom source is on screen now, with how many copies.
    static var sources: [String: Int] = [:]
}

/// Marks a product photo as the place its page zooms out of.
struct ProductZoomSource: ViewModifier {
    let id: String
    var cornerRadius: CGFloat = 16
    @Environment(\.productZoom) private var namespace

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), let namespace {
            content
                .matchedTransitionSource(id: id, in: namespace) { $0.clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)) }
                .onAppear { ProductZoom.sources[id, default: 0] += 1 }
                .onDisappear {
                    let n = (ProductZoom.sources[id] ?? 1) - 1
                    ProductZoom.sources[id] = n > 0 ? n : nil
                }
        } else {
            content
        }
    }
}

/// On a product page: zoom from its tile when one is on screen.
struct ProductZoomDestination: ViewModifier {
    let id: String?
    @Environment(\.productZoom) private var namespace
    /// Decided once, as the page is pushed: the tile is still on screen then.
    @State private var zooms: Bool?

    func body(content: Content) -> some View {
        // The UI tests' no-animation mode (MARRACAT_NO_ANIMATIONS) turns UIKit
        // animations off, and the zoom's interactive swipe back can't finish
        // without them (testHomeKeepsItsPlaceAfterViewingAProduct, 2026-11-16).
        // Those runs slide in as before; MasonryGridUITests drives the zoom
        // with animations on. A shipped launch never sets it.
        if #available(iOS 18.0, *), !MarracatApp.noAnimations, let id, let namespace, zooms ?? (ProductZoom.sources[id] != nil) {
            content
                .navigationTransition(.zoom(sourceID: id, in: namespace))
                .onAppear { if zooms == nil { zooms = true } }
        } else {
            content.onAppear { if zooms == nil { zooms = false } }
        }
    }
}

extension Route {
    var productID: String? { if case .product(let id) = self { return id } else { return nil } }
}
