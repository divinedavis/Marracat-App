import Accelerate
import AppleArchive
import CoreML
import Foundation
import System
import os

/// Products and phrases as points in one "meaning" space (Apple's MobileCLIP2),
/// so the app can find what a shopper means rather than the words they used
/// (owner, 2026-10-02). The Mac reads every product's title and photo into a
/// vector (catalog/embed_products.py); the iPhone runs the model's text half
/// on the Neural Engine (v5) for what's typed, and compares it with all of them.
///
/// Both pieces are downloaded from marracat.com when first needed, not shipped
/// in the app (the model is ~120 MB, the vectors ~40 MB). Until they're here,
/// every feature built on this simply doesn't show.
///
/// MobileCLIP2-S4 since 2026-10-24 (owner: "switch to s4"): on 13,385 products
/// it put 59% of an aisle's products in the top 10 against S0's 45%, and 74%
/// of shopper searches' top 10 were judged relevant against 67%
/// (catalog/research/2026-10-24-embedding-eval). S4 has its own files
/// (product-vectors-v2, text model v4/v5); builds before it keep S0's v1-v3.
final class MeaningIndex: @unchecked Sendable {
    static let shared = MeaningIndex()

    static let vectorsURL = URL(string: "https://marracat.com/ml/product-vectors-v2.bin")!
    private static let vectorsFile = "product-vectors-v2.bin"
    /// What S0 builds left on the phone, removed once S4's files are in use.
    private static let retired = ["product-vectors-v1.bin", "MobileCLIPText.mlmodelc", "MobileCLIPText-v2.mlmodelc", "MobileCLIPText-v3.mlmodelc"]
    /// v5 runs on the Neural Engine: S4's int8 weights with 16-bit compute,
    /// pinned to CPU + Neural Engine (`.all` sent S0's to the GPU), as S0's v3
    /// did. On an M5 it matches v4 at cosine 0.99998. Every load checks it
    /// against the phrase v4 embedded (probeReference) and falls back to v4
    /// if it ever disagrees.
    static let modelURL = URL(string: "https://marracat.com/ml/mobileclip-text-v5.aar")!
    private static let modelFolder = "MobileCLIPText-v5.mlmodelc"
    /// v4: the same int8 weights computed in 32-bit floats, on the GPU or CPU.
    static let fallbackModelURL = URL(string: "https://marracat.com/ml/mobileclip-text-v4.aar")!
    private static let fallbackFolder = "MobileCLIPText-v4.mlmodelc"
    private static let log = Logger(subsystem: "com.divinedavis.marracat", category: "meaning")

    struct Vectors {
        let dims: Int, modelDims: Int
        let mean: [Float]                 // modelDims
        let projection: [Float]           // modelDims x dims, row-major
        let scale: [Float]                // per product
        /// How close each product sits to shopping phrases in general
        /// (catalog/embed_products.py); ranking subtracts hubWeight x this.
        let hub: [Float]
        let ids: [String]
        let rows: [Int8]                  // count x dims
        let indexByID: [String: Int]

        /// Which space these vectors live in: changes only if the projection
        /// does, so a stored vector made in another space can be remade.
        var space: String {
            let probe = projection.prefix(64) + mean.prefix(16)
            return String(format: "%08x", probe.reduce(into: UInt32(2166136261)) { h, x in h = (h ^ x.bitPattern) &* 16777619 })
        }
    }

    /// The current space (see Vectors.space), or nil before the vectors load.
    var space: String? { lock.withLock { vectors?.space } }

    private let lock = NSLock()
    private var vectors: Vectors?
    private var model: MLModel?
    private var tokenizer: CLIPTokenizer?
    private var preparing: Task<Bool, Never>?
    private var modelURLOnDisk: URL?

    var isReady: Bool { lock.withLock { vectors != nil && model != nil } }
    /// Tests load a vectors file directly (the app downloads it).
    func installForTesting(_ v: Vectors) { lock.withLock { vectors = v } }
    var hasVectors: Bool { lock.withLock { vectors != nil } }

