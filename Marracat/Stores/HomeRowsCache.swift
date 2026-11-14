import Foundation

/// Home's personal rows exactly as this shopper last had them: "Picked for
/// you right now", "Time to restock?", the "Inspired by your search…" /
/// "Inspired by your likes" rows and "Keep shopping for", with the products
/// themselves rather than their ids.
///
/// Owner, 2026-10-11: "we definitely want these two rows to load early before
/// the user sees them loading into the screen". Those rows need the whole
/// catalog (search, scoring every product) or the on-device taste
/// (MeaningIndex), which land a second or more after Home draws from its
/// slice, so they popped in under the shopper, swapped products and pushed
/// the page down mid-scroll. Saved after every build of them and as the app
/// leaves the screen, read beside Home's slice before Home draws, they're on
/// Home's first frame; fresh ones replace them only at the next fresh visit
/// (leaving the tab, the app going to the background, pull-to-refresh, a new
/// search), never while they're on screen.
struct HomeRows: Codable, Equatable {
    struct Row: Codable, Equatable {
        let id: String
        let title: String
        let products: [Product]
        var reserved: [String] = []
    }

    var picked: [Product] = []
    var pickedReserved: [String] = []
    var restock: [Product] = []
    var rows: [Row] = []
    var keepShopping: [Product] = []

    var isEmpty: Bool { picked.isEmpty && restock.isEmpty && rows.isEmpty && keepShopping.isEmpty }

    /// Without what the shopper has hidden since; a row that falls under the
    /// four a row needs goes.
    func hiding(_ hidden: Set<String>) -> HomeRows {
        guard !hidden.isEmpty else { return self }
        func keep(_ ps: [Product], min: Int = 1) -> [Product] {
            let kept = ps.filter { !hidden.contains($0.id) }
            return kept.count >= min ? kept : []
        }
        var out = self
        out.picked = keep(picked, min: 4)
        out.restock = keep(restock)
        out.keepShopping = keep(keepShopping)
        out.rows = rows.compactMap { r in
            let ps = keep(r.products, min: 4)
            return ps.isEmpty ? nil : Row(id: r.id, title: r.title, products: ps, reserved: r.reserved)
        }
        return out
    }
}

enum HomeRowsCache {
    /// Caches: personal, rebuildable, and not worth an iCloud backup.
    static var url: URL? {
        try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("home-rows-v1.json")
    }

    /// The rows last saved, or nil. A UI test run that starts from a reset
    /// (-UITEST_RESET) starts with none, like the rest of its history;
    /// -NO_SAVED_HOME_ROWS keeps the history but drops the rows, as the first
    /// launch of a new build sees it (Home opens on placeholders).
    static func load(from url: URL? = url) -> HomeRows? {
        guard let url else { return nil }
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-UITEST_RESET") || args.contains("-NO_SAVED_HOME_ROWS") {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(HomeRows.self, from: data)
    }

    /// Written off the main thread, latest call last: a few dozen products,
    /// tens of kilobytes.
    static func save(_ rows: HomeRows, to url: URL? = url) {
        guard let url else { return }
        queue.async {
            if rows.isEmpty { try? FileManager.default.removeItem(at: url); return }
            guard let data = try? JSONEncoder().encode(rows) else { return }
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    static func clear(_ url: URL? = url) { save(HomeRows(), to: url) }

    /// Waits for the writes queued so far (tests).
    static func flush() { queue.sync {} }

    private static let queue = DispatchQueue(label: "marracat.home-rows", qos: .utility)
}

/// Home's "Shop by style" boards as last worked out: each style's id and
/// the six products its collage shows. Working them out takes the on-device
/// AI model and ten searches of the meaning space, a second or more after
/// launch, so the row came in late and the launch cover waited on it
/// (owner, build 132). Read beside Home's slice like HomeRows, the row is on
/// Home's first frame; this session's boards are saved for the next launch.
struct StyleBoards: Codable, Equatable {
    struct Board: Codable, Equatable {
        let id: String
        let products: [Product]
    }
    var boards: [Board] = []
}

enum StyleBoardsCache {
    static var url: URL? {
        try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("style-boards-v1.json")
    }

    /// Dropped with the rest of the saved rows by -UITEST_RESET and
    /// -NO_SAVED_HOME_ROWS.
    static func load(from url: URL? = url) -> StyleBoards? {
        guard let url else { return nil }
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-UITEST_RESET") || args.contains("-NO_SAVED_HOME_ROWS") {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        guard let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(StyleBoards.self, from: data),
              !saved.boards.isEmpty else { return nil }
        return saved
    }

    static func save(_ boards: StyleBoards, to url: URL? = url) {
        guard let url else { return }
        queue.async {
            if boards.boards.isEmpty { try? FileManager.default.removeItem(at: url); return }
            guard let data = try? JSONEncoder().encode(boards) else { return }
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    static func flush() { queue.sync {} }

    private static let queue = DispatchQueue(label: "marracat.style-boards", qos: .utility)
}

extension Array where Element == Product {
    /// One of each product a shopper would take for the same thing: the same
    /// brand and the same name as far as a tile shows it (its first four
    /// words). Owner, 2026-10-11: "The Rich One Moisture Repair…" twice in one
    /// row — Fenty Hair's shampoo and conditioner, which a two-line tile cuts
    /// to the same words — and shade or size listings of one product.
    func distinctLooking() -> [Product] {
        var seen = Set<String>()
        return filter { seen.insert(Self.lookKey($0)).inserted }
    }

    static func lookKey(_ p: Product) -> String {
        let words = p.title.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .prefix(4)
            .joined(separator: " ")
        return p.brand + "|" + (words.isEmpty ? p.id : words)
    }
}
