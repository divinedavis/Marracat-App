import Foundation

/// When each search happened on this phone and whether the shopper acted on
/// it — opened, saved, carted or bought something within half an hour
/// (owner, 2026-10-10: "prefer searches the shopper acted on"). Kept on the
/// phone only; Home uses it to choose which searches inspire its rows and to
/// let holiday searches expire.
struct SearchMemory: Codable, Equatable {
    var searchedAt: [String: Date] = [:]
    var acted: Set<String> = []
    var lastQuery: String?
    var lastAt: Date?

    static let actionWindow: TimeInterval = 30 * 60
    static let keep = 60
    private static let key = "search.memory.v1"

    static func normalized(_ q: String) -> String {
        q.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    mutating func searched(_ q: String, at date: Date = .now) {
        let k = Self.normalized(q)
        guard !k.isEmpty else { return }
        searchedAt[k] = date
        lastQuery = k; lastAt = date
        if searchedAt.count > Self.keep {
            for (old, _) in searchedAt.sorted(by: { $0.value < $1.value }).prefix(searchedAt.count - Self.keep) {
                searchedAt[old] = nil; acted.remove(old)
            }
        }
    }

    /// An open, save, cart or order: credits the latest search if it was recent.
    mutating func noteAction(at date: Date = .now) {
        guard let q = lastQuery, let at = lastAt, date.timeIntervalSince(at) <= Self.actionWindow else { return }
        acted.insert(q)
    }

    func actedOn(_ q: String) -> Bool { acted.contains(Self.normalized(q)) }

    /// A holiday or occasion search past its use: ten days after it was made,
    /// or once its holiday has gone by. A synced search with no date here
    /// lives only while its holiday is coming up.
    func isExpired(_ q: String, now: Date = .now) -> Bool {
        guard let occasion = Occasion.match(q) else { return false }
        let at = searchedAt[Self.normalized(q)]
        if let at, now.timeIntervalSince(at) > 10 * 86_400 { return true }
        // A birthday or wedding has no calendar day; only the ten days apply.
        guard occasion.hasDate else { return false }
        if let at {
            guard let day = occasion.next(onOrAfter: at) else { return false }
            return now > day.addingTimeInterval(86_400)
        }
        // No date: live only in the six weeks before the holiday.
        guard let day = occasion.next(onOrAfter: now) else { return true }
        return day.timeIntervalSince(now) > 45 * 86_400
    }

    // MARK: Stored on this phone

    static func load(_ defaults: UserDefaults = .standard) -> SearchMemory {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(SearchMemory.self, from: $0) } ?? SearchMemory()
    }

    func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }

    static func recordSearch(_ q: String) { var m = load(); m.searched(q); m.save() }
    static func recordAction() { var m = load(); m.noteAction(); m.save() }
    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}

/// Searches tied to a date on the calendar.
enum Occasion: CaseIterable {
    case valentines, mothersDay, fathersDay, graduation, halloween, thanksgiving, blackFriday, christmas
    case birthday, anniversary, wedding, babyShower

    private var phrases: [String] {
        switch self {
        case .valentines: ["valentine"]
        case .mothersDay: ["mothers day", "mother's day", "mother’s day", "mom day"]
        case .fathersDay: ["fathers day", "father's day", "father’s day"]
        case .graduation: ["graduation", "grad gift"]
        case .halloween: ["halloween"]
        case .thanksgiving: ["thanksgiving"]
        case .blackFriday: ["black friday", "cyber monday"]
        case .christmas: ["christmas", "xmas", "holiday gift", "stocking stuffer"]
        case .birthday: ["birthday"]
        case .anniversary: ["anniversary"]
        case .wedding: ["wedding gift", "bridal shower"]
        case .babyShower: ["baby shower"]
        }
    }

    static func match(_ q: String) -> Occasion? {
        let s = q.lowercased()
        return allCases.first { o in o.phrases.contains { s.contains($0) } }
    }

    var hasDate: Bool { ![.birthday, .anniversary, .wedding, .babyShower].contains(self) }

    /// This occasion's day in `year`, at midnight local time.
    func day(in year: Int, calendar: Calendar = .current) -> Date? {
        func nth(_ n: Int, weekday: Int, month: Int) -> Date? {
            calendar.date(from: DateComponents(year: year, month: month, weekday: weekday, weekdayOrdinal: n))
        }
        switch self {
        case .valentines: return calendar.date(from: DateComponents(year: year, month: 2, day: 14))
        case .mothersDay: return nth(2, weekday: 1, month: 5)
        case .fathersDay: return nth(3, weekday: 1, month: 6)
        case .graduation: return calendar.date(from: DateComponents(year: year, month: 6, day: 30))
        case .halloween: return calendar.date(from: DateComponents(year: year, month: 10, day: 31))
        case .thanksgiving: return nth(4, weekday: 5, month: 11)
        case .blackFriday: return nth(4, weekday: 5, month: 11).flatMap { calendar.date(byAdding: .day, value: 4, to: $0) }
        case .christmas: return calendar.date(from: DateComponents(year: year, month: 12, day: 25))
        default: return nil
        }
    }

    /// The first occurrence on or after `date`'s day.
    func next(onOrAfter date: Date, calendar: Calendar = .current) -> Date? {
        let start = calendar.startOfDay(for: date)
        let year = calendar.component(.year, from: date)
        for y in year...(year + 1) { if let d = day(in: y, calendar: calendar), d >= start { return d } }
        return nil
    }
}
