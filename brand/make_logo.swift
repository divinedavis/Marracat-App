// Marracat logo concepts — vector marks, wordmark lockups, app icons, and a
// comparison sheet, all from the same path definitions.
//
//   swift brand/make_logo.swift            # writes into brand/
//
// Marks are drawn in a 1000×1000 box with y pointing down (SVG space). The
// wordmark is real glyph outlines from SF Pro Rounded, so the SVGs need no font.
import AppKit
import CoreText

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "brand")

struct RGB {
    let r: CGFloat, g: CGFloat, b: CGFloat
    var cg: CGColor { CGColor(red: r, green: g, blue: b, alpha: 1) }
    var hex: String { String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255)) }
}

let cocoa = RGB(r: 0.23, g: 0.14, b: 0.09)
let ink = RGB(r: 0.12, g: 0.07, b: 0.04)
let gold = RGB(r: 1.0, g: 0.80, b: 0.25)
let amber = RGB(r: 0.78, g: 0.53, b: 0.23)
let cream = RGB(r: 1.0, g: 0.965, b: 0.91)

enum Part {
    case fill(CGPath, RGB)
    case stroke(CGPath, RGB, CGFloat)
}

// MARK: - Shapes

func almondEye(center c: CGPoint, halfWidth w: CGFloat, height h: CGFloat, tilt: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: -w, y: 0))
    p.addQuadCurve(to: CGPoint(x: w, y: 0), control: CGPoint(x: 0, y: -h))
    p.addQuadCurve(to: CGPoint(x: -w, y: 0), control: CGPoint(x: 0, y: h))
    p.closeSubpath()
    var t = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: tilt)
    return p.copy(using: &t)!
}

func pupil(center c: CGPoint, height h: CGFloat, width w: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h), transform: nil)
}

func catEyes(y: CGFloat, spread: CGFloat, size: CGFloat, eye: RGB, slit: RGB) -> [Part] {
    let l = CGPoint(x: 500 - spread, y: y), r = CGPoint(x: 500 + spread, y: y)
    let tilt: CGFloat = 0.17
    return [
        .fill(almondEye(center: l, halfWidth: size, height: size * 0.62, tilt: tilt), eye),
        .fill(almondEye(center: r, halfWidth: size, height: size * 0.62, tilt: -tilt), eye),
        .fill(pupil(center: l, height: size * 0.56, width: size * 0.2), slit),
        .fill(pupil(center: r, height: size * 0.56, width: size * 0.2), slit),
    ]
}

/// A. Cat Bag — a tote whose top corners are cat ears, handle between them.
func catBag(body: RGB, eyes: RGB, slit: RGB) -> [Part] {
    let handle = CGMutablePath()
    handle.addArc(center: CGPoint(x: 500, y: 420), radius: 108, startAngle: .pi, endAngle: 2 * .pi, clockwise: false)

    let b = CGMutablePath()
    b.move(to: CGPoint(x: 262, y: 420))
    b.addLine(to: CGPoint(x: 286, y: 276))
    b.addQuadCurve(to: CGPoint(x: 322, y: 272), control: CGPoint(x: 300, y: 236))
    b.addLine(to: CGPoint(x: 432, y: 404))
    b.addLine(to: CGPoint(x: 568, y: 404))
    b.addLine(to: CGPoint(x: 678, y: 272))
    b.addQuadCurve(to: CGPoint(x: 714, y: 276), control: CGPoint(x: 700, y: 236))
    b.addLine(to: CGPoint(x: 738, y: 420))
    b.addLine(to: CGPoint(x: 774, y: 744))
    b.addQuadCurve(to: CGPoint(x: 710, y: 812), control: CGPoint(x: 782, y: 812))
    b.addLine(to: CGPoint(x: 290, y: 812))
    b.addQuadCurve(to: CGPoint(x: 226, y: 744), control: CGPoint(x: 218, y: 812))
    b.closeSubpath()

    return [.stroke(handle, body, 40), .fill(b, body)] + catEyes(y: 596, spread: 116, size: 76, eye: eyes, slit: slit)
}

