import Foundation

/// How a search reads its words (owner, 2026-10-15, after a shopper's
/// "musthavejoy" found nothing while "must have joy" found 259, and "pink
/// shirt women" found 13 against "pink shirt"'s 87). The website does the
/// same in web/src/search-words.js.
enum SearchWords {
    /// Lowercase, accents off ("Adèle" -> "adele"), apostrophes dropped
    /// ("Women's" -> "womens"). Applied to the query and to every product's
    /// search text alike. Plain ASCII without an apostrophe, nearly every
    /// title, skips the folding.
    static func fold(_ s: String) -> String {
        let lower = s.lowercased()
        // One pass decides what's needed: Foundation's folding is slow, and
        // running it on every title with a "’" or "—" in the search index
        // (built while Home first scrolls) cost ~35 ms of Home's longest stall.
        var accents = false, quotes = false
        for u in lower.unicodeScalars {
            switch u.value {
            case 39, 96, 0x2018, 0x2019: quotes = true
            case 0xC0...0x24F, 0x300...0x36F: accents = true
            default: break
            }
        }
        guard accents || quotes else { return lower }
        var out = accents ? lower.folding(options: [.diacriticInsensitive], locale: nil) : lower
        if quotes { out.unicodeScalars.removeAll { [39, 96, 0x2018, 0x2019].contains($0.value) } }
        return out
    }

