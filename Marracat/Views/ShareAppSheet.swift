import SwiftUI
import CoreImage.CIFilterBuiltins
import Photos
import UIKit

/// You › Share Marracat (owner, 2026-11-16, "Marracat Share QR Alternatives"
/// #1, "Edge-to-edge sheet"): a QR code as wide as the sheet that opens
/// Marracat on the App Store, with Copy link, Share and Save under it.
/// Round dots and round finder eyes, the brand mark in the middle; error
/// correction H, so the mark covering the centre still scans.
enum AppQR {
    static let url = URL(string: "https://apps.apple.com/us/app/marracat/id6810905687")!

    /// The code's modules, row by row from the top, true = dark, without
    /// the quiet zone. nil only if Core Image can't make one.
    static func modules(for text: String = url.absoluteString) -> [[Bool]]? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "H"
        guard let image = filter.outputImage,
              let cg = CIContext().createCGImage(image, from: image.extent) else { return nil }
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 255, count: w * h)
        let drawn = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        // A bitmap context's first row in memory is the image's top row.
        let grid = (0..<h).map { y in (0..<w).map { x in px[y * w + x] < 128 } }
        let rows = grid.indices.filter { grid[$0].contains(true) }
        let cols = (0..<w).filter { x in grid.contains { $0[x] } }
        guard let r0 = rows.first, let r1 = rows.last, let c0 = cols.first, let c1 = cols.last, r1 - r0 == c1 - c0 else { return nil }
        return (r0...r1).map { y in (c0...c1).map { grid[y][$0] } }
    }

    /// The square left empty in the middle for the brand mark, in modules.
    static func holeSide(_ n: Int) -> Int { n >= 33 ? 9 : 7 }

    /// One of the three 7×7 finder squares (drawn as round eyes instead).
    static func inFinder(_ r: Int, _ c: Int, _ n: Int) -> Bool {
        (r < 7 && c < 7) || (r < 7 && c >= n - 7) || (r >= n - 7 && c < 7)
    }

    static func inHole(_ r: Int, _ c: Int, _ n: Int) -> Bool {
        let k = holeSide(n), a = (n - k) / 2
        return (a..<a + k).contains(r) && (a..<a + k).contains(c)
    }
}

/// The dotted code on white, with two modules of quiet zone around it.
struct AppQRCode: View {
    var modules: [[Bool]] = AppQR.modules() ?? []
    var ink: Color = .black
    private let quiet = 2.0

