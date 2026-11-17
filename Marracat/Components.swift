import CryptoKit
import ImageIO
import SafariServices
import SwiftUI

/// Loads and memory-caches product images, sharing in-flight downloads.
///
/// Replaces AsyncImage: in a lazy grid, AsyncImage's load is cancelled when a
/// cell scrolls away mid-download and the cell is left on its failure
/// placeholder for good — the "some images aren't loading" bug. Here the
/// download runs in a detached task that outlives the cell, lands in the
/// cache, and any cell that shows the URL later gets it immediately.
@MainActor
final class ImageLoader {
    static let shared = ImageLoader()
    private let cache = NSCache<NSURL, UIImage>()
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]

    // By bytes, not count: 500 full-size photos could hold hundreds of MB,
    // and iOS ends apps that hold that much once they're in the background.
    private init() { cache.totalCostLimit = Self.costLimit(physicalMemory: ProcessInfo.processInfo.physicalMemory) }

    /// The decoded-image budget for this device: a fortieth of its RAM, 96-256
    /// MB (2026-10-18). It was 160 MB everywhere, which is a lot on a 4 GB
    /// iPhone and little on a 16 GB iPad.
    nonisolated static func costLimit(physicalMemory: UInt64) -> Int {
        Int(min(max(physicalMemory / 40, 96 << 20), 256 << 20))
    }

    /// Memory warning: every decoded image goes; what's on screen is drawn
    /// already, and the rest reloads from disk or the URL cache.
    func shed() { cache.removeAllObjects() }

    func cached(_ url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }

    // --- the images Home opens on ------------------------------------------
    //
    // The hero carousel and brand circles are the first thing a cold launch
    // shows. Their files are kept on disk (a couple of dozen, pruned every
    // launch) so the splash can put them in memory before Home appears,
    // instead of Home opening on blank tiles while they download.

    private static let folder: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HomeImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    nonisolated private static func file(for url: URL) -> URL {
        let name = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(name)
    }

    /// The file this image was kept in on disk, if it was (Spotlight's
    /// thumbnails read it; they never download).
    nonisolated static func cachedFile(for url: URL) -> URL? {
        let f = file(for: url)
        return FileManager.default.fileExists(atPath: f.path) ? f : nil
    }

    /// Download (or read from disk) and decode, keeping the file on disk.
    /// `optional`: a prefetch nobody is waiting on, which Low Data Mode skips.
    nonisolated private static func fetch(_ url: URL, keep: Bool, optional: Bool = false) async -> UIImage? {
        let file = file(for: url)
        if let data = try? Data(contentsOf: file), let image = decode(data, for: url) {
            return image
        }
        var request = URLRequest(url: url)
        request.allowsConstrainedNetworkAccess = !optional
        for attempt in 0..<2 {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard ((response as? HTTPURLResponse)?.statusCode ?? 200) < 400,
                      let image = decode(data, for: url) else { return nil }
                if keep { try? data.write(to: file, options: .atomic) }
                return image
            } catch {
                if attempt == 0 { try? await Task.sleep(for: .milliseconds(400)) }
            }
        }
        return nil
    }

    /// Decoded here, off the main thread, straight to a bitmap no bigger than it
    /// is shown: ImageIO's thumbnail decode reads only what that size needs.
    /// The size is the URL's `width` (Shopify) or its `#w=` fragment (others);
    /// twice it bounds the long side, so a tall photo still fills its width.
    nonisolated static func decode(_ data: Data, for url: URL) -> UIImage? {
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let width = comps?.queryItems?.first { $0.name == "width" }?.value.flatMap(Int.init)
            ?? comps?.fragment.flatMap { $0.hasPrefix("w=") ? Int($0.dropFirst(2)) : nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(width ?? 1200, 64) * 2, 4096),
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return UIImage(data: data).map { $0.preparingForDisplay() ?? $0 }
        }
        return UIImage(cgImage: cg)
    }

    /// Put these in memory now, from disk where they're kept, and keep them on
    /// disk for the next launch. Gives up at `limit` so a slow network can't
    /// hold the launch; anything unfinished carries on loading in the background.
    func warm(_ urls: [URL], limit: Duration) async {
        let work = Task {
            await withTaskGroup(of: Void.self) { group in
                for url in urls where cached(url) == nil {
                    group.addTask { _ = await self.load(url, keep: true) }
                }
            }
        }
        // Whichever comes first: all loaded, or out of time.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let once = ResumeOnce(done)
            Task { await work.value; once.resume() }
            Task { try? await Task.sleep(for: limit); once.resume() }
        }
    }

    /// Save these to disk, at low priority, for a launch that hasn't happened
    /// yet. They don't go into memory.
    /// Skipped in Low Power Mode or when the phone is hot (DeviceBudget), and
    /// on Low Data Mode: the next launch loads these as it always could.
    func keepForLater(_ urls: [URL]) async {
        guard DeviceBudget.allowsOptionalWork else { return }
        await withTaskGroup(of: Void.self) { group in
            for url in urls where !FileManager.default.fileExists(atPath: Self.file(for: url).path) {
                group.addTask(priority: .background) { _ = await Self.fetch(url, keep: true, optional: true) }
            }
        }
    }

    /// Delete every kept file that isn't one of these.
    func prune(keeping urls: [URL]) {
        let keep = Set(urls.map { Self.file(for: $0).lastPathComponent })
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? []
        for f in files where !keep.contains(f.lastPathComponent) { try? FileManager.default.removeItem(at: f) }
    }

    func load(_ url: URL) async -> UIImage? { await load(url, keep: false) }

    func load(_ url: URL, keep: Bool) async -> UIImage? {
        if let hit = cached(url) { return hit }
        if let running = inFlight[url] { return await running.value }
        let task = Task.detached(priority: .userInitiated) { () -> UIImage? in
            await Self.fetch(url, keep: keep)
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        store(image, for: url)
        return image
    }

    private func store(_ image: UIImage?, for url: URL) {
        guard let image else { return }
        let cost = Int(image.size.width * image.scale * image.size.height * image.scale) * 4
        cache.setObject(image, forKey: url as NSURL, cost: cost)
    }

    /// Start the photos of the tiles about to scroll in, at low priority and
    /// on whatever cores are free, so they're decoded before they're on screen.
    func prefetch(_ urls: [URL]) {
        for url in urls where cached(url) == nil && inFlight[url] == nil {
            let task = Task.detached(priority: .utility) { await Self.fetch(url, keep: false) }
            inFlight[url] = task
            Task {
                let image = await task.value
                inFlight[url] = nil
                store(image, for: url)
            }
        }
    }

    /// The next `count` products' photos after `index`, at `width`.
    func prefetch(after index: Int, in products: [Product], width: Int, count: Int = 8) {
        guard index + 1 < products.count else { return }
        prefetch(products[(index + 1)..<min(index + 1 + count, products.count)]
            .compactMap { sizedImageURL($0.images.first, width: width) })
    }
}

/// Resumes a continuation the first time it's asked to, and ignores the rest.
@MainActor
private final class ResumeOnce {
    private var continuation: CheckedContinuation<Void, Never>?
    init(_ c: CheckedContinuation<Void, Never>) { continuation = c }
    func resume() { continuation?.resume(); continuation = nil }
}

struct RemoteImage: View {
    let url: String?
    var width: Int = 400
    var contentMode: ContentMode = .fit
    @State private var image: UIImage?
    @State private var failed = false