    private static var folder: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Meaning", isDirectory: true)
    }

    // MARK: Getting ready

    /// Loads what's on disk and downloads what isn't. Safe to call often.
    @discardableResult
    func prepare(download: Bool = true) async -> Bool {
        if isReady { return true }
        // UI tests never fetch ~92 MB, nor use files a manual run left on the
        // simulator: features built on this just don't show, the same on
        // every machine.
        guard Self.allowed else { return false }
        let task: Task<Bool, Never> = lock.withLock {
            if let preparing { return preparing }
            let t = Task.detached(priority: .utility) { await self.load(download: download) }
            preparing = t
            return t
        }
        let ok = await task.value
        lock.withLock { preparing = nil }
        return ok
    }

    /// -ALLOW_MEANING: the recorded marketing tour (TikTokTourUITests) and
    /// Home's launch test show the AI features on a reset simulator.
    private static var allowed: Bool {
        let args = ProcessInfo.processInfo.arguments
        return !(args.contains("-UITEST_RESET") || args.contains("-OFFLINE_CATALOG")) || args.contains("-ALLOW_MEANING")
    }

    /// Everything `prepare` reads is already on this phone: it needs no
    /// download. Home's Shop by style row holds its place, and the launch
    /// cover waits for its boards, only then (HomeSettle).
    static var onDisk: Bool {
        guard allowed, let folder else { return false }
        let fm = FileManager.default
        return fm.fileExists(atPath: folder.appendingPathComponent(Self.vectorsFile).path)
            && (fm.fileExists(atPath: folder.appendingPathComponent(modelFolder).path)
                || fm.fileExists(atPath: folder.appendingPathComponent(fallbackFolder).path))
    }

    /// Only the product vectors, from disk, without waiting on the model:
    /// all Home's taste row needs. On a launch with no saved row it fills
    /// the row's held place a few seconds sooner than `prepare` would.
    @discardableResult
    func loadVectors() async -> Bool {
        if hasVectors { return true }
        guard Self.allowed, let folder = Self.folder else { return false }
        return await Task.detached(priority: .userInitiated) {
            if self.hasVectors { return true }
            guard let v = Self.readVectors(folder.appendingPathComponent(Self.vectorsFile)) else { return false }
            self.lock.withLock { if self.vectors == nil { self.vectors = v } }
            return true
        }.value
    }

    private func load(download: Bool) async -> Bool {
        guard let folder = Self.folder else { return false }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let vectorFile = folder.appendingPathComponent(Self.vectorsFile)
        let modelDir = folder.appendingPathComponent(Self.modelFolder)
        let fallbackDir = folder.appendingPathComponent(Self.fallbackFolder)
        for old in Self.retired { try? FileManager.default.removeItem(at: folder.appendingPathComponent(old)) }
        if download {
            if !FileManager.default.fileExists(atPath: vectorFile.path) { await Self.fetch(Self.vectorsURL, to: vectorFile) }
            if !FileManager.default.fileExists(atPath: modelDir.path) { await Self.fetchModel(Self.modelURL, into: folder, as: Self.modelFolder) }
        }
        if !hasVectors, let v = Self.readVectors(vectorFile) { lock.withLock { vectors = v } }
        if lock.withLock({ tokenizer == nil }), let t = CLIPTokenizer() { lock.withLock { tokenizer = t } }
        if lock.withLock({ model == nil }), let tokenizer = lock.withLock({ self.tokenizer }) {
            if FileManager.default.fileExists(atPath: modelDir.path),
               let m = Self.loadModel(modelDir, units: .cpuAndNeuralEngine),
               Self.probeOK(Self.rawEmbedding(m, tokenizer, Self.probePhrase)) {
                lock.withLock { model = m; modelURLOnDisk = modelDir }
                try? FileManager.default.removeItem(at: fallbackDir)   // ~120 MB no longer needed
            } else {
                if FileManager.default.fileExists(atPath: modelDir.path) { Self.log.error("meaning: v5 failed its probe; using v4") }
                if download, !FileManager.default.fileExists(atPath: fallbackDir.path) {
                    await Self.fetchModel(Self.fallbackModelURL, into: folder, as: Self.fallbackFolder)
                }
                if FileManager.default.fileExists(atPath: fallbackDir.path), let m = Self.loadModel(fallbackDir, units: .all) {
                    lock.withLock { model = m; modelURLOnDisk = fallbackDir }
                }
            }
        }
        Self.log.info("meaning: vectors \(self.hasVectors), model \(self.lock.withLock { self.model != nil })")
        return isReady
    }

    /// The published vectors change with the catalog: refetched when the
    /// server has a newer copy (the background refresh calls this).
    func refreshVectors() async {
        guard let folder = Self.folder else { return }
        let file = folder.appendingPathComponent(Self.vectorsFile)
        if await Self.fetch(Self.vectorsURL, to: file, onlyIfNewer: true), let v = Self.readVectors(file) {
            lock.withLock { vectors = v }
        }
    }

    @discardableResult
    private static func fetch(_ url: URL, to file: URL, onlyIfNewer: Bool = false) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        request.allowsConstrainedNetworkAccess = false   // not on Low Data Mode
        let etagKey = "meaning.etag." + url.lastPathComponent
        if onlyIfNewer, let tag = UserDefaults.standard.string(forKey: etagKey) {
            request.setValue(tag, forHTTPHeaderField: "If-None-Match")
        }
        guard let (tmp, response) = try? await URLSession.shared.download(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }
        try? FileManager.default.removeItem(at: file)
        guard (try? FileManager.default.moveItem(at: tmp, to: file)) != nil else { return false }
        if let tag = http.value(forHTTPHeaderField: "ETag") { UserDefaults.standard.set(tag, forKey: etagKey) }
        return true
    }

    private static func loadModel(_ dir: URL, units: MLComputeUnits) -> MLModel? {
        let config = MLModelConfiguration()
        config.computeUnits = units
        return try? MLModel(contentsOf: dir, configuration: config)
    }

    /// The compiled model arrives as an Apple Archive and is unpacked in place.
    private static func fetchModel(_ url: URL, into folder: URL, as folderName: String) async {
        let archive = folder.appendingPathComponent("model.aar")
        guard await fetch(url, to: archive) else { return }
        defer { try? FileManager.default.removeItem(at: archive) }
        let staging = folder.appendingPathComponent("model-staging", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        guard let read = ArchiveByteStream.fileStream(path: FilePath(archive.path), mode: .readOnly, options: [],
                                                      permissions: FilePermissions(rawValue: 0o644)),
              let decompress = ArchiveByteStream.decompressionStream(readingFrom: read),
              let decode = ArchiveStream.decodeStream(readingFrom: decompress),
              let extract = ArchiveStream.extractStream(extractingTo: FilePath(staging.path),
                                                        flags: [.ignoreOperationNotPermitted]) else { return }
        defer { try? extract.close(); try? decode.close(); try? decompress.close(); try? read.close() }
        guard (try? ArchiveStream.process(readingFrom: decode, writingTo: extract)) != nil else { return }
        let unpacked = staging.appendingPathComponent("MobileCLIPText.mlmodelc")
        guard FileManager.default.fileExists(atPath: unpacked.path) else { return }
        let target = folder.appendingPathComponent(folderName)
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.moveItem(at: unpacked, to: target)
        try? FileManager.default.removeItem(at: staging)
    }

    static func readVectors(_ file: URL) -> Vectors? {
        guard let data = try? Data(contentsOf: file, options: .alwaysMapped) else { return nil }
        return parseVectors(data)
    }

    /// See catalog/embed_products.py for the layout.
    static func parseVectors(_ data: Data) -> Vectors? {
        data.withUnsafeBytes { raw -> Vectors? in
            var at = 0
            func u32() -> Int? {
                guard at + 4 <= raw.count else { return nil }
                defer { at += 4 }
                return Int(raw.loadUnaligned(fromByteOffset: at, as: UInt32.self).littleEndian)
            }
            func floats(_ n: Int) -> [Float]? {
                guard at + n * 4 <= raw.count else { return nil }
                defer { at += n * 4 }
                return (0..<n).map { Float(bitPattern: raw.loadUnaligned(fromByteOffset: at + $0 * 4, as: UInt32.self).littleEndian) }
            }
            guard raw.count > 20, String(decoding: raw[0..<4], as: UTF8.self) == "MRV1" else { return nil }
            at = 4
            guard let version = u32(), version == 1 || version == 2, let dims = u32(), let modelDims = u32(), let count = u32(),
                  dims > 0, modelDims >= dims, count > 0,
                  let mean = floats(modelDims), let projection = floats(modelDims * dims), let scale = floats(count),
                  let hub = version == 2 ? floats(count) : [Float](repeating: 0, count: count) else { return nil }
            var ids: [String] = []
            ids.reserveCapacity(count)
            for _ in 0..<count {
                guard let n = u32(), at + n <= raw.count else { return nil }
                ids.append(String(decoding: raw[at..<(at + n)], as: UTF8.self))
                at += n
            }
            guard at + count * dims == raw.count else { return nil }
            let start = at
            let rows = [Int8](unsafeUninitializedCapacity: count * dims) { buffer, filled in
                UnsafeMutableRawBufferPointer(buffer).copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[start..<(start + count * dims)]))
                filled = count * dims
            }
            return Vectors(dims: dims, modelDims: modelDims, mean: mean, projection: projection, scale: scale, hub: hub, ids: ids,
                           rows: rows, indexByID: Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a }))
        }
    }

    // MARK: Using it

    /// A phrase's place in the product space (unit length), or nil until ready.
    func embed(_ text: String) -> [Float]? {
        let (model, tokenizer, v) = lock.withLock { (self.model, self.tokenizer, self.vectors) }
        guard let model, let tokenizer, let v else { return nil }
        guard let input = Self.tokens(tokenizer, text), let e = Self.run(model, input), e.count == v.modelDims else { return nil }
        var raw = (0..<v.modelDims).map { e[$0].floatValue }
        // Never rank on NaN: a compute unit that overflows gets replaced by
        // the CPU for the rest of the session (the 16-bit model did this).
        if raw.contains(where: { $0.isNaN }) {
            Self.log.error("meaning: NaN from the model; switching to the CPU")
            let config = MLModelConfiguration(); config.computeUnits = .cpuOnly
            guard let url = lock.withLock({ modelURLOnDisk }), let cpu = try? MLModel(contentsOf: url, configuration: config),
                  let again = Self.run(cpu, input), again.count == v.modelDims else { return nil }
            lock.withLock { self.model = cpu }
            raw = (0..<v.modelDims).map { again[$0].floatValue }
            guard !raw.contains(where: { $0.isNaN }) else { return nil }
        }
        return Self.project(zip(raw, v.mean).map { $0 - $1 }, v)
    }

    private static func tokens(_ tokenizer: CLIPTokenizer, _ text: String) -> MLMultiArray? {
        let ids = tokenizer.tokens(text)
        guard let input = try? MLMultiArray(shape: [1, NSNumber(value: CLIPTokenizer.contextLength)], dataType: .int32) else { return nil }
        for (i, t) in ids.enumerated() { input[i] = NSNumber(value: t) }
        return input
    }

    /// A model output made elsewhere (unit length, before centring), placed
    /// in the product space: the style prompts the Mac embedded
    /// (ShopStyle.precomputed), with no model on the phone.
    func place(raw: [Float]) -> [Float]? {
        guard let v = lock.withLock({ vectors }), raw.count == v.modelDims, raw.allSatisfy(\.isFinite) else { return nil }
        return Self.project(zip(raw, v.mean).map { $0 - $1 }, v)
    }

    /// The model's own output for a phrase (unit length, before centring).
    private static func rawEmbedding(_ model: MLModel, _ tokenizer: CLIPTokenizer, _ text: String) -> [Float]? {
        guard let input = tokens(tokenizer, text), let e = run(model, input) else { return nil }
        return (0..<e.count).map { e[$0].floatValue }
    }

    // MARK: Load-time check

    static let probePhrase = "scented soy candle"
    /// v4's embedding of `probePhrase` on the CPU (float32, little-endian),
    /// MobileCLIP2-S4. v5 matched it at 0.99998 on an M5's Neural Engine; an
    /// unrelated phrase ("car tire") scores 0.63.
    static let probeReference: [Float] = {
        let data = Data(base64Encoded: "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") ?? Data()
        return data.withUnsafeBytes { raw in (0..<(raw.count / 4)).map { Float(bitPattern: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self).littleEndian) } }
    }()

    /// A model is used only if its probe embedding is finite and points
    /// where v4's does.
    static func probeOK(_ e: [Float]?, reference: [Float] = probeReference) -> Bool {
        guard let e, e.count == reference.count, !e.isEmpty, e.allSatisfy(\.isFinite) else { return false }
        return zip(e, reference).reduce(0) { $0 + $1.0 * $1.1 } >= 0.995
    }

    private static func run(_ model: MLModel, _ input: MLMultiArray) -> MLMultiArray? {
        (try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["tokens": input])))?
            .featureValue(for: "embedding")?.multiArrayValue
    }

    static func project(_ centred: [Float], _ v: Vectors) -> [Float] {
        var out = [Float](repeating: 0, count: v.dims)
        for i in 0..<v.modelDims where centred[i] != 0 {
            let x = centred[i], row = i * v.dims
            for j in 0..<v.dims { out[j] += x * v.projection[row + j] }
        }
        return normalized(out)
    }

    static func normalized(_ x: [Float]) -> [Float] {
        let n = sqrt(x.reduce(0) { $0 + $1 * $1 })
        return n > 0 ? x.map { $0 / n } : x
    }

    /// How much a product's closeness to every phrase counts against it. 0.5
    /// on the 2026-10-02 evaluation of 15 shopper queries (1.0 over-corrected).
    static let hubWeight: Float = 0.5

    /// A product's score against a query, as `nearest` ranks it.
    func score(_ query: [Float], productID: String) -> Float? {
        guard let v = lock.withLock({ vectors }), let i = v.indexByID[productID], query.count == v.dims else { return nil }
        let base = i * v.dims
        var dot: Float = 0
        for j in 0..<v.dims { dot += Float(v.rows[base + j]) * query[j] }
        return dot * v.scale[i] - Self.hubWeight * v.hub[i]
    }

    /// A product's vector (unit length), when it has one.
    func vector(for productID: String) -> [Float]? {
        guard let v = lock.withLock({ vectors }), let i = v.indexByID[productID] else { return nil }
        let base = i * v.dims, s = v.scale[i]
        return Self.normalized((0..<v.dims).map { Float(v.rows[base + $0]) * s })
    }

    /// Every product's score against `query`, as `score` computes one, with
    /// Accelerate: each block of int8 rows is widened to floats and multiplied
    /// by the query in one call, on one thread. The Swift loop this replaced
    /// took up to 8 cores per call, and Home's style boards called it once per
    /// style while the app was launching (2026-10-18).
    static func scores(_ query: [Float], _ v: Vectors) -> [Float] {
        let count = v.ids.count, dims = v.dims
        var out = [Float](repeating: 0, count: count)
        let block = min(count, 2048)
        var wide = [Float](repeating: 0, count: block * dims)
        v.rows.withUnsafeBufferPointer { rows in
            out.withUnsafeMutableBufferPointer { o in
                wide.withUnsafeMutableBufferPointer { w in
                    var start = 0
                    while start < count {
                        let n = min(block, count - start)
                        vDSP_vflt8(rows.baseAddress! + start * dims, 1, w.baseAddress!, 1, vDSP_Length(n * dims))
                        vDSP_mmul(w.baseAddress!, 1, query, 1, o.baseAddress! + start, 1, vDSP_Length(n), 1, vDSP_Length(dims))
                        start += n
                    }
                }
                // dot x scale - hubWeight x hub
                var weight = -hubWeight
                vDSP_vmul(o.baseAddress!, 1, v.scale, 1, o.baseAddress!, 1, vDSP_Length(count))
                vDSP_vsma(v.hub, 1, &weight, o.baseAddress!, 1, o.baseAddress!, 1, vDSP_Length(count))
            }
        }
        return out
    }

    /// The products nearest `query`, best first.
    func nearest(to query: [Float], limit: Int, where keep: ((String) -> Bool)? = nil) -> [(id: String, score: Float)] {
        guard let v = lock.withLock({ vectors }), query.count == v.dims, limit > 0 else { return [] }
        let count = v.ids.count
        let scores = Self.scores(query, v)
        // Only the leaders are ordered: everything at or above the score of the
        // `pool`-th best (found by a partial selection), then sorted. The
        // filter may reject some, so the pool is generous and grows if needed.
        var best: [(id: String, score: Float)] = []
        var pool = min(count, max(limit * 8, 256))
        var order: [Int] = []
        while true {
            let threshold = Self.nthLargest(scores, pool)
            order = (0..<count).filter { scores[$0] >= threshold }
            order.sort { scores[$0] > scores[$1] }
            let passing = keep.map { k in order.lazy.filter { k(v.ids[$0]) }.count } ?? order.count
            if passing >= limit || pool == count { break }
            pool = min(count, pool * 4)
        }
        for i in order {
            let id = v.ids[i]
            if let keep, !keep(id) { continue }
            best.append((id, scores[i]))
            if best.count == limit { break }
        }
        return best
    }

    /// The value of the `n`-th largest score (quickselect, average O(count)).
    static func nthLargest(_ values: [Float], _ n: Int) -> Float {
        guard n > 0, n <= values.count else { return values.min() ?? 0 }
        var a = values
        var lo = 0, hi = a.count - 1, target = n - 1
        while lo < hi {
            let pivot = a[(lo + hi) / 2]
            var i = lo, j = hi
            while i <= j {
                while a[i] > pivot { i += 1 }
                while a[j] < pivot { j -= 1 }
                if i <= j { a.swapAt(i, j); i += 1; j -= 1 }
            }
            if target <= j { hi = j } else if target >= i { lo = i } else { return a[target] }
        }
        return a[target]
    }

    /// The average direction of some products: a style, a taste, a session.
    func centroid(of productIDs: [String], weights: [Float]? = nil) -> [Float]? {
        var sum: [Float]?
        for (k, id) in productIDs.enumerated() {
            guard let x = vector(for: id) else { continue }
            let w = weights?[k] ?? 1
            sum = sum.map { s in zip(s, x).map { $0 + w * $1 } } ?? x.map { $0 * w }
        }
        return sum.map(Self.normalized)
    }
}
