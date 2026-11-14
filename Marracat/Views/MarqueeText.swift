import SwiftUI

/// A one-line title that, when it's too long for its space, glides left on a
/// loop so the whole name can be read (owner, 2026-11-04, picked "1 · Loop"
/// from three previews: "right now i cant see all the text in the header as i
/// scroll down a product or brand"). It waits `pause`, moves at `speed`, and a
/// second copy follows `gap` behind, so the start comes round again; the
/// edges fade. A name that fits stands still, and so does every name under
/// Reduce Motion, which shows the usual truncated line.
struct MarqueeText: View {
    let text: String
    var font: Font = .headline

    static let pause: TimeInterval = 1.5
    static let speed: CGFloat = 32
    static let gap: CGFloat = 48
    static let fade: CGFloat = 12

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var fullWidth: CGFloat = 0
    @State private var start = Date()

    /// Where the line sits `elapsed` seconds in: still for `pause`, then
    /// moving left one name and a gap per cycle.
    static func offset(elapsed: TimeInterval, textWidth: CGFloat) -> CGFloat {
        let travel = textWidth + gap
        guard travel > 0 else { return 0 }
        let cycle = pause + Double(travel / speed)
        let t = elapsed.truncatingRemainder(dividingBy: cycle)
        return t < pause ? 0 : -CGFloat(t - pause) * speed
    }

    /// Whether a line this wide moves in a space that wide.
    static func moves(textWidth: CGFloat, in width: CGFloat, reduceMotion: Bool) -> Bool {
        !reduceMotion && width > 0 && textWidth > width + 0.5
    }

    @State private var width: CGFloat = 0

    var body: some View {
        let moving = Self.moves(textWidth: fullWidth, in: width, reduceMotion: reduceMotion)
        // The plain line takes the place a title would (the bar sizes it),
        // and is what VoiceOver and UI tests read, in that place; while the
        // name moves it's see-through and the moving copies, drawn over it
        // and clipped to it, are hidden from accessibility (their frame ran
        // to 1,012 points and failed the centred-title check, 2026-11-04).
        Text(text).font(font).lineLimit(1)
            // Clear, not transparent: a see-through view drops out of
            // accessibility, and a parent combining its children (the bar
            // title) lost the name.
            .foregroundStyle(moving ? AnyShapeStyle(Color.clear) : AnyShapeStyle(.primary))
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .background {
                Text(text).font(font).lineLimit(1).fixedSize()
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { fullWidth = $0 }
            }
            .overlay {
                if moving {
                    GeometryReader { box in
                        // Drawn, not laid out: a parent that combines its
                        // children (the bar title) read the moving Texts
                        // even when hidden, at their full 1,012-point width.
                        TimelineView(.animation(minimumInterval: 1 / 60)) { tl in
                            let x = Self.offset(elapsed: tl.date.timeIntervalSince(start), textWidth: fullWidth)
                            Canvas { ctx, size in
                                let line = ctx.resolve(Text(text).font(font).foregroundStyle(.primary))
                                for copy in 0..<2 {
                                    ctx.draw(line, at: CGPoint(x: x + CGFloat(copy) * (fullWidth + Self.gap), y: size.height / 2),
                                             anchor: .leading)
                                }
                            }
                        }
                        .frame(width: box.size.width, height: box.size.height)
                        .mask {
                            LinearGradient(stops: [.init(color: .clear, location: 0),
                                                   .init(color: .black, location: Self.fade / max(box.size.width, 1)),
                                                   .init(color: .black, location: 1 - Self.fade / max(box.size.width, 1)),
                                                   .init(color: .clear, location: 1)],
                                           startPoint: .leading, endPoint: .trailing)
                        }
                    }
                    .accessibilityHidden(true)
                }
            }
            // A new name starts from its beginning again.
            .onChange(of: text) { start = .now }
            .onAppear { start = .now }
    }
}
