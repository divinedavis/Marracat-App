import Foundation

/// The catalog in a compact binary form the app writes for itself (owner,
/// 2026-10-02: "use the iPhone's hardware"). Decoding 82 MB of JSON was the
/// launch's biggest remaining cost (~300 ms across all cores); this reads in a
/// fraction of that, and holds the catalog in less memory, because:
///
/// - every distinct string (a brand id, "Default Title", a tag) is stored once
///   and every product points at it by number, so reading makes each string
///   once and all products share it, where JSON made a copy per product;
/// - there's nothing to parse: fixed-width numbers read straight out of a
///   memory-mapped file, the strings and the products each split over every
///   core.
///
/// The build bundles one for the bundled catalog (catalog.bin, written by
/// catalog/make_compact.py with this same code), so the first launch after an
/// update reads it too (2026-10-11). The app writes its own after it downloads
/// a catalog, or reads one from JSON, for the next launch. A file that doesn't
/// check out (magic, version, the catalog's date, its own lengths) is ignored
/// and the JSON is read as before.
enum CatalogBinary {
    private static let magic: UInt32 = 0x4D52_4331   // "MRC1"
    // 2: the second flag byte carries the True Metal badge (2026-10-08); a
    // version-1 file has no room for it, so it's rebuilt from the JSON.
    // 3: and Clear Scent and Safer Clean in its last two bits (2026-10-09).
    // 4: that byte's top bit says a third flag byte follows, carrying Clean
    // Food (1) and Baby Safe (2) (2026-10-09).
    // 5: and Natural Fiber (4), its Organic tier (8, with 4) and Safe Fabric
    // (16) in that third byte (2026-10-09).
    // 6: that third byte's 32 is Lab Verified, 64 Pet Safe, and its top bit
    // says a fourth byte follows with True Material (1), its Vegetable Tanned
    // tier (2, with 1), Natural Home (4) and its Certified tier (8, with 4)
    // (2026-10-09).
    // 7: a variant's flag byte's 4 says a u16 follows, the index of the
    // colour's own photo (2026-10-17).
    // 8: that fourth byte's 16 says the product's attrs follow its currency:
    // a u8 field count, then each field's name and its list of values
    // (skincare and hair filters, 2026-11-04).
    private static let version: UInt32 = 8
    private static let none: UInt32 = .max

    static var url: URL? {
        try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("catalog-v1.bin")
    }

    /// The build's copy of the bundled catalog.
    static func bundledURL(_ bundle: Bundle) -> URL? { bundle.url(forResource: "catalog", withExtension: "bin") }

    /// The bundled copy, then the app's own, whichever is of exactly this
    /// catalog — by the date in its header, so a stale file isn't decoded.
    private static func file(expecting generatedAt: String, bundle: Bundle) -> Data? {
        for url in [bundledURL(bundle), url].compactMap({ $0 }) {
            if let data = try? Data(contentsOf: url, options: .alwaysMapped), peekGeneratedAt(data) == generatedAt {
                willNeed(data)
                return data
            }
        }
        return nil
    }