/// B. M Ears — a monogram M whose slanted stem tops are cat ears.
func mEars(disc: RGB, letter: RGB) -> [Part] {
    let m = CGMutablePath()
    // Each stem rises to a pointed ear tip, then drops into the V — the
    // notch between tip and V is what makes the M read as cat ears.
    m.move(to: CGPoint(x: 250, y: 760))
    m.addLine(to: CGPoint(x: 250, y: 300))
    m.addLine(to: CGPoint(x: 262, y: 196))
    m.addQuadCurve(to: CGPoint(x: 286, y: 190), control: CGPoint(x: 270, y: 176))
    m.addLine(to: CGPoint(x: 372, y: 300))
    m.addLine(to: CGPoint(x: 500, y: 470))
    m.addLine(to: CGPoint(x: 628, y: 300))
    m.addLine(to: CGPoint(x: 714, y: 190))
    m.addQuadCurve(to: CGPoint(x: 738, y: 196), control: CGPoint(x: 730, y: 176))
    m.addLine(to: CGPoint(x: 750, y: 300))
    m.addLine(to: CGPoint(x: 750, y: 760))
    m.addLine(to: CGPoint(x: 630, y: 760))
    m.addLine(to: CGPoint(x: 630, y: 480))
    m.addLine(to: CGPoint(x: 500, y: 640))
    m.addLine(to: CGPoint(x: 370, y: 480))
    m.addLine(to: CGPoint(x: 370, y: 760))
    m.closeSubpath()
    let circle = CGPath(ellipseIn: CGRect(x: 60, y: 60, width: 880, height: 880), transform: nil)
    return [.fill(circle, disc), .fill(m, letter)]
}

/// C. Marrakech Door — a pointed horseshoe arch with cat eyes glowing inside.
func door(frame: RGB, dark: RGB, eyes: RGB) -> [Part] {
    func arch(inset i: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 240 + i, y: 840))
        p.addLine(to: CGPoint(x: 240 + i, y: 480))
        p.addQuadCurve(to: CGPoint(x: 500, y: 170 + i * 1.3), control: CGPoint(x: 240 + i, y: 250 + i * 0.6))
        p.addQuadCurve(to: CGPoint(x: 760 - i, y: 480), control: CGPoint(x: 760 - i, y: 250 + i * 0.6))
        p.addLine(to: CGPoint(x: 760 - i, y: 840))
        p.closeSubpath()
        return p
    }
    return [.fill(arch(inset: 0), frame), .fill(arch(inset: 58), dark)]
        + catEyes(y: 590, spread: 100, size: 68, eye: eyes, slit: dark)
}

/// The Marracat M — one continuous rounded monoline stroke. Two soft peaks
/// (they double as cat ears), and the valley crosses itself into a loop.
/// Tangents are matched at every join so the line reads as a single gesture.
func loopM(_ color: RGB, width: CGFloat = 92) -> [Part] {
    let p = CGMutablePath()
    // Left leg flares out at the foot, then a full rounded arch.
    p.move(to: CGPoint(x: 215, y: 770))
    p.addLine(to: CGPoint(x: 240, y: 420))
    p.addCurve(to: CGPoint(x: 430, y: 420), control1: CGPoint(x: 256, y: 190), control2: CGPoint(x: 430, y: 190))
    // Inner leg drops into the crossing point, already heading down-right.
    // Inner legs sit 140 apart so the strokes never touch above the crossing.
    p.addCurve(to: CGPoint(x: 500, y: 520), control1: CGPoint(x: 430, y: 460), control2: CGPoint(x: 471, y: 479))
    // The loop: an open round counter, its bottom level with the feet.
    p.addCurve(to: CGPoint(x: 500, y: 760), control1: CGPoint(x: 597, y: 659), control2: CGPoint(x: 690, y: 760))
    p.addCurve(to: CGPoint(x: 500, y: 520), control1: CGPoint(x: 310, y: 760), control2: CGPoint(x: 403, y: 659))
    // Up the right inner leg, over the second arch, down the flared right leg.
    p.addCurve(to: CGPoint(x: 570, y: 420), control1: CGPoint(x: 529, y: 479), control2: CGPoint(x: 570, y: 460))
    p.addCurve(to: CGPoint(x: 760, y: 420), control1: CGPoint(x: 570, y: 190), control2: CGPoint(x: 744, y: 190))
    p.addLine(to: CGPoint(x: 785, y: 770))
    return [.stroke(p, color, width)]
}

// MARK: - Wordmark