    init(url: String?, width: Int = 400, contentMode: ContentMode = .fit) {
        self.url = url
        self.width = width
        self.contentMode = contentMode
        // An image already in memory is on screen from the first frame, not
        // one frame later from the task below.
        _image = State(initialValue: sizedImageURL(url, width: width).flatMap { ImageLoader.shared.cached($0) })
    }

    private var resolved: URL? { sizedImageURL(url, width: width) }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else if failed {
                Image(systemName: "photo").font(.title2).foregroundStyle(.tertiary)
            } else {
                Color.clear
            }
        }
        // Re-runs every time the cell reappears, so a failed or cancelled load retries.
        .task(id: resolved) {
            guard let u = resolved else { failed = true; return }
            if let hit = ImageLoader.shared.cached(u) {
                image = hit
                return
            }
            image = nil
            failed = false
            let loaded = await ImageLoader.shared.load(u)
            if Task.isCancelled { return }
            withAnimation(.easeOut(duration: 0.15)) { image = loaded }
            failed = loaded == nil
        }
    }
}

/// A square image well with the product centred on a light ground.
struct ProductImageWell: View {
    let url: String?
    var width: Int = 400
    var padding: CGFloat = 6

    var body: some View {
        Theme.tile
            .aspectRatio(1, contentMode: .fit)
            .overlay { RemoteImage(url: url, width: width).padding(padding) }
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// "$129⁹⁹" — Amazon's superscript-cents price.
struct PriceView: View {
    let value: Double
    var currency: String = "USD"
    var size: CGFloat = 20
    var color: Color = .primary
    /// The brand's own amount beside the dollars rather than beneath them, so
    /// a card in another currency is no taller than the rest (owner,
    /// 2026-11-16: "too much space between the price and the bottom border").
    var inline = false

    init(_ value: Double, currency: String = "USD", size: CGFloat = 20, color: Color = .primary, inline: Bool = false) {
        self.value = value
        self.currency = currency
        self.size = size
        self.color = color
        self.inline = inline
    }

    /// Scales `size` with the reader's text size (the audit failed the fixed
    /// sizes as "Dynamic Type unsupported", 2026-10-03).
    @ScaledMetric(relativeTo: .title) private var scale: CGFloat = 1

    /// Dollars first (owner, 2026-11-08: "the app should lead with dollars",
    /// after the website did the same that day): a brand that charges in
    /// another currency shows the dollar figure as the price and its own
    /// amount beneath, since checkout still charges that amount. A currency
    /// with no known rate shows its own amount alone.
    static func approxUSD(_ value: Double, currency: String) -> Double? {
        currency == "USD" ? nil : FX.usd(value, currency)
    }

    var body: some View {
        let usd = Self.approxUSD(value, currency: currency)
        let p = Money.parts(usd ?? value)
        let s = size * scale
        let layout = inline ? AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 5))
                            : AnyLayout(VStackLayout(alignment: .leading, spacing: 1))
        layout {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(FX.symbol(usd == nil ? currency : "USD")).font(.system(size: s * 0.5)).baselineOffset(s * 0.36)
                Text(p.dollars).font(.system(size: s))
                Text(p.cents).font(.system(size: s * 0.5)).baselineOffset(s * 0.36)
            }
            .foregroundStyle(color)
            .layoutPriority(1)
            if usd != nil {
                Text(Money.string(value, currency: currency))
                    .font(.system(size: max(12, s * 0.55)))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityIdentifier("brandCurrencyPrice")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(usd.map { "About \(Money.spoken($0)), charged as \(Money.spoken(value, currency: currency))" }
                            ?? Money.spoken(value, currency: currency))
    }
}

struct DealBadge: View {
    let percent: Int

    var body: some View {
        HStack(spacing: 6) {
            Text("\(percent)% off")
                .font(.caption2.bold())
                .foregroundStyle(.black)
                .padding(.horizontal, 5).padding(.vertical, 3)
                .background(Theme.deal)
            Text("Sale").font(.caption2.bold()).foregroundStyle(Theme.deal)
        }
    }
}

/// A badge's seal on the product page (owner, 2026-10-31, from the B3
/// preview): its name around the rim, its own symbol in a disc of its colour.
/// Decorative; the row beside it carries the words for VoiceOver.
struct BadgeSeal: View {
    let color: Color
    /// The rim text, e.g. "MARRACAT • CLEAN •".
    let ring: String
    let symbol: String
    var size: CGFloat = 56

    var body: some View {
        let chars = Array(ring + " ")
        ZStack {
            Circle().stroke(color, lineWidth: size * 0.03).padding(size * 0.015)
            Circle().fill(color).frame(width: size * 0.54, height: size * 0.54)
            Image(systemName: symbol)
                .font(.system(size: size * 0.24, weight: .bold))
                .foregroundStyle(.white)
            // One letter per step around the circle, starting at nine o'clock.
            // Drawn, not laid out as Text views: twenty one-letter Texts were
            // each an element to the accessibility audit (Contrast and
            // Dynamic Type failures on "M", "A", "•" …, 2026-11-04) even with
            // the seal hidden, since the row around it combines its children.
            Canvas { ctx, box in
                ctx.translateBy(x: box.width / 2, y: box.height / 2)
                for i in chars.indices {
                    var c = ctx
                    c.rotate(by: .degrees(-90 + Double(i) / Double(chars.count) * 360))
                    let letter = c.resolve(Text(verbatim: String(chars[i]))
                        .font(.system(size: size * 0.11, weight: .bold))
                        .foregroundStyle(color))
                    c.draw(letter, at: CGPoint(x: 0, y: -size * 0.37))
                }
            }
            .accessibilityHidden(true)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A seal with the badge's name (and tier), what it means, and the link to
/// its standard. Used for every badge on the product page.
struct BadgeSealRow: View {
    let color: Color
    let symbol: String
    /// "Marracat Clean"; badge names stay English everywhere.
    let name: String
    var tier: String? = nil
    let summary: String
    var explains = true

    var body: some View {
        HStack(spacing: 12) {
            BadgeSeal(color: color, ring: Self.ring(for: name), symbol: symbol)
            VStack(alignment: .leading, spacing: 2) {
                (Text(verbatim: name).bold() + Text(verbatim: tier.map { " · \($0)" } ?? "").foregroundStyle(color))
                    .font(.subheadline)
                Text(summary).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if explains {
                    (Text("What this means") + Text(verbatim: " ›")).font(.caption.bold()).foregroundStyle(color)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// "Marracat Pet Safe" -> "MARRACAT • PET SAFE •"; "Certified organic"
    /// -> "CERTIFIED • ORGANIC •".
    static func ring(for name: String) -> String {
        let words = name.uppercased().split(separator: " ", maxSplits: 1).map(String.init)
        return words.count == 2 ? "\(words[0]) • \(words[1]) •" : "\(name.uppercased()) •"
    }
}

/// Green leaf for products the brand lists as certified organic
/// (`Product.isCertifiedOrganic`).
struct OrganicBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "leaf.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Theme.organic))
            Text("Certified organic").font(.caption2.bold()).foregroundStyle(Theme.organic)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Certified organic")
        .accessibilityIdentifier("organicBadge")
    }
}

/// The blue "Marracat Clean" mark: the brand publishes its full ingredient
/// list and it clears catalog/clean_standard.md. Tap opens the standard.
struct CleanBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Theme.clean))
            Text("Marracat Clean").font(.caption2.bold()).foregroundStyle(Theme.clean)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Marracat Clean ingredients")
        .accessibilityIdentifier("cleanBadge")
    }
}

/// What the blue badge means, in the shopper's words. Mirrors
/// catalog/clean_standard.md; keep the two in step.
struct CleanStandardSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var details = false

