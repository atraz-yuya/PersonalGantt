import Foundation

/// Preserves begun plans without equating them with completed work.
nonisolated struct ScheduleReplanner: Sendable {
    func schedule(tasks: [Task], availableSlots: [AvailableSlot], previousBlocks: [ScheduledBlock], now: Date,
                  workloadSettings: WorkloadSettings = .unlimited, calendar: Calendar = .current, workSessions: [WorkSession] = []) -> SchedulingResult {
        let protected = previousBlocks.filter { $0.start <= now }
        let occupied = protected.filter { $0.start < $0.end }.map { DateInterval(start: $0.start, end: $0.end) }
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
        var result = Scheduler().schedule(tasks: tasks, availableSlots: free, alreadyAllocatedSeconds: allocated,
            workloadSettings: workloadSettings, calendar: calendar,
            alreadyScheduledSecondsByDay: DailyWorkload.secondsByDay(blocks: protected, calendar: calendar),
            completedMinutesByTask: completed)
        result.blocks = (protected + result.blocks).sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.taskID.uuidString < $1.taskID.uuidString
        }
        return result
    }
}