    /// Tells the kernel the whole mapped file is about to be read, so it
    /// starts reading ahead from storage while the first pieces decode,
    /// instead of faulting in one page at a time (2026-10-18). Only a hint;
    /// nothing changes if it's ignored.
    static func willNeed(_ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, Int(bitPattern: base) % Int(getpagesize()) == 0 else { return }
            _ = madvise(UnsafeMutableRawPointer(mutating: base), raw.count, MADV_WILLNEED)
        }
    }

    private struct Header: Codable {
        var generatedAt: String
        var categories: [Category]
        var subcategories: [Subcategory]
        var brands: [Brand]
    }

    // MARK: Writing

    private struct Writer {
        var data = Data()
        mutating func u8(_ v: UInt8) { data.append(v) }
        mutating func u16(_ v: Int) { var x = UInt16(clamping: v).littleEndian; data.append(Data(bytes: &x, count: 2)) }
        mutating func u32(_ v: UInt32) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 4)) }
        mutating func i32(_ v: Int) { var x = Int32(clamping: v).littleEndian; data.append(Data(bytes: &x, count: 4)) }
        mutating func i64(_ v: Int64) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 8)) }
        mutating func f64(_ v: Double) { var x = v.bitPattern.littleEndian; data.append(Data(bytes: &x, count: 8)) }
    }

    static func encode(_ c: Catalog) throws -> Data {
        var table: [String: UInt32] = [:], strings: [String] = []
        func ref(_ s: String) -> UInt32 {
            if let i = table[s] { return i }
            let i = UInt32(strings.count); table[s] = i; strings.append(s); return i
        }
        func opt(_ s: String?) -> UInt32 { s.map(ref) ?? none }

        var records = Writer(), offsets: [UInt32] = []
        offsets.reserveCapacity(c.products.count + 1)
        for p in c.products {
            offsets.append(UInt32(records.data.count))
            var w = Writer()
            w.u32(ref(p.id)); w.u32(ref(p.brand)); w.u32(ref(p.title)); w.u32(ref(p.category)); w.u32(opt(p.productType))
            w.u16(p.subs.count); p.subs.forEach { w.u32(ref($0)) }
            w.f64(p.price)
            var flags: UInt8 = 0
            if p.compareAt != nil { flags |= 1 }
            if p.available { flags |= 2 }
            if p.description != nil { flags |= 4 }
            if p.publishedAt != nil { flags |= 8 }
            if p.bestRank != nil { flags |= 16 }
            if p.currency != nil { flags |= 32 }
            if let o = p.organic { flags |= 64; if o { flags |= 128 } }
            w.u8(flags)
            // clean: 0 unset, 1 false, 3 true; 4 marks an `opts` list after the tags;
            // 8 True Metal, 16 Ethically Sourced (with 8); 32 Clear Scent, 64 Safer Clean;
            // 128: a third byte follows with 1 Clean Food, 2 Baby Safe, 4 Natural Fiber,
            // 8 its Organic tier (with 4), 16 Safe Fabric, 32 Lab Verified, 64 Pet Safe,
            // 128: a fourth byte follows with 1 True Material, 2 Vegetable Tanned (with 1),
            // 4 Natural Home, 8 Certified (with 4).
            let metalBits: UInt8 = p.metal == "ethical" ? 24 : (p.metal == "true" ? 8 : 0)
            let labelBits: UInt8 = (p.scent == true ? 32 : 0) | (p.safer == true ? 64 : 0)
            let fiberBits: UInt8 = p.fiber == "organic" ? 12 : (p.fiber == "natural" ? 4 : 0)
            let materialBits: UInt8 = p.material == "veg" ? 3 : (p.material == "true" ? 1 : 0)
            let homeBits: UInt8 = p.home == "certified" ? 12 : (p.home == "natural" ? 4 : 0)
            let attrs = (p.attrs ?? [:]).filter { !$0.value.isEmpty }
            let fourthBits: UInt8 = materialBits | homeBits | (attrs.isEmpty ? 0 : 16)
            let moreBits: UInt8 = (p.food == true ? 1 : 0) | (p.baby == true ? 2 : 0) | fiberBits
                | (p.fabric == true ? 16 : 0) | (p.lab == true ? 32 : 0) | (p.pet == true ? 64 : 0)
                | (fourthBits != 0 ? 128 : 0)
            w.u8((p.clean == nil ? 0 : (p.clean! ? 3 : 1)) | (p.opts == nil ? 0 : 4) | metalBits | labelBits
                 | (moreBits != 0 ? 128 : 0))
            if moreBits != 0 { w.u8(moreBits) }
            if fourthBits != 0 { w.u8(fourthBits) }
            if let v = p.compareAt { w.f64(v) }
            w.u16(p.images.count); p.images.forEach { w.u32(ref($0)) }
            w.u32(ref(p.url))
            w.u16(p.variants.count)
            for v in p.variants {
                w.i64(v.id); w.u32(ref(v.title)); w.f64(v.price)
                w.u8((v.compareAt == nil ? 0 : 1) | (v.available ? 2 : 0) | (v.image == nil ? 0 : 4))
                if let x = v.compareAt { w.f64(x) }
                if let i = v.image { w.u16(i) }
            }
            w.u16(p.tags.count); p.tags.forEach { w.u32(ref($0)) }
            if let o = p.opts { w.u16(o.count); o.forEach { w.u32(ref($0)) } }
            if let d = p.description { w.u32(ref(d)) }
            if let d = p.publishedAt { w.u32(ref(d)) }
            if let r = p.bestRank { w.i32(r) }
            if let cur = p.currency { w.u32(ref(cur)) }
            if !attrs.isEmpty {
                w.u8(UInt8(min(attrs.count, 255)))
                for (field, values) in attrs.sorted(by: { $0.key < $1.key }).prefix(255) {
                    w.u32(ref(field)); w.u16(values.count); values.forEach { w.u32(ref($0)) }
                }
            }
            records.data.append(w.data)
        }
        offsets.append(UInt32(records.data.count))

        var out = Writer()
        out.u32(magic); out.u32(version)
        let header = try JSONEncoder().encode(Header(generatedAt: c.generatedAt, categories: c.categories,
                                                      subcategories: c.subcategories, brands: c.brands))
        out.u32(UInt32(header.count)); out.data.append(header)
        // Strings: count, count+1 offsets, then the UTF-8 bytes.
        var blob = Data(), stringOffsets: [UInt32] = [0]
        for s in strings { blob.append(contentsOf: s.utf8); stringOffsets.append(UInt32(blob.count)) }
        out.u32(UInt32(strings.count)); stringOffsets.forEach { out.u32($0) }; out.data.append(blob)
        // Products: count, count+1 offsets into the records, then the records.
        out.u32(UInt32(c.products.count)); offsets.forEach { out.u32($0) }; out.data.append(records.data)
        return out.data
    }

    /// Writes the binary for `c` unless one for the same catalog is there.
    static func save(_ c: Catalog) {
        guard let url, !c.products.isEmpty else { return }
        if let existing = try? Data(contentsOf: url, options: .alwaysMapped), peekGeneratedAt(existing) == c.generatedAt { return }
        guard let data = try? encode(c) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: Reading

    /// The catalog date in a binary file, from its header only.
    static func peekGeneratedAt(_ data: Data) -> String? {
        data.withUnsafeBytes { raw -> String? in
            guard raw.count > 12, raw.loadUnaligned(as: UInt32.self).littleEndian == magic,
                  raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian == version else { return nil }
            let n = Int(raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self).littleEndian)
            guard 12 + n <= raw.count else { return nil }
            return (try? JSONDecoder().decode(Header.self, from: Data(raw[12..<(12 + n)])))?.generatedAt
        }
    }

    static func load(expecting generatedAt: String, bundle: Bundle = .main) -> Catalog? {
        guard let data = file(expecting: generatedAt, bundle: bundle),
              let c = decode(data), c.generatedAt == generatedAt else { return nil }
        return c
    }

    /// Each product's stock, by id, without making the rest of the catalog:
    /// what the background refresh compares a download against (Interests).
    /// The first of a repeated id wins.
    static func availability(expecting generatedAt: String, bundle: Bundle = .main) -> [String: Bool]? {
        guard let data = file(expecting: generatedAt, bundle: bundle) else { return nil }
        return availability(data)
    }

    static func availability(_ data: Data) -> [String: Bool]? {
        data.withUnsafeBytes { raw -> [String: Bool]? in
            let count = raw.count
            func u32(_ at: Int) -> Int? {
                guard at >= 0, at + 4 <= count else { return nil }
                return Int(raw.loadUnaligned(fromByteOffset: at, as: UInt32.self).littleEndian)
            }
            guard u32(0) == Int(magic), u32(4) == Int(version), let headerLength = u32(8) else { return nil }
            let stringsAt = 12 + headerLength
            guard let stringCount = u32(stringsAt) else { return nil }
            let stringOffsetsAt = stringsAt + 4, blobAt = stringOffsetsAt + (stringCount + 1) * 4
            guard let blobLength = u32(stringOffsetsAt + stringCount * 4) else { return nil }
            let productsAt = blobAt + blobLength
            guard let productCount = u32(productsAt) else { return nil }
            let recordsAt = productsAt + 4 + (productCount + 1) * 4
            var out = [String: Bool](minimumCapacity: productCount)
            for i in 0..<productCount {
                // id, brand, title, category, type; the aisles; the price; then the flags.
                guard let record = u32(productsAt + 4 + i * 4).map({ recordsAt + $0 }),
                      let id = u32(record), id < stringCount,
                      let lo = u32(stringOffsetsAt + id * 4), let hi = u32(stringOffsetsAt + (id + 1) * 4),
                      lo <= hi, hi <= blobLength, record + 22 <= count else { return nil }
                let subs = Int(raw.loadUnaligned(fromByteOffset: record + 20, as: UInt16.self).littleEndian)
                let flagsAt = record + 22 + subs * 4 + 8
                guard flagsAt < count else { return nil }
                let key = String(decoding: UnsafeRawBufferPointer(rebasing: raw[(blobAt + lo)..<(blobAt + hi)]), as: UTF8.self)
                if out[key] == nil { out[key] = raw[flagsAt] & 2 != 0 }
            }
            return out
        }
    }

    static func decode(_ data: Data) -> Catalog? {
        data.withUnsafeBytes { raw -> Catalog? in
            let count = raw.count
            var at = 0
            func u32() -> UInt32? {
                guard at + 4 <= count else { return nil }
                defer { at += 4 }
                return raw.loadUnaligned(fromByteOffset: at, as: UInt32.self).littleEndian
            }
            guard u32() == magic, u32() == version, let headerLength = u32().map(Int.init),
                  at + headerLength <= count,
                  let header = try? JSONDecoder().decode(Header.self, from: Data(raw[at..<(at + headerLength)])) else { return nil }
            at += headerLength

            // Strings, made once each, on every core.
            guard let stringCount = u32().map(Int.init), at + (stringCount + 1) * 4 <= count else { return nil }
            let stringOffsetsAt = at
            at += (stringCount + 1) * 4
            let blobAt = at
            func stringOffset(_ i: Int) -> Int {
                Int(raw.loadUnaligned(fromByteOffset: stringOffsetsAt + i * 4, as: UInt32.self).littleEndian)
            }
            let blobLength = stringOffset(stringCount)
            guard blobAt + blobLength <= count else { return nil }
            at += blobLength
            var strings = [String](repeating: "", count: stringCount)
            let cores = pieces
            strings.withUnsafeMutableBufferPointer { out in
                DispatchQueue.concurrentPerform(iterations: cores) { slice in
                    for i in (stringCount * slice / cores)..<(stringCount * (slice + 1) / cores) {
                        let lo = stringOffset(i), hi = stringOffset(i + 1)
                        guard lo <= hi, hi <= blobLength else { continue }
                        out[i] = String(decoding: UnsafeRawBufferPointer(rebasing: raw[(blobAt + lo)..<(blobAt + hi)]), as: UTF8.self)
                    }
                }
            }

            // Products, read on every core from their offsets.
            guard let productCount = u32().map(Int.init), at + (productCount + 1) * 4 <= count else { return nil }
            let productOffsetsAt = at
            at += (productCount + 1) * 4
            let recordsAt = at
            func recordOffset(_ i: Int) -> Int {
                recordsAt + Int(raw.loadUnaligned(fromByteOffset: productOffsetsAt + i * 4, as: UInt32.self).littleEndian)
            }
            guard recordOffset(productCount) <= count else { return nil }
            var products = [Product?](repeating: nil, count: productCount)
            var bad = false
            let lock = NSLock()
            products.withUnsafeMutableBufferPointer { out in
                DispatchQueue.concurrentPerform(iterations: cores) { slice in
                    for i in (productCount * slice / cores)..<(productCount * (slice + 1) / cores) {
                        guard let p = readProduct(raw, from: recordOffset(i), to: recordOffset(i + 1), strings: strings) else {
                            lock.lock(); bad = true; lock.unlock(); return
                        }
                        out[i] = p
                    }
                }
            }
            guard !bad else { return nil }
            return Catalog(generatedAt: header.generatedAt, categories: header.categories,
                           subcategories: header.subcategories, brands: header.brands,
                           products: products.map { $0! })
        }
    }

    /// Pieces of a decode loop: four per core, so a performance core that
    /// finishes its piece takes the next instead of idling while an
    /// efficiency core works through an equal share (2026-10-18; Dispatch
    /// runs at most one piece per core at a time).
    static var pieces: Int { min(max(ProcessInfo.processInfo.activeProcessorCount, 1), 8) * 4 }

    private static func readProduct(_ raw: UnsafeRawBufferPointer, from start: Int, to end: Int, strings: [String]) -> Product? {
        guard start <= end, end <= raw.count else { return nil }
        var at = start
        var ok = true
        func take(_ n: Int) -> Int { let here = at; at += n; if at > end { ok = false }; return ok ? here : start }
        func u8() -> UInt8 { raw[take(1)] }
        func u16() -> Int { Int(raw.loadUnaligned(fromByteOffset: take(2), as: UInt16.self).littleEndian) }
        func i32() -> Int { Int(raw.loadUnaligned(fromByteOffset: take(4), as: Int32.self).littleEndian) }
        func i64() -> Int64 { raw.loadUnaligned(fromByteOffset: take(8), as: Int64.self).littleEndian }
        func f64() -> Double { Double(bitPattern: raw.loadUnaligned(fromByteOffset: take(8), as: UInt64.self).littleEndian) }
        func str() -> String {
            let i = Int(raw.loadUnaligned(fromByteOffset: take(4), as: UInt32.self).littleEndian)
            guard i < strings.count else { ok = false; return "" }
            return strings[i]
        }
        func optStr() -> String? {
            let i = raw.loadUnaligned(fromByteOffset: take(4), as: UInt32.self).littleEndian
            if i == none { return nil }
            guard Int(i) < strings.count else { ok = false; return nil }
            return strings[Int(i)]
        }
        func list(_ item: () -> String) -> [String] { let n = u16(); return (0..<n).map { _ in item() } }

        let id = str(), brand = str(), title = str(), category = str(), productType = optStr()
        let subs = list(str)
        let price = f64()
        let flags = u8(), clean = u8()
        let more: UInt8 = clean & 128 != 0 ? u8() : 0
        let fourth: UInt8 = more & 128 != 0 ? u8() : 0
        let compareAt: Double? = flags & 1 != 0 ? f64() : nil
        let images = list(str)
        let url = str()
        let variantCount = u16()
        var variants: [Variant] = []
        variants.reserveCapacity(variantCount)
        for _ in 0..<variantCount {
            let vid = i64(), vtitle = str(), vprice = f64(), vflags = u8()
            let vcompare: Double? = vflags & 1 != 0 ? f64() : nil
            let vimage: Int? = vflags & 4 != 0 ? u16() : nil
            variants.append(Variant(id: vid, title: vtitle, price: vprice,
                                    compareAt: vcompare, available: vflags & 2 != 0, image: vimage))
        }
        let tags = list(str)
        let opts: [String]? = clean & 4 != 0 ? list(str) : nil
        let description = flags & 4 != 0 ? str() : nil
        let publishedAt = flags & 8 != 0 ? str() : nil
        let bestRank = flags & 16 != 0 ? i32() : nil
        let currency = flags & 32 != 0 ? str() : nil
        var attrs: [String: [String]]? = nil
        if fourth & 16 != 0 {
            var out: [String: [String]] = [:]
            for _ in 0..<Int(u8()) { let field = str(); out[field] = list(str) }
            attrs = out
        }
        guard ok, at == end else { return nil }
        var p = Product(id: id, brand: brand, title: title, category: category, productType: productType, subs: subs,
                        price: price, compareAt: compareAt, images: images, url: url, available: flags & 2 != 0,
                        variants: variants, tags: tags, description: description, publishedAt: publishedAt,
                        bestRank: bestRank, currency: currency, opts: opts)
        if flags & 64 != 0 { p.organic = flags & 128 != 0 }
        if clean & 3 != 0 { p.clean = clean & 3 == 3 }
        if clean & 8 != 0 { p.metal = clean & 16 != 0 ? "ethical" : "true" }
        if clean & 32 != 0 { p.scent = true }
        if clean & 64 != 0 { p.safer = true }
        if more & 1 != 0 { p.food = true }
        if more & 2 != 0 { p.baby = true }
        if more & 4 != 0 { p.fiber = more & 8 != 0 ? "organic" : "natural" }
        if more & 16 != 0 { p.fabric = true }
        if more & 32 != 0 { p.lab = true }
        if more & 64 != 0 { p.pet = true }
        if fourth & 1 != 0 { p.material = fourth & 2 != 0 ? "veg" : "true" }
        if fourth & 4 != 0 { p.home = fourth & 8 != 0 ? "certified" : "natural" }
        p.attrs = attrs
        return p
    }
}
