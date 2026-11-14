// The website wordmark matches LaunchAnimationView: Futura-Medium, uppercase,
// tracking = font size * 0.14. Outlines keep the exact face on every browser.
// Run from the project root: swift web/scripts/make_wordmark.swift web/public/logo.svg
import AppKit
import CoreText

let font = CTFontCreateWithName("Futura-Medium" as CFString, 100, nil)
guard CTFontCopyPostScriptName(font) as String == "Futura-Medium" else {
    fatalError("Futura-Medium must be installed to regenerate the Marracat wordmark")
}
let text = NSAttributedString(string: "MARRACAT", attributes: [.font: font, .kern: 14])
let line = CTLineCreateWithAttributedString(text)
let outline = CGMutablePath()
for run in CTLineGetGlyphRuns(line) as! [CTRun] {
    let count = CTRunGetGlyphCount(run)
    var glyphs = [CGGlyph](repeating: 0, count: count)
    var positions = [CGPoint](repeating: .zero, count: count)
    CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
    CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
    for i in 0..<count {
        guard let path = CTFontCreatePathForGlyph(font, glyphs[i], nil) else { continue }
        outline.addPath(path, transform: CGAffineTransform(translationX: positions[i].x, y: 0).scaledBy(x: 1, y: -1))
    }
}
let box = outline.boundingBoxOfPath
var placement = CGAffineTransform(translationX: -box.minX, y: -box.minY)
let path = outline.copy(using: &placement)!
func n(_ value: CGFloat) -> String { String(format: "%.3f", Double(value)) }
func point(_ p: CGPoint) -> String { "\(n(p.x)) \(n(p.y))" }
var commands = [String]()
path.applyWithBlock { pointer in
    let element = pointer.pointee
    switch element.type {
    case .moveToPoint: commands.append("M\(point(element.points[0]))")
    case .addLineToPoint: commands.append("L\(point(element.points[0]))")
    case .addQuadCurveToPoint: commands.append("Q\(point(element.points[0])) \(point(element.points[1]))")
    case .addCurveToPoint: commands.append("C\(point(element.points[0])) \(point(element.points[1])) \(point(element.points[2]))")
    case .closeSubpath: commands.append("Z")
    @unknown default: fatalError("Unsupported glyph outline")
    }
}
let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(n(box.width)) \(n(box.height))\"><title>MARRACAT</title><path fill=\"#161616\" d=\"\(commands.joined())\"/></svg>\n"
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "web/public/logo.svg"
try svg.write(toFile: output, atomically: true, encoding: .utf8)
print("Wrote Futura-Medium MARRACAT wordmark to \(output)")