    /// The query's words, folded.
    static func tokens(_ query: String) -> [String] {
        fold(query).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// A plural matched by its singular: "shirts" -> "shirt", and "dresses",
    /// "watches", "boxes" lose the "es" ("dresse" matched no "Dress").
    static func singular(_ w: String) -> String {
        if w.count > 4, ["sses", "shes", "ches", "xes"].contains(where: w.hasSuffix) { return String(w.dropLast(2)) }
        if w.count > 3, w.hasSuffix("s"), !w.hasSuffix("ss") { return String(w.dropLast()) }
        return w
    }

    enum Audience { case women, men }
    static let women: Set<String> = ["women", "womens", "woman", "ladies", "lady", "female", "her", "hers"]
    static let men: Set<String> = ["men", "mens", "man", "male", "gents", "him", "his"]
    private static let womenMarks: Set<String> = ["women", "womens", "woman", "womans", "ladies", "lady", "female", "girl", "girls"]
    private static let menMarks: Set<String> = ["men", "mens", "man", "mans", "male", "gents", "guys", "boy", "boys"]

    /// "women"/"men" are a preference, not words a product must contain: few
    /// titles say "women", so requiring it dropped most women's shirts. The
    /// query's other words, and the audience named; a query of nothing but
    /// audience words keeps them.
    static func splitAudience(_ words: [String]) -> (words: [String], audience: Audience?) {
        var audience: Audience?
        var rest: [String] = []
        for w in words {
            let a: Audience? = women.contains(w) ? .women : men.contains(w) ? .men : nil
            if let a, audience == nil || audience == a { audience = a } else { rest.append(w) }
        }
        return rest.isEmpty ? (words, nil) : (rest, audience)
    }

    /// "independent" says who a brand is, and every brand on Marracat is: a
    /// shopper's "independent bag charms" wants every bag charm, not the black
    /// ones (owner, 2026-11-01: it found nothing, then only black-coloured
    /// charms). "independent", "independent", "independent", "independent" and the
    /// near spellings in ownershipSpan leave the query when other words remain; alone they stay. A title that
    /// says the whole query still goes first. As dropOwnership in
    /// web/src/search-words.js.
    static func dropOwnership(_ words: [String]) -> [String] {
        var rest: [String] = []
        var i = 0
        while i < words.count {
            let n = ownershipSpan(words, at: i)
            if n > 0 { i += n; continue }
            rest.append(words[i])
            i += 1
        }
        return rest.isEmpty ? words : rest
    }

    /// How many words at `i` say "independent": 1 for "independent" /
    /// "independent", 2 for black|blk followed by owned, own, ownd, owner or
    /// owners (owner, 2026-11-08: the notice shows for "independent" with any
    /// words before or after, and its near spellings), else 0. As
    /// ownershipSpan in web/src/search-words.js.
    static let ownershipJoined: Set<String> = ["independent", "independent"]
    static let ownershipSecond: Set<String> = ["owned", "own", "ownd", "owner", "owners"]
    static func ownershipSpan(_ words: [String], at i: Int) -> Int {
        if ownershipJoined.contains(words[i]) { return 1 }
        if words[i] == "black" || words[i] == "blk", i + 1 < words.count, ownershipSecond.contains(words[i + 1]) { return 2 }
        return 0
    }

    /// Words that name a business rather than a thing ("xennial co"). Dropping
    /// the unknown name from a search must not leave only these: "co" alone
    /// matched 6,627 products (2026-11-01).
    static let filler: Set<String> = ["co", "company", "inc", "llc", "ltd", "the", "shop", "store", "brand"]
    static func onlyFiller(_ words: [String]) -> Bool { words.allSatisfy(filler.contains) }

    /// -1 marked for the other audience (left out), 1 marked for this one or
    /// unisex, 0 neither. `text` is folded.
    static func audienceFit(_ text: String, _ audience: Audience?) -> Int {
        guard let audience else { return 0 }
        let words = Set(text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        let mine = audience == .women ? womenMarks : menMarks
        let other = audience == .women ? menMarks : womenMarks
        if !words.isDisjoint(with: mine) || words.contains("unisex") { return 1 }
        return words.isDisjoint(with: other) ? 0 : -1
    }

    /// Damerau-Levenshtein distance, giving up past `max`.
    static func distance(_ a: String, _ b: String, max: Int = 2) -> Int {
        let a = Array(a), b = Array(b)
        guard abs(a.count - b.count) <= max else { return max + 1 }
        if a.isEmpty || b.isEmpty { return Swift.max(a.count, b.count) }
        var d = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        for i in 1...a.count {
            var best = Int.max
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1) }
                best = min(best, d[i][j])
            }
            if best > max { return max + 1 }
        }
        return d[a.count][b.count]
    }

    /// Letters and digits only, folded: "Fear of God" and "fearofgod" are
    /// both "fearofgod", so a brand typed as one word, or as its domain or
    /// handle, still finds it (owner, 2026-10-20).
    static func squash(_ s: String) -> String {
        String(fold(s).filter { $0.isLetter || $0.isNumber })
    }

    /// "musthavejoy" -> "must have joy": the split into 2 or 3 known words of
    /// 3+ letters whose rarest word is most used ("bangsi" is not "bang si").
    /// Each word must be on 2+ products, as closestWord asks: "xennial" split
    /// into "xen nial" off one product's "nial" (2026-11-01).
    /// `uses` is how many products use a word, 0 for none.
    static func splitRunTogether(_ word: String, uses: (String) -> Int) -> String? {
        let c = Array(word)
        // Long words are pasted junk, and every split is a lookup.
        guard c.count >= 6, c.count <= 30 else { return nil }
        var best: (parts: [String], score: Int)?
        func consider(_ parts: [String]) {
            guard parts.allSatisfy({ $0.count >= 3 }) else { return }
            let counts = parts.map(uses)
            guard let score = counts.min(), score >= 2 else { return }
            if best == nil || parts.count < best!.parts.count || (parts.count == best!.parts.count && score > best!.score) {
                best = (parts, score)
            }
        }
        for i in 3...(c.count - 3) {
            consider([String(c[..<i]), String(c[i...])])
            var j = i + 3
            while j <= c.count - 3 {
                consider([String(c[..<i]), String(c[i..<j]), String(c[j...])])
                j += 1
            }
        }
        return best?.parts.joined(separator: " ")
    }

    /// The closest known word to a misspelling: one edit for 4–7 letters, two
    /// from 8; the most used wins a tie. `vocab` is every known word with its uses.
    /// `slack` allows that many more edits (alternatives() guesses wider).
    static func closestWord(_ word: String, vocab: some Sequence<(String, Int)>, slack: Int = 0) -> String? {
        guard word.count >= 4, word.count <= 20, !word.contains(where: \.isNumber) else { return nil }
        let max = (word.count >= 8 ? 2 : 1) + slack
        let first = Array(word)
        var best: (w: String, d: Int, n: Int)?
        for (w, n) in vocab where n >= 2 && abs(w.count - word.count) <= max {
            let wc = Array(w)
            guard wc.count > 1, wc[0] == first[0] || wc[1] == first[1] else { continue }
            let d = distance(word, w, max: max)
            if d <= max, best == nil || d < best!.d || (d == best!.d && n > best!.n) { best = (w, d, n) }
        }
        return best?.w
    }

    /// The query with each word no product uses split ("musthavejoy") or
    /// corrected ("hodie"), or nil when nothing changed.
    static func respell(_ query: String, uses: (String) -> Int, vocab: () -> [(String, Int)]) -> String? {
        var changed = false
        var all: [(String, Int)]?
        let out = tokens(query).map { w -> String in
            guard uses(w) == 0, uses(singular(w)) == 0 else { return w }
            if let split = splitRunTogether(w, uses: uses) { changed = true; return split }
            if all == nil { all = vocab() }
            if let fixed = closestWord(w, vocab: all!) { changed = true; return fixed }
            return w
        }
        return changed ? out.joined(separator: " ") : nil
    }

    // MARK: - Brand lead, other words, the ownership notice, guesses, picks
    // Owner, 2026-11-03, after a returning shopper's searches: lead with a
    // brand when its name is searched, add synonyms, show a charm or two to
    // someone who has been looking at charms, suggest what a search meant
    // instead of "no results", and say that everything here is independent
    // when that is searched. As web/src/search-words.js, line for line.

    /// Does a search name this brand? Its words, business words aside, are the
    /// first words of the brand's name: "fraiche" names Fraîche Studios,
    /// "xennial co" The Xennial Co. `words` is how many words named it;
    /// `full` when they are the whole name.
    static func namesBrand(_ words: [String], brandName: String) -> (matches: Bool, full: Bool, words: Int) {
        let q = words.filter { !filler.contains($0) }
        let b = tokens(brandName).filter { !filler.contains($0) }
        guard !q.isEmpty, q.count <= b.count, q.joined().count >= 3 else { return (false, false, 0) }
        for i in q.indices where q[i] != b[i] && singular(q[i]) != singular(b[i]) { return (false, false, 0) }
        return (true, q.count == b.count, q.count)
    }

    /// A search that names a brand puts that brand first, unless its words
    /// are an everyday word that other brands' products use more than the
    /// brand itself does: "black" names twenty brands, "okra" names O'kra's 3
    /// products and 58 others. A brand's whole name of two or more words
    /// always leads. `own`/`others`: matching products in and outside it.
    static func leadsWithBrand(_ named: (matches: Bool, full: Bool, words: Int), own: Int, others: Int) -> Bool {
        named.matches && own > 0 && ((named.full && named.words >= 2) || others <= own)
    }

    /// What leading adds to a brand's products' scores: more than any match
    /// elsewhere can score, so the brand comes first.
    static let brandLeadBonus = 20

    /// Departments a search barely touches (owner, 2026-11-03: craft kits
    /// and tea outranked real bag charms and purses). Only for a focused
    /// search: 10+ matches with one department holding 2 in 5 of them, and
    /// no brand leading. Then a department whose products merely mention
    /// things (craft kits and supplies, food and tea, book and album titles,
    /// cards, stationery, toys) is off topic when it holds under 1 in 20 of
    /// a one-word search's matches, or under 1 in 8 of a longer one's
    /// ("bag charm fruit"), and its products drop by offDepartmentPenalty,
    /// below everything on topic. A broad word ("pink") moves nothing, and a
    /// search naming that thing ("felting kit", "tea") makes it the main
    /// department. `counts`: matches per department; `words`: the search's.
    static let mentioningDepartments: Set<String> = ["crafts", "grocery", "books", "music", "party", "office", "toys"]
    static func offDepartments(_ counts: [String: Int], total: Int, words: Int) -> Set<String> {
        guard total >= 10, let top = counts.values.max(), top * 5 >= total * 2 else { return [] }
        let share = words > 1 ? 8 : 20
        return Set(counts.filter { mentioningDepartments.contains($0.key) && $0.value * share < total }.keys)
    }
    static let offDepartmentPenalty = 15

    /// Other words for a search word, keyed by its singular. `always`: the
    /// same thing ("keyring" is a keychain). `beside`: a looser kind, counted
    /// only beside other words, which pick the candidates, as a colour is:
    /// "bag charm fruit" finds the cherry charm, "fruit" alone stays fruit.
    /// A product matching only another word scores below one using the word.
    static let alwaysAlternates: [String: [String]] = [
        "keychain": ["key chain", "keyring", "key ring", "key fob"],
        "keyring": ["keychain", "key chain", "key ring"],
    ]
    static let besideAlternates: [String: [String]] = [
        "keychain": ["charm"],
        "keyring": ["charm"],
        "charm": ["keychain", "keyring", "key chain"],
        "fruit": ["strawberry", "strawberries", "cherry", "cherries", "apple", "lemon", "banana", "pineapple",
                  "watermelon", "grape", "mango", "kiwi", "berry", "berries", "pear", "plum", "fig", "citrus"],
    ]
    static func alternates(_ singular: String, beside: Bool) -> [String] {
        (alwaysAlternates[singular] ?? []) + (beside ? besideAlternates[singular] ?? [] : [])
    }

    /// Does the search say "independent" (any spelling dropOwnership takes)?
    /// Then the results say that everything on Marracat is (owner, 2026-11-03).
    static func saysOwnership(_ words: [String]) -> Bool {
        words.indices.contains { ownershipSpan(words, at: $0) > 0 }
    }

    /// What a search probably meant, for when it found nothing or only a
    /// guess: brands spelled close to it, the query respelled allowing one
    /// more edit, then each of its own words that finds something, most
    /// results first. Only guesses that find products, never the query
    /// itself or `excluding`; up to `limit`. `count` runs a search.
    static func alternatives(_ query: String, brandNames: [String], vocab: () -> [(String, Int)],
                             count: (String) -> Int, excluding: String? = nil, limit: Int = 3) -> [String] {
        var out: [String] = []
        // Compared without business words: "xennial co" is The Xennial Co.
        func keyOf(_ s: String) -> String { squash(tokens(s).filter { !filler.contains($0) }.joined()) }
        var seen: Set<String> = [keyOf(query)]
        if let excluding { seen.insert(keyOf(excluding)) }
        let shownWords = Set(tokens(excluding ?? ""))
        func offer(_ guess: String) {
            let key = keyOf(guess)
            guard out.count < limit, !key.isEmpty, seen.insert(key).inserted, count(guess) > 0 else { return }
            out.append(guess)
        }
        // A brand spelled close to the whole search ("xenial co" -> The Xennial Co).
        let sq = squash(tokens(query).filter { !filler.contains($0) }.joined())
        if sq.count >= 4 {
            let max = sq.count >= 8 ? 2 : 1
            var close: [(name: String, d: Int)] = []
            for name in brandNames {
                let bs = squash(tokens(name).filter { !filler.contains($0) }.joined())
                guard !bs.isEmpty else { continue }
                let d = bs.hasPrefix(sq) ? 0 : distance(sq, bs, max: max)
                if d <= max { close.append((name, d)) }
            }
            close.sort { $0.d != $1.d ? $0.d < $1.d : $0.name < $1.name }
            for c in close.prefix(2) { offer(c.name) }
        }
        // The words respelled a little more loosely than the automatic fix.
        let words = tokens(query)
        let all = vocab()
        let known = Set(all.lazy.filter { $0.1 >= 2 }.map(\.0))
        var changed = false
        let loose = words.map { w -> String in
            guard !known.contains(w), !known.contains(singular(w)), let fixed = closestWord(w, vocab: all, slack: 1) else { return w }
            changed = true
            return fixed
        }
        if changed { offer(loose.joined(separator: " ")) }
        // Then each word on its own, the one finding most first.
        if words.count > 1 {
            // Not a word of the search already shown ("bag charm 3d" shows "bag charm").
            let single = words.filter { $0.count >= 3 && !filler.contains($0) && !shownWords.contains($0) }.map { ($0, count($0)) }
            for (w, n) in single.sorted(by: { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }) where n > 0 { offer(w) }
        }
        return out
    }

    /// Show a brand guess instead of the shortened or respelled search when
    /// the brand's name is closer to what was typed: "brandon blakwod" is
    /// Brandon Blackwood, not "brandon"; "xennail" The Xennial Co, not
    /// "nail". Business words aside, by edit distance.
    static func prefersGuess(_ query: String, guess: String, over relaxed: String) -> Bool {
        func keyOf(_ s: String) -> String { squash(tokens(s).filter { !filler.contains($0) }.joined()) }
        let q = keyOf(query)
        return distance(q, keyOf(guess), max: 64) < distance(q, keyOf(relaxed), max: 64)
    }

    /// What a shopper has been looking at, for "Picked for you" on a short
    /// search: their recent searches, newest first, then the aisles of what
    /// they viewed, most viewed first. Phrases sharing a word with the
    /// search, or holding only business or ownership words, are skipped.
    /// Up to three, each with whether it was a search.
    static func interests(query: String, recentSearches: [String], viewedAisles: [String]) -> [(phrase: String, searched: Bool)] {
        let said = Set(dropOwnership(tokens(query)).map(singular))
        var aisleCount: [String: Int] = [:], aisleOrder: [String] = []
        for a in viewedAisles where !a.isEmpty {
            if aisleCount[a] == nil { aisleOrder.append(a) }
            aisleCount[a, default: 0] += 1
        }
        let aisles = aisleOrder.enumerated().sorted { aisleCount[$0.element]! != aisleCount[$1.element]! ? aisleCount[$0.element]! > aisleCount[$1.element]! : $0.offset < $1.offset }.map(\.element)
        var out: [(phrase: String, searched: Bool)] = []
        var seen = Set<String>()
        for (phrase, searched) in recentSearches.prefix(5).map({ ($0, true) }) + aisles.prefix(3).map({ ($0, false) }) {
            let words = dropOwnership(tokens(phrase)).filter { !filler.contains($0) }
            let key = words.map(singular).joined(separator: " ")
            guard !words.isEmpty, !saysOwnership(words), words.allSatisfy({ !said.contains(singular($0)) }), seen.insert(key).inserted else { continue }
            out.append((phrase, searched))
            if out.count == 3 { break }
        }
        return out
    }
}
