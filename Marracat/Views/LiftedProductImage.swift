import SwiftUI
import UIKit
import Vision
import CoreImage
import CryptoKit

/// A product lifted off its photo's background and set straight on what's
/// behind it: Home's event tiles show the product on the event's own colours,
/// not in a white box (owner, 2026-11-28, from a recording of another shop's
/// deal tiles: "use the … background behind the images"). The lift is Vision's
/// subject mask, worked out on the phone, once per photo, and kept on disk.
/// A photo it can't lift cleanly keeps today's white box.
struct LiftedProductImage: View {
    let url: String?
    var width: Int = 800
    /// The light behind the product, in the tile's own colour.
    var glow: Color

    @State private var lifted: UIImage?
    @State private var boxed = false

    var body: some View {
        ZStack {
            // A soft pool of the tile's colour where the product stands.
            RadialGradient(colors: [glow.opacity(0.55), glow.opacity(0)], center: .center, startRadius: 0, endRadius: 170)
                .opacity(boxed ? 0 : 1)
            if let lifted {
                Image(uiImage: lifted)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .shadow(color: .black.opacity(0.35), radius: 10, x: 0, y: 8)
                    .padding(22)
                    .transition(.opacity)
            } else if boxed {
                // The product on white, as the brand shot it.
                Color.white
                    .overlay { RemoteImage(url: url, width: width).padding(14) }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .transition(.opacity)
            }
        }
        .task(id: url) {
            if let hit = SubjectLift.cached(url, width: width) { lifted = hit; boxed = false; return }
            lifted = nil
            boxed = false
            let found = await SubjectLift.lift(url, width: width)
            if Task.isCancelled { return }
            withAnimation(.easeOut(duration: 0.2)) {
                lifted = found
                boxed = found == nil
            }
        }
    }
}

/// Lifts a product off its photo's background (Vision's subject mask).
@MainActor
enum SubjectLift {
    private static let memory: NSCache<NSURL, UIImage> = {
        let c = NSCache<NSURL, UIImage>()
        c.totalCostLimit = 40 * 1024 * 1024
        return c
    }()
    /// Photos already found not to lift: their tile keeps the white box.
    private static var unliftable = Set<URL>()
    private static var running: [URL: Task<UIImage?, Never>] = [:]

    nonisolated static let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LiftedPhotos", isDirectory: true)
    /// Kept files past this many: the folder is emptied and starts again.
    nonisolated static let keep = 300

    static func cached(_ url: String?, width: Int) -> UIImage? {
        guard let u = sizedImageURL(url, width: width) else { return nil }
        return memory.object(forKey: u as NSURL)
    }

    /// The product without its background, or nil when it can't be lifted
    /// cleanly: no subject found, too small a subject, or nothing taken away
    /// (a photo that's all subject, or all scene).
    static func lift(_ url: String?, width: Int) async -> UIImage? {
        guard let u = sizedImageURL(url, width: width), !unliftable.contains(u) else { return nil }
        if let hit = memory.object(forKey: u as NSURL) { return hit }
        if let running = running[u] { return await running.value }
        let task = Task<UIImage?, Never> {
            let file = file(for: u)
            let none = file.appendingPathExtension("none")
            let fromDisk = await Task.detached(priority: .userInitiated) { () -> (UIImage?, Bool) in
                if FileManager.default.fileExists(atPath: none.path) { return (nil, true) }
                return (UIImage(contentsOfFile: file.path).map { $0.preparingForDisplay() ?? $0 }, false)
            }.value
            if fromDisk.1 { return nil }
            if let image = fromDisk.0 { return image }
            guard let photo = await ImageLoader.shared.load(u), let cg = photo.cgImage else { return nil }
            return await Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard let cut = cutOut(cg) else {
                    FileManager.default.createFile(atPath: none.path, contents: Data())
                    return nil
                }
                let image = UIImage(cgImage: cut)
                save(image, to: file)
                return image.preparingForDisplay() ?? image
            }.value
        }
        running[u] = task
        let image = await task.value
        running[u] = nil
        if let image {
            memory.setObject(image, forKey: u as NSURL, cost: Int(image.size.width * image.size.height * image.scale * image.scale) * 4)
        } else {
            unliftable.insert(u)
        }
        return image
    }

    /// The lift is worth showing: the subject is a real part of the photo, and
    /// enough background went that the product reads on the tile.
    nonisolated static func usable(coverage: Double) -> Bool { coverage >= 0.04 && coverage <= 0.9 }

    nonisolated static func file(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(String(digest.prefix(32)) + ".png")
    }

    /// The subject on a clear background, cropped to it; nil when Vision finds
    /// none (the simulator can't run the model) or the lift isn't `usable`.
    nonisolated static func cutOut(_ photo: CGImage) -> CGImage? {
        let handler = VNImageRequestHandler(cgImage: photo)
        let request = VNGenerateForegroundInstanceMaskRequest()
        guard (try? handler.perform([request])) != nil, let found = request.results?.first,
              !found.allInstances.isEmpty else { return nil }
        guard let mask = try? found.generateScaledMaskForImage(forInstances: found.allInstances, from: handler),
              usable(coverage: coverage(of: mask)),
              let cut = try? found.generateMaskedImage(ofInstances: found.allInstances, from: handler, croppedToInstancesExtent: true)
        else { return nil }
        let image = CIImage(cvPixelBuffer: cut)
        return context.createCGImage(image, from: image.extent)
    }

    private nonisolated(unsafe) static let context = CIContext()

    /// The share of the photo the subject covers, from Vision's mask.
    nonisolated static func coverage(of mask: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask) else { return 0 }
        let w = CVPixelBufferGetWidth(mask), h = CVPixelBufferGetHeight(mask), row = CVPixelBufferGetBytesPerRow(mask)
        guard w > 0, h > 0 else { return 0 }
        var on = 0, seen = 0
        // Every fourth pixel each way: plenty for a share.
        for y in stride(from: 0, to: h, by: 4) {
            let line = base.advanced(by: y * row).assumingMemoryBound(to: Float32.self)
            for x in stride(from: 0, to: w, by: 4) {
                seen += 1
                if line[x] > 0.5 { on += 1 }
            }
        }
        return seen == 0 ? 0 : Double(on) / Double(seen)
    }

    private nonisolated static func save(_ image: UIImage, to file: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        if let count = try? fm.contentsOfDirectory(atPath: folder.path).count, count > keep {
            try? fm.removeItem(at: folder)
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try? image.pngData()?.write(to: file, options: .atomic)
    }
}