/// Glyph outlines for `text`, flipped into y-down space, origin at top-left.
func wordPath(_ text: String, size: CGFloat, weight: NSFont.Weight, tracking: CGFloat = 0) -> CGPath {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    let font = NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: size) ?? base
    let attr = NSAttributedString(string: text, attributes: [.font: font, .kern: tracking])
    let line = CTLineCreateWithAttributedString(attr)
    let ascent = CTFontGetAscent(font as CTFont)
    let out = CGMutablePath()
    for run in CTLineGetGlyphRuns(line) as! [CTRun] {
        let n = CTRunGetGlyphCount(run)
        var glyphs = [CGGlyph](repeating: 0, count: n)
        var pos = [CGPoint](repeating: .zero, count: n)
        CTRunGetGlyphs(run, CFRange(location: 0, length: n), &glyphs)
        CTRunGetPositions(run, CFRange(location: 0, length: n), &pos)
        for i in 0..<n {
            guard let g = CTFontCreatePathForGlyph(font as CTFont, glyphs[i], nil) else { continue }
            let t = CGAffineTransform(translationX: pos[i].x, y: ascent).scaledBy(x: 1, y: -1)
            out.addPath(g, transform: t)
        }
    }
    return out
}

// MARK: - Output

func svgData(_ p: CGPath) -> String {
    var d = ""
    func f(_ v: CGFloat) -> String { String(format: "%.1f", v) }
    p.applyWithBlock { e in
        let pts = e.pointee.points
        switch e.pointee.type {
        case .moveToPoint: d += "M\(f(pts[0].x)) \(f(pts[0].y))"
        case .addLineToPoint: d += "L\(f(pts[0].x)) \(f(pts[0].y))"
        case .addQuadCurveToPoint: d += "Q\(f(pts[0].x)) \(f(pts[0].y)) \(f(pts[1].x)) \(f(pts[1].y))"
        case .addCurveToPoint:
            d += "C\(f(pts[0].x)) \(f(pts[0].y)) \(f(pts[1].x)) \(f(pts[1].y)) \(f(pts[2].x)) \(f(pts[2].y))"
        case .closeSubpath: d += "Z"
        @unknown default: break
        }
    }
    return d
}

func svgParts(_ parts: [Part], transform: String = "") -> String {
    var s = transform.isEmpty ? "" : "<g transform=\"\(transform)\">"
    for part in parts {
        switch part {
        case .fill(let p, let c): s += "<path d=\"\(svgData(p))\" fill=\"\(c.hex)\"/>"
        case .stroke(let p, let c, let w):
            s += "<path d=\"\(svgData(p))\" fill=\"none\" stroke=\"\(c.hex)\" stroke-width=\"\(w)\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>"
        }
    }
    return s + (transform.isEmpty ? "" : "</g>")
}

func draw(_ parts: [Part], in ctx: CGContext, rect: CGRect) {
    ctx.saveGState()
    ctx.translateBy(x: rect.minX, y: rect.minY)
    ctx.scaleBy(x: rect.width / 1000, y: rect.height / 1000)
    for part in parts {
        switch part {
        case .fill(let p, let c):
            ctx.addPath(p); ctx.setFillColor(c.cg); ctx.fillPath()
        case .stroke(let p, let c, let w):
            ctx.addPath(p); ctx.setStrokeColor(c.cg); ctx.setLineWidth(w)
            ctx.setLineCap(.round); ctx.setLineJoin(.round); ctx.strokePath()
        }
    }
    ctx.restoreGState()
}

func fillPath(_ p: CGPath, _ c: RGB, in ctx: CGContext, at origin: CGPoint) {
    ctx.saveGState()
    ctx.translateBy(x: origin.x, y: origin.y)
    ctx.addPath(p); ctx.setFillColor(c.cg); ctx.fillPath()
    ctx.restoreGState()
}

/// Opaque sRGB bitmap in y-down space (App Store rejects icons with alpha).
func png(width: Int, height: Int, background: RGB, _ body: (CGContext) -> Void) -> Data {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(height))
    ctx.scaleBy(x: 1, y: -1)
    ctx.setFillColor(background.cg)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    body(ctx)
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

func write(_ data: Data, _ name: String) {
    try! data.write(to: outDir.appendingPathComponent(name))
}

struct Concept {
    let key: String
    let title: String
    let onLight: [Part]      // mark for cream backgrounds
    let icon: [Part]         // app-icon colourway
    let iconBackground: RGB
}

