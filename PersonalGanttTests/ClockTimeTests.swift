import Foundation
import Testing
@testable import PersonalGantt

struct ClockTimeTests {
    @Test(arguments: ["0000", "0930", "1000", "1900", "2359", " 0930 ", "09:30", "9:30"])
    func compactAndColonTimesNormalizeWithoutChangingMinute(text: String) throws {
        let minute = try #require(ClockTime.minute(text))
        let normalized = ClockTime.normalized(text)
        #expect(normalized.count == 5 && normalized.contains(":"))
        #expect(ClockTime.minute(normalized) == minute)
        if text.trimmingCharacters(in: .whitespaces) == "0930" || text == "09:30" || text == "9:30" { #expect(minute == 570 && normalized == "09:30") }
    }
    @Test(arguments: ["", "930", "093", "09300", "2400", "2401", "2360", "2500", "-100", "19a0", "09 30", "09:30:00"])
    func invalidStartTimesCannotBeConvertedOrApplied(text: String) {
        #expect(ClockTime.minute(text) == nil)
        #expect(ClockTime.date(text, on: ReminderFixtures.date(0), calendar: ReminderFixtures.calendar) == nil)
    }
    @Test func midnightEndAndWindowOrderRemainValidated() {
        var draft = ActivityWindowDraft(ActivityWindow(startMinute: 600, endMinute: 1440))
        draft.start = "1000"; draft.end = "2400"
        #expect(draft.window == ActivityWindow(startMinute: 600, endMinute: 1440))
        #expect(ClockTime.normalized("2400", allowsEndOfDay: true) == "24:00")
        draft.end = "0930"; #expect(draft.window == nil)
        draft.end = "2401"; #expect(draft.window == nil)
        draft.start = "2400"; draft.end = "2400"; #expect(draft.window == nil)
    }
    @Test func compactDeadlineTimePreservesDateInPresentationCalendar() throws {
        let calendar = ReminderFixtures.calendar, date = ReminderFixtures.date(23, day: 14)
        let changed = try #require(ClockTime.date("0930", on: date, calendar: calendar))
        #expect(changed == ReminderFixtures.date(9, 30, day: 14))
        #expect(ClockTime.text(for: changed, calendar: calendar) == "09:30")
    }
    @Test func nonexistentDSTTimeDoesNotSilentlyShiftDeadline() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let day = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8)))
        #expect(ClockTime.date("0230", on: day, calendar: calendar) == nil)
        let valid = try #require(ClockTime.date("0330", on: day, calendar: calendar))
        #expect(ClockTime.text(for: valid, calendar: calendar) == "03:30")
    }
}
