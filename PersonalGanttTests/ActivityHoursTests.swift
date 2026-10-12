import Foundation
import Testing
@testable import PersonalGantt

struct ActivityHoursTests {
    private var calendar: Calendar { ReminderFixtures.calendar }
    @Test func freshDefaultsIncludeWeekdaysWeekendsAndNextMidnight() throws {
        let settings = ActivitySettings.default
        #expect(settings.weekday == ActivityWindow(startMinute: 600, endMinute: 1440))
        #expect(settings.weekend == settings.weekday && settings.dayOverrides.isEmpty)
        let range = DateInterval(start: ReminderFixtures.date(0, day: 9), end: ReminderFixtures.date(0, day: 12))
        let slots = try AvailabilityService().availableSlots(fixedEvents: [], in: range, referenceDate: range.start, calendar: calendar)
        #expect(slots.count == 3)
        #expect(slots.map { calendar.component(.hour, from: $0.start) } == [10, 10, 10])
        #expect(slots.last?.end == range.end && slots.allSatisfy { $0.end.timeIntervalSince($0.start) == 840 * 60 })
    }
    @Test func overridesAffectOnlyTheirLocalDateAndSubtractEvents() throws {
        var settings = ActivitySettings.default
        settings.dayOverrides["2026-10-07"] = ActivityDayOverride(window: ActivityWindow(startMinute: 780, endMinute: 1080))
        settings.dayOverrides["2026-10-08"] = ActivityDayOverride(window: nil)
        let start = ReminderFixtures.date(0), end = ReminderFixtures.date(0, day: 10)
        let event = FixedEvent(id: "meeting", calendarID: "work", title: "Synthetic", start: ReminderFixtures.date(14), end: ReminderFixtures.date(15))
        let slots = try AvailabilityService().availableSlots(fixedEvents: [event], in: DateInterval(start: start, end: end), settings: settings, referenceDate: start, calendar: calendar)
        #expect(slots.map { DateInterval(start: $0.start, end: $0.end) } == [
            DateInterval(start: ReminderFixtures.date(13), end: ReminderFixtures.date(14)),
            DateInterval(start: ReminderFixtures.date(15), end: ReminderFixtures.date(18)),
            DateInterval(start: ReminderFixtures.date(10, day: 9), end: end)
        ])
        #expect(try JSONDecoder().decode(ActivitySettings.self, from: JSONEncoder().encode(settings)) == settings)
    }
    @Test(arguments: ["2026-02-30", "2026-13-01", "2026-1-01", "not-a-date"])
    func invalidOverrideKeysFailValidation(key: String) {
        var settings = ActivitySettings.default
        settings.dayOverrides[key] = ActivityDayOverride(window: nil)
        #expect(!settings.isValid)
    }
    @Test(arguments: ["24:01", "25:00", "-1:00", "10:60", "10:", "a:00", "10:00:00"])
    func malformedTimeCannotSave(text: String) {
        var draft = ActivityWindowDraft(.init(startMinute: 600, endMinute: 1440))
        draft.end = text; #expect(draft.window == nil)
    }
    @Test func timeDraftHandlesMidnightAndMinutePrecision() {
        var draft = ActivityWindowDraft(.init(startMinute: 600, endMinute: 1440))
        #expect(draft.end == "24:00" && draft.window?.endMinute == 1440)
        draft.start = "14:30"; draft.end = "19:15"
        #expect(draft.window == ActivityWindow(startMinute: 870, endMinute: 1155))
        draft.start = "24:00"; #expect(draft.window == nil)
        draft.start = "19:15"; #expect(draft.window == nil)
    }
    @Test func midnightAndOffDaysUseLocalDatesAcrossDSTAndTimeZones() throws {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let start = try #require(local.date(from: DateComponents(year: 2026, month: 11, day: 1)))
        let end = try #require(local.date(byAdding: .day, value: 1, to: start))
        var hours = ActivitySettings.default
        hours.dayOverrides["2026-11-01"] = ActivityDayOverride(window: ActivityWindow(startMinute: 0, endMinute: 1440))
        let slots = try AvailabilityService().availableSlots(fixedEvents: [], in: DateInterval(start: start, end: end), settings: hours, referenceDate: start, calendar: local)
        #expect(slots.first?.end == end && slots.first.map { $0.end.timeIntervalSince($0.start) } == 1500 * 60)
        #expect(ActivitySettings.dayKey(start, calendar: local) == "2026-11-01")
        var tokyo = local; tokyo.timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
        #expect(ActivitySettings.date(for: "2026-11-01", calendar: tokyo).map { ActivitySettings.dayKey($0, calendar: tokyo) } == "2026-11-01")
    }
}

