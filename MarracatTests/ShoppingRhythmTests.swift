import Foundation
import Testing
@testable import Marracat

/// When a shopper shops each aisle (owner, 2026-11-16: "if a user usually
/// looks for toilet paper the last week of each month we should know that").
@MainActor
struct ShoppingRhythmTests {
    private static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private let cal = Self.calendar
    private let paper = "household:toilet-paper"

    private func at(_ month: Int, _ day: Int, _ hour: Int = 12, year: Int = 2026) -> Date {
        cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
    private func e(_ kind: ShoppingRhythm.Kind, _ date: Date, aisle: String? = nil) -> ShoppingRhythm.Event {
        .init(aisle: aisle ?? paper, kind: kind, at: date)
    }

    /// The owner's example: toilet paper in the last week of each month.
    private var endOfMonth: [ShoppingRhythm.Event] {
        [e(.search, at(8, 25, 20)), e(.purchase, at(8, 26, 20)),
         e(.search, at(9, 24, 20)), e(.purchase, at(9, 24, 21)),
         e(.view, at(10, 27, 20)), e(.purchase, at(10, 28, 20))]
    }

    @Test func aFewDaysOfActivityIsOneVisit() {
        let visits = Rhythm.visits([e(.search, at(8, 25)), e(.purchase, at(8, 27)), e(.view, at(9, 5))])[paper]
        #expect(visits == [Rhythm.Visit(start: at(8, 25), purchased: true), Rhythm.Visit(start: at(9, 5), purchased: false)])
    }

    @Test func theLastWeekOfEachMonthIsFound() throws {
        let r = try #require(Rhythm.find(endOfMonth, now: at(11, 10), calendar: cal).first)
        guard case .monthly(let position, let spread) = r.pattern else { Issue.record("not monthly: \(r.pattern)"); return }
        #expect((0.78...0.87).contains(position))
        #expect((2...7).contains(spread))
        #expect(r.lastPurchase == at(10, 28, 20))
    }

    @Test func itIsDueInThatWeekAndNotBefore() throws {
        let r = try #require(Rhythm.find(endOfMonth, now: at(11, 23), calendar: cal).first)
        #expect(r.isDue(now: at(11, 23), calendar: cal))
        #expect(!r.isDue(now: at(11, 10), calendar: cal))
        #expect(!r.isDue(now: at(11, 2), calendar: cal))
    }

    @Test func buyingItThisMonthEndsItUntilNextMonth() throws {
        let events = endOfMonth + [e(.purchase, at(11, 24, 20))]
        let r = try #require(Rhythm.find(events, now: at(11, 26), calendar: cal).first)
        #expect(!r.isDue(now: at(11, 26), calendar: cal))
        #expect(r.isDue(now: at(12, 23), calendar: cal))
    }

    @Test func twoMonthsIsNotARhythmYet() {
        #expect(Rhythm.find(Array(endOfMonth.prefix(4)), now: at(10, 25), calendar: cal).isEmpty)
    }

    @Test func aHabitThatStoppedIsDropped() {
        #expect(Rhythm.find(endOfMonth, now: at(3, 1, year: 2027), calendar: cal).isEmpty)
    }

    @Test func daysSpreadRoundTheMonthAreNotMonthly() {
        #expect(Rhythm.monthly([at(8, 2), at(9, 12), at(10, 22), at(11, 30)], calendar: cal) == nil)
    }

    @Test func theSameDayEachWeek() throws {
        let saturdays = [3, 10, 17, 24, 31].map { e(.view, at(10, $0)) }
        let r = try #require(Rhythm.find(saturdays, now: at(11, 6), calendar: cal).first)
        #expect(r.pattern == .weekly(weekday: 7))
        #expect(r.isDue(now: at(11, 6), calendar: cal))    // the Friday before
        #expect(r.isDue(now: at(11, 7), calendar: cal))    // the Saturday
        #expect(!r.isDue(now: at(11, 4), calendar: cal))   // a Wednesday
    }

    /// Every other Wednesday lands on one weekday too, but comes round fortnightly.
    @Test func aSteadyGapBetweenVisits() throws {
        let fortnightly = [at(9, 2), at(9, 16), at(9, 30), at(10, 14)].map { e(.purchase, $0) }
        let r = try #require(Rhythm.find(fortnightly, now: at(10, 19), calendar: cal).first)
        #expect(r.pattern == .every(days: 14))
        #expect(!r.isDue(now: at(10, 19), calendar: cal))
        #expect(r.isDue(now: at(10, 27), calendar: cal))
    }

    @Test func theLogSkipsRepeatsAndForgetsTheOldest() {
        var log: [ShoppingRhythm.Event] = []
        log = ShoppingRhythm.adding(e(.view, at(8, 1, 10)), to: log)
        log = ShoppingRhythm.adding(e(.view, at(8, 1, 10).addingTimeInterval(600)), to: log)   // same page again
        log = ShoppingRhythm.adding(e(.cart, at(8, 1, 10).addingTimeInterval(600)), to: log)   // a different signal
        #expect(log.map(\.kind) == [.view, .cart])
        log = ShoppingRhythm.adding(e(.view, at(10, 1, year: 2027)), to: log)                   // over 400 days on
        #expect(log.count == 1)
    }

    @Test func theUsualHour() {
        let evenings = (1...9).map { e(.view, at(10, $0, 20 + $0 % 2)) } + [e(.view, at(10, 12, 9))]
        #expect(Rhythm.usualHour(evenings, now: at(10, 15), calendar: cal) == 20)
        #expect(Rhythm.usualHour(Array(evenings.prefix(5)), now: at(10, 15), calendar: cal) == nil)   // too little to go on
        let scattered = (0..<12).map { e(.view, at(10, $0 + 1, $0 * 2)) }
        #expect(Rhythm.usualHour(scattered, now: at(10, 15), calendar: cal) == nil)
    }

    @Test func alertsComeAtTheUsualHourWithinTheDay() {
        #expect(WeeklyAlerts.hour(fallback: 9, usual: nil) == 9)
        #expect(WeeklyAlerts.hour(fallback: 9, usual: 19) == 19)
        #expect(WeeklyAlerts.hour(fallback: 9, usual: 23) == 20)
        #expect(WeeklyAlerts.hour(fallback: 12, usual: 6) == 8)
    }

    @Test func homeRowsSavedBeforeThisStillLoad() throws {
        let old = #"{"picked":[],"pickedReserved":[],"restock":[],"rows":[],"keepShopping":[]}"#
        let rows = try JSONDecoder().decode(HomeRows.self, from: Data(old.utf8))
        #expect(rows.restockFirst == nil)
    }
}
