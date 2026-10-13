import Foundation

nonisolated struct OptimizationWeights: Codable, Equatable, Sendable {
    var fragmentation: Double = 1
    var imbalance: Double = 10
    var earliness: Double = 0.001
    var isValid: Bool { [fragmentation, imbalance, earliness].allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1_000_000 } }
    static func defaults(for mode: DistributionMode) -> Self {
        mode == .balanced ? Self() : Self(fragmentation: 1, imbalance: 0.001, earliness: 10)
    }
}
nonisolated struct ScheduleScore: Equatable, Comparable, Sendable {
    var hardViolations: Int
    var weightedUnallocatedMinutes: Double
    var softPenalty: Double
    static func < (a: Self, b: Self) -> Bool {
        if a.hardViolations != b.hardViolations { return a.hardViolations < b.hardViolations }
        if a.weightedUnallocatedMinutes != b.weightedUnallocatedMinutes { return a.weightedUnallocatedMinutes < b.weightedUnallocatedMinutes }
        return a.softPenalty < b.softPenalty
    }
}
nonisolated struct OptimizationRequest: Sendable {
    var tasks: [Task]
    var slots: [AvailableSlot]
    var allocatedSeconds: [UUID: Double] = [:]
    var dailySeconds: [Date: Double] = [:]
    var completedMinutes: [UUID: Double] = [:]
    var workload: WorkloadSettings = .unlimited
    var settings: SchedulingSettings = .default
    var calendar: Calendar = .current
    var fixedEvents: [FixedEvent] = []
    var protectedBlocks: [ScheduledBlock] = []
    var referenceDate: Date? = nil
    var globalExclusionsApplied = false
    var calendarCoverage: CalendarCoverage? = nil
    var requiresCalendarCoverage = false
    var planningRange: DateInterval? = nil
}
nonisolated protocol LocalScheduleOptimizing: Sendable {
    func schedule(_ request: OptimizationRequest) -> SchedulingResult
}
/// Bounded local candidates; no network, AI service, stochastic search or clock.
nonisolated struct ScheduleOptimizationEngine: LocalScheduleOptimizing {
    func schedule(_ request: OptimizationRequest) -> SchedulingResult {
        let baseline = candidate(request, mode: request.settings.distributionMode)
        guard request.settings.optimizeLocally == true else { return baseline }
        let other: DistributionMode = request.settings.distributionMode == .balanced ? .earliestFirst : .balanced
        let alternate = candidate(request, mode: other)
        return score(alternate, request: request) < score(baseline, request: request) ? alternate : baseline
    }
    private func candidate(_ request: OptimizationRequest, mode: DistributionMode) -> SchedulingResult {
        Scheduler().schedule(tasks: request.tasks, availableSlots: request.slots, alreadyAllocatedSeconds: request.allocatedSeconds,
            workloadSettings: request.workload, calendar: request.calendar, alreadyScheduledSecondsByDay: request.dailySeconds,
            completedMinutesByTask: request.completedMinutes, distributionMode: mode,
            activitySettings: request.settings.activitySettings, fixedEvents: request.fixedEvents, protectedBlocks: request.protectedBlocks,
            referenceDate: request.referenceDate, globalExclusionsApplied: request.globalExclusionsApplied, restSettings: request.settings,
            calendarCoverage: request.calendarCoverage, requiresCalendarCoverage: request.requiresCalendarCoverage, planningRange: request.planningRange)
    }
    func restedSlots(_ input: [AvailableSlot], settings: SchedulingSettings) -> [AvailableSlot] {
        guard let maximum = settings.maxContinuousMinutes, let rest = settings.minimumBreakMinutes, settings.isValid else { return input }
        return Scheduler().normalizedSlots(input).flatMap { slot -> [AvailableSlot] in
            var result: [AvailableSlot] = [], cursor = slot.start
            while cursor < slot.end {
                let end = min(slot.end, cursor.addingTimeInterval(Double(maximum) * 60))
                result.append(AvailableSlot(start: cursor, end: end))
                cursor = end.addingTimeInterval(Double(rest) * 60)
            }
            return result
        }
    }
    func score(_ result: SchedulingResult, request: OptimizationRequest) -> ScheduleScore {
        let tasks = Dictionary(uniqueKeysWithValues: request.tasks.map { ($0.id, $0) })
        let normalized = Scheduler().normalizedSlots(request.slots)
        let slots = request.globalExclusionsApplied ? normalized : AvailabilityExclusionSlots.subtract(request.settings.activitySettings?.globalAvailabilityExclusions ?? [], from: normalized, calendar: request.calendar)
        let ordered = result.blocks.sorted { $0.start < $1.start }
        var slotIndex = 0
        var latestEnd: Date?
        var violations = 0, allocated: [UUID: Double] = [:], perTaskDay: [UUID: [Date: Double]] = [:]
        for block in ordered {
            if let latestEnd, latestEnd > block.start { violations += 1 }
            latestEnd = max(latestEnd ?? block.end, block.end)
            guard let task = tasks[block.taskID] else { violations += 1; continue }
            let fixed = task.isFixedRoutine && task.fixedRoutineBlock == block
            if block.end > task.deadline || block.start >= block.end { violations += 1 }
            if let notBefore = task.notBefore, block.start < notBefore { violations += 1 }
            while slotIndex < slots.count && slots[slotIndex].end <= block.start { slotIndex += 1 }
            if !fixed && (slotIndex == slots.count || slots[slotIndex].start > block.start || slots[slotIndex].end < block.end) { violations += 1 }
            if !fixed && AvailabilityExclusionSlots.intervals(task.availabilityExclusions, in: DateInterval(start: block.start, end: block.end), calendar: request.calendar).contains(where: { $0.start < block.end && block.start < $0.end }) { violations += 1 }
            if !fixed, let day = task.routineOccurrence, block.start < day.dayStart || block.end > day.dayEnd { violations += 1 }
            allocated[task.id, default: 0] += block.durationMinutes
            for part in DailyWorkload.dayParts(start: block.start, end: block.end, calendar: request.calendar) {
                perTaskDay[task.id, default: [:]][request.calendar.startOfDay(for: part.start), default: 0] += part.duration / 60
            }
        }
        if let limit = request.workload.maxScheduledMinutesPerDay {
            for (day, seconds) in DailyWorkload.secondsByDay(blocks: result.blocks, calendar: request.calendar) {
                if seconds > max(0, Double(limit) * 60 - (request.dailySeconds[day] ?? 0)) + 0.000001 { violations += 1 }
            }
        }
        var unallocated = 0.0, imbalance = 0.0
        for task in request.tasks where !task.isCompleted {
            let missing = max(0, Double(task.estimatedMinutes) - (request.completedMinutes[task.id] ?? 0) - (request.allocatedSeconds[task.id] ?? 0) / 60 - (allocated[task.id] ?? 0))
            unallocated += (missing < 0.000001 ? 0 : missing) * task.priority.weight
            guard task.routineOccurrence == nil, task.estimatedMinutes >= 180 else { continue }
            let taskSlots = AvailabilityExclusionSlots.subtract(task.availabilityExclusions, from: slots, calendar: request.calendar)
            let days = Set(taskSlots.filter { $0.start < task.deadline && $0.end > (task.notBefore ?? .distantPast) }
                .flatMap { DailyWorkload.dayParts(start: $0.start, end: min($0.end, task.deadline), calendar: request.calendar).map { request.calendar.startOfDay(for: $0.start) } })
            guard !days.isEmpty else { continue }
            let mean = (allocated[task.id] ?? 0) / Double(days.count)
            imbalance += days.reduce(0) { $0 + pow((perTaskDay[task.id]?[$1] ?? 0) - mean, 2) } / max(1, mean)
        }
        violations += result.fixedRoutineConflicts.count
        let weights = request.settings.weights ?? .defaults(for: request.settings.distributionMode)
        let origin = slots.first?.start ?? .distantPast
        let earliness = result.blocks.reduce(0) { $0 + max(0, $1.start.timeIntervalSince(origin)) / 86400 }
        return ScheduleScore(hardViolations: violations, weightedUnallocatedMinutes: unallocated,
            softPenalty: Double(result.blocks.count) * weights.fragmentation + imbalance * weights.imbalance + earliness * weights.earliness)
    }
}
