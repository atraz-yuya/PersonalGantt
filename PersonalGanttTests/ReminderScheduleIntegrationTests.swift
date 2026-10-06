import Foundation
import Testing
@testable import PersonalGantt

@MainActor
struct ReminderScheduleIntegrationTests {
    @Test func reminderRequirementsFlowThroughGoogleAvailabilityAndSchedulerWithoutFurtherGoogleReads() async throws {
        let http = MockGoogleHTTP()
        http.responses = [(200, calendars), (200, events)]
        let provider = FakeReminderProvider()
        provider.records = [ReminderFixtures.record()]
        let model = makeModel(http)
        model.attachReminders(provider: provider, storage: MemoryReminderMetadata())
        #expect(await model.applyCalendarSelection(["study"]))
        let reminders = try #require(model.reminders)
        #expect(await reminders.applySelection(["list"]))
        #expect(model.tasks.isEmpty && reminders.waitingRecords.count == 1)
        try reminders.configure(identifier: "r", estimatedMinutesText: "300", deadlineOverride: nil)
        let task = try #require(model.tasks.first)
        #expect(model.result.blocks == [
            ScheduledBlock(taskID: task.id, start: ReminderFixtures.date(8), end: ReminderFixtures.date(10)),
            ScheduledBlock(taskID: task.id, start: ReminderFixtures.date(12), end: ReminderFixtures.date(14)),
            ScheduledBlock(taskID: task.id, start: ReminderFixtures.date(16), end: ReminderFixtures.date(17))
        ])
        #expect(model.result.unscheduledTaskIDs.isEmpty)
        #expect(model.result.blocks.allSatisfy { block in model.fixedEvents.allSatisfy { block.end <= $0.start || block.start >= $0.end } })
        try model.updateTask(id: task.id, draft: TaskDraft(title: task.title, estimatedMinutesText: "360", deadline: task.deadline))
        #expect(model.result.blocks.last?.end == ReminderFixtures.date(18))
        await model.toggleTaskCompletion(id: task.id)
        #expect(model.tasks.first?.isCompleted == true && model.result.blocks.isEmpty)
        await model.toggleTaskCompletion(id: task.id)
        #expect(model.result.blocks.last?.end == ReminderFixtures.date(18))
        model.deleteTask(id: task.id)
        #expect(model.tasks.isEmpty && model.result.blocks.isEmpty)
        #expect(provider.records.count == 1 && provider.writes.count == 2)
        #expect(http.requests.count == 2 && http.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    @Test func externalCompletionAndRemovalPreserveBegunBlocksButRemoveFutureWork() async throws {
        let http = MockGoogleHTTP()
        http.responses = [(200, calendars), (200, events)]
        let clock = ReminderPlanClock(ReminderFixtures.date(0))
        let provider = FakeReminderProvider()
        provider.records = [ReminderFixtures.record()]
        let model = makeModel(http, clock: { clock.date })
        model.attachReminders(provider: provider, storage: MemoryReminderMetadata())
        #expect(await model.applyCalendarSelection(["study"]))
        let reminders = try #require(model.reminders)
        #expect(await reminders.applySelection(["list"]))
        try reminders.configure(identifier: "r", estimatedMinutesText: "300", deadlineOverride: nil)
        let first = try #require(model.result.blocks.first)
        clock.date = ReminderFixtures.date(9)
        provider.records = [ReminderFixtures.record(completed: true)]
        await reminders.refresh()
        #expect(model.result.blocks == [first])
        provider.records = []
        await reminders.refresh()
        #expect(model.tasks.isEmpty && model.result.blocks == [first])
        #expect(model.title(for: first.taskID) == "合成Task")
        #expect(http.requests.count == 2)
    }

    @Test func failedReminderWriteAndReadKeepConfirmedGooglePlan() async throws {
        let http = MockGoogleHTTP()
        http.responses = [(200, calendars), (200, events)]
        let provider = FakeReminderProvider()
        provider.records = [ReminderFixtures.record()]
        let model = makeModel(http)
        model.attachReminders(provider: provider, storage: MemoryReminderMetadata())
        #expect(await model.applyCalendarSelection(["study"]))
        let reminders = try #require(model.reminders)
        #expect(await reminders.applySelection(["list"]))
        try reminders.configure(identifier: "r", estimatedMinutesText: "300", deadlineOverride: nil)
        let before = model.result
        provider.failCompletion = true
        await model.toggleTaskCompletion(id: try #require(model.tasks.first).id)
        #expect(model.result == before && model.tasks.first?.isCompleted == false)
        provider.failRecords = true
        await reminders.refresh()
        #expect(model.result == before && model.fixedEvents.count == 2)
    }

    @Test func sourceTitleAndDeadlineCannotBeEditedThroughTaskEditorAPI() async throws {
        let provider = FakeReminderProvider()
        provider.records = [ReminderFixtures.record()]
        let model = makeModel(MockGoogleHTTP())
        model.attachReminders(provider: provider, storage: MemoryReminderMetadata())
        let reminders = try #require(model.reminders)
        #expect(await reminders.applySelection(["list"]))
        try reminders.configure(identifier: "r", estimatedMinutesText: "60", deadlineOverride: nil)
        let task = try #require(model.tasks.first)
        #expect(throws: ReminderServiceError.sourceOwnedFields) {
            try model.updateTask(id: task.id, draft: TaskDraft(title: "別名", estimatedMinutesText: "60", deadline: task.deadline))
        }
        #expect(throws: ReminderServiceError.sourceOwnedFields) {
            try model.updateTask(id: task.id, draft: TaskDraft(title: task.title, estimatedMinutesText: "60", deadline: task.deadline.addingTimeInterval(60)))
        }
        #expect(model.tasks == [task] && provider.writes.isEmpty)
    }

    @Test func localTasksCoexistWithImportedTasksAndNeverWriteReminders() async throws {
        let provider = FakeReminderProvider()
        provider.records = [ReminderFixtures.record()]
        let model = makeModel(MockGoogleHTTP())
        let local = try model.addTask(TaskDraft(title: "手動", estimatedMinutesText: "30", deadline: ReminderFixtures.date(22)))
        model.attachReminders(provider: provider, storage: MemoryReminderMetadata())
        let reminders = try #require(model.reminders)
        #expect(await reminders.applySelection(["list"]))
        try reminders.configure(identifier: "r", estimatedMinutesText: "60", deadlineOverride: nil)
        await model.toggleTaskCompletion(id: local.id)
        #expect(model.tasks.count == 2 && model.tasks.first { $0.id == local.id }?.isCompleted == true)
        #expect(provider.writes.isEmpty)
        #expect(await reminders.applySelection([]))
        #expect(model.tasks.count == 1 && model.tasks[0].id == local.id)
    }

    @Test func nextRecurringOccurrenceDoesNotDeductPreviousOccurrenceProtectedTime() async throws {
        let http = MockGoogleHTTP()
        http.responses = [(200, calendars), (200, #"{"items":[]}"#)]
        let clock = ReminderPlanClock(ReminderFixtures.date(0))
        let provider = FakeReminderProvider()
        provider.records = [ReminderFixtures.record(recurring: true, occurrence: "first")]
        let model = makeModel(http, clock: { clock.date })
        model.attachReminders(provider: provider, storage: MemoryReminderMetadata())
        #expect(await model.applyCalendarSelection(["study"]))
        let reminders = try #require(model.reminders)
        #expect(await reminders.applySelection(["list"]))
        try reminders.configure(identifier: "r", estimatedMinutesText: "60", deadlineOverride: nil)
        let old = try #require(model.result.blocks.first)
        clock.date = ReminderFixtures.date(9)
        provider.records = [ReminderFixtures.record(deadline: ReminderFixtures.date(23, day: 8), recurring: true, occurrence: "second")]
        await reminders.refresh()
        let next = try #require(model.tasks.first)
        #expect(next.id != old.taskID)
        #expect(model.result.blocks.contains(old))
        #expect(model.scheduledMinutes(for: next.id) == 60)
        #expect(model.title(for: old.taskID) == "合成Task")
    }

    private func makeModel(_ http: MockGoogleHTTP, clock: @escaping () -> Date = { ReminderFixtures.date(0) }) -> ScheduleViewModel {
        ScheduleViewModel(tasks: [], calendarProvider: GoogleCalendarService(tokens: MockGoogleTokens(), transport: http,
            calendar: ReminderFixtures.calendar), calendar: ReminderFixtures.calendar, clock: clock)
    }
    private var calendars: String { #"{"items":[{"id":"study","summary":"合成Calendar","accessRole":"reader"}]}"# }
    private var events: String {
        #"{"timeZone":"UTC","items":[{"id":"lesson","start":{"dateTime":"2026-10-07T10:00:00Z"},"end":{"dateTime":"2026-10-07T12:00:00Z"}},{"id":"work","start":{"dateTime":"2026-10-07T14:00:00Z"},"end":{"dateTime":"2026-10-07T16:00:00Z"}}]}"#
    }
}

@MainActor
private final class ReminderPlanClock {
    var date: Date
    init(_ date: Date) { self.date = date }
}
