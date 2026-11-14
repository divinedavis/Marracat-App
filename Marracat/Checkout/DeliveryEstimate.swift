import Foundation

/// When a delivery option should arrive, worked out from what the store says
/// about it — never invented. UCP's fulfillment option carries a renderable
/// `description` ("Arrives in 4 business days", "Arrives Dec 12-15 via
/// FedEx") and optional `earliest_fulfillment_time` / `latest_fulfillment_time`
/// (ucp.dev 2026-08-25, Fulfillment extension). Shopify stores send the
/// description only, worded "3 to 5 business days", "2 Business Days",
/// "Monday, October 19–Wednesday, October 21", "Ship by: 14-Oct-2026;
/// Delivery by: 15-Oct-2026" (live replies, 2026-10-13); some put the days in
/// the title instead ("Fedex Ground Economy (7 to 10 business days)").
///
/// - "N to M business days" is projected onto the calendar from today,
///   skipping weekends and US federal holidays, and labelled "Est." because
///   the brand's own handling time isn't in it.
/// - Explicit dates, or anything else the store wrote, are shown as given.
/// - Nothing at all → no estimate.
struct DeliveryEstimate: Equatable {
    /// "Est. arrives Oct 17–20", "Arrives Oct 15", or the store's own words.
    let text: String
    /// The store's wording says the days count from shipping or after
    /// processing, so the real date is later still.
    let excludesHandling: Bool

    private static let businessDays = try! NSRegularExpression(
        pattern: #"(\d+)(?:\s*(?:to|-|–)\s*(\d+))?\s*business\s+days?"#, options: [.caseInsensitive])
    private static let handling = try! NSRegularExpression(
        pattern: #"after ship|from (?:the )?(?:date of )?ship|after dispatch|processing|typically ship"#, options: [.caseInsensitive])

    static func make(title: String?, description: String?, earliest: String? = nil, latest: String? = nil,
                     from start: Date = .now, calendar: Calendar = .marracatUS) -> DeliveryEstimate? {
        let words = [description, title].compactMap { $0 }.joined(separator: " ")
        let handlingNote = handling.firstMatch(in: words, range: NSRange(words.startIndex..., in: words)) != nil
        // Dates the store states outright come first.
        if let first = parseDate(earliest, calendar) ?? parseDate(latest, calendar) {
            let last = parseDate(latest, calendar) ?? first
            let when = range(first, max(first, last), calendar: calendar)
            return DeliveryEstimate(text: String(localized: "Arrives \(when)", comment: "Delivery estimate the store stated; the argument is a date or range like Oct 17–20"), excludesHandling: handlingNote)
        }
        // The description, then the title, for "N (to M) business days".
        for source in [description, title].compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) }) where !source.isEmpty {
            if let (low, high) = days(in: source) {
                let a = add(businessDays: low, to: start, calendar: calendar)
                let b = add(businessDays: high, to: start, calendar: calendar)
                let when = range(a, b, calendar: calendar)
                return DeliveryEstimate(text: String(localized: "Est. arrives \(when)", comment: "Estimated delivery; the argument is a date or range like Oct 17–20"), excludesHandling: handlingNote)
            }
        }
        // Anything else in the description (dates, "Within 3 days…") is the
        // store's own estimate, shown as written. A title is already on screen.
        if let d = description?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty {
            return DeliveryEstimate(text: d, excludesHandling: handlingNote)
        }
        return nil
    }

    /// The business-day range in a phrase: (3, 5) for "3 to 5 business days",
    /// (2, 2) for "2 Business Days". A reversed range is put in order.
    static func days(in text: String) -> (Int, Int)? {
        guard let m = businessDays.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r1 = Range(m.range(at: 1), in: text), let low = Int(text[r1]) else { return nil }
        let high = Range(m.range(at: 2), in: text).flatMap { Int(text[$0]) } ?? low
        guard low <= 60, high <= 60 else { return nil }   // not a delivery window
        return (min(low, high), max(low, high))
    }

    /// `n` business days after `start`: weekends and US federal holidays
    /// don't count, so Friday + 1 is Monday.
    static func add(businessDays n: Int, to start: Date, calendar: Calendar = .marracatUS) -> Date {
        var day = calendar.startOfDay(for: start)
        var left = n
        while left > 0 {
            day = calendar.date(byAdding: .day, value: 1, to: day)!
            if isBusinessDay(day, calendar: calendar) { left -= 1 }
        }
        return day
    }

    static func isBusinessDay(_ day: Date, calendar: Calendar = .marracatUS) -> Bool {
        !calendar.isDateInWeekend(day) && !USHolidays.isHoliday(day, calendar: calendar)
    }

    /// "Oct 17–20", "Oct 30–Nov 2", "Oct 17".
    static func range(_ a: Date, _ b: Date, calendar: Calendar = .marracatUS) -> String {
        let month = DateFormatter(), day = DateFormatter()
        // English keeps its fixed "Oct 17"; other languages get their own
        // month names and day-month order ("17. Okt.").
        let english = Bundle.main.preferredLocalizations.first?.hasPrefix("en") ?? true
        month.calendar = calendar; month.timeZone = calendar.timeZone
        month.locale = english ? Locale(identifier: "en_US_POSIX") : .current
        day.calendar = calendar; day.timeZone = calendar.timeZone; day.locale = month.locale
        if english { month.dateFormat = "MMM d" } else { month.setLocalizedDateFormatFromTemplate("MMMd") }
        day.dateFormat = "d"
        if calendar.isDate(a, inSameDayAs: b) { return month.string(from: a) }
        let sameMonth = calendar.component(.month, from: a) == calendar.component(.month, from: b)
        return month.string(from: a) + "–" + (sameMonth ? day.string(from: b) : month.string(from: b))
    }

    /// A full timestamp as stated; a bare "2026-10-17" as that day here, not
    /// midnight UTC (which is the day before in the US).
    private static func parseDate(_ s: String?, _ calendar: Calendar) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        if let d = ISO8601DateFormatter().date(from: s) { return d }
        let dateOnly = ISO8601DateFormatter()
        dateOnly.formatOptions = [.withFullDate]
        dateOnly.timeZone = calendar.timeZone
        return dateOnly.date(from: String(s.prefix(10)))
    }
}

