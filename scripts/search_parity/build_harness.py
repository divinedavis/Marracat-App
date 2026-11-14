"""Build a command-line copy of the app's search from the app's own source,
for scripts/search_parity.sh (owner, 2026-10-31: the website must search
exactly as the app does).

The functions are copied verbatim out of Marracat/Stores/CatalogStore.swift
(matching, scoring helpers, brand mixing) and compiled with
SearchWords.swift, so an app change is what gets compared. runSearch's
scoring loop and relaxedSearch are restated below line for line, without
the word index (it only narrows candidates) or the colour fallback (the
JS side turns colour words off for the comparison).

    python3 build_harness.py <out dir>
"""
import os, re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)
src = (ROOT / "Marracat/Stores/CatalogStore.swift").read_text()


def extract(name):
    m = re.search(r"^\s*(?:private |fileprivate )?static func " + name + r"\b", src, re.M)
    if not m:
        raise SystemExit(f"CatalogStore.{name} not found")
    i, depth = src.index("{", m.end()), 0
    for j in range(i, len(src)):
        depth += {"{": 1, "}": -1}.get(src[j], 0)
        if depth == 0:
            return src[m.start():j + 1].replace("private static func", "static func")


funcs = "\n\n".join(extract(n) for n in
                    ["containsBytes", "matchesTerm", "matchesWord", "startsWord", "hash", "interleaveBrands", "leadWithBrands", "rankBrandsAndDepartments"])
funcs = funcs.replace("Self.", "CS.")

