import Foundation
import Testing
@testable import PersonalGantt

@MainActor
struct ReminderAssociationTests {
    @Test func editingTaskPreservesLocalReminderAssociation() throws {
        let task = PersonalGantt.Task(title: "卒論", estimatedMinutes: 60, deadline: .distantFuture, reminderIdentifier: "synthetic-reminder")
        let model = ScheduleViewModel(tasks: [task], availableSlots: [])
        try model.updateTask(id: task.id, draft: TaskDraft(title: "卒論の編集", estimatedMinutesText: "90", deadline: .distantFuture))
        model.toggleCompletion(id: task.id)
        #expect(model.tasks[0].reminderIdentifier == "synthetic-reminder")
        #expect(model.tasks[0].estimatedMinutes == 90)
        #expect(try JSONDecoder().decode(PersonalGantt.Task.self, from: JSONEncoder().encode(model.tasks[0])) == model.tasks[0])
    }

    @Test func olderTaskJsonWithoutReminderIdentifierStillDecodes() throws {
        let json = #"{"id":"00000000-0000-0000-0000-000000000001","title":"旧タスク","isCompleted":false,"estimatedMinutes":60,"deadline":0}"#
        let task = try JSONDecoder().decode(PersonalGantt.Task.self, from: Data(json.utf8))
        #expect(task.reminderIdentifier == nil)
    }
}
