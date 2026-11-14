import SwiftUI
import UIKit

/// Home's outline while the catalog loads on a cold launch that doesn't play
/// the splash (the splash is the day's first open only; owner, 2026-10-02).
/// Every block sits where the real thing will, so nothing jumps when Home
/// fades in: the department chips, the hero and its dots,
/// the square-grid cards, "Shop by brand" and the floating tab bar.
///
/// The shimmer is Facebook's: a soft highlight sweeping left to right across
/// the grey shapes every 1.6 s (the 1.5-2 s cycle usability studies favour),
/// so the wait reads as "loading", not "stuck". Reduce Motion gets a slow
/// pulse instead of the sweep.
///
/// The sweep is a Core Animation layer animation, not a SwiftUI one (owner's
/// recording, 2026-10-03: the glint jumped across the screen). SwiftUI steps
/// its animations on the main thread, which is exactly what's busy decoding
/// the catalog while this shows; Core Animation runs in the render server and
/// keeps every frame.
struct LaunchSkeleton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .top) {
                Theme.canvas.ignoresSafeArea()
                // No header: Home has had no bar or search since 2026-10-20
                    // (search floats on Browse), so neither does its outline.
                    VStack(spacing: 0) {
                    // The highlight is clipped to the grey shapes, not the gaps.
                    shapes(width: w)
                        .overlay { shimmer(width: w).mask(shapes(width: w)).allowsHitTesting(false) }
                    Spacer(minLength: 0)
                }
            }
            .overlay(alignment: .bottom) { tabBar }
            // Exactly the screen: the rows run past its bottom edge and must
            // not push the tab bar off it.
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            .clipped()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading Marracat")
        .accessibilityIdentifier("launchSkeleton")
        .onAppear {
            if reduceMotion {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { dim = true }
            }
        }
    }

    private func shapes(width w: CGFloat) -> some View {
        // Home's order and proportions, measured from the real page on a
        // 402-pt-wide iPhone: chips, the hero (0.63 of its width tall) and
        // its page dots, the two big square-grid cards, then "Shop by brand".
        VStack(alignment: .leading, spacing: 14) {
            chips
            block(width: w - 24, height: (w - 24) * 0.63, radius: 14)
            block(width: 150, height: 12, radius: 6).frame(maxWidth: .infinity)
            quadRow(width: w)
            block(width: 150, height: 20, radius: 4).padding(.top, 6)
            HStack(spacing: 18) {
                ForEach(0..<4, id: \.self) { _ in Circle().fill(Theme.field.opacity(dim ? 0.55 : 1)).frame(width: (w - 78) / 4) }
            }
        }
        .padding(.top, 10)
        .padding(.horizontal, 12)
        .frame(width: w, alignment: .leading)
        .clipped()
    }

    private var chips: some View {
        HStack(spacing: 8) {
            ForEach([58, 52, 84, 74, 64], id: \.self) { block(width: CGFloat($0), height: 30, radius: 15) }
        }
    }

    /// The "New arrivals" / "Deals for you" cards: a title over a 2 x 2 grid.
    private func quadRow(width w: CGFloat) -> some View {
        let card = (w - 24 - 12) / 2.1
        return HStack(spacing: 12) {
            ForEach(0..<3, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 12) {
                    block(width: card * 0.55, height: 16, radius: 4)
                    LazyVGrid(columns: [GridItem(.fixed((card - 36) / 2), spacing: 10), GridItem(.fixed((card - 36) / 2))], spacing: 10) {
                        ForEach(0..<4, id: \.self) { _ in block(width: (card - 36) / 2, height: (card - 36) / 2, radius: 8) }
                    }
                }
                .padding(13)
                .frame(width: card, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface))
            }
        }
    }

    private func block(width: CGFloat, height: CGFloat, radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Theme.field.opacity(dim ? 0.55 : 1))
            .frame(width: width, height: height)
    }

    @ViewBuilder
    private func shimmer(width: CGFloat) -> some View {
        if !reduceMotion { ShimmerSweep() }
    }

    private var tabBar: some View {
        HStack {
            ForEach(0..<5, id: \.self) { _ in Circle().fill(Color.white.opacity(0.18)).frame(width: 26, height: 26).frame(maxWidth: .infinity) }
        }
        .frame(height: FloatingTabBar.height)
        .background(Capsule().fill(Color(red: 45 / 255, green: 46 / 255, blue: 49 / 255)))
        .padding(.horizontal, 22)
        .padding(.bottom, 4)
    }
}

/// The highlight band, moved by Core Animation: the gradient's stops slide at
/// an even speed from just off the left edge to just off the right one (1.5 s),
/// then rest 0.1 s before the next pass (about 0.35 s with no band in view). Measured on a recording: with
/// ease-in-out timing and a wider band, half of each cycle was off screen.
private struct ShimmerSweep: UIViewRepresentable {
    func makeUIView(context: Context) -> SweepView { SweepView() }
    func updateUIView(_ view: SweepView, context: Context) {}

    final class SweepView: UIView {
        override class var layerClass: AnyClass { CAGradientLayer.self }
        private var gradient: CAGradientLayer { layer as! CAGradientLayer }

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            backgroundColor = .clear
            gradient.colors = [UIColor.clear, UIColor.white.withAlphaComponent(0.12), UIColor.clear].map(\.cgColor)
            // A slight tilt, as Facebook's and Airbnb's glints have.
            gradient.startPoint = CGPoint(x: 0, y: 0.45)
            gradient.endPoint = CGPoint(x: 1, y: 0.55)
            gradient.compositingFilter = "plusL"
            gradient.locations = [-0.3, -0.15, 0]
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil, gradient.animation(forKey: "sweep") == nil else { return }
            let sweep = CABasicAnimation(keyPath: "locations")
            sweep.fromValue = [-0.3, -0.15, 0]
            sweep.toValue = [1, 1.15, 1.3]
            sweep.duration = 1.5
            sweep.timingFunction = CAMediaTimingFunction(name: .linear)
            let cycle = CAAnimationGroup()
            cycle.animations = [sweep]
            cycle.duration = 1.6
            cycle.repeatCount = .infinity
            cycle.isRemovedOnCompletion = false
            gradient.add(cycle, forKey: "sweep")
        }
    }
}
