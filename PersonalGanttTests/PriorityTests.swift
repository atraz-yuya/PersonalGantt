import Foundation
import Testing
@testable import PersonalGantt

struct PriorityTests {
    @Test func sameDeadlineUsesPriorityAndThenDeterministicIdentity() {
        let tasks = TaskPriority.allCases.map { PersonalGantt.Task(title: $0.displayName, estimatedMinutes: 60, deadline: ReminderFixtures.date(12), priority: $0) }
        let slots = [AvailableSlot(start: ReminderFixtures.date(8), end: ReminderFixtures.date(12))]
        let a = Scheduler().schedule(tasks: tasks, availableSlots: slots)
        let b = Scheduler().schedule(tasks: tasks.reversed(), availableSlots: slots)
        #expect(a == b && a.blocks.map(\.taskID) == tasks.reversed().map(\.id))
    }
    @Test func earlierDeadlineWinsOverCriticalLaterDeadline() {
        let early = PersonalGantt.Task(title: "Early", estimatedMinutes: 60, deadline: ReminderFixtures.date(9), priority: .low)
        let later = PersonalGantt.Task(title: "Later", estimatedMinutes: 60, deadline: ReminderFixtures.date(10), priority: .critical)
        let result = Scheduler().schedule(tasks: [later,early], availableSlots: [AvailableSlot(start: ReminderFixtures.date(8), end: ReminderFixtures.date(10))])
        #expect(result.blocks.first?.taskID == early.id && result.unscheduledTaskIDs.isEmpty)
    }
    @Test func legacyJSONDefaultsToNormalAndInvalidPriorityRejects() throws {
        let task = PersonalGantt.Task(title: "Legacy", estimatedMinutes: 60, deadline: ReminderFixtures.date(12))
        let data = try JSONEncoder().encode(task)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "priority")
        #expect(try JSONDecoder().decode(PersonalGantt.Task.self, from: JSONSerialization.data(withJSONObject: object)).priority == .normal)
        object["priority"] = 999
        #expect(throws: (any Error).self) { try JSONDecoder().decode(PersonalGantt.Task.self, from: JSONSerialization.data(withJSONObject: object)) }
    }
    @Test func balancedMixStillRespectsDeadlineAndDailyLimit() {
        let tasks = TaskPriority.allCases.map { PersonalGantt.Task(title: $0.displayName, estimatedMinutes: 300, deadline: ReminderFixtures.date(23, day: 14), priority: $0) }
        let slots = (7...14).map { AvailableSlot(start: ReminderFixtures.date(8, day: $0), end: ReminderFixtures.date(23, day: $0)) }
        let result = Scheduler().schedule(tasks: tasks, availableSlots: slots, workloadSettings: WorkloadSettings(maxScheduledMinutesPerDay: 180), calendar: ReminderFixtures.calendar, distributionMode: .balanced)
        #expect(result.unscheduledTaskIDs.isEmpty)
        #expect(DailyWorkload.secondsByDay(blocks: result.blocks, calendar: ReminderFixtures.calendar).values.allSatisfy { $0 <= 180 * 60 })
    }
}
@MainActor struct PriorityIntegrationTests {
    @Test func editingPreservesIdentityAndPrioritySurvivesSync() throws {
        let a = ScheduleViewModel(tasks: [], availableSlots: []), b = ScheduleViewModel(tasks: [], availableSlots: [])
        let work = try a.addTask(TaskDraft(title: "Priority", deadline: ReminderFixtures.date(23), priority: .high))
        var draft = TaskDraft(task: work); draft.priority = .critical
        try a.updateTask(id: work.id, draft: draft)
        try b.mergeSyncRecords(Array(a.syncState.records.values))
        #expect(b.task(for: work.id)?.priority == .critical)
    }
}
