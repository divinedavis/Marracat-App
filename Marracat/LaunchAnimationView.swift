import SwiftUI
import UIKit

/// Motion runs on the compositor while Home loads. The exit starts only after
/// the local catalog is ready; its expansion, logo lift, and fade share a clock.
struct LaunchAnimationView: UIViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let hold: Double
    let isReady: Bool
    /// The day's look (HolidayTheme.swift); nil is the everyday splash.
    var holiday: Holiday? = HolidayCalendar.current()
    let onFinished: () -> Void

    func makeUIView(context: Context) -> LaunchSurface {
        LaunchSurface(hold: hold, reduceMotion: reduceMotion, holiday: holiday, onFinished: onFinished)
    }

    func updateUIView(_ uiView: LaunchSurface, context: Context) {
        uiView.isReady = isReady
    }

    static func dismantleUIView(_ uiView: LaunchSurface, coordinator: ()) {
        uiView.cancel()
    }
}

final class LaunchSurface: UIView, CAAnimationDelegate {
    private let disc = CALayer()
    private let wordmark = UILabel()
    /// On a holiday: a ring of its colours drawn round the disc, and its
    /// line and mark under the word, fading in after it.
    private let holiday: Holiday?
    private let ring = CAGradientLayer()
    private let ringMask = CAShapeLayer()
    private let extra = UIView()
    private let line = UILabel()
    private var flames: [CALayer] = []
    private var fireworks: [CAEmitterLayer] = []
    private let hold: Double
    private let reduceMotion: Bool
    private var onFinished: (() -> Void)?
    private var started = false
    private var arrived = false
    private var held = false
    private var revealing = false
    var isReady = false { didSet { revealIfReady() } }