main = r'''
import Foundation

struct Product: Decodable { let id: String; let brand: String; let title: String; let category: String
    let product_type: String?; let tags: [String]?; let available: Bool }
struct Named: Decodable { let id: String; let name: String }
struct Data_: Decodable { let products: [Product]; let brands: [Named]; let categories: [Named] }

enum CS {
''' + funcs + r'''
}

let args = CommandLine.arguments
let data = try! JSONDecoder().decode(Data_.self, from: try! Data(contentsOf: URL(fileURLWithPath: args[1])))
let queries = try! JSONDecoder().decode([String].self, from: try! Data(contentsOf: URL(fileURLWithPath: args[2])))
let relaxQueries = try! JSONDecoder().decode([String].self, from: try! Data(contentsOf: URL(fileURLWithPath: args[3])))
let seed = Int(args[4])!
let brandNames = Dictionary(data.brands.map { ($0.id, SearchWords.fold($0.name)) }, uniquingKeysWith: { a, _ in a })
let categoryNames = Dictionary(data.categories.map { ($0.id, SearchWords.fold($0.name)) }, uniquingKeysWith: { a, _ in a })
let texts = data.products.map { p in (SearchWords.fold(p.title), SearchWords.fold(([p.product_type ?? ""] + (p.tags ?? [])).joined(separator: " "))) }

// CatalogStore.runSearch, without the word index and the colour fallback.
func search(_ query: String) -> [Product] {
    let (said, audience) = SearchWords.splitAudience(SearchWords.tokens(query))
    let tokens = SearchWords.dropOwnership(said)
    guard !tokens.isEmpty else { return [] }
    let phrase = said.count > 1 ? said.map(SearchWords.singular).joined(separator: " ") : ""
    let alternates: [String: [String]] = Dictionary(tokens.compactMap { t in
        let alts = SearchWords.alternates(SearchWords.singular(t), beside: tokens.count > 1)
        return alts.isEmpty ? nil : (t, alts)
    }, uniquingKeysWith: { a, _ in a })
    var scored: [(Product, Int)] = []
    for (i, p) in data.products.enumerated() {
        let brandName = brandNames[p.brand] ?? "", categoryName = categoryNames[p.category] ?? ""
        let (title, rest) = texts[i]
        var score = 0, allMatched = true
        for t in tokens {
            let singular = SearchWords.singular(t)
            if CS.matchesTerm(title, singular) { score += 4 }
            else if CS.matchesTerm(brandName, singular) { score += 3 }
            else if CS.matchesTerm(categoryName, singular) { score += 2 }
            else if CS.matchesTerm(rest, singular) { score += 1 }
            else if singular.count >= 3, [title, brandName, categoryName, rest].contains(where: { CS.startsWord($0, singular) }) { score += 1 }
            else if let alts = alternates[t], alts.contains(where: { CS.matchesTerm(title, $0) }) { score += 3 }
            else if let alts = alternates[t], alts.contains(where: { CS.matchesTerm(rest, $0) }) { score += 1 }
            else { allMatched = false; break }
        }
        if allMatched {
            let fit = SearchWords.audienceFit(title + " " + rest, audience)
            guard fit >= 0 else { continue }
            if !phrase.isEmpty, CS.matchesTerm(title, phrase) { score += 10 }
            scored.append((p, score + fit * 2 + (p.available ? 1 : 0)))
        }
    }
    return CS.interleaveBrands(CS.rankBrandsAndDepartments(scored, tokens: tokens, brandNames: brandNames), seed: seed)
}

// SearchWordIndex.build's counts, for respelling.
var useCount: [String: Int] = [:]
for (i, p) in data.products.enumerated() {
    var seen = Set<Substring>()
    for field in [texts[i].0, brandNames[p.brand] ?? "", categoryNames[p.category] ?? "", texts[i].1] {
        for w in field.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) where seen.insert(w).inserted { useCount[String(w), default: 0] += 1 }
    }
}
let vocabulary: [(String, Int)] = useCount.keys.sorted().map { ($0, useCount[$0]!) }

// CatalogStore.relaxedSearch.
func relaxedSearch(_ query: String) -> (query: String, results: [Product])? {
    var tokens = SearchWords.dropOwnership(SearchWords.tokens(query))
    guard !tokens.isEmpty, search(query).isEmpty else { return nil }
    let squashed = SearchWords.squash(query)
    if squashed.count >= 4, let b = data.brands.first(where: { SearchWords.squash($0.name) == squashed }) {
        let results = search(b.name)
        if !results.isEmpty { return (b.name, results) }
    }
    if let fixed = SearchWords.respell(query, uses: { useCount[$0] ?? 0 }, vocab: { vocabulary }) {
        let results = search(fixed)
        if !results.isEmpty { return (fixed, results) }
        tokens = SearchWords.dropOwnership(SearchWords.tokens(fixed))
    }
    guard tokens.count > 1 else { return nil }
    while tokens.count > 1 {
        var best: (tokens: [String], results: [Product])?
        for i in tokens.indices {
            var shorter = tokens
            shorter.remove(at: i)
            if SearchWords.onlyFiller(shorter) { continue }
            let results = search(shorter.joined(separator: " "))
            if best == nil || results.count > best!.results.count { best = (shorter, results) }
        }
        guard let best else { return nil }
        if !best.results.isEmpty { return (best.tokens.joined(separator: " "), best.results) }
        tokens = best.tokens
    }
    return nil
}

// SearchResultsView: sold-out results go last.
func shown(_ ps: [Product]) -> [String] { (ps.filter(\.available) + ps.filter { !$0.available }).map(\.id) }
var searches: [String: [String]] = [:]
for q in queries { searches[q] = shown(search(q)) }
var relaxed: [String: Any] = [:]
var guesses: [String: [String]] = [:]
for q in relaxQueries {
    let r = relaxedSearch(q)
    if let r { relaxed[q] = ["q": r.query, "ids": shown(r.results)] }
    else { relaxed[q] = ["q": NSNull(), "ids": [String]()] }
    // CatalogStore.alternatives, as SearchResultsView asks for them.
    guesses[q] = SearchWords.alternatives(q, brandNames: data.brands.map(\.name), vocab: { vocabulary },
                                          count: { search($0).count }, excluding: r?.query)
}
// SearchWords.interests over a few shopper histories (fixed in the harness).
var interests: [String: [String]] = [:]
for (q, searched, aisles) in [("fruit", ["fruit", "bag charm", "Independent"], ["Keychains & Charms", "Tote Bags", "Keychains & Charms"]),
                              ("pink", ["pink top", "perfume", "the co"], []), ("bag", [], ["Tote Bags", "Crossbody Bags", "Crossbody Bags"])] {
    interests[q] = SearchWords.interests(query: q, recentSearches: searched, viewedAisles: aisles).map { "\($0.phrase)|\($0.searched)" }
}
let json = try! JSONSerialization.data(withJSONObject: ["searches": searches, "relaxed": relaxed, "guesses": guesses, "interests": interests], options: [.sortedKeys])
FileManager.default.createFile(atPath: args[5], contents: json)
'''
(out / "main.swift").write_text(main)
(out / "SearchWords.swift").write_text((ROOT / "Marracat/Stores/SearchWords.swift").read_text())
