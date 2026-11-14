import Foundation

/// The CLIP byte-pair tokenizer MobileCLIP reads text through, ported from
/// open_clip's SimpleTokenizer so a phrase typed on the iPhone becomes the same
/// 77 numbers the Mac turned product titles into (catalog/embed_products.py).
/// MarracatTests/CLIPTokenizerTests checks it against Python's output.
final class CLIPTokenizer: @unchecked Sendable {
    static let contextLength = 77
    static let start = 49406, end = 49407

    private let encoder: [String: Int]
    private let ranks: [Pair: Int]
    private let byteEncoder: [UInt8: Character]
    private var cache: [String: [String]] = [:]
    private let lock = NSLock()
    private let pattern = try! NSRegularExpression(
        pattern: #"'s|'t|'re|'ve|'m|'ll|'d|[\p{L}]+|[\p{N}]|[^\s\p{L}\p{N}]+"#,
        options: [.caseInsensitive])

    private struct Pair: Hashable { let a: String, b: String }

    init?(mergesURL: URL? = Bundle.main.url(forResource: "clip-merges", withExtension: "txt")) {
        guard let mergesURL, let text = try? String(contentsOf: mergesURL, encoding: .utf8) else { return nil }
        let merges = text.split(separator: "\n").map { line -> Pair? in
            let parts = line.split(separator: " ")
            return parts.count == 2 ? Pair(a: String(parts[0]), b: String(parts[1])) : nil
        }
        guard merges.allSatisfy({ $0 != nil }) else { return nil }
        let bytes = Self.bytesToUnicode()
        byteEncoder = bytes
        // Vocabulary order: the 256 byte characters, the same with "</w>",
        // each merge joined, then the two special tokens.
        let ordered = (0...255).map { UInt8($0) }.sorted { Self.order($0) < Self.order($1) }.map { String(bytes[$0]!) }
        var vocab = ordered + ordered.map { $0 + "</w>" }
        vocab += merges.map { $0!.a + $0!.b }
        vocab += ["<start_of_text>", "<end_of_text>"]
        encoder = Dictionary(vocab.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        ranks = Dictionary(merges.enumerated().map { ($1!, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// The 77 token ids for `text`: start, the text's tokens (cut to fit), end, zeros.
    func tokens(_ text: String) -> [Int32] {
        var ids = [Self.start] + encode(text)
        if ids.count > Self.contextLength - 1 { ids = Array(ids.prefix(Self.contextLength - 1)) }
        ids.append(Self.end)
        return (ids + Array(repeating: 0, count: Self.contextLength - ids.count)).map(Int32.init)
    }

    func encode(_ text: String) -> [Int] {
        let clean = text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
        let ns = clean as NSString
        var out: [Int] = []
        for match in pattern.matches(in: clean, range: NSRange(location: 0, length: ns.length)) {
            let piece = ns.substring(with: match.range)
            let mapped = String(piece.utf8.map { byteEncoder[$0]! })
            for word in bpe(mapped) { if let id = encoder[word] { out.append(id) } }
        }
        return out
    }

    private func bpe(_ token: String) -> [String] {
        lock.lock(); if let hit = cache[token] { lock.unlock(); return hit }; lock.unlock()
        var word = token.map(String.init)
        guard !word.isEmpty else { return [] }
        word[word.count - 1] += "</w>"
        while word.count > 1 {
            var best: (rank: Int, index: Int)?
            for i in 0..<(word.count - 1) {
                if let r = ranks[Pair(a: word[i], b: word[i + 1])], best == nil || r < best!.rank { best = (r, i) }
            }
            guard let best else { break }
            let first = word[best.index], second = word[best.index + 1]
            // Merge every occurrence of the pair, left to right, as Python does.
            var merged: [String] = [], i = 0
            while i < word.count {
                if i < word.count - 1, word[i] == first, word[i + 1] == second {
                    merged.append(first + second); i += 2
                } else {
                    merged.append(word[i]); i += 1
                }
            }
            word = merged
        }
        lock.lock(); cache[token] = word; lock.unlock()
        return word
    }

    /// GPT-2's reversible byte -> printable character map.
    private static func bytesToUnicode() -> [UInt8: Character] {
        var map: [UInt8: Character] = [:]
        var printable = Array(33...126) + Array(161...172) + Array(174...255)
        for b in printable { map[UInt8(b)] = Character(UnicodeScalar(b)!) }
        var n = 0
        for b in 0...255 where !printable.contains(b) {
            map[UInt8(b)] = Character(UnicodeScalar(256 + n)!)
            printable.append(b); n += 1
        }
        return map
    }

    /// Python lists the printable bytes first, then the rest in byte order.
    private static func order(_ b: UInt8) -> Int {
        let v = Int(b)
        let printable = (33...126).contains(v) || (161...172).contains(v) || (174...255).contains(v)
        return printable ? v : 1000 + v
    }
}
