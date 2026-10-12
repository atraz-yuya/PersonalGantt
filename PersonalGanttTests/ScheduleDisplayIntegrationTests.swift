import Foundation
import Testing
@testable import PersonalGantt

@MainActor
struct ScheduleDisplayIntegrationTests {
    @Test func taskEditsCompletionAndDeletionUpdateDisplayedSnapshotWithoutProviderReads() async throws {
        let http = MockGoogleHTTP()
        http.responses = [(200, #"{"items":[{"id":"study","summary":"Synthetic","accessRole":"reader"}]}"#),
            (200, #"{"items":[{"id":"fixed","summary":"合成固定予定","start":{"dateTime":"2026-10-07T10:00:00Z"},"end":{"dateTime":"2026-10-07T12:00:00Z"}}]}"#)]
        let clock = DisplayClock(ReminderFixtures.date(0))
        let task = PersonalGantt.Task(title: "合成作業", estimatedMinutes: 180, deadline: ReminderFixtures.date(23))
        let model = ScheduleViewModel(tasks: [task], calendarProvider: GoogleCalendarService(tokens: MockGoogleTokens(), transport: http,
            calendar: ReminderFixtures.calendar), activitySettings: .legacyFixture, calendar: ReminderFixtures.calendar, clock: { clock.date })
        #expect(await model.applyCalendarSelection(["study"]))
        let before = model.result
        let first = try #require(model.daySchedule(on: ReminderFixtures.date(0)))
        #expect(first.blocks.count == 2 && first.events.count == 1 && first.workMinutes == 180)
        #expect(model.result == before)
        #expect(model.displayDays(referenceDate: ReminderFixtures.date(0)).count == 14)
        try model.updateTask(id: task.id, draft: TaskDraft(title: "変更した作業", estimatedMinutesText: "90", deadline: task.deadline))
        let edited = try #require(model.daySchedule(on: ReminderFixtures.date(0)))
        #expect(edited.blocks.count == 1 && edited.workMinutes == 90)
        let placement = try #require(GanttPlacement.of(edited.blocks[0].interval, in: edited.day))
        #expect(abs(placement.lengthFraction - 90.0 / 1440) < 0.000001)
        #expect(model.title(for: task.id) == "変更した作業")
        await model.toggleTaskCompletion(id: task.id)
        #expect(model.daySchedule(on: ReminderFixtures.date(0))?.blocks.isEmpty == true)
        await model.toggleTaskCompletion(id: task.id)
        let protected = try #require(model.result.blocks.first)
        clock.date = ReminderFixtures.date(8, 30)
        model.deleteTask(id: task.id)
        #expect(model.task(for: task.id) == nil)
        #expect(model.title(for: task.id) == "変更した作業")
        #expect(model.daySchedule(on: ReminderFixtures.date(0))?.blocks.map(\.source) == [protected])
        #expect(http.requests.count == 2)
    }

    @Test func reminderCompletionFromDetailUsesSameControllerAndUpdatesDisplay() async throws {
        let provider = FakeReminderProvider()
        provider.records = [ReminderFixtures.record()]
        let model = ScheduleViewModel(tasks: [], availableSlots: [AvailableSlot(start: ReminderFixtures.date(8), end: ReminderFixtures.date(10))])
        model.attachReminders(provider: provider, storage: MemoryReminderMetadata())
        let reminders = try #require(model.reminders)
        #expect(await reminders.applySelection(["list"]))
        try reminders.configure(identifier: "r", estimatedMinutesText: "60", deadlineOverride: nil)
        let task = try #require(model.tasks.first)
        #expect(model.canToggleTask(task) && !model.taskIsBusy(task.id))
        await model.toggleTaskCompletion(id: task.id)
        #expect(provider.writes.count == 1 && model.task(for: task.id)?.isCompleted == true)
        #expect(model.result.blocks.isEmpty)
        await model.toggleTaskCompletion(id: task.id)
        #expect(model.result.blocks.count == 1 && provider.writes.count == 2)
    }

    @Test func readOnlyReminderDetailDisablesCompletionAndMissingTaskReturnsNil() async throws {
        let provider = FakeReminderProvider(); provider.records = [ReminderFixtures.record(writable: false)]
        let model = ScheduleViewModel(tasks: [], availableSlots: [])
        model.attachReminders(provider: provider, storage: MemoryReminderMetadata())
        let reminders = try #require(model.reminders)
        #expect(await reminders.applySelection(["list"]))
        try reminders.configure(identifier: "r", estimatedMinutesText: "60", deadlineOverride: nil)
        #expect(!model.canToggleTask(try #require(model.tasks.first)))
        #expect(model.task(for: UUID()) == nil)
    }
}

@MainActor
private final class DisplayClock {
    var date: Date
    init(_ date: Date) { self.date = date }
}
