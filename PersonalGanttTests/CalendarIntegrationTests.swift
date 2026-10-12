import Foundation
import EventKit
import Testing
@testable import PersonalGantt

@MainActor
struct CalendarIntegrationTests {
    @Test func eventKitOccurrenceFlowsThroughAvailabilityAndScheduler() throws {
        // In-memory EK objects only: no access request, fetch, or Calendar write.
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        event.title = "会議"
        event.startDate = date(9)
        event.endDate = date(10)
        event.timeZone = TimeZone(secondsFromGMT: 0)
        let fixed = try #require(LegacyEventKitCalendarFixture.fixedEvent(from: event, calendarID: "work"))
        #expect(fixed.title == "会議")
        #expect(fixed.start == date(9))
        #expect(fixed.end == date(10))
        #expect(!fixed.isAllDay)
        #expect(LegacyEventKitCalendarFixture.fixedEvent(from: event, calendarID: "work")?.id == fixed.id)
        let slots = try AvailabilityService().availableSlots(fixedEvents: [fixed], settings: .legacyFixture, referenceDate: date(0), calendar: utc)
        let first = task(1, minutes: 90, deadline: date(12))
        let second = task(2, minutes: 120, deadline: date(15))
        let result = Scheduler().schedule(tasks: [second, first], availableSlots: slots)
        #expect(result.blocks == [
            ScheduledBlock(taskID: first.id, start: date(8), end: date(9)),
            ScheduledBlock(taskID: first.id, start: date(10), end: date(10, 30)),
            ScheduledBlock(taskID: second.id, start: date(10, 30), end: date(12, 30))
        ])
        #expect(result.unscheduledTaskIDs.isEmpty)
        #expect(result.blocks.allSatisfy { $0.end <= fixed.start || $0.start >= fixed.end })
    }

    @Test func eventKitAllDayAndRecurringOccurrenceIDsAreCopiedCorrectly() throws {
        // EventKit floating all-day events use the OS time zone, even for unsaved EKEvents.
        // The activity calendar must use that same time zone rather than the UTC test fixtures.
        var localCalendar = Calendar(identifier: .gregorian)
        localCalendar.timeZone = .current
        func localDate(_ hour: Int, day: Int) throws -> Date {
            try #require(localCalendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour)))
        }
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        event.title = "終日"
        event.startDate = try localDate(0, day: 6)
        event.endDate = try localDate(0, day: 7)
        // Set the timed interval first: assigning an end date to an already-all-day
        // EKEvent treats that end date's day as inclusive (23:59:59 on macOS).
        event.isAllDay = true
        let first = try #require(LegacyEventKitCalendarFixture.fixedEvent(from: event, calendarID: "work"))
        #expect(first.isAllDay)
        let slots = try AvailabilityService().availableSlots(fixedEvents: [first], settings: .legacyFixture, referenceDate: localDate(0, day: 6), calendar: localCalendar)
        #expect(try slots.first?.start == localDate(8, day: 7))
        #expect(try AvailabilityService().occupiedIntervals([first], calendar: localCalendar) == [DateInterval(start: localDate(0, day: 6), end: localDate(0, day: 7))])
        event.isAllDay = false
        event.startDate = try localDate(0, day: 7)
        event.endDate = try localDate(0, day: 8)
        event.isAllDay = true
        let second = try #require(LegacyEventKitCalendarFixture.fixedEvent(from: event, calendarID: "work"))
        #expect(first.id != second.id)
    }

    @Test func unsavedInvalidEventIsNotImported() {
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        #expect(LegacyEventKitCalendarFixture.fixedEvent(from: event, calendarID: "work") == nil)
        event.startDate = date(10)
        event.endDate = date(9)
        #expect(LegacyEventKitCalendarFixture.fixedEvent(from: event, calendarID: "work") == nil)
    }

    @Test func selectedCalendarFiltersEventsAndRebuildsFuturePlan() async {
        let provider = FakeCalendarProvider()
        provider.events = [event("work", 8, 9), event("personal", 9, 12)]
        let model = makeModel(provider)
        #expect(model.result.blocks.first?.start == date(8))
        #expect(model.selectedCalendarIDs.isEmpty)
        await model.loadCalendarState()
        #expect(provider.requestedIDs.isEmpty)
        #expect(model.calendars.count == 2)
        #expect(await model.applyCalendarSelection(["work"]))
        #expect(model.selectedCalendarIDs == ["work"])
        #expect(model.fixedEvents == [event("work", 8, 9)])
        #expect(model.result.blocks.first?.start == date(9))
        #expect(model.result.blocks.first?.end == date(11))
        #expect(provider.requestedIDs == [Set(["work"])])
        #expect(provider.requestedRanges.last == DateInterval(start: date(0), end: date(0, day: 20)))
    }

    @Test func emptySelectionClearsEventsAndNeverQueriesAllCalendars() async {
        let provider = FakeCalendarProvider()
        provider.events = [event("work", 8, 9)]
        let model = makeModel(provider)
        #expect(await model.applyCalendarSelection(["work"]))
        #expect(await model.applyCalendarSelection([]))
        #expect(model.fixedEvents.isEmpty)
        #expect(model.selectedCalendarIDs.isEmpty)
        #expect(model.result.blocks.first?.start == date(8))
        #expect(provider.requestedIDs == [Set(["work"])])
    }

    @Test func refreshPicksUpChangedEventsAndPreservesSelection() async {
        let provider = FakeCalendarProvider()
        provider.events = [event("work", 8, 9)]
        let model = makeModel(provider)
        #expect(await model.applyCalendarSelection(["work"]))
        provider.events = [event("work", 8, 12)]
        await model.refreshCalendars()
        #expect(model.selectedCalendarIDs == ["work"])
        #expect(model.result.blocks.first?.start == date(12))
        #expect(model.result.blocks.first?.end == date(14))
        #expect(model.lastCalendarRefresh == date(0))
    }

    @Test func failedReadDoesNotPartiallyReplaceSelectionOrPlan() async {
        let provider = FakeCalendarProvider()
        provider.events = [event("work", 8, 9)]
        let model = makeModel(provider)
        #expect(await model.applyCalendarSelection(["work"]))
        let before = model.result
        let oldSlots = model.availableSlots
        let oldEvents = model.fixedEvents
        provider.failEvents = true
        #expect(!(await model.applyCalendarSelection(["personal"])))
        #expect(model.selectedCalendarIDs == ["work"])
        #expect(model.result == before)
        #expect(model.availableSlots == oldSlots)
        #expect(model.fixedEvents == oldEvents)
        #expect(model.calendarMessage != nil)
        provider.failCalendars = true
        await model.refreshCalendars()
        #expect(model.result == before)
    }

    @Test func removedCalendarIsPrunedWithNotice() async {
        let provider = FakeCalendarProvider()
        provider.events = [event("work", 8, 9)]
        let model = makeModel(provider)
        #expect(await model.applyCalendarSelection(["work"]))
        provider.sources.removeAll { $0.id == "work" }
        await model.refreshCalendars()
        #expect(model.selectedCalendarIDs.isEmpty)
        #expect(model.fixedEvents.isEmpty)
        #expect(model.result.blocks.first?.start == date(8))
        #expect(model.calendarMessage != nil)
    }

    @Test func cancelledOrUnselectedOccurrencesDoNotAffectPlan() async {
        let provider = FakeCalendarProvider()
        var cancelled = event("work", 8, 23)
        cancelled.isCancelled = true
        provider.events = [cancelled, event("personal", 8, 23)]
        let model = makeModel(provider)
        #expect(await model.applyCalendarSelection(["work"]))
        #expect(model.fixedEvents.isEmpty)
        #expect(model.result.blocks.first?.start == date(8))
    }

    @Test func explicitAccessRequestLoadsSourcesAfterGrant() async {
        let provider = FakeCalendarProvider()
        provider.authorization = .signedOut
        let model = makeModel(provider)
        await model.loadCalendarState()
        #expect(provider.accessRequests == 0)
        #expect(provider.calendarLoads == 0)
        await model.requestCalendarAccess()
        #expect(provider.accessRequests == 1)
        #expect(model.calendarAuthorization == .connected)
        #expect(model.calendars.count == 2)
        #expect(model.selectedCalendarIDs.isEmpty)
        #expect(provider.requestedIDs.isEmpty)
    }

    @Test func denyingAccessKeepsProvisionalPlanAndDoesNotReadEvents() async {
        let provider = FakeCalendarProvider()
        provider.authorization = .signedOut
        provider.nextAuthorization = .denied
        let model = makeModel(provider)
        let before = model.result
        await model.requestCalendarAccess()
        #expect(model.calendarAuthorization == .denied)
        #expect(model.calendarMessage != nil)
        #expect(model.result == before)
        #expect(provider.calendarLoads == 0)
        #expect(provider.requestedIDs.isEmpty)
    }

    @Test(arguments: [CalendarAuthorization.denied, .restricted, .insufficientScope])
    func insufficientAuthorizationDoesNotReadOrEraseSnapshot(status: CalendarAuthorization) async {
        let provider = FakeCalendarProvider()
        provider.events = [event("work", 8, 9)]
        let model = makeModel(provider)
        #expect(await model.applyCalendarSelection(["work"]))
        let before = model.result
        let reads = provider.calendarLoads
        provider.authorization = status
        await model.refreshCalendars()
        #expect(!(await model.applyCalendarSelection(["personal"])))
        #expect(model.calendarAuthorization == status)
        #expect(model.result == before)
        #expect(model.selectedCalendarIDs == ["work"])
        #expect(provider.calendarLoads == reads)
    }

    @Test func begunBlocksSurviveRefreshAndConflictsAreReported() async {
        let provider = FakeCalendarProvider()
        let clock = TestClock(date: date(0))
        let first = task(1, minutes: 120, deadline: date(22))
        let second = task(2, minutes: 60, deadline: date(23))
        let model = ScheduleViewModel(tasks: [first, second], calendarProvider: provider, activitySettings: .legacyFixture, calendar: utc, clock: { clock.date })
        #expect(await model.applyCalendarSelection(["work"]))
        let current = model.result.blocks[0]
        clock.date = date(9)
        provider.events = [event("work", 8, 12)]
        await model.refreshCalendars()
        #expect(model.result.blocks.contains(current))
        #expect(model.result.blocks.first { $0.taskID == second.id }?.start == date(12))
        #expect(model.protectedConflictCount == 1)
        model.deleteTask(id: first.id)
        #expect(model.result.blocks.contains(current))
        #expect(model.title(for: first.id) == first.title)
        #expect(model.tasks == [second])
    }

    @Test func taskChangesUseSnapshotWithoutAdditionalCalendarReads() async throws {
        let provider = FakeCalendarProvider()
        let model = makeModel(provider)
        #expect(await model.applyCalendarSelection(["work"]))
        let reads = provider.calendarLoads
        let added = try model.addTask(TaskDraft(title: "追加", estimatedMinutesText: "60", deadline: date(23)))
        model.toggleCompletion(id: added.id)
        model.toggleCompletion(id: added.id)
        model.deleteTask(id: added.id)
        #expect(provider.calendarLoads == reads)
        #expect(model.result == Scheduler().schedule(tasks: model.tasks, availableSlots: model.availableSlots))
    }

    private func makeModel(_ provider: FakeCalendarProvider) -> ScheduleViewModel {
        let now = date(0)
        return ScheduleViewModel(tasks: [task(1, minutes: 120, deadline: date(23))], calendarProvider: provider, activitySettings: .legacyFixture, calendar: utc, clock: { now })
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ hour: Int, _ minute: Int = 0, day: Int = 6) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private func task(_ index: Int, minutes: Int, deadline: Date) -> PersonalGantt.Task {
        PersonalGantt.Task(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!, title: "作業 \(index)", estimatedMinutes: minutes, deadline: deadline)
    }

    private func event(_ calendarID: String, _ start: Int, _ end: Int) -> FixedEvent {
        FixedEvent(id: "\(calendarID)-\(start)-\(end)", calendarID: calendarID, title: "予定", start: date(start), end: date(end))
    }
}

