import SwiftUI
import UIKit

/// Pull to refresh with the Marracat M in place of the system spinner (owner
/// picked it from ten loader ideas, 2026-11-18). Pulling draws the M in, one
/// stroke from the left foot to the right; while the refresh runs, a bright
/// segment travels along the letter. The system spinner is hidden app-wide
/// (`hideSystemSpinner`), so every pull-to-refresh uses this modifier.
extension View {
    func markRefreshable(action: @escaping @Sendable () async -> Void) -> some View {
        modifier(MarkRefreshable(action: action))
    }
}

enum MarkRefresh {
    /// How far a pull has to go before the M is fully drawn: about where
    /// UIRefreshControl fires.
    static let fullPull: CGFloat = 110
    /// The gap the refresh control holds open while it runs.
    static let heldGap: CGFloat = 60

    /// The M stays at least one full trip along the letter, however quick
    /// the refresh (Home's takes about 0.6 s).
    static let minimumShow: TimeInterval = 1.0 / 0.75
    /// UI tests: XCUITest waits for the app to go idle after a drag, which is
    /// after the refresh (the hidden spinner still spins). So the tests pin
    /// the M on, still, as it looks while a refresh runs.
    static let pinnedForUITests = ProcessInfo.processInfo.arguments.contains("-PIN_MARK_REFRESH")

    /// The share of the M a pull of `overscroll` points draws.
    static func drawn(overscroll: CGFloat) -> CGFloat { min(1, max(0, overscroll / fullPull)) }

    /// The travelling segment at time `t` (seconds): one trip along the M
    /// every 1.33 s, entering from the left foot and leaving at the right.
    static func segment(at t: TimeInterval) -> (from: CGFloat, to: CGFloat) {
        let t = max(0, t)
        let length: CGFloat = 0.35
        let head = CGFloat(t * 0.75 - (t * 0.75).rounded(.down)) * (1 + length)
        return (max(0, head - length), min(1, head))
    }

    /// Called once at launch: the refresh control stays (it holds the gap and
    /// fires the refresh), only its spinner goes.
    static func hideSystemSpinner() {
        UIRefreshControl.appearance().tintColor = .clear
    }
}

struct MarkRefreshIndicator: View {
    var drawn: CGFloat
    var refreshing: Bool
    /// When the refresh began: the travelling segment starts at the left foot.
    var since: Date = .distantPast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    static let size: CGFloat = 50
    /// The M's centreline box (MarracatMark fits its 570 x 523 logo units to
    /// it); the stroke is the logo's 92 units at that scale.
    private static let glyph = CGSize(width: 30, height: 30 * 523 / 570)

    var body: some View {
        let style = StrokeStyle(lineWidth: 92 * Self.glyph.width / 570, lineCap: .round, lineJoin: .round)
        ZStack {
            MarracatMark().stroke(Color.primary.opacity(0.22), style: style)
            if refreshing && (reduceMotion || MarkRefresh.pinnedForUITests) {
                MarracatMark().stroke(Color.primary, style: style)
            } else if refreshing {
                TimelineView(.animation) { ctx in
                    let seg = MarkRefresh.segment(at: ctx.date.timeIntervalSince(since))
                    MarracatMark().trim(from: seg.from, to: seg.to).stroke(Color.primary, style: style)
                }
            } else {
                MarracatMark().trim(from: 0, to: drawn).stroke(Color.primary, style: style)
            }
        }
        .frame(width: Self.glyph.width, height: Self.glyph.height)
        .frame(width: Self.size, height: Self.size)
    }
}

private struct MarkRefreshable: ViewModifier {
    let action: @Sendable () async -> Void
    @State private var overscroll: CGFloat = 0
    @State private var refreshing = false
    @State private var since = Date.distantPast

    func body(content: Content) -> some View {
        // A sibling above the scroll view, not its overlay: VoiceOver (and
        // XCUITest) never reach a scroll view's overlay.
        ZStack(alignment: .top) {
            content
                .refreshable {
                    since = Date()
                    refreshing = true
                    await action()
                    // A refresh is often cancelled as the page it rebuilt
                    // redraws, so this wait can't be: the refresh control
                    // keeps the gap open until the closure returns.
                    let rest = MarkRefresh.minimumShow - Date().timeIntervalSince(since)
                    if rest > 0 { await Task.detached { try? await Task.sleep(for: .seconds(rest)) }.value }
                    refreshing = false
                }
                .onAppear { if MarkRefresh.pinnedForUITests { refreshing = true } }
                .modifier(OverscrollReader(overscroll: $overscroll))
            // Centred in the gap the pull opens, below the bars (the ZStack
            // keeps to the safe area, as the content's top does at rest).
            // iOS 17 can't read the pull, so there the M only shows while the
            // refresh runs.
            let gap = max(overscroll, refreshing ? MarkRefresh.heldGap : 0)
                        if gap > 8 {
                MarkRefreshIndicator(drawn: MarkRefresh.drawn(overscroll: overscroll), refreshing: refreshing, since: since)
                    .opacity(refreshing ? 1 : min(1, Double(overscroll - 8) / 30))
                    .offset(y: gap / 2 - MarkRefreshIndicator.size / 2)
                    .allowsHitTesting(false)
                    .accessibilityElement()
                    .accessibilityLabel(Text(refreshing ? "Refreshing" : "Pull to refresh", comment: "Pull-to-refresh indicator: the Marracat M"))
                    .accessibilityIdentifier("markRefresh")
            }
        }
    }
}

/// How far the scroll view is pulled past its top, in points; 0 otherwise,
/// so ordinary scrolling never updates state.
private struct OverscrollReader: ViewModifier {
    @Binding var overscroll: CGFloat
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { g in
                max(0, -(g.contentOffset.y + g.contentInsets.top)).rounded()
            } action: { _, new in
                overscroll = new
            }
        } else {
            content
        }
    }
}
