import Foundation

/// Deterministic, earliest-deadline-first allocation. No UI, clock, or persistence.
nonisolated struct Scheduler: Sendable {
    func schedule(
        tasks: [Task], availableSlots: [AvailableSlot],
        alreadyAllocatedSeconds: [UUID: TimeInterval] = [:],
        workloadSettings: WorkloadSettings = .unlimited,
        calendar: Calendar = .current,
        alreadyScheduledSecondsByDay: [Date: TimeInterval] = [:],
        completedMinutesByTask: [UUID: Double] = [:],
        distributionMode: DistributionMode = .earliestFirst
    ) -> SchedulingResult {
        let orderedTasks = tasks.filter { !$0.isCompleted }.sorted {
            if $0.deadline != $1.deadline { return $0.deadline < $1.deadline }
            return $0.id.uuidString < $1.id.uuidString
        }
        var slots = normalizedSlots(availableSlots)
        let needsDays = distributionMode == .balanced || workloadSettings.maxScheduledMinutesPerDay != nil || tasks.contains { $0.routineOccurrence != nil }
        if needsDays {
            slots = slots.flatMap { slot in
                DailyWorkload.dayParts(start: slot.start, end: slot.end, calendar: calendar)
                    .map { AvailableSlot(start: $0.start, end: $0.end) }
            }
        }
        var dailySeconds = alreadyScheduledSecondsByDay
        let dailyLimit = workloadSettings.maxScheduledMinutesPerDay.map { max(0, Double($0) * 60) }
        var result = SchedulingResult(blocks: [], unscheduledTaskIDs: [])

        for task in orderedTasks {
            // Zero duration needs no allocation; negative estimates are invalid.
            guard task.estimatedMinutes >= 0 else {
                result.unscheduledTaskIDs.append(task.id)
                continue
            }
            // Reserved planned work isn't a completion record. The default remains zero.
            let allocated = alreadyAllocatedSeconds[task.id] ?? 0
            var remainingSeconds = max(0, max(0, Double(task.estimatedMinutes) - (completedMinutesByTask[task.id] ?? 0)) * 60 - (allocated.isFinite ? max(0, allocated) : 0))

            var budgets: [Date: Double]? = nil
            if distributionMode == .balanced && task.routineOccurrence == nil && remainingSeconds >= 180 * 60 {
                budgets = balancedBudgets(task: task, remaining: remainingSeconds, slots: slots,
                    used: dailySeconds, dailyLimit: dailyLimit, calendar: calendar)
            }
            for index in slots.indices {
                guard remainingSeconds > 0 else { break }
                let start = slots[index].start
                if let occurrence = task.routineOccurrence,
                   (start < occurrence.dayStart || start >= occurrence.dayEnd) { continue }
                let latestEnd = min(slots[index].end, task.deadline)
                guard start < latestEnd else { continue }

                let day = calendar.startOfDay(for: start)
                let used = dailySeconds[day] ?? 0
                let capacity = dailyLimit.map { max(0, $0 - used) } ?? .infinity
                let duration = min(remainingSeconds, latestEnd.timeIntervalSince(start), capacity, budgets?[day] ?? .infinity)
                guard duration > 0 else { continue }
                let end = start.addingTimeInterval(duration)
                result.blocks.append(ScheduledBlock(taskID: task.id, start: start, end: end))
                slots[index].start = end
                remainingSeconds = max(0, remainingSeconds - duration)
                if let previousBudget = budgets?[day] { budgets?[day] = max(0, previousBudget - duration) }
                dailySeconds[day, default: 0] += duration
            }

            if remainingSeconds > 0.000001 {
                result.unscheduledTaskIDs.append(task.id)
            }
        }

        result.blocks.sort {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.taskID.uuidString < $1.taskID.uuidString
        }
        return result
    }

    /// Water-fill actual daily capacities: small days saturate first, and the
    /// remaining work spreads across the other usable days. Whole seconds avoid
    /// tiny floating-point blocks; residual seconds use chronological tie breaks.
    private func balancedBudgets(task: Task, remaining: Double, slots: [AvailableSlot],
                                 used: [Date: Double], dailyLimit: Double?, calendar: Calendar) -> [Date: Double]? {
        var capacities: [Date: Double] = [:]
        for slot in slots where slot.start < task.deadline {
            let seconds = max(0, min(slot.end, task.deadline).timeIntervalSince(slot.start))
            capacities[calendar.startOfDay(for: slot.start), default: 0] += seconds
        }
        for day in capacities.keys {
            capacities[day] = min(capacities[day] ?? 0, dailyLimit.map { max(0, $0 - (used[day] ?? 0)) } ?? .infinity)
        }
        let days = capacities.keys.filter { (capacities[$0] ?? 0) > 0 }.sorted()
        guard days.count >= 3 else { return nil }
        var pending = days, budget = min(remaining, capacities.values.reduce(0, +)), result: [Date: Double] = [:]
        while !pending.isEmpty {
            let average = budget / Double(pending.count)
            let small = pending.filter { (capacities[$0] ?? 0) <= average }
            if small.isEmpty {
                let share = floor(average)
                for day in pending { result[day] = share }
                var residual = budget - share * Double(pending.count)
                for day in pending where residual > 0 {
                    let extra = min(1, residual, (capacities[day] ?? 0) - share)
                    result[day, default: 0] += extra; residual -= extra
                }
                break
            }
            for day in small { let amount = capacities[day] ?? 0; result[day] = amount; budget = max(0, budget - amount) }
            let removed = Set(small); pending.removeAll { removed.contains($0) }
        }
        return result
    }

    /// Treat overlapping/adjacent input slots as a union so capacity isn't counted twice.
    private func normalizedSlots(_ input: [AvailableSlot]) -> [AvailableSlot] {
        let ordered = input.filter { $0.start < $0.end }.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.end < $1.end
        }
        var result: [AvailableSlot] = []
        for slot in ordered {
            if let lastIndex = result.indices.last, slot.start <= result[lastIndex].end {
                result[lastIndex].end = max(result[lastIndex].end, slot.end)
            } else {
                result.append(slot)
            }
        }
        return result
    }
}