    var body: some View {
        let n = modules.count
        ZStack {
            Canvas { ctx, size in
                guard n > 0 else { return }
                let cell = size.width / (Double(n) + quiet * 2)
                let origin = quiet * cell
                for r in 0..<n {
                    for c in 0..<n where modules[r][c] && !AppQR.inFinder(r, c, n) && !AppQR.inHole(r, c, n) {
                        let d = cell * 0.84
                        let rect = CGRect(x: origin + Double(c) * cell + (cell - d) / 2,
                                          y: origin + Double(r) * cell + (cell - d) / 2, width: d, height: d)
                        ctx.fill(Path(ellipseIn: rect), with: .color(ink))
                    }
                }
                for (r, c) in [(0, 0), (0, n - 7), (n - 7, 0)] {
                    let center = CGPoint(x: origin + (Double(c) + 3.5) * cell, y: origin + (Double(r) + 3.5) * cell)
                    let ring = Path(ellipseIn: CGRect(x: center.x - 3 * cell, y: center.y - 3 * cell, width: 6 * cell, height: 6 * cell))
                    ctx.stroke(ring, with: .color(ink), lineWidth: cell)
                    ctx.fill(Path(ellipseIn: CGRect(x: center.x - 1.5 * cell, y: center.y - 1.5 * cell, width: 3 * cell, height: 3 * cell)), with: .color(ink))
                }
            }
            if n > 0 {
                GeometryReader { geo in
                    let cell = geo.size.width / (Double(n) + quiet * 2)
                    let side = (Double(AppQR.holeSide(n)) - 1.2) * cell
                    Image("BrandIcon").resizable().scaledToFill()
                        .frame(width: side, height: side)
                        .clipShape(RoundedRectangle(cornerRadius: side * 0.22, style: .continuous))
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .background(Color.white)
    }
}

struct ShareAppSheet: View {
    @State private var copied = false
    @State private var saved: Bool?
    @State private var height: CGFloat = 640
    private let paper = Color(red: 0.949, green: 0.949, blue: 0.957)   // #F2F2F4
    private let note = Color(red: 0.42, green: 0.42, blue: 0.44)       // #6C6C70

    var body: some View {
        VStack(spacing: 0) {
            Text("Get Marracat", comment: "Title of the Share Marracat sheet with the App Store QR code")
                .brandFont(.title3.bold())
                .padding(.top, 28)
            Text("Point a phone's camera here to open Marracat on the App Store.", comment: "Under the title of the Share Marracat QR sheet")
                .brandFont(.subheadline).foregroundStyle(note)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            AppQRCode()
                .padding(8)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .accessibilityElement()
                .accessibilityLabel(Text("QR code that opens Marracat on the App Store", comment: "VoiceOver label of the Share Marracat QR code"))
                .accessibilityAddTraits(.isImage)
                .accessibilityIdentifier("appQRCode")
                .padding(.top, 16)
            HStack(spacing: 10) {
                Button(action: copy) {
                    label(copied ? String(localized: "Copied", comment: "Share Marracat sheet: the link was copied")
                                 : String(localized: "Copy link", comment: "Share Marracat sheet button"),
                          copied ? "checkmark" : "doc.on.doc")
                }
                .accessibilityIdentifier("copyAppLink")
                ShareLink(item: AppQR.url,
                          subject: Text("Marracat", comment: "Subject when sharing the Marracat App Store link"),
                          message: Text("Get Marracat on the App Store", comment: "Message when sharing the Marracat App Store link")) {
                    label(String(localized: "Share", comment: "Share Marracat sheet button"), "square.and.arrow.up")
                }
                .simultaneousGesture(TapGesture().onEnded { Analytics.shared.track("share", ["kind": .string("app")]) })
                .accessibilityIdentifier("shareAppLink")
                Button(action: save) {
                    switch saved {
                    case true?: label(String(localized: "Saved", comment: "Share Marracat sheet: the QR image is in Photos"), "checkmark")
                    case false?: label(String(localized: "Not saved", comment: "Share Marracat sheet: Photos access was refused"), "exclamationmark.circle")
                    case nil: label(String(localized: "Save", comment: "Share Marracat sheet button: saves the QR code to Photos"), "arrow.down.to.line")
                    }
                }
                .accessibilityIdentifier("saveAppQR")
            }
            .buttonStyle(.plain)
            .padding(.top, 18)
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .frame(maxWidth: 440)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .frame(maxWidth: .infinity)
        .environment(\.colorScheme, .light)
        .presentationDetents([.height(height)])
        .presentationDragIndicator(.visible)
        .presentationBackground(paper)
        .presentationCornerRadius(34)
    }

    private func label(_ title: String, _ icon: String) -> some View {
        Label(title, systemImage: icon)
            .brandFont(.subheadline.weight(.semibold))
            .lineLimit(1).minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
    }

    private func copy() {
        UIPasteboard.general.url = AppQR.url
        Analytics.shared.track("share", ["kind": .string("app")])
        withAnimation(.snappy) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.snappy) { copied = false }
        }
    }

    /// The code on white, 1080 px square, into Photos (add-only access).
    private func save() {
        let renderer = ImageRenderer(content: AppQRCode().padding(40).background(Color.white).frame(width: 360, height: 360))
        renderer.scale = 3
        guard let image = renderer.uiImage else { saved = false; return }
        PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        } completionHandler: { ok, _ in
            Task { @MainActor in withAnimation(.snappy) { saved = ok } }
        }
    }
}