    /// (icon, short title, one line, the full wording). The one-liners lead
    /// (owner, 2026-10-04: "more simple and more beautiful"); the full wording
    /// stays one tap away under "Read the full standard".
    private let rules: [(icon: String, title: String, line: String, full: String)] = [
        ("list.bullet.rectangle", String(localized: "Ingredient list published", comment: "Clean badge standard sheet: a rule (short title, one line, or full wording)"), String(localized: "The brand publishes an ingredient list.", comment: "Clean badge standard sheet: a rule (short title, one line, or full wording)"),
         String(localized: "The brand publishes an ingredient list on its product page, and the badge is checked against that list. We can\u{2019}t confirm the list is complete. No list, no badge.", comment: "Clean badge standard sheet: a rule (short title, one line, or full wording)")),
        ("globe", String(localized: "Banned nowhere", comment: "Clean badge standard sheet: a rule (short title, one line, or full wording)"), String(localized: "Nothing a major market bans.", comment: "Clean badge standard sheet: a rule (short title, one line, or full wording)"),
         String(localized: "No ingredient in it is banned in a major cosmetics market. Europe\u{2019}s list is the longest anywhere, over 1,700 substances, and where another market bans something Europe still permits, that fails too: chlorphenesin is allowed in Europe and not in Japan, and sunscreen filters banned in Palau fail in any sunscreen.", comment: "Clean badge standard sheet: a rule (short title, one line, or full wording)")),
        ("shield.lefthalf.filled", String(localized: "Stricter than the law", comment: "Clean badge standard sheet: a rule (short title, one line, or full wording)"), String(localized: "No parabens, triclosan, SLS or SLES.", comment: "Clean badge standard sheet: a rule (short title, one line, or full wording)"),
         String(localized: "Where a country sets a concentration limit rather than a ban, the ingredient is barred instead, because a list of ingredients can\u{2019}t prove how much is in the bottle. So no parabens at all, no isothiazolinone preservatives, no triclosan, no retinyl palmitate. EDTA goes too, on the EU Ecolabel\u{2019}s biodegradability rules, and so do SLS and SLES.", comment: "Clean badge standard sheet: a rule (short title, one line, or full wording)")),
        ("wind", String(localized: "Fragrance named", comment: "Clean badge standard sheet: a rule (short title, one line, or full wording)"), String(localized: "Allergens disclosed, or no fragrance.", comment: "Clean badge standard sheet: a rule (short title, one line, or full wording)"),
         String(localized: "\u{201C}Fragrance\u{201D}, \u{201C}parfum\u{201D} or \u{201C}scent\u{201D} alone doesn\u{2019}t pass. The brand names its fragrance allergens to the European standard that takes effect in July 2026, or uses no fragrance.", comment: "Clean badge standard sheet: a rule (short title, one line, or full wording)")),
        ("flame", String(localized: "Candles too", comment: "Clean badge standard sheet: a rule (short title, one line, or full wording)"), String(localized: "Named wax and wick, a clean scent.", comment: "Clean badge standard sheet: a rule (short title, one line, or full wording)"),
         String(localized: "Candles aren\u{2019}t cosmetics, so their badge asks for the wax and wick to be named, no metal-core wick, and a scent from essential oils, stated phthalate-free, or none.", comment: "Clean badge standard sheet: a rule (short title, one line, or full wording)")),
        ("xmark.circle", String(localized: "Never badged", comment: "Clean badge standard sheet: a rule (short title, one line, or full wording)"), String(localized: "Relaxers, keratin, permanent colour, skin bleaching.", comment: "Clean badge standard sheet: a rule (short title, one line, or full wording)"),
         String(localized: "Relaxers, keratin and straightening treatments, permanent colour, and skin bleaching, whatever the formula.", comment: "Clean badge standard sheet: a rule (short title, one line, or full wording)")),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 40, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 84, height: 84)
                            .background(Circle().fill(Theme.clean.gradient))
                            .shadow(color: Theme.clean.opacity(0.35), radius: 16, y: 6)
                            .accessibilityHidden(true)
                        Text("Marracat Clean").font(.title.bold())
                        Text("Checked against the world\u{2019}s strictest ingredient rules, then a little stricter for textured hair and Black skin.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding(.top, 8)

                    VStack(spacing: 0) {
                        ForEach(Array(rules.enumerated()), id: \.offset) { i, rule in
                            HStack(alignment: .top, spacing: 14) {
                                Image(systemName: rule.icon)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Theme.clean)
                                    .frame(width: 36, height: 36)
                                    .background(Circle().fill(Theme.clean.opacity(0.14)))
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(rule.title).font(.headline)
                                    Text(rule.line).font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 12)
                            .accessibilityElement(children: .combine)
                            if i < rules.count - 1 { Divider().padding(.leading, 50) }
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 18).fill(Theme.surface))

                    DisclosureGroup(isExpanded: $details) {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(rules, id: \.title) { rule in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(rule.title).font(.subheadline.bold())
                                    Text(rule.full).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                            Text("Read from the brand\u{2019}s own published ingredient list at catalog build time. It is a check on the formula, not a safety certification, medical advice, or a claim that the product is registered to sell in any particular country. Petrolatum, mineral oil, linear silicones, the lye in traditional soap and paraffin candle wax are allowed.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.top, 10)
                    } label: {
                        Text("Read the full standard").font(.subheadline.weight(.semibold))
                    }
                    .tint(Theme.clean)
                    .accessibilityIdentifier("cleanStandardDetails")
                }
                .padding(20)
            }
            .background(Theme.canvas)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("cleanStandardDone")
                }
            }
        }
        .accessibilityIdentifier("cleanStandardSheet")
    }
}

