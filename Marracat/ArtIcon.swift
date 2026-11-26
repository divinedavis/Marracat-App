import SwiftUI
import UIKit

/// A small 3D picture of a thing: a department on Browse, a tile or a row on
/// Profile (owner, 2026-11-25: "replace with images that are similar to what
/// we use in Crease"). The pictures live in Assets › Art, one per name, cut
/// out so they sit on any surface in either look. They are the only colour
/// on those two screens.
///
/// A name with no picture yet (a department the catalog adds tomorrow) falls
/// back to its SF Symbol, so nothing ever shows an empty square. Pictures are
/// decoration beside a title: hidden from VoiceOver, never the only label.
struct ArtIcon: View {
    let name: String
    let symbol: String
    var size: CGFloat = 36
    /// The symbol's colour when there is no picture.
    var tint: Color = .primary

    static func has(_ name: String) -> Bool { !name.isEmpty && UIImage(named: "Art/\(name)") != nil }

    var body: some View {
        Group {
            if Self.has(name) {
                Image("Art/\(name)").resizable().scaledToFit()
            } else {
                Image(systemName: symbol).foregroundStyle(tint)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
