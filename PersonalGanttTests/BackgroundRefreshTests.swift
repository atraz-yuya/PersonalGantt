import Foundation
import Testing
@testable import PersonalGantt

@MainActor struct BackgroundRefreshTests {
    @Test func refreshUsesExistingSessionAndReplansOnlyFuture() async throws {
        let provider = BackgroundProvider(); let clock = BackgroundClock()
        let task = PersonalGantt.Task(title: "合成", estimatedMinutes: 180, deadline: ReminderFixtures.date(23))
        let model = ScheduleViewModel(tasks: [task], calendarProvider: provider, calendar: ReminderFixtures.calendar, clock: { clock.now })
        #expect(await model.applyCalendarSelection(["work"]))
        let begun = try #require(model.result.blocks.first)
        clock.now = ReminderFixtures.date(9)
        provider.events = [FixedEvent(id: "urgent", calendarID: "work", title: "Synthetic", start: ReminderFixtures.date(12), end: ReminderFixtures.date(17))]
        await model.performBackgroundRefresh()
        #expect(model.result.blocks.contains(begun) && provider.prompts == 0)
        provider.fail = true
        let before = model.result
        await model.performBackgroundRefresh()
        #expect(model.result == before && model.calendarMessage != nil)
    }
    @Test func signedOutBackgroundNeverPrompts() async {
        let provider = BackgroundProvider(); provider.authorization = .signedOut
        let model = ScheduleViewModel(tasks: [], calendarProvider: provider)
        await model.performBackgroundRefresh()
        #expect(provider.prompts == 0 && provider.reads == 0)
    }
}
@MainActor private final class BackgroundClock { var now = ReminderFixtures.date(0) }
@MainActor private final class BackgroundProvider: CalendarProviding {
    var authorization: CalendarAuthorization = .connected
    var prompts = 0, reads = 0
    var fail = false
    var events: [FixedEvent] = []
    func requestAccess() async throws -> CalendarAuthorization { prompts += 1; return authorization }
    func loadCalendars() async throws -> [CalendarSource] { reads += 1; if fail { throw GoogleCalendarError.network }; return [CalendarSource(id: "work", title: "Synthetic", accountTitle: "Test")] }
    func loadEvents(in range: DateInterval, calendarIDs: Set<String>) async throws -> [FixedEvent] { events }
}