/// A quality-label mark beside the Clean shield: Marracat Clear Scent on
/// fragrance, Marracat Safer Clean on household cleaners, Marracat Clean Food
/// on groceries, Marracat Baby Safe on baby products, Marracat Natural Fiber
/// and Marracat Safe Fabric on clothing, Marracat Lab Verified on wellness,
/// Marracat Pet Safe on pet products, Marracat True Material on bags and
/// Marracat Natural Home on home goods.
struct QualityLabelBadge: View {
    enum Label: Hashable, Identifiable, CaseIterable {
        case clearScent, saferClean, cleanFood, babySafe, naturalFiber, naturalFiberOrganic, safeFabric
        case labVerified, petSafe, trueMaterial, trueMaterialVeg, naturalHome, naturalHomeCertified
        var title: String {
            switch self {
            case .clearScent: "Marracat Clear Scent"
            case .saferClean: "Marracat Safer Clean"
            case .cleanFood: "Marracat Clean Food"
            case .babySafe: "Marracat Baby Safe"
            case .naturalFiber: "Marracat Natural Fiber"
            case .naturalFiberOrganic: "Marracat Natural Fiber · Organic"
            case .safeFabric: "Marracat Safe Fabric"
            case .labVerified: "Marracat Lab Verified"
            case .petSafe: "Marracat Pet Safe"
            case .trueMaterial: "Marracat True Material"
            case .trueMaterialVeg: "Marracat True Material · Vegetable Tanned"
            case .naturalHome: "Marracat Natural Home"
            case .naturalHomeCertified: "Marracat Natural Home · Certified"
            }
        }
        var icon: String {
            switch self {
            case .clearScent: "drop.fill"
            case .saferClean: "leaf.fill"
            case .cleanFood: "carrot.fill"
            case .babySafe: "heart.fill"
            case .naturalFiber, .naturalFiberOrganic: "tshirt.fill"
            case .safeFabric: "checkmark.shield.fill"
            case .labVerified: "flask.fill"
            case .petSafe: "pawprint.fill"
            case .trueMaterial, .trueMaterialVeg: "bag.fill"
            case .naturalHome, .naturalHomeCertified: "house.fill"
            }
        }
        var color: Color {
            switch self {
            case .clearScent: Theme.scent
            case .saferClean: Theme.saferClean
            case .cleanFood: Theme.cleanFood
            case .babySafe: Theme.babySafe
            case .naturalFiber, .naturalFiberOrganic: Theme.naturalFiber
            case .safeFabric: Theme.safeFabric
            case .labVerified: Theme.labVerified
            case .petSafe: Theme.petSafe
            case .trueMaterial, .trueMaterialVeg: Theme.trueMaterial
            case .naturalHome, .naturalHomeCertified: Theme.naturalHome
            }
        }
        var id: String {
            switch self {
            case .clearScent: "clearScent"
            case .saferClean: "saferClean"
            case .cleanFood: "cleanFood"
            case .babySafe: "babySafe"
            case .naturalFiber: "naturalFiber"
            case .naturalFiberOrganic: "naturalFiberOrganic"
            case .safeFabric: "safeFabric"
            case .labVerified: "labVerified"
            case .petSafe: "petSafe"
            case .trueMaterial: "trueMaterial"
            case .trueMaterialVeg: "trueMaterialVeg"
            case .naturalHome: "naturalHome"
            case .naturalHomeCertified: "naturalHomeCertified"
            }
        }
        /// What the sheet's subtitle says the badge is.
        var summary: String {
            switch self {
            case .clearScent: "A fragrance whose brand shows exactly what\u{2019}s in it, with nothing banned anywhere."
            case .saferClean: "A cleaner whose brand shows exactly what\u{2019}s in it, with nothing banned anywhere."
            case .cleanFood: "A food whose brand publishes its ingredient list, with no additive on it banned in any country."
            case .babySafe: "A baby product that says exactly what it\u{2019}s made of, with nothing banned for children anywhere."
            case .naturalFiber: "A garment whose brand states its fibres, at least 90% of them natural."
            case .naturalFiberOrganic: "A garment at least 90% natural fibre, and that fibre organic or GOTS certified."
            case .safeFabric: "A garment that states its fibres, with no finish banned anywhere and no harmful synthetics."
            case .labVerified: "A supplement tested by a named third-party programme or lab, with nothing banned anywhere."
            case .petSafe: "A pet product that says what it is, with nothing toxic to pets or banned anywhere."
            case .trueMaterial: "A bag whose brand names exactly what it\u{2019}s made of."
            case .trueMaterialVeg: "A leather bag named as such and vegetable-tanned or chrome-free."
            case .naturalHome: "A home product made of a named natural material, with nothing banned anywhere."
            case .naturalHomeCertified: "A home product of organic or GOTS textile, or FSC-certified wood."
            }
        }
        func applies(to p: Product) -> Bool {
            switch self {
            case .clearScent: p.isMarracatClearScent
            case .saferClean: p.isMarracatSaferClean
            case .cleanFood: p.isMarracatCleanFood
            case .babySafe: p.isMarracatBabySafe
            case .naturalFiber: p.isMarracatNaturalFiber && !p.isOrganicNaturalFiber
            case .naturalFiberOrganic: p.isOrganicNaturalFiber
            case .safeFabric: p.isMarracatSafeFabric
            case .labVerified: p.isMarracatLabVerified
            case .petSafe: p.isMarracatPetSafe
            case .trueMaterial: p.isMarracatTrueMaterial && !p.isVegetableTanned
            case .trueMaterialVeg: p.isVegetableTanned
            case .naturalHome: p.isMarracatNaturalHome && !p.isCertifiedNaturalHome
            case .naturalHomeCertified: p.isCertifiedNaturalHome
            }
        }
        /// The labels a product carries, in display order.
        static func all(for p: Product) -> [Label] { allCases.filter { $0.applies(to: p) } }
    }
    let label: Label

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: label.icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 16, height: 16)
                .background(Circle().fill(label.color))
            Text(label.title)
                .font(.caption2.bold()).foregroundStyle(label.color).lineLimit(1).minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label.title)
        .accessibilityIdentifier("\(label.id)Badge")
    }
}

/// What a quality-label badge means. Each mirrors its standard in catalog/
/// (scent_standard.md, safer_clean_standard.md, food_standard.md,
/// baby_standard.md, fiber_standard.md, fabric_standard.md, lab_standard.md,
/// pet_standard.md, material_standard.md, home_standard.md); keep the pairs in step.
struct QualityLabelStandardSheet: View {
    let label: QualityLabelBadge.Label
    @Environment(\.dismiss) private var dismiss

