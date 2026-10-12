import Foundation
import Testing
@testable import PersonalGantt

@MainActor struct InputQueuePresentationTests {
    @Test func missingDeadlineDisappearsAfterInlineSaveAndReusesConfirmedCalendar() async throws {
        let setup = try await fixture(records: [ReminderFixtures.record(deadline: nil)], minutes: 60)
        let value = setup.model, reminders = try #require(value.reminders)
        #expect(value.inputQueueCount == 1 && value.tasks.isEmpty)
        let reads = setup.calendar.reads, coverage = value.calendarCoverage
        var draft = InputQueueDraft(record: try #require(reminders.waitingRecords.first), metadata: reminders.metadata(for: "r"), reference: ReminderFixtures.date(0), calendar: ReminderFixtures.calendar)
        #expect(draft.validationMessage != nil && draft.minutes == "60")
        draft.select(.today, reference: ReminderFixtures.date(0), calendar: ReminderFixtures.calendar)
        try draft.save(to: reminders)
        #expect(value.inputQueueCount == 0 && value.inputQueueAccessibilityLabel == "入力待ち")
        #expect(value.tasks.first?.deadline == ReminderFixtures.date(23, 59) && value.result.blocks.count == 1)
        #expect(setup.calendar.reads == reads && value.calendarCoverage == coverage && setup.provider.writes.isEmpty)
        #expect(setup.plan.value?.tasks == value.tasks)
    }
    @Test func missingMinutesAndBothRequirementsUseSameValidationAndPublishPath() async throws {
        for missingDeadline in [false, true] {
            let setup = try await fixture(records: [ReminderFixtures.record(deadline: missingDeadline ? nil : ReminderFixtures.date(22))])
            let reminders = try #require(setup.model.reminders), record = try #require(reminders.waitingRecords.first)
            var draft = InputQueueDraft(record: record, metadata: reminders.metadata(for: record.id), reference: ReminderFixtures.date(0), calendar: ReminderFixtures.calendar)
            draft.minutes = "90"
            if missingDeadline { draft.select(.tomorrow, reference: ReminderFixtures.date(0), calendar: ReminderFixtures.calendar) }
            #expect(draft.validationMessage == nil)
            try draft.save(to: reminders)
            #expect(setup.model.inputQueueCount == 0 && setup.model.tasks.first?.estimatedMinutes == 90)
            #expect(setup.model.result.blocks.reduce(0) { $0 + $1.durationMinutes } == 90)
        }
    }
    @Test(arguments: ["", "0", "-1", "1.5", "invalid"]) func invalidMinutesNeverSaveOrChangeSchedule(minutes: String) async throws {
        let setup = try await fixture(records: [ReminderFixtures.record()])
        let reminders = try #require(setup.model.reminders)
        var draft = InputQueueDraft(record: try #require(reminders.waitingRecords.first), metadata: reminders.metadata(for: "r"), reference: ReminderFixtures.date(0), calendar: ReminderFixtures.calendar)
        draft.minutes = minutes
        let saves = setup.metadata.saves, before = setup.model.result
        #expect(draft.validationMessage != nil)
        #expect(throws: TaskInputError.self) { try draft.save(to: reminders) }
        #expect(setup.metadata.saves == saves && setup.model.result == before && setup.model.inputQueueCount == 1)
    }
    @Test func datePickerRetainsExactDateAndTimeWithoutWritingSource() async throws {
        let setup = try await fixture(records: [ReminderFixtures.record(deadline: nil)], minutes: 45)
        let reminders = try #require(setup.model.reminders)
        var draft = InputQueueDraft(record: try #require(reminders.waitingRecords.first), metadata: reminders.metadata(for: "r"), reference: ReminderFixtures.date(0), calendar: ReminderFixtures.calendar)
        draft.setsDeadline = true; draft.deadline = ReminderFixtures.date(14, 37, day: 9)
        try draft.save(to: reminders)
        #expect(setup.model.tasks.first?.deadline == draft.deadline)
        #expect(reminders.metadata(for: "r")?.deadlineOverride == draft.deadline && setup.provider.records.first?.deadline == nil)
    }
    @Test func sourceDeadlineRemainsAuthoritativeAndRecurrenceNeedsSourceRepair() async throws {
        let setup = try await fixture(records: [ReminderFixtures.record(), ReminderFixtures.record("recurring", deadline: nil, recurring: true)])
        let reminders = try #require(setup.model.reminders)
        var source = InputQueueDraft(record: try #require(reminders.record(for: "r")), metadata: reminders.metadata(for: "r"), reference: ReminderFixtures.date(0), calendar: ReminderFixtures.calendar)
        source.minutes = "60"
        source.select(.week, reference: ReminderFixtures.date(0), calendar: ReminderFixtures.calendar)
        #expect(!source.canSetDeadline && source.deadlineOverride == nil)
        try source.save(to: reminders)
        #expect(setup.model.tasks.first?.deadline == ReminderFixtures.date(23))
        var recurring = InputQueueDraft(record: try #require(reminders.record(for: "recurring")), metadata: reminders.metadata(for: "recurring"), reference: ReminderFixtures.date(0), calendar: ReminderFixtures.calendar)
        recurring.minutes = "60"; recurring.setsDeadline = true
        #expect(!recurring.canSetDeadline && recurring.validationMessage != nil)
        #expect(throws: TaskInputError.self) { try recurring.save(to: reminders) }
    }
    @Test func completedAndExcludedRecordsDoNotInflateQueueBadge() async throws {
        let setup = try await fixture(records: [ReminderFixtures.record(), ReminderFixtures.record("done", completed: true), ReminderFixtures.record("excluded")])
        let reminders = try #require(setup.model.reminders)
        #expect(reminders.exclude(identifier: "excluded"))
        #expect(setup.model.inputQueueCount == 1 && setup.model.inputQueueAccessibilityLabel == "入力待ち、1件")
        try reminders.configure(identifier: "r", estimatedMinutesText: "30", deadlineOverride: nil)
        #expect(setup.model.inputQueueCount == 0 && setup.model.todayAttention.isEmpty)
    }
    @Test func storageFailureKeepsInputQueueAndConfirmedPlan() async throws {
        let setup = try await fixture(records: [ReminderFixtures.record()])
        let reminders = try #require(setup.model.reminders)
        var draft = InputQueueDraft(record: try #require(reminders.waitingRecords.first), metadata: reminders.metadata(for: "r"), reference: ReminderFixtures.date(0), calendar: ReminderFixtures.calendar)
        draft.minutes = "60"; setup.metadata.failSave = true
        let before = setup.model.result
        #expect(throws: ReminderServiceError.self) { try draft.save(to: reminders) }
        #expect(setup.model.result == before && setup.model.inputQueueCount == 1 && setup.model.tasks.isEmpty)
    }
    @Test func todayOnlyShowsActionableFailuresAndClearsAfterRecovery() async throws {
        let setup = try await fixture(records: [])
        #expect(setup.model.todayAttention.isEmpty)
        setup.calendar.fail = true; await setup.model.refreshCalendars()
        #expect(setup.model.todayAttention.map(\.id) == ["calendar"])
        #expect(setup.model.todayAttention.first?.destination == .settings)
        setup.calendar.fail = false; await setup.model.refreshCalendars()
        #expect(setup.model.todayAttention.isEmpty)
        setup.provider.failRecords = true; await setup.model.reminders?.refresh()
        #expect(setup.model.todayAttention.map(\.id) == ["reminders"])
        setup.provider.failRecords = false; await setup.model.reminders?.refresh()
        #expect(setup.model.todayAttention.isEmpty)
    }
    @Test func failedPlanSaveHasConciseSettingsNotice() async throws {
        let setup = try await fixture(records: [])
        setup.plan.fail = true
        _ = try setup.model.addTask(TaskDraft(title: "Synthetic", deadline: ReminderFixtures.date(23)))
        #expect(setup.model.todayAttention.map(\.id) == ["save"])
        #expect(setup.model.todayAttention.first?.title.contains("Synthetic") == false)
        setup.plan.fail = false; setup.model.retryPlanSave()
        #expect(setup.model.todayAttention.isEmpty)
    }
    @Test func unreadableReminderMetadataRemainsActionableBeforeOSAccess() async {
        let provider = FakeReminderProvider(), storage = MemoryReminderMetadata()
        provider.authorization = .notDetermined; storage.failLoad = true
        let model = ScheduleViewModel(tasks: [], availableSlots: [])
        model.attachReminders(provider: provider, storage: storage)
        await model.reminders?.loadState()
        #expect(model.todayAttention.map(\.id) == ["reminders"])
        #expect(provider.accessRequests == 0)
    }

    private func fixture(records: [ReminderRecord], minutes: Int? = nil) async throws -> QueueFixture {
        let calendar = QueueCalendar(), provider = FakeReminderProvider(), metadata = MemoryReminderMetadata(), plan = QueuePlanStore()
        provider.records = records
        if let minutes { metadata.state.metadata["r"] = ReminderFixtures.metadata(minutes: minutes) }
        let model = ScheduleViewModel(tasks: [], calendarProvider: calendar, calendar: ReminderFixtures.calendar, clock: { ReminderFixtures.date(0) })
        model.attachPlanStore(plan); model.attachReminders(provider: provider, storage: metadata)
        #expect(await model.applyCalendarSelection(["study"]))
        #expect(await model.reminders?.applySelection(["list"]) == true)
        return QueueFixture(model: model, provider: provider, metadata: metadata, calendar: calendar, plan: plan)
    }
}

struct QuickDeadlineTests {
    @Test(arguments: QuickDeadline.allCases) func quickDeadlineUsesLocalCalendarAndExplicitTime(quick: QuickDeadline) throws {
        let date = try #require(quick.date(reference: ReminderFixtures.date(10), calendar: ReminderFixtures.calendar))
        let components = ReminderFixtures.calendar.dateComponents([.hour, .minute, .second, .day], from: date)
        #expect(components.hour == 23 && components.minute == 59 && components.second == 0)
        let expected: [QuickDeadline: Int] = [.today: 7, .tomorrow: 8, .weekend: 11, .threeDays: 10, .week: 14]
        #expect(components.day == expected[quick])
    }
    @Test func sundayWeekendIsTodayAndDSTDoesNotShiftDeadlineHour() throws {
        #expect(QuickDeadline.weekend.date(reference: ReminderFixtures.date(10, day: 4), calendar: ReminderFixtures.calendar) == ReminderFixtures.date(23, 59, day: 4))
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let reference = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 12)))
        let date = try #require(QuickDeadline.tomorrow.date(reference: reference, calendar: calendar))
        #expect(calendar.component(.day, from: date) == 1 && calendar.component(.hour, from: date) == 23)
        #expect(date.timeIntervalSince(calendar.startOfDay(for: reference)) == 49 * 3600 - 60)
    }
}
@MainActor private struct QueueFixture {
    let model: ScheduleViewModel
    let provider: FakeReminderProvider
    let metadata: MemoryReminderMetadata
    let calendar: QueueCalendar
    let plan: QueuePlanStore
}
@MainActor private final class QueueCalendar: CalendarProviding {
    var authorization: CalendarAuthorization = .connected
    var reads = 0, fail = false
    func requestAccess() async throws -> CalendarAuthorization { authorization }
    func loadCalendars() async throws -> [CalendarSource] { [CalendarSource(id: "study", title: "Synthetic", accountTitle: "Test")] }
    func loadEvents(in range: DateInterval, calendarIDs: Set<String>) async throws -> [FixedEvent] {
        reads += 1; if fail { throw CalendarServiceError.calendarUnavailable }; return []
    }
}
@MainActor private final class QueuePlanStore: PlanSnapshotStoring {
    var value: PlanSnapshot?, fail = false
    func load() throws -> PlanSnapshot? { value }
    func save(_ snapshot: PlanSnapshot) throws { if fail { throw PlanStorageError.unavailable }; try snapshot.validate(); value = snapshot }
}
