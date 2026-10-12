import Foundation
import Testing
@testable import PersonalGantt

struct OptimizationTests {
    private var calendar: Calendar { ReminderFixtures.calendar }
    @Test func scoreRejectsFixedConflictDeadlineCapAndRoutineRangeBeforeSoftBenefits() {
        let task = PersonalGantt.Task(title: "Synthetic", estimatedMinutes: 60, deadline: ReminderFixtures.date(10))
        let slots = [AvailableSlot(start: ReminderFixtures.date(8), end: ReminderFixtures.date(9))]
        let request = OptimizationRequest(tasks: [task], slots: slots, workload: WorkloadSettings(maxScheduledMinutesPerDay: 60), calendar: calendar)
        let valid = Scheduler().schedule(tasks: [task], availableSlots: slots)
        let invalid = SchedulingResult(blocks: [ScheduledBlock(taskID: task.id, start: ReminderFixtures.date(9), end: ReminderFixtures.date(12))], unscheduledTaskIDs: [])
        let engine = ScheduleOptimizationEngine()
        #expect(engine.score(valid, request: request).hardViolations == 0)
        #expect(engine.score(invalid, request: request).hardViolations >= 3)
        #expect(engine.score(valid, request: request) < engine.score(invalid, request: request))
    }
    @Test func optimizerChoosesBalancedWhenSpreadIsRequestedAndIsDeterministic() {
        let tasks = [PersonalGantt.Task(title: "Synthetic", estimatedMinutes: 1200, deadline: ReminderFixtures.date(0, day: 17))]
        let slots = (7..<17).map { AvailableSlot(start: ReminderFixtures.date(8, day: $0), end: ReminderFixtures.date(23, day: $0)) }
        let settings = SchedulingSettings(distributionMode: .balanced, optimizeLocally: true)
        let request = OptimizationRequest(tasks: tasks, slots: slots, workload: WorkloadSettings(maxScheduledMinutesPerDay: 300), settings: settings, calendar: calendar)
        let engine = ScheduleOptimizationEngine(), result = engine.schedule(request)
        #expect(result.blocks.count == 10 && result.blocks.allSatisfy { $0.durationMinutes == 120 })
        #expect(engine.score(result, request: request).hardViolations == 0 && result == engine.schedule(request))
    }
    @Test func optimizerDoesNotSacrificeCapacityForDistribution() {
        let task = PersonalGantt.Task(title: "Synthetic", estimatedMinutes: 1000, deadline: ReminderFixtures.date(10))
        let request = OptimizationRequest(tasks: [task], slots: [AvailableSlot(start: ReminderFixtures.date(8), end: ReminderFixtures.date(23))],
            settings: SchedulingSettings(distributionMode: .balanced, optimizeLocally: true), calendar: calendar)
        let result = ScheduleOptimizationEngine().schedule(request)
        #expect(result.blocks.first?.durationMinutes == 120 && result.blocks.first?.end == task.deadline)
    }
    @Test func restWindowsBoundContinuousWorkAndLeaveMinimumGaps() {
        let task = PersonalGantt.Task(title: "Synthetic", estimatedMinutes: 240, deadline: ReminderFixtures.date(18))
        let settings = SchedulingSettings(maxContinuousMinutes: 90, minimumBreakMinutes: 15)
        let request = OptimizationRequest(tasks: [task], slots: [AvailableSlot(start: ReminderFixtures.date(8), end: ReminderFixtures.date(18))], settings: settings, calendar: calendar)
        let result = ScheduleOptimizationEngine().schedule(request)
        #expect(result.blocks.map(\.durationMinutes) == [90,90,60])
        #expect(zip(result.blocks, result.blocks.dropFirst()).allSatisfy { $1.start.timeIntervalSince($0.end) >= 900 })
        #expect(result.unscheduledTaskIDs.isEmpty)
    }
    @Test func begunWorkIsPreservedAndRestStartsAfterIt() {
        let task = PersonalGantt.Task(title: "Synthetic", estimatedMinutes: 300, deadline: ReminderFixtures.date(23))
        let begun = ScheduledBlock(taskID: task.id, start: ReminderFixtures.date(8), end: ReminderFixtures.date(10))
        let result = ScheduleReplanner().schedule(tasks: [task], availableSlots: [AvailableSlot(start: ReminderFixtures.date(9), end: ReminderFixtures.date(23))],
            previousBlocks: [begun], now: ReminderFixtures.date(9), calendar: calendar,
            optimizationSettings: SchedulingSettings(maxContinuousMinutes: 90, minimumBreakMinutes: 15))
        #expect(result.blocks.contains(begun) && result.blocks.dropFirst().first?.start == ReminderFixtures.date(10, 15))
    }
    @Test(arguments: [0,-1,481]) func invalidContinuousSettingsAreRejected(minutes: Int) {
        #expect(!SchedulingSettings(maxContinuousMinutes: minutes, minimumBreakMinutes: 15).isValid)
    }
    @Test func priorityWeightsAffectUnallocatedPenaltyAndNoExternalServiceIsRequired() {
        let normal = PersonalGantt.Task(title: "Normal", estimatedMinutes: 60, deadline: ReminderFixtures.date(12))
        var high = normal; high.priority = .critical
        let empty = SchedulingResult(blocks: [], unscheduledTaskIDs: [normal.id])
        let engine = ScheduleOptimizationEngine()
        let a = engine.score(empty, request: OptimizationRequest(tasks: [normal], slots: []))
        let b = engine.score(empty, request: OptimizationRequest(tasks: [high], slots: []))
        #expect(b.weightedUnallocatedMinutes > a.weightedUnallocatedMinutes)
    }
}