    static func rules(_ label: QualityLabelBadge.Label) -> [(icon: String, title: String, line: String)] {
        switch label {
        case .clearScent:
            return [("list.bullet.rectangle", String(localized: "Ingredients published", comment: "Quality badge standard sheet: a rule (short title or one line)"), String(localized: "The brand publishes the fragrance\u{2019}s ingredient list.", comment: "Quality badge standard sheet: a rule (short title or one line)")),
                    ("globe", String(localized: "Nothing banned anywhere", comment: "Quality badge standard sheet: a rule (short title or one line)"), String(localized: "No ingredient banned in any country: EU, UK, California, Canada, Japan and more.", comment: "Quality badge standard sheet: a rule (short title or one line)")),
                    ("drop", String(localized: "Phthalate-free", comment: "Quality badge standard sheet: a rule (short title or one line)"), String(localized: "No phthalate of any kind, including DEP.", comment: "Quality badge standard sheet: a rule (short title or one line)")),
                    ("eye", String(localized: "Scent disclosed", comment: "Quality badge standard sheet: a rule (short title or one line)"), String(localized: "Fragrance allergens are named, or the scent is named essential oils.", comment: "Quality badge standard sheet: a rule (short title or one line)"))]
        case .saferClean:
            return [("list.bullet.rectangle", String(localized: "Ingredients published", comment: "Quality badge standard sheet: a rule (short title or one line)"), String(localized: "The brand publishes an ingredient list, as California requires.", comment: "Quality badge standard sheet: a rule (short title or one line)")),
                    ("globe", String(localized: "Nothing banned anywhere", comment: "Quality badge standard sheet: a rule (short title or one line)"), String(localized: "No chlorine bleach, phosphates, NPEs, triclosan, PFAS, borates or 1,4-dioxane.", comment: "Quality badge standard sheet: a rule (short title or one line)")),
                    ("eye", String(localized: "Fragrance disclosed", comment: "Quality badge standard sheet: a rule (short title or one line)"), String(localized: "Fragrance allergens are named, or the scent is named essential oils.", comment: "Quality badge standard sheet: a rule (short title or one line)")),
                    ("info.circle", String(localized: "Noted, not failed", comment: "Quality badge standard sheet: a rule (short title or one line)"), String(localized: "Quats and optical brighteners are legal everywhere; we note them.", comment: "Quality badge standard sheet: a rule (short title or one line)"))]
        case .cleanFood:
            return [("list.bullet.rectangle", String(localized: "Ingredients published", comment: "Quality badge standard sheet: a rule (short title or one line)"), String(localized: "The brand publishes the food\u{2019}s ingredient list.", comment: "Quality badge standard sheet: a rule (short title or one line)")),
                    ("globe", String(localized: "Nothing banned anywhere", comment: "Quality badge standard sheet: a rule (short title or one line)"), String(localized: "No additive banned in any country: Red 3, synthetic dyes, titanium dioxide, potassium bromate, BVO and more.", comment: "Quality badge standard sheet: a rule (short title or one line)")),
                    ("drop", String(localized: "No high-fructose corn syrup", comment: "Quality badge standard sheet: a rule (short title or one line)"), String(localized: "Not banned anywhere, but left out by the Marracat standard.", comment: "Quality badge standard sheet: a rule (short title or one line)")),
                    ("info.circle", String(localized: "Noted, not failed", comment: "Quality badge standard sheet: a rule (short title or one line)"), String(localized: "BHA, caramel colour and carrageenan are legal everywhere; we note them.", comment: "Quality badge standard sheet: a rule (short title or one line)"))]
        case .babySafe:
            return [("list.bullet.rectangle", String(localized: "Made-of published", comment: "Quality badge standard sheet: a rule (short title or one line)"), String(localized: "An ingredient list, or the material the product is made of.", comment: "Quality badge standard sheet: a rule (short title or one line)")),
                    ("globe", String(localized: "Nothing banned for children", comment: "Quality badge standard sheet: a rule (short title or one line)"), String(localized: "No BPA, phthalates, PVC, lead, flame retardants or PFAS, and nothing banned under 3 anywhere.", comment: "Quality badge standard sheet: a rule (short title or one line)")),
                    ("drop", String(localized: "No fragrance at all", comment: "Quality badge standard sheet: a rule (short title or one line)"), String(localized: "Washes and creams have no fragrance and no essential oils.", comment: "Quality badge standard sheet: a rule (short title or one line)")),
                    ("leaf", String(localized: "Natural fibres", comment: "Quality badge standard sheet: a rule (short title or one line)"), String(localized: "Clothing and bedding are cotton, linen, wool, silk or hemp, or certified organic.", comment: "Quality badge standard sheet: a rule (short title or one line)"))]
        case .naturalFiber, .naturalFiberOrganic:
            return [("list.bullet.rectangle", String(localized: "Composition stated", comment: "Quality badge standard sheet: a rule (short title or one line)"), String(localized: "The brand says exactly what the garment is made of.", comment: "Quality badge standard sheet: a rule (short title or one line)")),
                    ("leaf", String(localized: "At least 90% natural", comment: "Quality badge standard sheet: a rule (short title or one line)"), String(localized: "Cotton, linen, hemp, wool, cashmere, alpaca or silk; up to 10% stretch is fine.", comment: "Quality badge standard sheet: a rule (short title or one line)")),
                    ("arrow.triangle.2.circlepath", String(localized: "Viscose isn\u{2019}t natural", comment: "Quality badge standard sheet: a rule (short title or one line)"), String(localized: "Viscose, modal, lyocell and bamboo are chemically regenerated, so they don\u{2019}t count.", comment: "Quality badge standard sheet: a rule (short title or one line)")),
                    ("checkmark.seal", String(localized: "Organic tier", comment: "Quality badge standard sheet: a rule (short title or one line)"), String(localized: "When the fibre is organic or GOTS certified.", comment: "Quality badge standard sheet: a rule (short title or one line)"))]
        case .safeFabric:
            return [("list.bullet.rectangle", String(localized: "Composition stated", comment: "Quality badge standard sheet: a rule (short title or one line)"), String(localized: "The brand says exactly what the garment is made of.", comment: "Quality badge standard sheet: a rule (short title or one line)")),
                    ("globe", String(localized: "No finish banned anywhere", comment: "Quality badge standard sheet: a rule (short title or one line)"), String(localized: "No PFAS water-repellents, flame retardants, antimicrobial biocides or phthalate PVC.", comment: "Quality badge standard sheet: a rule (short title or one line)")),
                    ("tshirt", String(localized: "No harmful synthetics", comment: "Quality badge standard sheet: a rule (short title or one line)"), String(localized: "Less than half polyester, nylon, acrylic or elastane, unless certified.", comment: "Quality badge standard sheet: a rule (short title or one line)")),
                    ("checkmark.seal", String(localized: "Certified fabric", comment: "Quality badge standard sheet: a rule (short title or one line)"), String(localized: "OEKO-TEX, bluesign or GOTS test for banned dyes and chemicals a label can\u{2019}t show.", comment: "Quality badge standard sheet: a rule (short title or one line)"))]
        case .labVerified:
            return [("checkmark.seal", String(localized: "Named programme", comment: "Quality badge standard sheet: a rule (short title or one line)"), String(localized: "NSF Certified for Sport, USP Verified, Informed Sport, BSCG or Clean Label Project.", comment: "Quality badge standard sheet: a rule (short title or one line)")),
                    ("doc.text.magnifyingglass", String(localized: "Or a published lab report", comment: "Quality badge standard sheet: a rule (short title or one line)"), String(localized: "A certificate of analysis from an independent, accredited lab.", comment: "Quality badge standard sheet: a rule (short title or one line)")),
                    ("building.2", String(localized: "A facility audit isn\u{2019}t enough", comment: "Quality badge standard sheet: a rule (short title or one line)"), String(localized: "\u{201C}GMP\u{201D} or an NSF-registered plant audits the factory, not the product.", comment: "Quality badge standard sheet: a rule (short title or one line)")),
                    ("globe", String(localized: "Nothing banned anywhere", comment: "Quality badge standard sheet: a rule (short title or one line)"), String(localized: "No DMAA, ephedra, kratom, phenibut, yohimbe, kava, CBD or delta-8.", comment: "Quality badge standard sheet: a rule (short title or one line)"))]
        case .petSafe:
            return [("fork.knife", String(localized: "Food: complete or single-ingredient", comment: "Quality badge standard sheet: a rule (short title or one line)"), String(localized: "An AAFCO complete-and-balanced statement, or one named ingredient.", comment: "Quality badge standard sheet: a rule (short title or one line)")),
                    ("exclamationmark.triangle", String(localized: "Nothing toxic to pets", comment: "Quality badge standard sheet: a rule (short title or one line)"), String(localized: "No xylitol, grapes, onion, garlic, chocolate or macadamia; no propylene glycol for cats.", comment: "Quality badge standard sheet: a rule (short title or one line)")),
                    ("drop", String(localized: "Grooming: no toxic oils", comment: "Quality badge standard sheet: a rule (short title or one line)"), String(localized: "Ingredients listed, with no tea tree, citrus, pine, peppermint or other oils toxic to pets.", comment: "Quality badge standard sheet: a rule (short title or one line)")),
                    ("pawprint", String(localized: "Goods: material named", comment: "Quality badge standard sheet: a rule (short title or one line)"), String(localized: "Chew toys and bowls stated BPA- and phthalate-free; no PVC.", comment: "Quality badge standard sheet: a rule (short title or one line)"))]
        case .trueMaterial, .trueMaterialVeg:
            return [("tag", String(localized: "Material named", comment: "Quality badge standard sheet: a rule (short title or one line)"), String(localized: "Real leather, canvas, jute, raffia, cork, or a named recycled or plant leather.", comment: "Quality badge standard sheet: a rule (short title or one line)")),
                    ("questionmark.circle", String(localized: "No unnamed \u{201C}vegan leather\u{201D}", comment: "Quality badge standard sheet: a rule (short title or one line)"), String(localized: "Faux leather has to say what it is: PU, cactus, apple, mushroom.", comment: "Quality badge standard sheet: a rule (short title or one line)")),
                    ("globe", String(localized: "No phthalate PVC", comment: "Quality badge standard sheet: a rule (short title or one line)"), String(localized: "PVC or vinyl must be stated phthalate-free.", comment: "Quality badge standard sheet: a rule (short title or one line)")),
                    ("leaf", String(localized: "Vegetable Tanned tier", comment: "Quality badge standard sheet: a rule (short title or one line)"), String(localized: "Leather tanned without chrome, so no chromium VI.", comment: "Quality badge standard sheet: a rule (short title or one line)"))]
        case .naturalHome, .naturalHomeCertified:
            return [("tag", String(localized: "Material named", comment: "Quality badge standard sheet: a rule (short title or one line)"), String(localized: "The main material is stated: wood, linen, wool, stone, glass, rattan and more.", comment: "Quality badge standard sheet: a rule (short title or one line)")),
                    ("cup.and.saucer", String(localized: "Lead-free ceramics", comment: "Quality badge standard sheet: a rule (short title or one line)"), String(localized: "Mugs, plates and bowls in ceramic are stated lead-free.", comment: "Quality badge standard sheet: a rule (short title or one line)")),
                    ("globe", String(localized: "Nothing banned anywhere", comment: "Quality badge standard sheet: a rule (short title or one line)"), String(localized: "No composite wood without CARB Phase 2, no phthalate PVC, no bamboo melamine.", comment: "Quality badge standard sheet: a rule (short title or one line)")),
                    ("checkmark.seal", String(localized: "Certified tier", comment: "Quality badge standard sheet: a rule (short title or one line)"), String(localized: "Organic or GOTS textiles, or FSC-certified wood.", comment: "Quality badge standard sheet: a rule (short title or one line)"))]
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    VStack(spacing: 12) {
                        Image(systemName: label.icon)
                            .font(.system(size: 38, weight: .semibold))
                            .foregroundStyle(.black)
                            .frame(width: 84, height: 84)
                            .background(Circle().fill(label.color.gradient))
                            .accessibilityHidden(true)
                        Text(label.title).font(.title.bold()).multilineTextAlignment(.center)
                        Text(label.summary)
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding(.top, 8)
                    VStack(spacing: 0) {
                        let rules = Self.rules(label)
                        ForEach(Array(rules.enumerated()), id: \.offset) { i, rule in
                            HStack(alignment: .top, spacing: 14) {
                                Image(systemName: rule.icon)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(label.color)
                                    .frame(width: 36, height: 36)
                                    .background(Circle().fill(label.color.opacity(0.14)))
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(rule.title).font(.headline)
                                    Text(rule.line).font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 12)
                            .accessibilityElement(children: .combine)
                            if i < rules.count - 1 { Divider().padding(.leading, 50) }
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 18).fill(Theme.surface))
                    Text("Read from the ingredient list the brand publishes, at catalog build time. A product without a published list isn\u{2019}t badged. It is a check on the list, not a lab test.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(20)
            }
            .background(Theme.canvas)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("\(label.id)StandardDone")
                }
            }
        }
        .accessibilityIdentifier("\(label.id)StandardSheet")
    }
}

