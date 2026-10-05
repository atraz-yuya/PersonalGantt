import Foundation
import Testing
@testable import PersonalGantt

struct ScheduleReplannerTests {
    private let replanner = ScheduleReplanner()

    @Test func pastAndCurrentBlocksArePreservedAndOnlyFutureRemainderMoves() {
        let task = makeTask(minutes: 180)
        let past = block(task, 8, 9)
        let current = block(task, 9, 10)
        let future = block(task, 10, 11)
        let result = replanner.schedule(tasks: [task], availableSlots: [slot(12, 14)], previousBlocks: [past, current, future], now: date(9, 30))
        #expect(result.blocks == [past, current, block(task, 12, 13)])
        #expect(result.unscheduledTaskIDs.isEmpty)
        #expect(result.blocks.reduce(0) { $0 + $1.durationMinutes } == 180)
    }

    @Test func currentWorkReservesItsWholeIntervalEvenIfTaskIsDeleted() {
        let removed = makeTask(minutes: 60)
        let pending = makeTask(minutes: 30)
        let current = block(removed, 9, 10)
        let result = replanner.schedule(tasks: [pending], availableSlots: [slot(9, 12)], previousBlocks: [current], now: date(9, 30))
        #expect(result.blocks == [current, block(pending, 10, 10, endMinute: 30)])
    }

    @Test func completingTaskKeepsBegunBlockAndDropsFutureBlocks() {
        var task = makeTask(minutes: 120)
        task.isCompleted = true
        let past = block(task, 8, 9)
        let future = block(task, 10, 11)
        let result = replanner.schedule(tasks: [task], availableSlots: [slot(10, 12)], previousBlocks: [past, future], now: date(9))
        #expect(result.blocks == [past])
        #expect(result.unscheduledTaskIDs.isEmpty)
    }

    @Test func slotsBeforeNowAreClippedAndEmptySlotsIgnored() {
        let task = makeTask(minutes: 30)
        let result = replanner.schedule(tasks: [task], availableSlots: [slot(7, 8), slot(9, 12)], previousBlocks: [], now: date(10))
        #expect(result.blocks == [block(task, 10, 10, endMinute: 30)])
    }

    @Test func partiallyPlacedFutureWorkIsReportedUnscheduled() {
        let task = makeTask(minutes: 180)
        let past = block(task, 8, 9)
        let result = replanner.schedule(tasks: [task], availableSlots: [slot(10, 11)], previousBlocks: [past], now: date(9))
        #expect(result.blocks == [past, block(task, 10, 11)])
        #expect(result.unscheduledTaskIDs == [task.id])
    }

    @Test func subminuteReservationDoesNotRoundAwayRemainingWork() {
        let task = makeTask(minutes: 1)
        let past = ScheduledBlock(taskID: task.id, start: date(8), end: date(8).addingTimeInterval(30))
        let result = replanner.schedule(tasks: [task], availableSlots: [slot(9, 10)], previousBlocks: [past], now: date(8, 1))
        #expect(result.blocks == [past, ScheduledBlock(taskID: task.id, start: date(9), end: date(9).addingTimeInterval(30))])
        #expect(result.unscheduledTaskIDs.isEmpty)
    }

    @Test func blockStartingExactlyNowIsProtected() {
        let task = makeTask(minutes: 60)
        let current = block(task, 9, 10)
        let result = replanner.schedule(tasks: [task], availableSlots: [], previousBlocks: [current], now: date(9))
        #expect(result.blocks == [current])
        #expect(result.unscheduledTaskIDs.isEmpty)
    }

    @Test func shortenedEstimateNeverChangesProtectedBlock() {
        var task = makeTask(minutes: 120)
        let current = block(task, 9, 10)
        task.estimatedMinutes = 30
        let result = replanner.schedule(tasks: [task], availableSlots: [slot(11, 12)], previousBlocks: [current], now: date(9, 30))
        #expect(result.blocks == [current])
        #expect(result.unscheduledTaskIDs.isEmpty)
    }

    @Test func replanningRemainsDeterministic() {
        let task = makeTask(minutes: 120)
        let previous = [block(task, 8, 9), block(task, 10, 11)]
        let slots = [slot(11, 13)]
        #expect(replanner.schedule(tasks: [task], availableSlots: slots, previousBlocks: previous, now: date(9)) == replanner.schedule(tasks: [task], availableSlots: slots, previousBlocks: previous, now: date(9)))
    }

    private func makeTask(minutes: Int) -> PersonalGantt.Task {
        PersonalGantt.Task(title: "作業", estimatedMinutes: minutes, deadline: date(23))
    }

    private func date(_ hour: Int, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: hour, minute: minute))!
    }

    private func block(_ task: PersonalGantt.Task, _ start: Int, _ end: Int, endMinute: Int = 0) -> ScheduledBlock {
        ScheduledBlock(taskID: task.id, start: date(start), end: date(end, endMinute))
    }

    private func slot(_ start: Int, _ end: Int) -> AvailableSlot {
        AvailableSlot(start: date(start), end: date(end))
    }
}