@MainActor struct ActivityHoursIntegrationTests {
    @Test func todayHoursImmediatelyReplanWithoutCalendarFetch() async throws {
        let setup = makeModel(), value = setup.model
        let task = try value.addTask(TaskDraft(title: "Synthetic", deadline: ReminderFixtures.date(23)))
        #expect(await value.applyCalendarSelection(["work"]))
        #expect(value.result.blocks.first?.start == ReminderFixtures.date(10))
        let reads = setup.provider.reads
        try value.setActivityWindow(ActivityWindow(startMinute: 780, endMinute: 1080), on: ReminderFixtures.date(0))
        #expect(value.result.blocks == [ScheduledBlock(taskID: task.id, start: ReminderFixtures.date(13), end: ReminderFixtures.date(14))])
        #expect(setup.provider.reads == reads && value.lastRecalculation != nil)
        try value.setActivityWindow(nil, on: ReminderFixtures.date(0))
        #expect(value.result.blocks.isEmpty && value.result.unscheduledTaskIDs == [task.id])
        try value.clearActivityOverride(on: ReminderFixtures.date(0))
        #expect(value.result.blocks.first?.start == ReminderFixtures.date(10))
    }
    @Test func invalidHoursLeaveSettingsPlanAndStoreUnchanged() throws {
        let setup = makeModel(), value = setup.model
        let before = value.result, settings = value.activitySettings, saves = setup.store.saves
        #expect(throws: AvailabilityError.self) { try value.setActivityWindow(ActivityWindow(startMinute: 1440, endMinute: 600), on: ReminderFixtures.date(0)) }
        #expect(value.result == before && value.activitySettings == settings && setup.store.saves == saves)
    }
    @Test func restartSyncAndBackupPreserveNormalAndDayHours() throws {
        let setup = makeModel(), value = setup.model
        _ = try value.addTask(TaskDraft(title: "Synthetic", deadline: ReminderFixtures.date(23)))
        var settings = value.activitySettings; settings.weekday = ActivityWindow(startMinute: 720, endMinute: 1440)
        try value.setActivitySettings(settings)
        try value.setActivityWindow(ActivityWindow(startMinute: 900, endMinute: 1200), on: ReminderFixtures.date(0))
        try value.setActivityWindow(nil, on: ReminderFixtures.date(0, day: 8))
        let restarted = makeModel(store: setup.store).model
        #expect(restarted.activitySettings == value.activitySettings)
        let target = makeModel().model
        try target.mergeSyncRecords(Array(value.syncState.records.values))
        #expect(target.activitySettings == value.activitySettings && target.result.blocks.first?.start == ReminderFixtures.date(15))
        let backup = try PersonalGanttBackup.decode(value.makeBackup().encoded())
        let restored = makeModel().model
        try restored.restoreBackup(backup)
        #expect(restored.activitySettings == value.activitySettings && restored.result.blocks.first?.start == ReminderFixtures.date(15))
    }
    @Test func shortenedHoursProtectAlreadyStartedWork() async throws {
        let clock = ActivityTestClock(), setup = makeModel(clock: clock)
        let task = try setup.model.addTask(TaskDraft(title: "Synthetic", estimatedMinutesText: "120", deadline: ReminderFixtures.date(23)))
        #expect(await setup.model.applyCalendarSelection(["work"]))
        let confirmed = setup.model.result.blocks
        clock.now = ReminderFixtures.date(10, 30)
        try setup.model.setActivityWindow(nil, on: clock.now)
        #expect(setup.model.result.blocks == confirmed && setup.model.result.blocks.first?.taskID == task.id)
    }
    private func makeModel(store: ActivityPlanStore? = nil, clock: ActivityTestClock? = nil) -> (model: ScheduleViewModel, provider: ActivityCalendar, store: ActivityPlanStore) {
        let store = store ?? ActivityPlanStore(), provider = ActivityCalendar()
        let model = ScheduleViewModel(tasks: [], calendarProvider: provider, calendar: ReminderFixtures.calendar,
            clock: { clock?.now ?? ReminderFixtures.date(0) }, planStore: store)
        model.configureBackup(reminderStore: MemoryReminderMetadata(), journal: ActivityJournal(), deviceID: UUID())
        return (model, provider, store)
    }
}
@MainActor private final class ActivityTestClock { var now = ReminderFixtures.date(0) }
@MainActor private final class ActivityPlanStore: PlanSnapshotStoring {
    var value: PlanSnapshot?, saves = 0
    func load() throws -> PlanSnapshot? { value }
    func save(_ snapshot: PlanSnapshot) throws { try snapshot.validate(); value = snapshot; saves += 1 }
}
@MainActor private final class ActivityCalendar: CalendarProviding {
    var authorization: CalendarAuthorization = .connected
    var reads = 0
    func requestAccess() async throws -> CalendarAuthorization { authorization }
    func loadCalendars() async throws -> [CalendarSource] { [CalendarSource(id: "work", title: "Synthetic", accountTitle: "Test")] }
    func loadEvents(in range: DateInterval, calendarIDs: Set<String>) async throws -> [FixedEvent] {
        reads += 1
        return [FixedEvent(id: "meeting", calendarID: "work", title: "Synthetic", start: ReminderFixtures.date(14), end: ReminderFixtures.date(15))]
    }
}
@MainActor private final class ActivityJournal: BackupJournalStoring {
    var value: PersonalGanttBackup?
    func load() throws -> PersonalGanttBackup? { value }
    func save(_ backup: PersonalGanttBackup) throws { value = backup }
    func remove() throws { value = nil }
}