/// The gold "Marracat True Metal" mark on jewelry: every metal the listing
/// names is real and solid (catalog/metal_standard.md). With `ethical`, the
/// Ethically Sourced tier.
struct TrueMetalBadge: View {
    var ethical = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "seal.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Theme.metal))
            Text(ethical ? "Marracat True Metal · Ethically Sourced" : "Marracat True Metal")
                .font(.caption2.bold()).foregroundStyle(Theme.metal).lineLimit(1).minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ethical ? "Marracat True Metal, ethically sourced" : "Marracat True Metal")
        .accessibilityIdentifier("trueMetalBadge")
    }
}

/// What the gold badge means. Mirrors catalog/metal_standard.md; keep the two in step.
struct TrueMetalStandardSheet: View {
    @Environment(\.dismiss) private var dismiss

    static let rules: [(icon: String, title: String, line: String)] = [
        ("seal", String(localized: "Solid, real metal", comment: "True Metal badge standard sheet: a rule (short title or one line)"), String(localized: "10k+ gold, sterling silver, platinum, 316L steel, titanium or niobium.", comment: "True Metal badge standard sheet: a rule (short title or one line)")),
        ("xmark.circle", String(localized: "Nothing plated as solid", comment: "True Metal badge standard sheet: a rule (short title or one line)"), String(localized: "No plating, gold-tone, PVD, gold-filled or vermeil over another metal.", comment: "True Metal badge standard sheet: a rule (short title or one line)")),
        ("hand.raised", String(localized: "Skin-safe", comment: "True Metal badge standard sheet: a rule (short title or one line)"), String(localized: "No nickel, lead or cadmium as a material: inside EU, US and California limits.", comment: "True Metal badge standard sheet: a rule (short title or one line)")),
        ("leaf", String(localized: "Ethically Sourced tier", comment: "True Metal badge standard sheet: a rule (short title or one line)"), String(localized: "Recycled or Fairmined/Fairtrade gold, RJC certified, lab-grown or conflict-free stones.", comment: "True Metal badge standard sheet: a rule (short title or one line)")),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    VStack(spacing: 12) {
                        Image(systemName: "seal.fill")
                            .font(.system(size: 40, weight: .semibold))
                            .foregroundStyle(.black)
                            .frame(width: 84, height: 84)
                            .background(Circle().fill(Theme.metal.gradient))
                            .accessibilityHidden(true)
                        Text("Marracat True Metal").font(.title.bold())
                        Text("Every metal the brand names is the real thing, and it\u{2019}s safe on skin.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding(.top, 8)
                    VStack(spacing: 0) {
                        ForEach(Array(Self.rules.enumerated()), id: \.offset) { i, rule in
                            HStack(alignment: .top, spacing: 14) {
                                Image(systemName: rule.icon)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Theme.metal)
                                    .frame(width: 36, height: 36)
                                    .background(Circle().fill(Theme.metal.opacity(0.14)))
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(rule.title).font(.headline)
                                    Text(rule.line).font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 12)
                            .accessibilityElement(children: .combine)
                            if i < Self.rules.count - 1 { Divider().padding(.leading, 50) }
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 18).fill(Theme.surface))
                    Text("Read from what the brand publishes about the piece at catalog build time. A listing that doesn\u{2019}t name its metal isn\u{2019}t badged. It is a check on the listing, not an assay or a certification.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(20)
            }
            .background(Theme.canvas)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("trueMetalStandardDone")
                }
            }
        }
        .accessibilityIdentifier("trueMetalStandardSheet")
    }
}

/// A card's labels as one row of icons, no words (owner, 2026-10-10: two
/// spelled-out labels took three lines of a narrow card and got cut off).
/// Each icon still reads its full name to VoiceOver and keeps the
/// identifier the full badge has, and the product page spells them out.
struct BadgeIconRow: View {
    let product: Product

    private struct Mark: Identifiable {
        let id: String, symbol: String, color: Color, ink: Color, name: String
    }

    private var marks: [Mark] { Self.marks(for: product) }

