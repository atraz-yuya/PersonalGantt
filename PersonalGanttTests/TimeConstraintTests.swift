import Foundation
import Testing
@testable import PersonalGantt

struct TimeConstraintTests {
    let calendar = ReminderFixtures.calendar
    func date(_ hour: Int, _ minute: Int = 0, day: Int = 13) -> Date { ReminderFixtures.date(hour, minute, day: day) }
    func rule(_ start: Int, _ end: Int, days: Set<Int> = Set(1...7)) -> AvailabilityExclusion {
        AvailabilityExclusion(weekdays: days, startMinuteOfDay: start, endMinuteOfDay: end)
    }
    func slots(_ rules: [AvailabilityExclusion], day: Int = 13, days: Int = 1, events: [FixedEvent] = []) throws -> [AvailableSlot] {
        var hours = ActivitySettings.default; hours.globalAvailabilityExclusions = rules
        return try AvailabilityService().availableSlots(fixedEvents: events,
            in: DateInterval(start: date(0, day: day), end: date(0, day: day + days)), settings: hours, referenceDate: date(0, day: day), calendar: calendar)
    }
    func routine(start: Int? = 1140, minutes: Int = 60, recurrence: RecurrenceRule = .weekly(weekday: 3), last: Int = 20) -> Routine {
        Routine(title: "Synthetic fixed", estimatedMinutesPerDay: minutes, startDate: date(0), endDate: date(0, day: last), recurrence: recurrence, fixedStartMinuteOfDay: start)
    }
    func occurrences(_ routine: Routine, days: Int = 8) -> [PersonalGantt.Task] {
        RoutinePlanner().tasks(for: [routine], in: DateInterval(start: date(0), end: date(0, day: 13 + days)), calendar: calendar)
    }
    func ranges(_ values: [AvailableSlot]) -> [DateInterval] { values.map { DateInterval(start: $0.start, end: $0.end) } }
    @Test func dailyGlobalExclusionProducesExpectedBaseSlots() throws {
        #expect(ranges(try slots([rule(720, 780), rule(1080, 1140)])) == [DateInterval(start: date(10), end: date(12)), DateInterval(start: date(13), end: date(18)), DateInterval(start: date(19), end: date(0, day: 14))])
    }
    @Test func weekdayAndSelectedWeekdaysUseLocalCalendar() throws {
        let weekdays = try slots([rule(720, 780, days: Set(2...6))], day: 16, days: 3)
        #expect(weekdays.count == 4 && weekdays.filter { calendar.component(.weekday, from: $0.start) == 7 }.count == 1)
        let selected = try slots([rule(900, 960, days: [1, 7])], day: 16, days: 3)
        #expect(selected.count == 5 && selected.filter { calendar.component(.weekday, from: $0.start) == 6 }.count == 1)
    }
    @Test(arguments: [0, 1, 2, 3, 4]) func globalUnionHandlesOverlapsAdjacencyAndOutsideHours(kind: Int) throws {
        let values: [AvailabilityExclusion]
        switch kind {
        case 0: values = [rule(720, 780), rule(750, 840)]
        case 1: values = [rule(720, 780), rule(780, 840)]
        case 2: values = [rule(720, 840), rule(720, 840)]
        case 3: values = [rule(0, 120), rule(720, 840)]
        default: values = [rule(720, 840), rule(780, 800), rule(0, 600)]
        }
        #expect(ranges(try slots(values)) == [DateInterval(start: date(10), end: date(12)), DateInterval(start: date(14), end: date(0, day: 14))])
    }
    @Test func commonExclusionAndCalendarOverlapAreSubtractedOnce() throws {
        let event = FixedEvent(id: "synthetic", calendarID: "test", title: "Synthetic", start: date(11), end: date(12, 30))
        #expect(ranges(try slots([rule(720, 780)], events: [event])) == [DateInterval(start: date(10), end: date(11)), DateInterval(start: date(13), end: date(0, day: 14))])
    }
    @Test func taskExclusionSplitsAndLeavesOtherTasksCandidateTime() {
        let a = PersonalGantt.Task(id: ReminderFixtures.id(7001), title: "A", estimatedMinutes: 90, deadline: date(20), availabilityExclusions: [rule(1080, 1140)])
        let result = Scheduler().schedule(tasks: [a], availableSlots: [AvailableSlot(start: date(17, 30), end: date(20))], calendar: calendar)
        #expect(result.blocks == [ScheduledBlock(taskID: a.id, start: date(17, 30), end: date(18)), ScheduledBlock(taskID: a.id, start: date(19), end: date(20))])
        var constrained = a; constrained.estimatedMinutes = 60
        let b = PersonalGantt.Task(id: ReminderFixtures.id(7002), title: "B", estimatedMinutes: 60, deadline: date(20))
        let pair = Scheduler().schedule(tasks: [constrained, b], availableSlots: [AvailableSlot(start: date(18), end: date(20))], calendar: calendar)
        #expect(pair.blocks.contains(ScheduledBlock(taskID: b.id, start: date(18), end: date(19))))
        #expect(pair.unscheduledTaskIDs.isEmpty)
    }
    @Test func globalTaskAndDeadlineConstraintsCompose() throws {
        let task = PersonalGantt.Task(title: "A", estimatedMinutes: 240, deadline: date(14, 30), availabilityExclusions: [rule(660, 720)])
        let result = Scheduler().schedule(tasks: [task], availableSlots: try slots([rule(720, 780)]), calendar: calendar)
        #expect(result.blocks.map { DateInterval(start: $0.start, end: $0.end) } == [DateInterval(start: date(10), end: date(11)), DateInterval(start: date(13), end: date(14, 30))])
        #expect(result.unscheduledTaskIDs == [task.id])
    }
    @Test func deletingConstraintRestoresContinuousScheduling() {
        var task = PersonalGantt.Task(title: "A", estimatedMinutes: 90, deadline: date(20), availabilityExclusions: [rule(1080, 1140)])
        let input = [AvailableSlot(start: date(17, 30), end: date(20))]
        #expect(Scheduler().schedule(tasks: [task], availableSlots: input, calendar: calendar).blocks.count == 2)
        task.availabilityExclusions = []
        #expect(Scheduler().schedule(tasks: [task], availableSlots: input, calendar: calendar).blocks == [ScheduledBlock(taskID: task.id, start: date(17, 30), end: date(19))])
    }
    @Test func capsApplyAfterBothExclusionKinds() throws {
        let task = PersonalGantt.Task(title: "A", estimatedMinutes: 180, deadline: date(0, day: 15), availabilityExclusions: [rule(600, 660)])
        let result = Scheduler().schedule(tasks: [task], availableSlots: try slots([rule(720, 780)], days: 2), workloadSettings: WorkloadSettings(maxScheduledMinutesPerDay: 90), calendar: calendar)
        #expect(result.unscheduledTaskIDs.isEmpty && DailyWorkload.secondsByDay(blocks: result.blocks, calendar: calendar).values.allSatisfy { $0 == 90 * 60 })
        #expect(result.blocks.allSatisfy { calendar.component(.hour, from: $0.start) >= 11 })
    }
    @Test func balancedModeHonorsPerTaskDailyCapacities() throws {
        let task = PersonalGantt.Task(title: "A", estimatedMinutes: 600, deadline: date(0, day: 17), availabilityExclusions: [rule(600, 1380, days: [4])])
        let result = Scheduler().schedule(tasks: [task], availableSlots: try slots([], days: 4), calendar: calendar, distributionMode: .balanced)
        let totals = DailyWorkload.secondsByDay(blocks: result.blocks, calendar: calendar)
        #expect(result.unscheduledTaskIDs.isEmpty && totals[date(0, day: 14)] == 60 * 60)
    }
    @Test(arguments: [0, 1, 2, 3, 4, 5]) func invalidRulesCannotEnterTaskOrActivitySettings(kind: Int) throws {
        var value = rule(720, 780)
        switch kind {
        case 0: value.endMinuteOfDay = 720
        case 1: value.startMinuteOfDay = 800
        case 2: value.startMinuteOfDay = -1
        case 3: value.endMinuteOfDay = 1441
        case 4: value.weekdays = []
        default: value.weekdays = [8]
        }
        #expect(!value.isValid)
        var hours = ActivitySettings.default; hours.globalAvailabilityExclusions = [value]; #expect(!hours.isValid)
        #expect(throws: TaskInputError.invalidAvailabilityExclusions) { try TaskDraft(title: "A", deadline: date(23), availabilityExclusions: [value]).validated() }
    }
    @Test func duplicateRuleIDsFailAndMidnightEndsExactly() throws {
        let value = rule(1380, 1440)
        #expect(!AvailabilityExclusion.valid([value, value]))
        #expect(try slots([value]).last?.end == date(23))
    }
    @Test func fixedWeeklyAndSelectedDaysUseStableOccurrenceIdentity() {
        var source = routine()
        let tasks = occurrences(source)
        #expect(tasks.count == 2 && tasks.allSatisfy { $0.fixedRoutineBlock?.start == date(19, day: calendar.component(.day, from: $0.deadline.addingTimeInterval(-1))) })
        let selected = occurrences(routine(recurrence: .selectedWeekdays([2, 4, 6])))
        #expect(selected.count == 3 && selected.allSatisfy(\.isFixedRoutine))
        source.fixedStartMinuteOfDay = nil
        let flexible = occurrences(source)
        #expect(flexible.map(\.id) == tasks.map(\.id) && flexible.allSatisfy { !$0.isFixedRoutine })
    }
    @Test func fixedOffUsesLegacyAllocation() throws {
        let task = try #require(occurrences(routine(start: nil), days: 1).first)
        #expect(Scheduler().schedule(tasks: [task], availableSlots: try slots([]), calendar: calendar).blocks.first?.start == date(10))
    }
    @Test func fixedRoutineReservesTimeBeforeEarlierDeadlineNormalTask() throws {
        let fixed = try #require(occurrences(routine(), days: 1).first)
        let normal = PersonalGantt.Task(title: "Normal", estimatedMinutes: 120, deadline: date(21))
        let result = Scheduler().schedule(tasks: [normal, fixed], availableSlots: [AvailableSlot(start: date(18), end: date(22))], calendar: calendar)
        let expected = try #require(fixed.fixedRoutineBlock)
        #expect(result.blocks.contains(expected))
        #expect(result.blocks.filter { $0.taskID == normal.id }.map { DateInterval(start: $0.start, end: $0.end) } == [DateInterval(start: date(18), end: date(19)), DateInterval(start: date(20), end: date(21))])
    }
    @Test(arguments: [0, 1, 2]) func fixedConflictKeepsExactTime(kind: Int) throws {
        let task = try #require(occurrences(routine(), days: 1).first)
        var hours = ActivitySettings.default
        let events = kind == 0 ? [FixedEvent(id: "event", calendarID: "work", title: "Synthetic", start: date(19, 30), end: date(20, 30))] : []
        if kind == 1 { hours.globalAvailabilityExclusions = [rule(1140, 1200)] }
        if kind == 2 { hours.weekday.endMinute = 18 * 60 }
        let available = try AvailabilityService().availableSlots(fixedEvents: events, in: DateInterval(start: date(0), end: date(0, day: 14)), settings: hours, referenceDate: date(0), calendar: calendar)
        let result = Scheduler().schedule(tasks: [task], availableSlots: available, calendar: calendar, activitySettings: hours, fixedEvents: events, globalExclusionsApplied: true)
        let expected = try #require(task.fixedRoutineBlock)
        #expect(result.blocks == [expected])
        #expect(result.fixedRoutineConflicts.contains { $0.taskID == task.id && $0.reason == (kind == 0 ? .calendarEvent : kind == 1 ? .globalExclusion : .outsideActivityHours) })
    }
    @Test func twoFixedRoutinesBothReportCollisionAndRemainFixed() throws {
        let a = try #require(occurrences(routine(), days: 1).first)
        let b = try #require(occurrences(routine(start: 1170), days: 1).first)
        let result = Scheduler().schedule(tasks: [a, b], availableSlots: try slots([]), calendar: calendar)
        #expect(result.blocks.count == 2 && Set(result.fixedRoutineConflicts.filter { $0.reason == .anotherFixedRoutine }.map(\.taskID)) == Set([a.id, b.id]))
    }
    @Test func fixedCapIsChargedFirstAndExcessNeverDropsFixedBlock() throws {
        let fixed = try #require(occurrences(routine(minutes: 120), days: 1).first)
        let normal = PersonalGantt.Task(title: "Normal", estimatedMinutes: 60, deadline: date(23))
        for cap in [90, 150] {
            let result = Scheduler().schedule(tasks: [normal, fixed], availableSlots: try slots([]), workloadSettings: WorkloadSettings(maxScheduledMinutesPerDay: cap), calendar: calendar)
            let expected = try #require(fixed.fixedRoutineBlock)
        #expect(result.blocks.contains(expected))
            #expect(result.blocks.filter { $0.taskID == normal.id }.reduce(0) { $0 + $1.durationMinutes } == Double(max(0, cap - 120)))
            #expect(result.fixedRoutineConflicts.contains { $0.reason == .dailyCap } == (cap == 90))
        }
    }
    @Test func fixedMidnightBoundaryChargesBothCalendarDays() throws {
        let fixed = try #require(occurrences(routine(start: 1410, minutes: 90), days: 1).first)
        let result = Scheduler().schedule(tasks: [fixed], availableSlots: try slots([], days: 2), calendar: calendar)
        #expect(result.blocks.first?.start == date(23, 30) && result.blocks.first?.end == date(1, day: 14))
        #expect(DailyWorkload.secondsByDay(blocks: result.blocks, calendar: calendar) == [date(0): 30 * 60, date(0, day: 14): 60 * 60])
    }
    @Test func finalOvernightOccurrenceExtendsHorizonToActualEnd() throws {
        var value = routine(start: 1410, minutes: 90, recurrence: .daily, last: 26)
        // End date's time component must not move its occurrence into the next day.
        value.endDate = date(23, 59, day: 26)
        let horizon = try PlanningHorizonResolver().resolve(now: date(0), tasks: [], routines: [value], calendar: calendar)
        #expect(horizon.end == date(1, day: 27) && !horizon.wasCapped)
        let last = try #require(RoutinePlanner().tasks(for: [value], in: horizon.interval, calendar: calendar).last)
        let result = Scheduler().schedule(tasks: [last], availableSlots: [AvailableSlot(start: date(23, day: 26), end: horizon.end)], calendar: calendar, planningRange: horizon.interval)
        #expect(result.blocks == [try #require(last.fixedRoutineBlock)] && result.unscheduledTaskIDs.isEmpty)
    }
    @Test func nonrecurringEndDateDoesNotExtendFixedHorizon() throws {
        // Oct 26 is Monday; this routine occurs only on Tuesday.
        let value = routine(start: 1410, minutes: 90, last: 26)
        let horizon = try PlanningHorizonResolver().resolve(now: date(0), tasks: [], routines: [value], calendar: calendar)
        #expect(horizon.end == date(0, day: 27) && !horizon.wasCapped)
    }
    @Test(arguments: [14, 90]) func cappedOvernightFixedRoutineIsNotPlacedOutsideHorizon(days: Int) throws {
        var value = routine(start: 1410, minutes: 90, recurrence: .daily)
        value.endDate = try #require(calendar.date(byAdding: .day, value: days - 1, to: date(0)))
        let horizon = try PlanningHorizonResolver().resolve(now: date(0), tasks: [], routines: [value], settings: PlanningHorizonSettings(minimumDays: 14, maximumDays: days), calendar: calendar)
        #expect(horizon.wasCapped && horizon.end == calendar.date(byAdding: .day, value: days, to: date(0)))
        let last = try #require(RoutinePlanner().tasks(for: [value], in: horizon.interval, calendar: calendar).last)
        // No selected Calendar: the planning cap must independently prevent placement.
        let result = ScheduleOptimizationEngine().schedule(OptimizationRequest(tasks: [last], slots: [AvailableSlot(start: horizon.end.addingTimeInterval(-3600), end: horizon.end)], settings: SchedulingSettings(optimizeLocally: true), calendar: calendar, planningRange: horizon.interval))
        #expect(result.blocks.isEmpty && result.unscheduledTaskIDs == [last.id])
        #expect(result.fixedRoutineConflicts == [.init(taskID: last.id, reason: .outsidePlanningHorizon)])
    }
    @Test func extendedOvernightHorizonStillRequiresFullCalendarCoverage() throws {
        let value = routine(start: 1410, minutes: 90, recurrence: .daily, last: 26)
        let horizon = try PlanningHorizonResolver().resolve(now: date(0), tasks: [], routines: [value], calendar: calendar)
        let last = try #require(RoutinePlanner().tasks(for: [value], in: horizon.interval, calendar: calendar).last)
        let input = [AvailableSlot(start: date(23, day: 26), end: horizon.end)]
        let partial = Scheduler().schedule(tasks: [last], availableSlots: input, calendar: calendar, calendarCoverage: CalendarCoverage(start: horizon.start, end: date(0, day: 27)), requiresCalendarCoverage: true, planningRange: horizon.interval)
        #expect(partial.blocks.isEmpty && partial.fixedRoutineConflicts.first?.reason == .unavailableCalendarRange)
        let fetched = Scheduler().schedule(tasks: [last], availableSlots: input, calendar: calendar, calendarCoverage: CalendarCoverage(start: horizon.start, end: horizon.end), requiresCalendarCoverage: true, planningRange: horizon.interval)
        #expect(fetched.blocks == [try #require(last.fixedRoutineBlock)])
    }
    @Test func planningCapDoesNotDiscardBegunFixedWork() throws {
        let value = routine(start: 1410, minutes: 90, recurrence: .daily, last: 26)
        let range = DateInterval(start: date(0), end: date(0, day: 27))
        let last = try #require(RoutinePlanner().tasks(for: [value], in: range, calendar: calendar).last)
        let block = try #require(last.fixedRoutineBlock)
        let result = ScheduleReplanner().schedule(tasks: [last], availableSlots: [], previousBlocks: [block], now: date(23, 45, day: 26), calendar: calendar, planningRange: range)
        #expect(result.blocks == [block] && !result.fixedRoutineConflicts.contains { $0.reason == .outsidePlanningHorizon })
    }
    @Test func fixedCompletionSkipAndProtectedWorkDoNotDuplicateReservations() throws {
        var value = routine()
        let task = try #require(occurrences(value, days: 1).first), block = try #require(task.fixedRoutineBlock)
        let replanned = ScheduleReplanner().schedule(tasks: [task], availableSlots: try slots([]), previousBlocks: [block], now: date(19, 30), calendar: calendar)
        #expect(replanned.blocks == [block])
        let missed = Scheduler().schedule(tasks: [task], availableSlots: try slots([]), calendar: calendar, referenceDate: date(21))
        #expect(missed.blocks.isEmpty && missed.fixedRoutineConflicts.contains { $0.reason == .missedStart })
        let completed = Scheduler().schedule(tasks: [task], availableSlots: try slots([]), calendar: calendar, completedMinutesByTask: [task.id: 60])
        #expect(completed.blocks.isEmpty)
        value.skippedOccurrenceIDs.insert(task.id); #expect(occurrences(value, days: 1).isEmpty)
    }
    @Test func fixedTimeCannotPlaceBeyondUnfetchedCalendarCoverage() throws {
        let task = try #require(occurrences(routine(), days: 1).first)
        let result = Scheduler().schedule(tasks: [task], availableSlots: try slots([]), calendar: calendar, calendarCoverage: CalendarCoverage(start: date(0), end: date(18)), requiresCalendarCoverage: true)
        #expect(result.blocks.isEmpty && result.unscheduledTaskIDs == [task.id] && result.fixedRoutineConflicts.first?.reason == .unavailableCalendarRange)
    }
    @Test func optimizerPreservesFixedTimeAndRestAfterIt() throws {
        let fixed = try #require(occurrences(routine(), days: 1).first)
        let task = PersonalGantt.Task(title: "Normal", estimatedMinutes: 60, deadline: date(22), notBefore: date(20))
        let settings = SchedulingSettings(distributionMode: .balanced, optimizeLocally: true, maxContinuousMinutes: 60, minimumBreakMinutes: 15)
        let result = ScheduleOptimizationEngine().schedule(OptimizationRequest(tasks: [task, fixed], slots: try slots([]), settings: settings, calendar: calendar))
        let expected = try #require(fixed.fixedRoutineBlock)
        #expect(result.blocks.contains(expected))
        #expect(result.blocks.filter { $0.taskID == task.id }.first?.start == date(20, 15))
    }
    @Test func springGapDoesNotSilentlyMoveFixedRoutine() throws {
        var local = calendar; local.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let day = try #require(local.date(from: DateComponents(year: 2026, month: 3, day: 8))), next = try #require(local.date(byAdding: .day, value: 1, to: day))
        let value = Routine(title: "DST", estimatedMinutesPerDay: 60, startDate: day, endDate: day, recurrence: .daily, fixedStartMinuteOfDay: 150)
        let tasks = RoutinePlanner().tasks(for: [value], in: DateInterval(start: day, end: next), calendar: local)
        let result = Scheduler().schedule(tasks: tasks, availableSlots: [AvailableSlot(start: day, end: next)], calendar: local)
        #expect(tasks.first?.isFixedRoutine == true && result.blocks.isEmpty && result.fixedRoutineConflicts.first?.reason == .nonexistentLocalTime)
    }
    @Test func fallBackExcludesBothPassesOfCivilTimeAndFixedStartsOnce() throws {
        var local = calendar; local.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let day = try #require(local.date(from: DateComponents(year: 2026, month: 11, day: 1))), next = try #require(local.date(byAdding: .day, value: 1, to: day))
        let excluded = AvailabilityExclusionSlots.intervals([rule(60, 90)], in: DateInterval(start: day, end: next), calendar: local)
        #expect(excluded.count == 2 && excluded.reduce(0) { $0 + $1.duration } == 60 * 60)
        let value = Routine(title: "DST", estimatedMinutesPerDay: 60, startDate: day, endDate: day, recurrence: .daily, fixedStartMinuteOfDay: 90)
        let tasks = RoutinePlanner().tasks(for: [value], in: DateInterval(start: day, end: next), calendar: local)
        #expect(tasks.count == 1 && tasks.first?.fixedRoutineBlock?.start == day.addingTimeInterval(90 * 60))
    }
    @Test func oldModelsDecodeDefaultsAndNewModelsRoundTrip() throws {
        let task = PersonalGantt.Task(title: "A", estimatedMinutes: 30, deadline: date(23), availabilityExclusions: [rule(720, 780)])
        let fixed = routine()
        var hours = ActivitySettings.default; hours.globalAvailabilityExclusions = [rule(1080, 1140)]
        #expect(try JSONDecoder().decode(PersonalGantt.Task.self, from: JSONEncoder().encode(task)) == task)
        #expect(try JSONDecoder().decode(Routine.self, from: JSONEncoder().encode(fixed)) == fixed)
        #expect(try JSONDecoder().decode(ActivitySettings.self, from: JSONEncoder().encode(hours)) == hours)
        func legacy<T: Encodable>(_ value: T, removing key: String) throws -> Data {
            var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any]); object.removeValue(forKey: key)
            return try JSONSerialization.data(withJSONObject: object)
        }
        #expect(try JSONDecoder().decode(PersonalGantt.Task.self, from: legacy(task, removing: "availabilityExclusions")).availabilityExclusions.isEmpty)
        #expect(try JSONDecoder().decode(Routine.self, from: legacy(fixed, removing: "fixedStartMinuteOfDay")).fixedStartMinuteOfDay == nil)
        #expect(try JSONDecoder().decode(ActivitySettings.self, from: legacy(hours, removing: "globalAvailabilityExclusions")).globalAvailabilityExclusions.isEmpty)
        var metadata = ReminderFixtures.metadata(); metadata.availabilityExclusions = task.availabilityExclusions
        let portable = try #require(ReminderSyncMetadata(metadata: metadata))
        #expect(try JSONDecoder().decode(ReminderTaskMetadata.self, from: legacy(metadata, removing: "availabilityExclusions")).availabilityExclusions.isEmpty)
        #expect(try JSONDecoder().decode(ReminderSyncMetadata.self, from: legacy(portable, removing: "availabilityExclusions")).availabilityExclusions.isEmpty)
    }
    @Test(arguments: [0, 1, 2]) func nestedSecretFieldsInsideConstraintArraysAreRejected(kind: Int) throws {
        let values = [rule(720, 780)]
        var metadata = ReminderFixtures.metadata(); metadata.availabilityExclusions = values
        let portable = try #require(ReminderSyncMetadata(metadata: metadata))
        var record = try localRecord()
        if kind == 0 { record.payload = try SyncState.payloadData(PersonalGantt.Task(id: UUID(uuidString: record.id)!, title: "A", estimatedMinutes: 30, deadline: date(23), availabilityExclusions: values)) }
        if kind == 1 { record.kind = .reminderMetadata; record.id = portable.id; record.payload = try SyncState.payloadData(portable) }
        if kind == 2 {
            var hours = ActivitySettings.default; hours.globalAvailabilityExclusions = values
            record.kind = .schedulingSettings; record.id = "settings"; record.payload = try SyncState.payloadData(SchedulingSettings(activitySettings: hours))
        }
        let payload = try #require(record.payload)
        var object = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        if kind < 2 {
            var rules = try #require(object["availabilityExclusions"] as? [[String: Any]]); rules[0]["accessToken"] = "synthetic"; object["availabilityExclusions"] = rules
        } else {
            var activity = try #require(object["activitySettings"] as? [String: Any]); var rules = try #require(activity["globalAvailabilityExclusions"] as? [[String: Any]])
            rules[0]["title"] = "native-title"; activity["globalAvailabilityExclusions"] = rules; object["activitySettings"] = activity
        }
        record.payload = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: SyncError.invalidData) { try SyncPayloadValidator.validate(record) }
    }
}
