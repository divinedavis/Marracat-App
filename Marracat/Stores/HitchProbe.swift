import UIKit
import os

/// Main-thread stalls once Home is on screen, for the scroll-hitch perf test
/// (PerformanceTests.testHomeFlingAfterLaunch, 2026-10-11). Owner, build 132:
/// a fling down Home ~1.75 s after it appeared froze for ~280 ms. A display
/// link fires every frame; a callback that comes late means the main thread
/// was busy, and the lateness is hitch time, the same measure as Apple's
/// hitch-time ratio (ms of hitch per second).
///
/// Off unless the app is launched with -HITCH_PROBE. The numbers are read by
/// the UI test from a 1-pt accessibility element, "hitchProbe", whose label
/// is worked out only when asked, so the probe adds no work per frame beyond
/// a subtraction. Stalls over 50 ms are also logged (category "launch").
@MainActor
final class HitchProbe: NSObject {
    static let shared = HitchProbe()
    static let enabled = ProcessInfo.processInfo.arguments.contains("-HITCH_PROBE")

    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var since: CFTimeInterval = 0
    private var hitch: CFTimeInterval = 0
    private var longest: CFTimeInterval = 0
    private var interactiveMs = -1
    private var view: ProbeView?

    func start() {
        guard Self.enabled, link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// Home is in front of the shopper: count from here.
    func homeShown() {
        guard Self.enabled, since == 0 else { return }
        since = CACurrentMediaTime()
        hitch = 0; longest = 0
        interactiveMs = LaunchTiming.sinceStart()
        attach()
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        defer { last = now }
        if since > 0, view == nil { attach() }
        guard since > 0, last >= since else { return }
        let frame = link.targetTimestamp > now ? link.targetTimestamp - now : link.duration
        let gap = now - last
        guard frame > 0, gap > frame * 1.5 else { return }
        hitch += gap - frame
        longest = max(longest, gap)
        if gap > 0.05 {
            LaunchTiming.log.notice("hitch: main thread stalled \(Int(gap * 1000), privacy: .public) ms at \(LaunchTiming.sinceStart(), privacy: .public) ms")
        }
    }

    /// "hitch=<ms per s>;stall=<longest ms>;interactive=<ms from process start>;elapsed=<s>"
    var summary: String {
        let elapsed = since > 0 ? CACurrentMediaTime() - since : 0
        let ratio = elapsed > 0 ? hitch * 1000 / elapsed : 0
        return String(format: "hitch=%.2f;stall=%.1f;interactive=%d;elapsed=%.2f", ratio, longest * 1000, interactiveMs, elapsed)
    }

    private func attach() {
        guard view == nil, let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return }
        let v = ProbeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        v.isUserInteractionEnabled = false
        v.isAccessibilityElement = true
        v.accessibilityIdentifier = "hitchProbe"
        window.addSubview(v)
        view = v
    }

    private final class ProbeView: UIView {
        override var accessibilityLabel: String? {
            get { MainActor.assumeIsolated { HitchProbe.shared.summary } }
            set {}
        }
    }
}