    /// Whether the product shows any badge icons (a row reserves their line).
    static func hasMarks(_ product: Product) -> Bool { !marks(for: product).isEmpty }

    private static func marks(for product: Product) -> [Mark] {
        var out: [Mark] = []
        if product.isCertifiedOrganic { out.append(.init(id: "organicBadge", symbol: "leaf.fill", color: Theme.organic, ink: .white, name: "Certified organic")) }
        if product.isMarracatClean { out.append(.init(id: "cleanBadge", symbol: "checkmark.shield.fill", color: Theme.clean, ink: .white, name: "Marracat Clean ingredients")) }
        if product.isMarracatTrueMetal {
            out.append(.init(id: "trueMetalBadge", symbol: "seal.fill", color: Theme.metal, ink: .black,
                             name: product.isEthicallySourced ? "Marracat True Metal, ethically sourced" : "Marracat True Metal"))
        }
        for label in QualityLabelBadge.Label.all(for: product) {
            out.append(.init(id: "\(label.id)Badge", symbol: label.icon, color: label.color, ink: .black, name: label.title))
        }
        return out
    }

    var body: some View {
        let marks = marks
        if !marks.isEmpty {
            HStack(spacing: 5) {
                ForEach(marks) { m in
                    Image(systemName: m.symbol)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(m.ink)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(m.color))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(m.name)
                        .accessibilityIdentifier(m.id)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("badgeIconRow")
        }
    }
}

struct ProductTile: View {
    @Environment(CatalogStore.self) private var catalog
    let product: Product
    /// A fixed photo square, so every card in a row is the same size. Without
    /// it the well is only as wide as the layout proposes, and a row ended up
    /// mixing 150pt and 128pt cards.
    var imageSide: CGFloat?

    var body: some View {
        // Price and stock as fresh as this phone has them (FreshCatalog).
        let product = FreshCatalog.shared.current(self.product)
        NavigationLink(value: Route.product(product.id)) {
            VStack(alignment: .leading, spacing: 4) {
                // The sale tag and badge icons sit on the photo, as on the
                // masonry tiles, and another currency sits beside the price:
                // every card is then the same height under its photo, so a
                // row reserves nothing for lines most of its cards don't have
                // (owner, 2026-11-16: "too much space between the price and
                // the bottom border of a row").
                ProductImageWell(url: product.images.first)
                    .frame(width: imageSide, height: imageSide)
                    .overlay(alignment: .topLeading) {
                        if let off = product.percentOff, product.available { DealBadge(percent: off).padding(6) }
                    }
                    .overlay(alignment: .bottomLeading) { BadgeIconRow(product: product).padding(6) }
                    .modifier(ProductZoomSource(id: product.id, cornerRadius: 6))
                // No reserved second line: a one-line name sat a blank line
                // above its brand. Rows stay level because the grids align
                // tiles to the top, so the photos line up whatever the text.
                Text(product.title)
                    .font(.subheadline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(catalog.brand(product.brand)?.name ?? "")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    PriceView(product.price, currency: product.currencyCode, size: 20, inline: true)
                    if !product.available {
                        Text("Sold out").font(.caption).foregroundStyle(Theme.deal)
                    }
                }
            }
            .foregroundStyle(.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("productTile")
    }
}

struct SectionHeader: View {
    let title: String
    var route: Route?
    /// A dot in a holiday's colour before the title (HolidayEventRows).
    var accent: Color? = nil

    var body: some View {
        HStack(spacing: 8) {
            if let accent { Circle().fill(accent).frame(width: 10, height: 10).accessibilityHidden(true) }
            Text(title).font(.title3.bold())
            Spacer()
            if let route {
                NavigationLink(value: route) {
                    Image(systemName: "arrow.right").font(.headline).foregroundStyle(.primary)
                        .frame(minWidth: 44, minHeight: 44, alignment: .trailing)   // Apple's 44 pt hit target
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("See all \(title)")
            }
        }
    }
}

/// Amazon's 2×2 "For you" card.
struct QuadCard: View {
    let title: String
    let products: [Product]
    let route: Route

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NavigationLink(value: route) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(products.prefix(4)) { p in
                    NavigationLink(value: Route.product(p.id)) {
                        // The tag sits on the photo, not under it: under it,
                        // a card with tags grew taller than the row (sized by
                        // the untagged New arrivals card) and its bottom row
                        // was cut off (2026-10-11).
                        ProductImageWell(url: p.images.first, width: 240, padding: 4)
                            .accessibilityLabel(p.title)   // a photo alone read as an unlabeled button
                            .overlay(alignment: .bottomLeading) {
                                if let off = p.percentOff {
                                    Text("\(off)% off")
                                        .font(.caption2.bold()).foregroundStyle(.black)
                                        .padding(.horizontal, 4).padding(.vertical, 2)
                                        .background(Theme.deal)
                                        .padding(4)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(10)
        .frame(width: 190)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
    }
}

/// A row of cards scrolls sideways in a lazy stack, which takes its height
/// from the cards first on screen; a taller one scrolled in later (a sale
/// line, badge icons, a second line of name) was cut off at the bottom
/// (owner, 2026-11-15, "More for your hair oils & serums"). The row reserves
/// the tallest a card in it can be, measured in the current text size.
struct TileRowHeight: ViewModifier {
    let products: [Product]
    let width: CGFloat
    @State private var text: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .frame(minHeight: text > 0 ? width + 4 + text : nil, alignment: .top)
            .background(alignment: .topLeading) {
                TileTextProbe(products: products)
                    .frame(width: width)
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden()
                    .accessibilityHidden(true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { text = $0 }
            }
    }
}

/// ProductTile's text at its tallest: two lines of name, the brand and the
/// price. Nothing else varies under a card's photo, so this is every card's
/// height but for a one-line name.
private struct TileTextProbe: View {
    let products: [Product]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: "M\nM").font(.subheadline).lineLimit(2)
            Text(verbatim: "M").font(.caption)
            PriceView(10, size: 20, inline: true)
        }
    }
}

struct ProductRow: View {
    /// Every card in every row is this wide, photo included.
    static let tileWidth: CGFloat = 150
    let title: String
    let products: [Product]
    var route: Route?
    /// The name this row's views and taps are counted under (Analytics); nil
    /// for rows that aren't recommendations.
    var track: String? = nil
    /// Products in reserved other-department slots, counted as "dept_mix".
    var reserved: Set<String> = []
    var accent: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: title, route: route, accent: accent).padding(.horizontal, 12)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(Array(products.enumerated()), id: \.element.id) { index, product in
                        ProductTile(product: product, imageSide: Self.tileWidth).frame(width: Self.tileWidth)
                            .simultaneousGesture(TapGesture().onEnded {
                                guard let track else { return }
                                Analytics.shared.tapped(row: reserved.contains(product.id) ? "dept_mix" : track,
                                                        product: product, position: index)
                            })
                    }
                }
                .modifier(TileRowHeight(products: products, width: Self.tileWidth))
                .padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 14)
        .background(Theme.surface)
        .modifier(RecRowTracking(row: track, first: products.first))
    }
}

