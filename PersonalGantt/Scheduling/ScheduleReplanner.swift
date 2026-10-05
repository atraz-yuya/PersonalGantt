import Foundation

/// Preserves begun plans without equating them with completed work.
nonisolated struct ScheduleReplanner: Sendable {
    func schedule(tasks: [Task], availableSlots: [AvailableSlot], previousBlocks: [ScheduledBlock], now: Date) -> SchedulingResult {
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
        var result = Scheduler().schedule(tasks: tasks, availableSlots: free, alreadyAllocatedSeconds: allocated)
        result.blocks = (protected + result.blocks).sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.taskID.uuidString < $1.taskID.uuidString
        }
        return result
    }
}
