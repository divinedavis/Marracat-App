import SwiftUI

/// The Marracat M — same centreline as `loopM` in brand/make_logo.swift,
/// mapped from its 1000-unit box into `rect`. Stroke it; don't fill it.
/// Shared so the tab bar and the delivery Live Activity draw the same M.
struct MarracatMark: Shape {
    func path(in rect: CGRect) -> Path {
        // Centreline bounds in the logo box: x 215…785, y ≈247…770.
        let s = min(rect.width / 570, rect.height / 523)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.midX + (x - 500) * s, y: rect.midY + (y - 508) * s)
        }
        var path = Path()
        path.move(to: p(215, 770))
        path.addLine(to: p(240, 420))
        path.addCurve(to: p(430, 420), control1: p(256, 190), control2: p(430, 190))
        path.addCurve(to: p(500, 520), control1: p(430, 460), control2: p(471, 479))
        path.addCurve(to: p(500, 760), control1: p(597, 659), control2: p(690, 760))
        path.addCurve(to: p(500, 520), control1: p(310, 760), control2: p(403, 659))
        path.addCurve(to: p(570, 420), control1: p(529, 479), control2: p(570, 460))
        path.addCurve(to: p(760, 420), control1: p(570, 190), control2: p(744, 190))
        path.addLine(to: p(785, 770))
        return path
    }
}
