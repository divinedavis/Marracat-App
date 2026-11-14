import XCTest
@testable import Marracat

@MainActor
final class SearchCompletionTests: XCTestCase {
    /// Typing a phrase finishes it from real product titles, Amazon-style.
    func testSuggestionsFinishTheTypedPhrase() throws {
        let catalog = CatalogStore(synchronously: true)
        let rows = catalog.suggestions("sea moss")
        print("sea moss →", rows.map(\.text))
        XCTAssertTrue(rows.first?.searchesAll == true, "the typed words stay the first row")
        let finishes = rows.dropFirst().filter { $0.text.lowercased().hasPrefix("sea moss ") }
        XCTAssertGreaterThanOrEqual(finishes.count, 3, "expected several '… sea moss X' finishes, got \(rows.map(\.text))")
    }

    /// Eight trending terms plus two brands for "shea" once sent prefix() a
    /// negative count and crashed the app on that keystroke (2026-10-20).
    /// Every limit, on queries heavy in trending terms and brands, returns.
    func testSuggestionsNeverCrashOnFullRows() throws {
        let catalog = CatalogStore(synchronously: true)
        for q in ["shea", "shea butter", "sh", "hair", "black soap", "bag"] {
            XCTAssertFalse(catalog.suggestions(q).isEmpty, q)
            for limit in 0...12 { _ = catalog.suggestions(q, limit: limit) }
        }
    }

    /// Finishing the phrase must not push the category itself off the list.
    func testCategoryStillSuggested() throws {
        let catalog = CatalogStore(synchronously: true)
        let rows = catalog.suggestions("bag")
        print("bag →", rows.map { "\($0.text)[\($0.kind)]" })
        XCTAssertTrue(rows.contains { $0.kind == .category("bags") }, "got \(rows.map(\.text))")
    }

    /// Suggestions run on every keystroke, so finishing must stay cheap.
    func testFinishingIsFastPerKeystroke() throws {
        let catalog = CatalogStore(synchronously: true)
        var clock = ContinuousClock.now
        // The title index is built on the first two-letter query (one letter
        // never finishes anything), which the app does in the background once
        // the catalog lands. Until 2026-10-02 this warmed with "b", which never
        // built it, so the build landed in the per-keystroke average.
        _ = catalog.suggestions("bo")
        print("first two-letter keystroke (builds the index):", ContinuousClock.now - clock)
        clock = .now
        var typed = ""
        for ch in "body wash" { typed.append(ch); _ = catalog.suggestions(typed) }
        let perKey = (ContinuousClock.now - clock) / 9
        print("per keystroke:", perKey)
        XCTAssertLessThan(perKey, .milliseconds(150))
    }

    /// The worst case is a short, common prefix. One or two letters once held
    /// the main thread for minutes (a quadratic pass over every finish); every
    /// one- and two-letter prefix of common words must now come back quickly.
    func testShortCommonPrefixesStayFast() throws {
        let catalog = CatalogStore(synchronously: true)
        _ = catalog.suggestions("zz")   // build the index and vocabulary first
        var worst: (String, Duration) = ("", .zero)
        for q in ["s", "sh", "b", "bo", "c", "ca", "t", "th", "m", "ma", "p", "pr", "la", "de", "co", "bl"] {
            let clock = ContinuousClock.now
            _ = catalog.suggestions(q)
            let took = ContinuousClock.now - clock
            if took > worst.1 { worst = (q, took) }
        }
        print("slowest short prefix:", worst)
        XCTAssertLessThan(worst.1, .milliseconds(300), "'\(worst.0)' took \(worst.1)")
    }

    /// A half-typed last word is completed before being extended.
    func testHalfTypedWordIsCompleted() throws {
        let catalog = CatalogStore(synchronously: true)
        let texts = catalog.suggestions("lip gl").map { $0.text.lowercased() }
        print("lip gl →", texts)
        XCTAssertTrue(texts.contains("lip gloss"), "got \(texts)")
    }

    /// Finishes never end on a dangling word or run past a title's separator.
    func testFinishesEndCleanly() throws {
        let catalog = CatalogStore(synchronously: true)
        for q in ["shea butter", "candle", "hoodie", "laundry detergent", "wig"] {
            let finishes = catalog.completions(q)
            print(q, "→", finishes.prefix(9).map(\.text))
            for f in finishes {
                let last = f.text.split(separator: " ").last.map(String.init) ?? ""
                XCTAssertFalse(["and", "for", "with", "the", "of", "in", "by", "&"].contains(last), f.text)
            }
            // Whole-word finishes lead: "wig" before "wiggle".
            if let first = finishes.first { XCTAssertTrue(first.exactWord, "\(q) led with \(first.text)") }
        }
    }

    /// One word no product uses must not empty the page: "bulk t shirts"
    /// falls back to "t shirts" and says so.
    func testUnknownWordFallsBackToTheRestOfTheSearch() throws {
        let catalog = CatalogStore(synchronously: true)
        XCTAssertTrue(catalog.search("bulk t shirts").isEmpty, "precondition: no product says bulk")
        let relaxed = try XCTUnwrap(catalog.relaxedSearch("bulk t shirts"))
        XCTAssertEqual(relaxed.query, "t shirts")
        XCTAssertTrue(relaxed.results.prefix(10).allSatisfy { $0.title.lowercased().contains("shirt") },
                      relaxed.results.prefix(10).map(\.title).description)
        XCTAssertNil(catalog.relaxedSearch("t shirts"), "a search that already matches needs no fallback")
        XCTAssertNil(catalog.relaxedSearch("zzqxv wqkjx"), "gibberish still ends in the empty state")
    }
}
