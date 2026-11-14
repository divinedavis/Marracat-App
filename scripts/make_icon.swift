// Renders the 1024px app icon: a gold shopping-bag "M" on a cocoa gradient.
// Usage: swift scripts/make_icon.swift Marracat/Assets.xcassets/AppIcon.appiconset/icon-1024.png
// Then flatten it — App Store rejects icons with an alpha channel:
//   sips -s format jpeg Marracat/Assets.xcassets/AppIcon.appiconset/icon-1024.png --out /tmp/i.jpg && sips -s format png /tmp/i.jpg --out Marracat/Assets.xcassets/AppIcon.appiconset/icon-1024.png
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let rect = NSRect(x: 0, y: 0, width: size, height: size)

let cocoa = NSColor(red: 0.23, green: 0.14, blue: 0.09, alpha: 1)
let amber = NSColor(red: 0.62, green: 0.38, blue: 0.16, alpha: 1)
NSGradient(starting: amber, ending: cocoa)!.draw(in: rect, angle: -90)

let gold = NSColor(red: 1.0, green: 0.82, blue: 0.25, alpha: 1)
gold.setStroke()

// Bag handle.
let handle = NSBezierPath()
handle.appendArc(withCenter: NSPoint(x: 512, y: 640), radius: 130, startAngle: 0, endAngle: 180)
handle.lineWidth = 44
handle.lineCapStyle = .round
handle.stroke()

// Bag body as a rounded square.
let body = NSBezierPath(roundedRect: NSRect(x: 262, y: 200, width: 500, height: 440), xRadius: 70, yRadius: 70)
gold.setFill()
body.fill()

// The "M" cut into the bag.
let para = NSMutableParagraphStyle()
para.alignment = .center
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 330, weight: .black),
    .foregroundColor: cocoa,
    .paragraphStyle: para,
]
NSAttributedString(string: "M", attributes: attrs).draw(in: NSRect(x: 262, y: 222, width: 500, height: 400))

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