@MainActor
private final class TestClock {
    var date: Date
    init(date: Date) { self.date = date }
}

@MainActor
private final class FakeCalendarProvider: CalendarProviding {
    var authorization: CalendarAuthorization = .connected
    var nextAuthorization: CalendarAuthorization = .connected
    var sources = [CalendarSource(id: "work", title: "仕事", accountTitle: "テスト"), CalendarSource(id: "personal", title: "個人", accountTitle: "テスト")]
    var events: [FixedEvent] = []
    var failCalendars = false
    var failEvents = false
    var accessRequests = 0
    var calendarLoads = 0
    var requestedIDs: [Set<String>] = []
    var requestedRanges: [DateInterval] = []

    func requestAccess() async throws -> CalendarAuthorization {
        accessRequests += 1
        authorization = nextAuthorization
        return authorization
    }

    func loadCalendars() throws -> [CalendarSource] {
        calendarLoads += 1
        if failCalendars { throw CalendarServiceError.calendarUnavailable }
        return sources
    }

    func loadEvents(in range: DateInterval, calendarIDs: Set<String>) throws -> [FixedEvent] {
        requestedIDs.append(calendarIDs)
        requestedRanges.append(range)
        if failEvents { throw CalendarServiceError.calendarUnavailable }
        // Intentionally return extra sources to also exercise the VM's defensive filter.
        return events
    }
}
