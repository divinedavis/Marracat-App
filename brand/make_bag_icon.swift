// Marracat app icon: a white carrier-bag ground with the MARRACAT wordmark
// nearly edge to edge (the user dropped the cord handle, 2026-09-11).
// Writes an opaque 1024px PNG (App Store rejects an alpha channel) and an
// optional home-screen preview with the iOS corner mask on a dark ground.
//
//   swift brand/make_bag_icon.swift <icon-1024.png> [preview.png]
import AppKit
import CoreText

let args = CommandLine.arguments
let iconOut = args.count > 1 ? args[1] : "icon-1024.png"
let previewOut = args.count > 2 ? args[2] : nil
let S: CGFloat = 1024

func context(_ w: Int, _ h: Int) -> CGContext {
    let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    c.translateBy(x: 0, y: CGFloat(h))
    c.scaleBy(x: 1, y: -1)   // y down, like the rest of brand/
    return c
}

func gray(_ v: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(gray: v, alpha: a) }

/// Glyph outlines for `text`, flipped into y-down space, origin at the top-left of the line.
func wordPath(_ text: String, font: CTFont, tracking: CGFloat) -> CGPath {
    let attr = NSAttributedString(string: text, attributes: [.font: font, .kern: tracking])
    let line = CTLineCreateWithAttributedString(attr)
    let ascent = CTFontGetAscent(font)
    let out = CGMutablePath()
    for run in CTLineGetGlyphRuns(line) as! [CTRun] {
        let n = CTRunGetGlyphCount(run)
        var glyphs = [CGGlyph](repeating: 0, count: n)
        var pos = [CGPoint](repeating: .zero, count: n)
        CTRunGetGlyphs(run, CFRange(location: 0, length: n), &glyphs)
        CTRunGetPositions(run, CFRange(location: 0, length: n), &pos)
        for i in 0..<n {
            guard let g = CTFontCreatePathForGlyph(font, glyphs[i], nil) else { continue }
            out.addPath(g, transform: CGAffineTransform(translationX: pos[i].x, y: ascent).scaledBy(x: 1, y: -1))
        }
    }
    return out
}

func drawIcon(in c: CGContext, origin: CGPoint, scale s: CGFloat) {
    c.saveGState()
    c.translateBy(x: origin.x, y: origin.y)
    c.scaleBy(x: s, y: s)
    let full = CGRect(x: 0, y: 0, width: S, height: S)

    // Paper: white at the top falling to a soft light grey, like a lit carrier bag.
    let paper = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                           colors: [gray(1.0), gray(0.955), gray(0.90)] as CFArray,
                           locations: [0, 0.55, 1])!
    c.drawLinearGradient(paper, start: CGPoint(x: S / 2, y: 0), end: CGPoint(x: S / 2, y: S), options: [])
    // A faint side shade gives the bag its fold.
    let side = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                          colors: [gray(0, 0.05), gray(0, 0), gray(0, 0), gray(0, 0.05)] as CFArray,
                          locations: [0, 0.18, 0.82, 1])!
    c.drawLinearGradient(side, start: CGPoint(x: 0, y: S / 2), end: CGPoint(x: S, y: S / 2), options: [])

    // No handle (the user asked for it off): the wordmark is the whole mark.
    // Black capitals, evenly tracked, ~86% of the width — nearly edge to edge,
    // with a small margin inside the iOS corner mask — centred in the icon.
    let font = CTFontCreateWithName("Futura-Medium" as CFString, 140, nil)
    var word = wordPath("MARRACAT", font: font, tracking: 22)
    var box = word.boundingBoxOfPath
    let target = S * 0.86
    var t = CGAffineTransform(scaleX: target / box.width, y: target / box.width)
    word = word.copy(using: &t)!
    box = word.boundingBoxOfPath
    var place = CGAffineTransform(translationX: (S - box.width) / 2 - box.minX, y: S * 0.5 - box.midY)
    word = word.copy(using: &place)!
    c.addPath(word)
    c.setFillColor(gray(0.06))
    c.fillPath()

    _ = full
    c.restoreGState()
}

func save(_ c: CGContext, _ path: String) {
    let data = NSBitmapImageRep(cgImage: c.makeImage()!).representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

let icon = context(Int(S), Int(S))
drawIcon(in: icon, origin: .zero, scale: 1)
save(icon, iconOut)

if let previewOut {
    // Home-screen preview: the iOS squircle-ish mask on a dark wallpaper.
    let W = 700, pad: CGFloat = 110
    let p = context(W, W)
    p.setFillColor(CGColor(red: 0.20, green: 0.14, blue: 0.09, alpha: 1))
    p.fill(CGRect(x: 0, y: 0, width: W, height: W))
    let side = CGFloat(W) - pad * 2
    let r = CGRect(x: pad, y: pad, width: side, height: side)
    p.saveGState()
    p.addPath(CGPath(roundedRect: r, cornerWidth: side * 0.2237, cornerHeight: side * 0.2237, transform: nil))
    p.clip()
    drawIcon(in: p, origin: r.origin, scale: side / S)
    p.restoreGState()
    save(p, previewOut)
}
