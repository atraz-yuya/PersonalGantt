import Foundation

nonisolated struct SchedulingResult: Equatable, Sendable {
    var blocks: [ScheduledBlock]
    /// Includes tasks with any unallocated time, even if partially scheduled.
    var unscheduledTaskIDs: [UUID]
}
