import Foundation
import Testing
@testable import PersonalGantt

struct SchedulerTests {
    private let scheduler = Scheduler()

    @Test func ninetyMinutesFitInOneSlot() {
        let task = makeTask(1, minutes: 90)
        let result = scheduler.schedule(tasks: [task], availableSlots: [slot(18, 20)])
        #expect(result.blocks == [block(task, from: date(18), to: date(19, 30))])
        #expect(result.unscheduledTaskIDs.isEmpty)
    }

    @Test func tasksConsumeCapacityWithoutOverlap() {
        let first = makeTask(1, minutes: 90, deadline: date(20))
        let second = makeTask(2, minutes: 30, deadline: date(21))
        let result = scheduler.schedule(tasks: [second, first], availableSlots: [slot(18, 20)])
        #expect(result.blocks == [
            block(first, from: date(18), to: date(19, 30)),
            block(second, from: date(19, 30), to: date(20))
        ])
        #expect(result.unscheduledTaskIDs.isEmpty)
    }

    @Test func taskSplitsAcrossSeparateSlots() {
        let task = makeTask(1, minutes: 120)
        let result = scheduler.schedule(tasks: [task], availableSlots: [slot(20, 21), slot(18, 19)])
        #expect(result.blocks == [
            block(task, from: date(18), to: date(19)),
            block(task, from: date(20), to: date(21))
        ])
        #expect(result.unscheduledTaskIDs.isEmpty)
    }

    @Test func deadlineClipsPartialAllocation() {
        let task = makeTask(1, minutes: 90, deadline: date(19))
        let result = scheduler.schedule(tasks: [task], availableSlots: [slot(18, 20)])
        #expect(result.blocks == [block(task, from: date(18), to: date(19))])
        #expect(result.unscheduledTaskIDs == [task.id])
    }

    @Test func slotsAtOrAfterDeadlineAreNotUsed() {
        let task = makeTask(1, minutes: 30, deadline: date(18))
        let result = scheduler.schedule(tasks: [task], availableSlots: [slot(18, 20), slot(21, 22)])
        #expect(result.blocks.isEmpty)
        #expect(result.unscheduledTaskIDs == [task.id])
    }

    @Test func endingExactlyAtDeadlineIsAllowed() {
        let task = makeTask(1, minutes: 90, deadline: date(19, 30))
        let result = scheduler.schedule(tasks: [task], availableSlots: [slot(18, 20)])
        #expect(result.blocks == [block(task, from: date(18), to: date(19, 30))])
        #expect(result.unscheduledTaskIDs.isEmpty)
    }

    @Test func changedAvailabilityRebuildsSchedule() {
        let task = makeTask(1, minutes: 90, deadline: date(23, day: 29))
        let before = scheduler.schedule(tasks: [task], availableSlots: [slot(19, 21)])
        // A fixed event removes tonight's slot; tomorrow's availability replaces it.
        let after = scheduler.schedule(tasks: [task], availableSlots: [slot(10, 12, day: 29)])
        #expect(before.blocks == [block(task, from: date(19), to: date(20, 30))])
        #expect(after.blocks == [block(task, from: date(10, day: 29), to: date(11, 30, day: 29))])
        #expect(after.unscheduledTaskIDs.isEmpty)
    }

    @Test func completedTasksDoNotConsumeCapacity() {
        var completed = makeTask(1, minutes: 90, deadline: date(19))
        completed.isCompleted = true
        let pending = makeTask(2, minutes: 120)
        let result = scheduler.schedule(tasks: [completed, pending], availableSlots: [slot(18, 20)])
        #expect(result.blocks == [block(pending, from: date(18), to: date(20))])
        #expect(result.unscheduledTaskIDs.isEmpty)
    }

    @Test func specificationMVPExample() {
        let first = makeTask(1, minutes: 90, deadline: date(23, day: 30))
        let second = makeTask(2, minutes: 120, deadline: date(23, day: 1, month: 10))
        let result = scheduler.schedule(tasks: [second, first], availableSlots: [slot(18, 20, day: 29), slot(18, 20)])
        #expect(result.blocks == [
            block(first, from: date(18), to: date(19, 30)),
            block(second, from: date(19, 30), to: date(20)),
            block(second, from: date(18, day: 29), to: date(19, 30, day: 29))
        ])
        #expect(result.blocks.reduce(0) { $0 + $1.durationMinutes } == 210)
        #expect(result.unscheduledTaskIDs.isEmpty)
    }

    @Test func sameDeadlineAndReorderedInputRemainDeterministic() {
        let first = makeTask(1, minutes: 90)
        let second = makeTask(2, minutes: 60)
        let slots = [slot(18, 20), slot(21, 22)]
        let result = scheduler.schedule(tasks: [second, first], availableSlots: slots)
        #expect(result == scheduler.schedule(tasks: [second, first], availableSlots: slots))
        #expect(result == scheduler.schedule(tasks: [first, second], availableSlots: slots.reversed()))
        #expect(result.blocks.first?.taskID == first.id)
        #expect(Set(result.blocks.map(\.id)).count == result.blocks.count)
    }

    @Test func overlappingDuplicateAndAdjacentSlotsDoNotDoubleCountCapacity() {
        let task = makeTask(1, minutes: 240)
        let result = scheduler.schedule(tasks: [task], availableSlots: [
            slot(18, 20), slot(19, 21), slot(18, 20), slot(21, 22)
        ])
        #expect(result.blocks == [block(task, from: date(18), to: date(22))])
        #expect(result.unscheduledTaskIDs.isEmpty)
        let tooLong = makeTask(2, minutes: 241)
        let insufficient = scheduler.schedule(tasks: [tooLong], availableSlots: [slot(18, 20), slot(19, 22)])
        #expect(insufficient.blocks.reduce(0) { $0 + $1.durationMinutes } == 240)
        #expect(insufficient.unscheduledTaskIDs == [tooLong.id])
    }

    @Test func invalidAndEmptySlotsAreIgnored() {
        let task = makeTask(1, minutes: 60)
        let invalid = [slot(20, 18), slot(19, 19)]
        let result = scheduler.schedule(tasks: [task], availableSlots: invalid)
        #expect(result.blocks.isEmpty)
        #expect(result.unscheduledTaskIDs == [task.id])
        #expect(scheduler.schedule(tasks: [task], availableSlots: []).unscheduledTaskIDs == [task.id])
        #expect(scheduler.schedule(tasks: [], availableSlots: [slot(18, 20)]) == SchedulingResult(blocks: [], unscheduledTaskIDs: []))
    }

    @Test func zeroAndNegativeEstimatesDoNotCreateBlocks() {
        let zero = makeTask(1, minutes: 0)
        let invalid = makeTask(2, minutes: -30)
        let valid = makeTask(3, minutes: 60)
        let result = scheduler.schedule(tasks: [zero, invalid, valid], availableSlots: [slot(18, 19)])
        #expect(result.blocks == [block(valid, from: date(18), to: date(19))])
        #expect(result.unscheduledTaskIDs == [invalid.id])
    }

    @Test func deadlineRemainderStaysAvailableForLaterTasks() {
        let first = makeTask(1, minutes: 120, deadline: date(19))
        let second = makeTask(2, minutes: 60, deadline: date(20))
        let result = scheduler.schedule(tasks: [first, second], availableSlots: [slot(18, 20)])
        #expect(result.blocks == [
            block(first, from: date(18), to: date(19)),
            block(second, from: date(19), to: date(20))
        ])
        #expect(result.unscheduledTaskIDs == [first.id])
    }

    @Test func subminuteBoundariesPreserveExactDuration() {
        let task = makeTask(1, minutes: 60)
        let result = scheduler.schedule(tasks: [task], availableSlots: [
            AvailableSlot(start: date(18, second: 30), end: date(19)),
            AvailableSlot(start: date(20), end: date(21))
        ])
        #expect(result.blocks == [
            block(task, from: date(18, second: 30), to: date(19)),
            block(task, from: date(20), to: date(20, second: 30))
        ])
        #expect(result.blocks.reduce(0) { $0 + $1.durationMinutes } == 60)
        #expect(result.unscheduledTaskIDs.isEmpty)
    }

    @Test @MainActor func viewModelReplacesOldBlocksAndReportsUnallocatedMinutes() {
        let task = makeTask(1, minutes: 90)
        let model = ScheduleViewModel(tasks: [task], availableSlots: [slot(18, 20)])
        #expect(model.result.unscheduledTaskIDs.isEmpty)
        model.updateAvailableSlots([slot(20, 21)])
        #expect(model.result.blocks == [block(task, from: date(20), to: date(21))])
        #expect(model.unscheduledTasks == [task])
        #expect(model.unallocatedMinutes(for: task) == 30)
        let result = model.result
        model.recalculate()
        #expect(model.result == result)
    }

    @Test func modelsRoundTripThroughJSON() throws {
        let task = makeTask(1, minutes: 90)
        let scheduled = block(task, from: date(18), to: date(19, 30))
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        #expect(try decoder.decode(PersonalGantt.Task.self, from: encoder.encode(task)) == task)
        #expect(try decoder.decode(ScheduledBlock.self, from: encoder.encode(scheduled)) == scheduled)
    }

    @Test(arguments: [15, 60, 90, 150, 300, 600])
    func allocationInvariants(minutes: Int) throws {
        let tasks = [
            makeTask(1, minutes: minutes, deadline: date(19, 30)),
            makeTask(2, minutes: minutes, deadline: date(22)),
            makeTask(3, minutes: minutes, deadline: date(23, day: 29))
        ]
        let slots = [slot(18, 20), slot(21, 22), slot(10, 12, day: 29)]
        let result = scheduler.schedule(tasks: tasks, availableSlots: slots)
        for block in result.blocks {
            let task = try #require(tasks.first { $0.id == block.taskID })
            #expect(block.start < block.end)
            #expect(block.end <= task.deadline)
            #expect(slots.contains { $0.start <= block.start && block.end <= $0.end })
        }
        for (first, second) in zip(result.blocks, result.blocks.dropFirst()) {
            #expect(first.end <= second.start)
        }
        for task in tasks {
            let allocated = result.blocks.filter { $0.taskID == task.id }.reduce(0) { $0 + $1.durationMinutes }
            #expect(allocated <= Double(task.estimatedMinutes))
            #expect(result.unscheduledTaskIDs.contains(task.id) == (allocated < Double(task.estimatedMinutes)))
        }
    }

    private func makeTask(_ index: Int, minutes: Int, deadline: Date? = nil) -> PersonalGantt.Task {
        PersonalGantt.Task(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!,
            title: "Task \(index)",
            estimatedMinutes: minutes,
            deadline: deadline ?? date(23)
        )
    }

    private func block(_ task: PersonalGantt.Task, from start: Date, to end: Date) -> ScheduledBlock {
        ScheduledBlock(taskID: task.id, start: start, end: end)
    }

    private func slot(_ startHour: Int, _ endHour: Int, day: Int = 28) -> AvailableSlot {
        AvailableSlot(start: date(startHour, day: day), end: date(endHour, day: day))
    }

    /// UTC fixtures are independent of the machine's calendar and time zone.
    private func date(_ hour: Int, _ minute: Int = 0, second: Int = 0, day: Int = 28, month: Int = 9) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute, second: second))!
    }
}
