import Foundation

/// Preserves begun plans without equating them with completed work.
nonisolated struct ScheduleReplanner: Sendable {
    func schedule(tasks: [Task], availableSlots: [AvailableSlot], previousBlocks: [ScheduledBlock], now: Date,
                  workloadSettings: WorkloadSettings = .unlimited, calendar: Calendar = .current, workSessions: [WorkSession] = [], distributionMode: DistributionMode = .earliestFirst, optimizationSettings: SchedulingSettings? = nil, activitySettings: ActivitySettings? = nil, fixedEvents: [FixedEvent] = [], globalExclusionsApplied: Bool = false, calendarCoverage: CalendarCoverage? = nil, requiresCalendarCoverage: Bool = false, planningRange: DateInterval? = nil) -> SchedulingResult {
        let protected = previousBlocks.filter { $0.start <= now }
        var occupied = protected.filter { $0.start < $0.end }.map { DateInterval(start: $0.start, end: $0.end) }
        if let settings = optimizationSettings, settings.isValid,
           let maximum = settings.maxContinuousMinutes, let rest = settings.minimumBreakMinutes {
            let union = Scheduler().normalizedSlots(occupied.map { AvailableSlot(start: $0.start, end: $0.end) })
            occupied += union.filter { $0.end.timeIntervalSince($0.start) >= Double(maximum) * 60 }
                .map { DateInterval(start: $0.end, duration: Double(rest) * 60) }
            occupied += workSessions.filter { $0.actualMinutes >= maximum }
                .map { DateInterval(start: $0.end, duration: Double(rest) * 60) }
        }
        let futureSlots = availableSlots.compactMap { slot -> AvailableSlot? in
            let start = max(slot.start, now)
            return start < slot.end ? AvailableSlot(start: start, end: slot.end) : nil
        }
        let free = IntervalSubtraction.subtract(occupied, from: futureSlots)
        var allocated: [UUID: TimeInterval] = [:]
        for block in protected {
            allocated[block.taskID, default: 0] += max(0, block.end.timeIntervalSince(block.start))
        }
        let completed = WorkSession.minutesByTask(workSessions)
        // A recorded session explicitly replaces any implied reservation from
        // elapsed planned blocks. Only ongoing unrecorded work remains reserved.
        for id in completed.keys {
            allocated[id] = protected.filter { $0.taskID == id && $0.end > now }.reduce(0) { total, block in
                total + WorkSession.unrecordedMinutes(in: block, sessions: workSessions) * 60
            }
        }
        var settings = optimizationSettings ?? SchedulingSettings(distributionMode: distributionMode)
        if let activitySettings { settings.activitySettings = activitySettings }
        let request = OptimizationRequest(tasks: tasks, slots: free, allocatedSeconds: allocated,
            dailySeconds: DailyWorkload.secondsByDay(blocks: protected, calendar: calendar), completedMinutes: completed,
            workload: workloadSettings, settings: settings, calendar: calendar, fixedEvents: fixedEvents, protectedBlocks: protected, referenceDate: now, globalExclusionsApplied: globalExclusionsApplied, calendarCoverage: calendarCoverage, requiresCalendarCoverage: requiresCalendarCoverage, planningRange: planningRange)
        var result = ScheduleOptimizationEngine().schedule(request)
        result.blocks = (protected + result.blocks).sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.taskID.uuidString < $1.taskID.uuidString
        }
        return result
    }
}