struct FilterChips: View {
    let options: [(id: String, name: String)]
    @Binding var selection: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            // Lazy: a department can carry 150+ brands, and building every chip
            // up front stalled the push that follows a search suggestion.
            LazyHStack(spacing: 8) {
                chip(String(localized: "All", comment: "Filter chip that clears the brand or category filter"), selected: selection == nil) { selection = nil }
                ForEach(options, id: \.id) { o in
                    chip(o.name, selected: selection == o.id) { selection = o.id }
                }
            }
            .padding(.horizontal, 12)
        }
    }

    private func chip(_ name: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(name)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(selected ? Color.white : Theme.field))
                .foregroundStyle(selected ? Color.black : Color.primary)
                .overlay(Capsule().stroke(Theme.hairline, lineWidth: selected ? 0 : 1))
        }
        .buttonStyle(.plain)
    }
}

/// A shopper who sorts by price keeps that sort (owner, 2026-11-16, after a
/// new shopper's first move on "heels" was Price: low to high: "lets auto sort
/// for users who do that because price seems to be an important feature").
/// The last price sort picked opens every later search, department and brand
/// page; picking Featured or Newest forgets it. Kept on this phone only.
enum SortPreference {
    static let key = "sortPreference"
    static var defaults: UserDefaults = .standard

    static var current: ProductSort {
        guard let s = defaults.string(forKey: key).flatMap(ProductSort.init(rawValue:)), s.isPrice else { return .featured }
        return s
    }

    static func record(_ sort: ProductSort) {
        if sort.isPrice { defaults.set(sort.rawValue, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}

extension ProductFilters {
    /// A list's filters when it opens: none, in the shopper's kept sort.
    static var starting: ProductFilters {
        var f = ProductFilters()
        f.sort = SortPreference.current
        return f
    }
}

enum ProductSort: String, CaseIterable, Identifiable {
    case featured = "Featured"
    case newest = "Newest arrivals"
    case priceLow = "Price: Low to High"
    case priceHigh = "Price: High to Low"
    var id: String { rawValue }
    var isPrice: Bool { self == .priceLow || self == .priceHigh }

    /// The long names read well in a menu but not on a chip.
    var shortName: String {
        switch self {
        case .featured: return String(localized: "Featured", comment: "Sort order picker option")
        case .newest: return String(localized: "Newest", comment: "Sort order picker option")
        case .priceLow: return String(localized: "Price: low to high", comment: "Sort order picker option")
        case .priceHigh: return String(localized: "Price: high to low", comment: "Sort order picker option")
        }
    }

    func apply(_ products: [Product]) -> [Product] {
        switch self {
        case .featured:
            // In stock first, otherwise keep the brand's own ordering.
            return products.enumerated().sorted {
                ($0.element.available ? 0 : 1, $0.offset) < ($1.element.available ? 0 : 1, $1.offset)
            }.map(\.element)
        case .newest: return products.sorted { ($0.publishedAt ?? "") > ($1.publishedAt ?? "") }
        // Compared in dollars, so a euro bag sits among dollar bags at its
        // dollar price. Grouping by currency code put every euro item before
        // any dollar one (a creator's "handbags" low to high opened on €350
        // bags, 2026-10-16).
        case .priceLow: return products.sorted { $0.usdPrice < $1.usdPrice }
        case .priceHigh: return products.sorted { $0.usdPrice > $1.usdPrice }
        }
    }
}

struct QuantityPill: View {
    let quantity: Int
    let onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button { onChange(quantity - 1) } label: {
                Image(systemName: quantity == 1 ? "trash" : "minus").frame(width: 44, height: 44).contentShape(Rectangle())   // 44 pt target
            }
            .accessibilityLabel(quantity == 1 ? "Delete" : "Decrease quantity")
            Text("\(quantity)").font(.subheadline.bold()).frame(minWidth: 30)
            Button { onChange(quantity + 1) } label: {
                Image(systemName: "plus").frame(width: 44, height: 44).contentShape(Rectangle())   // 44 pt target
            }
            .disabled(quantity >= 10)
            .accessibilityLabel("Increase quantity")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .overlay(Capsule().stroke(Theme.gold, lineWidth: 3))
    }
}

struct IdentifiedURL: Identifiable {
    let id = UUID()
    let url: URL
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let vc = SFSafariViewController(url: url)
        vc.preferredControlTintColor = UIColor(Theme.cocoa)
        // Marracat is a dark app, and the web view inherits that: a store whose
        // dark-mode CSS is half-finished renders its checkout labels white on
        // white (Ten To One's form came through as unlabelled boxes). Brand
        // sites are designed light, so show them light.
        vc.overrideUserInterfaceStyle = .light
        return vc
    }

    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}

/// Swipe a row left to remove it, as in Mail (owner, 2026-09-30: "we should be
/// able to swipe to remove items in the cart"). A short swipe opens a red
/// Remove button; a long one removes straight away. The cart lives in a
/// ScrollView, not a List, so `.swipeActions` isn't available; the drag only
/// takes over once it's clearly sideways, so vertical scrolling still works.
struct SwipeToRemove: ViewModifier {
    let label: String
    let onRemove: () -> Void
    @State private var offset: CGFloat = 0
    @State private var settled: CGFloat = 0
    @State private var sideways: Bool?
    @State private var width: CGFloat = 0
    private let button: CGFloat = 88

    func body(content: Content) -> some View {
        ZStack(alignment: .trailing) {
            Button(role: .destructive) { remove() } label: {
                Label("Remove", systemImage: "trash")
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: max(button, -offset))
                    .frame(maxHeight: .infinity)
                    .background(Color.red)
            }
            .opacity(offset < 0 ? 1 : 0)
            .accessibilityHidden(offset == 0)
            .accessibilityLabel(label)
            .accessibilityIdentifier("swipeRemove")
            if offset < 0 && sideways == nil {
                // An open row: tapping the item closes it again.
                Color.clear.contentShape(Rectangle())
                    .padding(.trailing, button)
                    .onTapGesture { withAnimation(.snappy) { offset = 0; settled = 0 } }
            }
            content
                // Full width, so "a long swipe" is measured against the row,
                // not just its text (a 110 pt drag counted as a full swipe).
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface)
                .allowsHitTesting(sideways != true && offset == 0)
                .offset(x: offset)
                .background(GeometryReader { geo in
                    Color.clear.onAppear { width = geo.size.width }
                        .onChange(of: geo.size.width) { _, w in width = w }
                })
        }
        .clipped()
        // Simultaneous, so a vertical drag still scrolls the cart. While a
        // sideways swipe is under way the row's links are switched off, so the
        // swipe can't end as a tap that opens the product (XCUITest caught it).
        .simultaneousGesture(
            DragGesture(minimumDistance: 14)
                .onChanged { drag in
                    if sideways == nil {
                        sideways = abs(drag.translation.width) > abs(drag.translation.height)
                    }
                    guard sideways == true else { return }
                    offset = min(0, settled + drag.translation.width)
                }
                .onEnded { _ in
                    defer { sideways = nil }
                    guard sideways == true else { return }
                    if width > 0, -offset > width * 0.45 {
                        remove()
                    } else {
                        withAnimation(.snappy) { offset = -offset > button / 2 ? -button : 0 }
                        settled = offset
                    }
                }
        )
        .accessibilityAction(named: label) { onRemove() }
    }

    private func remove() {
        withAnimation(.easeOut(duration: 0.2)) { offset = -max(width, button) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            onRemove()
            offset = 0
            settled = 0
        }
    }
}

extension View {
    func swipeToRemove(_ label: String = String(localized: "Remove", comment: "Default accessibility action name for swiping a row away"), perform: @escaping () -> Void) -> some View {
        modifier(SwipeToRemove(label: label, onRemove: perform))
    }
}