let concepts = [
    Concept(key: "a", title: "A · Cat Bag",
            onLight: catBag(body: cocoa, eyes: gold, slit: cocoa),
            icon: catBag(body: gold, eyes: cocoa, slit: gold), iconBackground: cocoa),
    Concept(key: "b", title: "B · M Ears",
            onLight: mEars(disc: cocoa, letter: gold),
            icon: mEars(disc: cocoa, letter: gold), iconBackground: amber),
    Concept(key: "c", title: "C · Marrakech Door",
            onLight: door(frame: amber, dark: ink, eyes: gold),
            icon: door(frame: gold, dark: ink, eyes: gold), iconBackground: cocoa),
]

let word = wordPath("marracat", size: 200, weight: .heavy, tracking: -3)
let wordBox = word.boundingBoxOfPath

try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

for c in concepts {
    // Mark alone.
    write(Data("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1000 1000\">\(svgParts(c.onLight))</svg>\n".utf8),
          "marracat-mark-\(c.key).svg")

    // Horizontal lockup: mark at wordmark height ×1.6, then the word.
    let markSize = wordBox.height * 1.9
    let gap = markSize * 0.12
    let width = markSize + gap + wordBox.width
    let wordY = (markSize - wordBox.height) / 2 - wordBox.minY
    let wordX = markSize + gap - wordBox.minX
    let lockup = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(Int(width.rounded(.up))) \(Int(markSize.rounded(.up)))\">"
        + svgParts(c.onLight, transform: "scale(\(markSize / 1000))")
        + "<path transform=\"translate(\(wordX) \(wordY))\" d=\"\(svgData(word))\" fill=\"\(cocoa.hex)\"/></svg>\n"
    write(Data(lockup.utf8), "marracat-lockup-\(c.key).svg")

    // App icon, full-bleed (iOS applies the corner mask).
    write(png(width: 1024, height: 1024, background: c.iconBackground) { ctx in
        draw(c.icon, in: ctx, rect: CGRect(x: 112, y: 112, width: 800, height: 800))
    }, "icon-\(c.key).png")
}

// Comparison sheet: one column per concept — mark, lockup, icon on a phone-ish tile.
let colW = 900, sheetH = 1700
write(png(width: colW * concepts.count, height: sheetH, background: RGB(r: 0.95, g: 0.93, b: 0.90)) { ctx in
    for (i, c) in concepts.enumerated() {
        let x0 = CGFloat(i * colW)
        ctx.setFillColor(cream.cg)
        ctx.fill(CGRect(x: x0 + 30, y: 30, width: CGFloat(colW) - 60, height: CGFloat(sheetH) - 60))

        let label = wordPath(c.title, size: 54, weight: .semibold)
        fillPath(label, cocoa, in: ctx, at: CGPoint(x: x0 + 80, y: 70))

        draw(c.onLight, in: ctx, rect: CGRect(x: x0 + 150, y: 170, width: 600, height: 600))

        // Lockup, scaled to the column.
        let scale: CGFloat = 0.62
        let markSize = wordBox.height * 1.9 * scale
        let lockW = markSize * 1.12 + wordBox.width * scale
        let lx = x0 + (CGFloat(colW) - lockW) / 2, ly: CGFloat = 860
        draw(c.onLight, in: ctx, rect: CGRect(x: lx, y: ly, width: markSize, height: markSize))
        ctx.saveGState()
        ctx.translateBy(x: lx + markSize * 1.12, y: ly + (markSize - wordBox.height * scale) / 2)
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -wordBox.minX, y: -wordBox.minY)
        ctx.addPath(word); ctx.setFillColor(cocoa.cg); ctx.fillPath()
        ctx.restoreGState()

        // Icon preview with the iOS squircle-ish mask.
        let iconRect = CGRect(x: x0 + CGFloat(colW) / 2 - 210, y: 1150, width: 420, height: 420)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: iconRect, cornerWidth: 94, cornerHeight: 94, transform: nil))
        ctx.clip()
        ctx.setFillColor(c.iconBackground.cg); ctx.fill(iconRect)
        draw(c.icon, in: ctx, rect: iconRect.insetBy(dx: 46, dy: 46))
        ctx.restoreGState()
    }
}, "concepts.png")

// MARK: - The chosen direction: the Marracat M

/// Diagonal two-stop gradient, lighter top-left (the Airbnb-style icon ground).
func gradient(_ ctx: CGContext, _ rect: CGRect, from a: RGB, to b: RGB) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [a.cg, b.cg] as CFArray,
                       locations: [0, 1])!
    ctx.saveGState()
    ctx.clip(to: rect)
    ctx.drawLinearGradient(g, start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.maxX, y: rect.maxY),
                           options: [])
    ctx.restoreGState()
}

