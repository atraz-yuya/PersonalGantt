import Foundation
import Observation

@MainActor
@Observable
final class ScheduleViewModel {
    private(set) var tasks: [Task]
    private(set) var availableSlots: [AvailableSlot]
    private(set) var result: SchedulingResult

    init(tasks: [Task], availableSlots: [AvailableSlot]) {
        self.tasks = tasks
        self.availableSlots = availableSlots
        self.result = Scheduler().schedule(tasks: tasks, availableSlots: availableSlots)
    }

    convenience init() {
        let sample = SampleSchedule.make()
        self.init(tasks: sample.tasks, availableSlots: sample.slots)
    }

    var unscheduledTasks: [Task] {
        result.unscheduledTaskIDs.compactMap { id in tasks.first { $0.id == id } }
    }

    func recalculate() {
        result = Scheduler().schedule(tasks: tasks, availableSlots: availableSlots)
    }

    /// Replace generated availability when fixed events change, then rebuild the plan.
    func updateAvailableSlots(_ slots: [AvailableSlot]) {
        availableSlots = slots
        recalculate()
    }

    func title(for taskID: UUID) -> String {
        tasks.first { $0.id == taskID }?.title ?? "不明なタスク"
    }

    func scheduledMinutes(for taskID: UUID) -> Double {
        result.blocks.filter { $0.taskID == taskID }.reduce(0) { $0 + $1.durationMinutes }
    }

    /// Unallocated estimate, not a record of completed work.
    func unallocatedMinutes(for task: Task) -> Double {
        max(0, Double(task.estimatedMinutes) - scheduledMinutes(for: task.id))
    }
}