extension Calendar {
    /// Gregorian in the phone's time zone: delivery days are local days.
    static var marracatUS: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }
}

/// The eleven US federal holidays (5 U.S.C. 6103), with the observed day when
/// one falls on a weekend: Saturday → Friday, Sunday → Monday.
enum USHolidays {
    static func isHoliday(_ day: Date, calendar: Calendar = .marracatUS) -> Bool {
        let y = calendar.component(.year, from: day)
        return (dates(y, calendar: calendar) + dates(y + 1, calendar: calendar)).contains { calendar.isDate($0, inSameDayAs: day) }
    }

    static func dates(_ year: Int, calendar: Calendar = .marracatUS) -> [Date] {
        func fixed(_ m: Int, _ d: Int) -> Date {
            let date = calendar.date(from: DateComponents(year: year, month: m, day: d))!
            switch calendar.component(.weekday, from: date) {
            case 7: return calendar.date(byAdding: .day, value: -1, to: date)!   // Saturday → Friday
            case 1: return calendar.date(byAdding: .day, value: 1, to: date)!    // Sunday → Monday
            default: return date
            }
        }
        /// The nth given weekday (1 = Sunday) of a month; n = -1 is the last.
        func nth(_ n: Int, _ weekday: Int, _ month: Int) -> Date {
            if n > 0 {
                return calendar.date(from: DateComponents(year: year, month: month, weekday: weekday, weekdayOrdinal: n))!
            }
            var d = calendar.date(from: DateComponents(year: year, month: month + 1, day: 1))!
            repeat { d = calendar.date(byAdding: .day, value: -1, to: d)! } while calendar.component(.weekday, from: d) != weekday
            return d
        }
        return [fixed(1, 1), nth(3, 2, 1), nth(3, 2, 2), nth(-1, 2, 5), fixed(6, 19), fixed(7, 4),
                nth(1, 2, 9), nth(2, 2, 10), fixed(11, 11), nth(4, 5, 11), fixed(12, 25)]
    }
}
