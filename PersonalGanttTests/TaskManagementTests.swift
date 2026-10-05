import Foundation
import Testing
@testable import PersonalGantt

@MainActor
struct TaskManagementTests {
    @Test func addingTaskReordersAndRecalculatesOtherTasks() throws {
        let existing = task(1, minutes: 90, deadline: date(21))
        let model = makeModel(tasks: [existing])
        let added = try model.addTask(TaskDraft(title: " 新しい作業 \n", estimatedMinutesText: "30", deadline: date(20)))
        #expect(model.tasks.count == 2)
        #expect(added.title == "新しい作業")
        #expect(!added.isCompleted)
        #expect(added.id != existing.id)
        #expect(model.result.blocks == [
            block(added, from: date(18), to: date(18, 30)),
            block(existing, from: date(18, 30), to: date(20))
        ])
        #expect(model.result.unscheduledTaskIDs.isEmpty)
    }

    @Test func addingOversizedTaskReportsPartiallyUnallocatedTime() throws {
        let model = makeModel()
        let added = try model.addTask(TaskDraft(title: "大きな作業", estimatedMinutesText: "150", deadline: date(21)))
        #expect(model.result.blocks == [block(added, from: date(18), to: date(20))])
        #expect(model.unscheduledTasks == [added])
        #expect(model.unallocatedMinutes(for: added) == 30)
    }

    @Test func editingAllFieldsPreservesIdentityAndMovesOtherTasks() throws {
        let first = task(1, minutes: 90, deadline: date(20))
        let second = task(2, minutes: 60, deadline: date(22))
        let model = makeModel(tasks: [first, second])
        #expect(model.unallocatedMinutes(for: second) == 30)
        try model.updateTask(id: first.id, draft: TaskDraft(title: "変更後", estimatedMinutesText: "30", deadline: date(23)))
        let edited = try #require(model.tasks.first { $0.id == first.id })
        #expect(edited.id == first.id)
        #expect(edited.title == "変更後")
        #expect(edited.estimatedMinutes == 30)
        #expect(edited.deadline == date(23))
        #expect(model.title(for: first.id) == "変更後")
        #expect(model.result.blocks == [
            block(second, from: date(18), to: date(19)),
            block(edited, from: date(19), to: date(19, 30))
        ])
        #expect(model.result.unscheduledTaskIDs.isEmpty)
    }

    @Test func earlierDeadlineRemovesIneligibleBlocks() throws {
        let original = task(1, minutes: 90, deadline: date(21))
        let model = makeModel(tasks: [original])
        try model.updateTask(id: original.id, draft: TaskDraft(title: "締切変更", estimatedMinutesText: "90", deadline: date(18)))
        #expect(model.result.blocks.isEmpty)
        #expect(model.result.unscheduledTaskIDs == [original.id])
        #expect(model.unallocatedMinutes(for: model.tasks[0]) == 90)
    }

    @Test func deletingTaskFreesCapacityAndRemovesEveryReference() {
        let first = task(1, minutes: 90, deadline: date(20))
        let second = task(2, minutes: 60, deadline: date(21))
        let model = makeModel(tasks: [first, second])
        #expect(model.unallocatedMinutes(for: second) == 30)
        model.deleteTask(id: first.id)
        #expect(model.tasks == [second])
        #expect(model.result.blocks == [block(second, from: date(18), to: date(19))])
        #expect(model.result.unscheduledTaskIDs.isEmpty)
        #expect(model.unallocatedMinutes(for: second) == 0)
        model.deleteTask(id: second.id)
        #expect(model.tasks.isEmpty)
        #expect(model.result == SchedulingResult(blocks: [], unscheduledTaskIDs: []))
    }

    @Test func completionAndReopeningRecalculateAndRestoreDeterministicPlan() {
        let first = task(1, minutes: 90, deadline: date(20))
        let second = task(2, minutes: 60, deadline: date(21))
        let model = makeModel(tasks: [first, second])
        let before = model.result
        model.toggleCompletion(id: first.id)
        #expect(model.tasks[0].isCompleted)
        #expect(model.result.blocks == [block(second, from: date(18), to: date(19))])
        #expect(model.unscheduledTasks.isEmpty)
        #expect(model.unallocatedMinutes(for: model.tasks[0]) == 0)
        model.toggleCompletion(id: first.id)
        #expect(!model.tasks[0].isCompleted)
        #expect(model.result == before)
    }

    @Test func completingUnscheduledTaskRemovesWarning() {
        let original = task(1, minutes: 150, deadline: date(21))
        let model = makeModel(tasks: [original])
        #expect(model.unscheduledTasks == [original])
        model.toggleCompletion(id: original.id)
        #expect(model.result.blocks.isEmpty)
        #expect(model.unscheduledTasks.isEmpty)
        #expect(model.unallocatedMinutes(for: model.tasks[0]) == 0)
    }

    @Test func editingCompletedTaskPreservesCompletion() throws {
        var original = task(1, minutes: 90, deadline: date(21))
        original.isCompleted = true
        let model = makeModel(tasks: [original])
        try model.updateTask(id: original.id, draft: TaskDraft(title: "完了後編集", estimatedMinutesText: "120", deadline: date(23)))
        #expect(model.tasks[0].id == original.id)
        #expect(model.tasks[0].isCompleted)
        #expect(model.result.blocks.isEmpty)
        #expect(model.result.unscheduledTaskIDs.isEmpty)
        model.toggleCompletion(id: original.id)
        #expect(model.result.blocks == [block(model.tasks[0], from: date(18), to: date(20))])
    }

    @Test(arguments: ["", " ", "\n\t　"])
    func emptyTitlesRejectAddAndEditWithoutMutation(title: String) {
        assertRejected(
            TaskDraft(title: title, estimatedMinutesText: "60", deadline: date(21)),
            error: .emptyTitle
        )
    }

    @Test(arguments: ["0", "-1", "1.5", "abc", "", "  ", String(repeating: "9", count: 40)])
    func invalidMinutesRejectAddAndEditWithoutMutation(minutes: String) {
        assertRejected(
            TaskDraft(title: "作業", estimatedMinutesText: minutes, deadline: date(21)),
            error: .invalidMinutes
        )
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity,
                      Date.distantPast.timeIntervalSinceReferenceDate - 1,
                      Date.distantFuture.timeIntervalSinceReferenceDate + 1])
    func invalidDatesRejectAddAndEditWithoutMutation(interval: Double) {
        assertRejected(
            TaskDraft(title: "作業", estimatedMinutesText: "60", deadline: Date(timeIntervalSinceReferenceDate: interval)),
            error: .invalidDeadline
        )
    }

    @Test func pastDeadlineIsValidButHasNoFuturePlacement() throws {
        let model = makeModel()
        let added = try model.addTask(TaskDraft(title: "期限切れ", estimatedMinutesText: "60", deadline: date(17)))
        #expect(model.tasks == [added])
        #expect(model.result.blocks.isEmpty)
        #expect(model.result.unscheduledTaskIDs == [added.id])
        #expect(model.unallocatedMinutes(for: added) == 60)
    }

    @Test func whitespaceAndPositiveIntegerMinutesAreNormalized() throws {
        let input = try TaskDraft(title: "  作業\n", estimatedMinutesText: "  0015 \n", deadline: date(21)).validated()
        #expect(input.title == "作業")
        #expect(input.estimatedMinutes == 15)
    }

    @Test func cancelledDraftEditsDoNotMutateTaskOrSchedule() {
        let original = task(1, minutes: 90, deadline: date(21))
        let model = makeModel(tasks: [original])
        let before = model.result
        var draft = TaskDraft(task: original)
        draft.title = "未保存"
        draft.estimatedMinutesText = "15"
        draft.deadline = date(19)
        #expect(model.tasks == [original])
        #expect(model.result == before)
    }

    @Test func missingTaskCannotBeRecreatedByStaleEditor() {
        let original = task(1, minutes: 90, deadline: date(21))
        let model = makeModel(tasks: [original])
        let draft = TaskDraft(task: original)
        model.deleteTask(id: original.id)
        #expect(throws: TaskInputError.taskNotFound) { try model.updateTask(id: original.id, draft: draft) }
        model.deleteTask(id: original.id)
        model.toggleCompletion(id: original.id)
        #expect(model.tasks.isEmpty)
        #expect(model.result == SchedulingResult(blocks: [], unscheduledTaskIDs: []))
    }

    private func assertRejected(_ draft: TaskDraft, error: TaskInputError) {
        let original = task(1, minutes: 90, deadline: date(21))
        let model = makeModel(tasks: [original])
        let before = model.result
        #expect(draft.validationMessage == error.errorDescription)
        #expect(throws: error) { try model.addTask(draft) }
        #expect(model.tasks == [original])
        #expect(model.result == before)
        #expect(throws: error) { try model.updateTask(id: original.id, draft: draft) }
        #expect(model.tasks == [original])
        #expect(model.result == before)
    }

    private func makeModel(tasks: [PersonalGantt.Task] = []) -> ScheduleViewModel {
        ScheduleViewModel(tasks: tasks, availableSlots: [AvailableSlot(start: date(18), end: date(20))])
    }

    private func task(_ index: Int, minutes: Int, deadline: Date) -> PersonalGantt.Task {
        PersonalGantt.Task(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!,
                          title: "Task \(index)", estimatedMinutes: minutes, deadline: deadline)
    }

    private func block(_ task: PersonalGantt.Task, from start: Date, to end: Date) -> ScheduledBlock {
        ScheduledBlock(taskID: task.id, start: start, end: end)
    }

    private func date(_ hour: Int, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: hour, minute: minute))!
    }
}