struct Colorway { let name: String, file: String, top: RGB, bottom: RGB, mark: RGB }
let cocoaLight = RGB(r: 0.40, g: 0.25, b: 0.15)
let amberLight = RGB(r: 0.93, g: 0.68, b: 0.36)
let colorways = [
    Colorway(name: "Primary · gold on cocoa", file: "icon-m.png", top: cocoaLight, bottom: cocoa, mark: gold),
    Colorway(name: "Alt · cream on amber", file: "icon-m-alt.png", top: amberLight, bottom: amber, mark: cream),
]

func drawIcon(_ ctx: CGContext, _ rect: CGRect, _ c: Colorway) {
    gradient(ctx, rect, from: c.top, to: c.bottom)
    let inset = rect.width * 0.17     // mark spans ~44% of the icon's width, like the reference
    draw(loopM(c.mark), in: ctx, rect: rect.insetBy(dx: inset, dy: inset))
}

for c in colorways {
    write(png(width: 1024, height: 1024, background: c.bottom) { drawIcon($0, CGRect(x: 0, y: 0, width: 1024, height: 1024), c) },
          c.file)
}

write(Data("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1000 1000\">\(svgParts(loopM(cocoa)))</svg>\n".utf8),
      "marracat-m-mark.svg")
write(Data("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1000 1000\"><defs><linearGradient id=\"g\" x1=\"0\" y1=\"0\" x2=\"1\" y2=\"1\"><stop offset=\"0\" stop-color=\"\(cocoaLight.hex)\"/><stop offset=\"1\" stop-color=\"\(cocoa.hex)\"/></linearGradient></defs><rect width=\"1000\" height=\"1000\" rx=\"224\" fill=\"url(#g)\"/>\(svgParts(loopM(gold), transform: "translate(170 170) scale(0.66)"))</svg>\n".utf8),
      "marracat-m-icon.svg")
do {
    let markSize = wordBox.height * 1.5
    let gap = markSize * 0.14
    let width = markSize + gap + wordBox.width
    let lockup = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(Int(width.rounded(.up))) \(Int(markSize.rounded(.up)))\">"
        + svgParts(loopM(cocoa, width: 110), transform: "scale(\(markSize / 1000))")
        + "<path transform=\"translate(\(markSize + gap - wordBox.minX) \((markSize - wordBox.height) / 2 - wordBox.minY))\" d=\"\(svgData(word))\" fill=\"\(cocoa.hex)\"/></svg>\n"
    write(Data(lockup.utf8), "marracat-m-lockup.svg")
}

// Review sheet: both icon colourways, the mark on cream, and the lockup.
write(png(width: 2400, height: 1400, background: cream) { ctx in
    for (i, c) in colorways.enumerated() {
        let r = CGRect(x: 120 + CGFloat(i) * 760, y: 170, width: 640, height: 640)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 144, cornerHeight: 144, transform: nil))
        ctx.clip()
        drawIcon(ctx, r, c)
        ctx.restoreGState()
        fillPath(wordPath(c.name, size: 44, weight: .semibold), cocoa, in: ctx, at: CGPoint(x: r.minX, y: 70))
    }
    draw(loopM(cocoa), in: ctx, rect: CGRect(x: 1640, y: 170, width: 640, height: 640))
    fillPath(wordPath("Mark on light", size: 44, weight: .semibold), cocoa, in: ctx, at: CGPoint(x: 1640, y: 70))

    let scale: CGFloat = 0.9
    let markSize = wordBox.height * 1.5 * scale
    let lockW = markSize * 1.14 + wordBox.width * scale
    let lx = (2400 - lockW) / 2, ly: CGFloat = 960
    draw(loopM(cocoa, width: 110), in: ctx, rect: CGRect(x: lx, y: ly, width: markSize, height: markSize))
    ctx.saveGState()
    ctx.translateBy(x: lx + markSize * 1.14, y: ly + (markSize - wordBox.height * scale) / 2)
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: -wordBox.minX, y: -wordBox.minY)
    ctx.addPath(word); ctx.setFillColor(cocoa.cg); ctx.fillPath()
    ctx.restoreGState()
}, "m-sheet.png")

print("wrote \(concepts.count) concepts + the Marracat M to \(outDir.path)")