    init(hold: Double, reduceMotion: Bool, holiday: Holiday? = nil, onFinished: @escaping () -> Void) {
        self.hold = hold.isFinite ? min(max(hold, 0.3), 10) : 0.52
        self.reduceMotion = reduceMotion
        self.holiday = holiday
        self.onFinished = onFinished
        super.init(frame: .zero)
        backgroundColor = .white
        clipsToBounds = true
        isAccessibilityElement = true
        accessibilityLabel = holiday.map { "MARRACAT, " + $0.line.capitalized } ?? "MARRACAT"
        accessibilityIdentifier = "splash"
        accessibilityTraits = .staticText
        disc.backgroundColor = (holiday.map { UIColor(hex: $0.disc) } ?? .black).cgColor
        layer.addSublayer(disc)
        if let holiday, !holiday.ring.isEmpty {
            ring.type = .conic
            ring.startPoint = CGPoint(x: 0.5, y: 0.5)
            ring.endPoint = CGPoint(x: 0.5, y: 0)
            // Hard stops: each colour is an equal arc, as on the flag.
            let n = holiday.ring.count
            ring.colors = holiday.ring.flatMap { [UIColor(hex: $0).cgColor, UIColor(hex: $0).cgColor] }
            ring.locations = (0..<n).flatMap { [NSNumber(value: Double($0) / Double(n)), NSNumber(value: Double($0 + 1) / Double(n))] }
            ringMask.fillColor = nil
            ringMask.strokeColor = UIColor.black.cgColor
            ringMask.strokeEnd = 0
            ring.mask = ringMask
            disc.addSublayer(ring)
        }
        wordmark.textAlignment = .center
        addSubview(wordmark)
        if let holiday {
            line.textAlignment = .center
            line.numberOfLines = 2
            extra.addSubview(line)
            extra.alpha = 0
            addSubview(extra)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !started, window != nil, bounds.width > 0, bounds.height > 0 else { return }
        started = true
        let diameter = min(bounds.width * 0.68, 300)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        disc.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        disc.position = center
        disc.cornerRadius = diameter / 2
        wordmark.attributedText = NSAttributedString(string: "MARRACAT", attributes: [
            .font: UIFont(name: "Futura-Medium", size: diameter * 0.10)
                ?? UIFont.systemFont(ofSize: diameter * 0.10, weight: .medium),
            .kern: diameter * 0.014,
            .foregroundColor: UIColor.white,
        ])
        wordmark.bounds = CGRect(x: 0, y: 0, width: diameter, height: 60)
        wordmark.center = center
        if let holiday { layoutHoliday(holiday, diameter: diameter, center: center) }
        CATransaction.commit()
        animate(diameter: diameter)
    }

    /// The ring round the disc, the day's line and its mark (an SF Symbol, or
    /// a kinara's seven candles), sized to the disc like the word.
    private func layoutHoliday(_ holiday: Holiday, diameter: CGFloat, center: CGPoint) {
        let width = diameter * 0.055
        ring.frame = disc.bounds.insetBy(dx: -width, dy: -width)
        let r = diameter / 2 + width / 2
        ringMask.frame = ring.bounds
        ringMask.lineWidth = width
        ringMask.path = UIBezierPath(arcCenter: CGPoint(x: ring.bounds.midX, y: ring.bounds.midY), radius: r,
                                     startAngle: -.pi / 2, endAngle: 1.5 * .pi, clockwise: true).cgPath
        line.attributedText = NSAttributedString(string: holiday.line, attributes: [
            .font: UIFont(name: "Futura-Medium", size: diameter * 0.042) ?? UIFont.systemFont(ofSize: diameter * 0.042, weight: .medium),
            .kern: diameter * 0.012,
            .foregroundColor: UIColor.white,
        ])
        let lineSize = line.sizeThatFits(CGSize(width: diameter * 0.78, height: .greatestFiniteMagnitude))
        line.frame = CGRect(x: (diameter - lineSize.width) / 2, y: 0, width: lineSize.width, height: lineSize.height)
        var height = lineSize.height
        if let mark = holiday.mark {
            let gap = diameter * 0.035
            if mark == "kinara" {
                let k = kinara(width: diameter * 0.33)
                k.frame.origin = CGPoint(x: (diameter - k.frame.width) / 2, y: height + gap)
                extra.layer.addSublayer(k)
                height += gap + k.frame.height
            } else {
                let side = diameter * 0.11
                let image = UIImageView(image: UIImage(systemName: mark))
                image.tintColor = .white
                image.contentMode = .scaleAspectFit
                image.frame = CGRect(x: (diameter - side) / 2, y: height + gap, width: side, height: side)
                extra.addSubview(image)
                height += gap + side
            }
        }
        extra.frame = CGRect(x: center.x - diameter / 2, y: center.y + diameter * 0.06, width: diameter, height: height)
        // The word moves up a touch to make room, so the pair sits centred.
        wordmark.center.y -= diameter * 0.02
    }

    /// Seven candles, three red, one black, three green, each with a flame
    /// that lights in turn once the disc lands.
    private func kinara(width: CGFloat) -> CALayer {
        let holder = CALayer()
        let colors = ["#C8102E", "#C8102E", "#C8102E", "#0A0A0A", "#007A3D", "#007A3D", "#007A3D"]
        let w = width / 9, gap = w / 3
        let tallest = w * 4.2
        holder.frame = CGRect(x: 0, y: 0, width: 7 * w + 6 * gap, height: tallest + w * 1.2)
        for (i, c) in colors.enumerated() {
            let h = i == 3 ? tallest : tallest * 0.8
            let candle = CALayer()
            candle.backgroundColor = UIColor(hex: c).cgColor
            candle.borderColor = UIColor.white.cgColor
            candle.borderWidth = 0.6
            candle.cornerRadius = w * 0.18
            let x = CGFloat(i) * (w + gap)
            candle.frame = CGRect(x: x, y: holder.frame.height - h, width: w, height: h)
            holder.addSublayer(candle)
            let flame = CAShapeLayer()
            let fw = w * 0.7, fh = w * 1.0
            flame.path = UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: fw, height: fh)).cgPath
            flame.fillColor = UIColor(hex: "#E8B000").cgColor
            flame.frame = CGRect(x: x + (w - fw) / 2, y: holder.frame.height - h - fh - w * 0.15, width: fw, height: fh)
            flame.opacity = reduceMotion ? 1 : 0
            holder.addSublayer(flame)
            flames.append(flame)
        }
        return holder
    }

    private let ease = CAMediaTimingFunction(name: .easeInEaseOut)

    private func track(_ key: String, values: [Double], times: [Double],
                       start: CFTimeInterval,
                       curves: [CAMediaTimingFunction]? = nil) -> CAKeyframeAnimation {
        let duration = times.last!
        let animation = CAKeyframeAnimation(keyPath: key)
        animation.values = values
        animation.keyTimes = times.map { NSNumber(value: $0 / duration) }
        animation.timingFunctions = curves ?? Array(repeating: ease, count: values.count - 1)
        animation.duration = duration
        animation.beginTime = start
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false
        return animation
    }

    // The logo lands, then breathes (grows and settles) until Home is ready,
    // so the wait never looks frozen (owner, 2026-09-30). `hold` is now only
    // the shortest the splash stays up; the pulse runs through it and past it.
    private func animate(diameter: CGFloat) {
        // 0.52 s, 30% slower on 2026-10-02 (0.68), and 30% slower again on
        // 2026-10-08 (owner).
        let arrival = reduceMotion ? 0.1 : 0.88
        let start = layer.convertTime(CACurrentMediaTime(), from: nil) + 0.04
        if reduceMotion {
            backgroundColor = .black
            disc.isHidden = true
        } else {
            disc.add(track("transform.scale", values: [0.18, 1], times: [0, arrival], start: start,
                           curves: [CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)]),
                     forKey: "launch.scale")
            wordmark.layer.add(track("opacity", values: [0, 0, 1],
                                     times: [0, 0.137, 0.78], start: start),   // 0.08 / 0.46, then 0.105 / 0.6, each step 30% slower
                               forKey: "launch.wordOpacity")
            wordmark.layer.add(track("transform.scale", values: [0.94, 1],
                                     times: [0, arrival], start: start),
                               forKey: "launch.wordScale")
        }
        animateHolidayIn(start: start)
        if holiday?.effect == "fireworks", !reduceMotion { launchFireworks(diameter: disc.bounds.width) }
        let intro = track("opacity", values: [1, 1], times: [0, arrival], start: start)
        intro.setValue("intro", forKey: "phase")
        intro.delegate = self
        layer.add(intro, forKey: "launch.intro")
        let minimum = track("opacity", values: [1, 1], times: [0, reduceMotion ? 0.1 : arrival + hold], start: start)
        minimum.setValue("hold", forKey: "phase")
        minimum.delegate = self
        layer.add(minimum, forKey: "launch.hold")
    }

    /// The ring draws round the disc as it lands, then the day's line and
    /// mark rise in under the word, and a kinara's candles light in turn.
    private func animateHolidayIn(start: CFTimeInterval) {
        guard holiday != nil else { return }
        if reduceMotion {
            backgroundColor = disc.backgroundColor.map(UIColor.init(cgColor:)) ?? .black
            extra.alpha = 1
            return
        }
        let sweep = track("strokeEnd", values: [0, 0, 1], times: [0, 0.4, 1.4], start: start,
                          curves: [ease, CAMediaTimingFunction(controlPoints: 0.3, 0, 0.2, 1)])
        ringMask.add(sweep, forKey: "holiday.ring")
        extra.layer.add(track("opacity", values: [0, 0, 1], times: [0, 0.55, 1.05], start: start), forKey: "holiday.in")
        extra.layer.add(track("transform.translation.y", values: [6, 6, 0], times: [0, 0.55, 1.05], start: start), forKey: "holiday.rise")
        extra.alpha = 1
        for (i, flame) in flames.enumerated() {
            let t = 0.9 + Double(i) * 0.12
            flame.add(track("opacity", values: [0, 0, 1], times: [0, t, t + 0.1], start: start), forKey: "holiday.flame")
        }
    }

    /// New Year's: three bursts of gold, silver and red sparks around the
    /// disc as it lands, a beat apart, each fading as it falls.
    private func launchFireworks(diameter: CGFloat) {
        let spark = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { _ in
            UIColor.white.setFill()
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: 8, height: 8)).fill()
        }.cgImage
        let spots = [CGPoint(x: bounds.midX - diameter * 0.48, y: bounds.midY - diameter * 0.62),
                     CGPoint(x: bounds.midX + diameter * 0.5, y: bounds.midY - diameter * 0.78),
                     CGPoint(x: bounds.midX + diameter * 0.1, y: bounds.midY + diameter * 0.8)]
        // Silver, not white: white sparks vanish on the white splash.
        let colors = [UIColor(hex: "#E8B000"), UIColor(hex: "#A9AEB8"), UIColor(hex: "#C8102E")]
        for (i, spot) in spots.enumerated() {
            let burst = CAEmitterLayer()
            burst.emitterPosition = spot
            burst.emitterShape = .point
            burst.renderMode = .additive
            burst.birthRate = 0
            burst.cornerRadius = 0
            burst.emitterCells = colors.map { color in
                let c = CAEmitterCell()
                c.contents = spark
                c.color = color.cgColor
                c.birthRate = 160
                c.lifetime = 1.1
                c.velocity = diameter * 0.55
                c.velocityRange = diameter * 0.15
                c.emissionRange = .pi * 2
                c.yAcceleration = diameter * 0.35
                c.scale = 0.8
                c.scaleSpeed = -0.45
                c.alphaSpeed = -0.9
                return c
            }
            layer.insertSublayer(burst, below: disc)
            fireworks.append(burst)
            let delay = 0.55 + Double(i) * 0.45
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak burst] in
                burst?.birthRate = 1
                burst?.beginTime = CACurrentMediaTime()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { burst?.birthRate = 0 }
            }
        }
    }

    private func breathe() {
        let pulse = CABasicAnimation(keyPath: "transform.scale")
        pulse.fromValue = 1
        pulse.toValue = 1.07
        pulse.duration = 1.01   // 0.6, then 0.78, each step 30% slower
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = ease
        disc.removeAnimation(forKey: "launch.scale")
        disc.add(pulse, forKey: "launch.wait")
        let word = pulse.copy() as! CABasicAnimation
        word.toValue = 1.04
        wordmark.layer.removeAnimation(forKey: "launch.wordScale")
        wordmark.layer.add(word, forKey: "launch.wait")
    }

    private func revealIfReady() {
        guard arrived, held, isReady, !revealing, onFinished != nil else { return }
        revealing = true
        // A frame for Home's updated layout to commit before the exit begins.
        let start = layer.convertTime(CACurrentMediaTime(), from: nil) + 0.04
        // 0.52 s (0.92 until 2026-09-27, then 0.62, then 0.40 for a 40% shorter
        // splash on 2026-10-02 and 30% slower again the same day, then 0.68,
        // 30% slower on 2026-10-08). Every keyframe below is scaled by the same
        // factor, so it keeps its shape.
        let duration = reduceMotion ? 0.25 : 0.68
        let k = 0.68 / 0.62
        if !reduceMotion {
            let scale = (disc.presentation()?.value(forKeyPath: "transform.scale") as? NSNumber)?.doubleValue ?? 1
            let cover = Double(hypot(bounds.width, bounds.height) / disc.bounds.width + 0.08)
            disc.removeAnimation(forKey: "launch.wait")
            wordmark.layer.removeAnimation(forKey: "launch.wait")
            disc.add(track("transform.scale", values: [scale, cover, cover],
                           times: [0, 0.42 * k, duration], start: start,
                           curves: [CAMediaTimingFunction(controlPoints: 0.55, 0, 0.85, 0.5), ease]),
                     forKey: "launch.scale")
            wordmark.layer.add(track("opacity", values: [1, 1, 0, 0],
                                     times: [0, 0.08 * k, 0.42 * k, duration], start: start),
                               forKey: "launch.wordOpacity")
            extra.layer.removeAllAnimations()
            extra.layer.add(track("opacity", values: [1, 1, 0, 0], times: [0, 0.05 * k, 0.3 * k, duration], start: start),
                            forKey: "holiday.out")
            extra.layer.add(track("transform.translation.y", values: [0, 0, -Double(bounds.height) * 0.2, -Double(bounds.height) * 0.2],
                                  times: [0, 0.05 * k, 0.3 * k, duration], start: start), forKey: "holiday.lift")
            wordmark.layer.add(track("transform.translation.y",
                                     values: [0, 0, -Double(bounds.height) * 0.23,
                                              -Double(bounds.height) * 0.23],
                                     times: [0, 0.05 * k, 0.42 * k, duration], start: start),
                               forKey: "launch.wordLift")
        }
        // Completion follows the actual fade, never a sleep deadline. With
        // Reduce Motion enabled, this is the only movement in the opening.
        let dissolve = track("opacity", values: [1, 1, 0],
                             times: [0, reduceMotion ? 0.02 : 0.42 * k, duration], start: start)
        dissolve.setValue("exit", forKey: "phase")
        dissolve.delegate = self
        layer.removeAnimation(forKey: "launch.intro")
        layer.removeAnimation(forKey: "launch.hold")
        layer.add(dissolve, forKey: "launch.finish")
    }

    func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        guard flag, onFinished != nil else { return }
        switch anim.value(forKey: "phase") as? String {
        case "intro":
            arrived = true
            if !reduceMotion { breathe() }
            revealIfReady()
        case "hold":
            held = true
            revealIfReady()
        default:
            let finish = onFinished
            onFinished = nil
            finish?()
        }
    }

    func cancel() {
        onFinished = nil
        layer.removeAllAnimations()
        disc.removeAllAnimations()
        wordmark.layer.removeAllAnimations()
    }
}
