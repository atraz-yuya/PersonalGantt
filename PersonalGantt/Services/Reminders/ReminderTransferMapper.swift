import Foundation

nonisolated enum ReminderTransferMapper {
    struct Result: Sendable {
        var state: ReminderLocalState
        var taskIDs: [UUID: UUID]
        var reminderIDs: [String: String]
    }

    /// Only a unique external identifier in both the file and the selected native records qualifies.
    static func resolve(_ state: ReminderLocalState, records: [ReminderRecord]) throws -> Result {
        try state.validate()
        var next = state
        var taskIDs: [UUID: UUID] = [:]
        var reminderIDs: [String: String] = [:]
        for (sourceID, source) in state.pendingTransfer ?? [:] {
            guard let external = source.externalIdentifier, !external.isEmpty,
                  state.pendingTransfer?.values.filter({ $0.externalIdentifier == external }).count == 1 else { continue }
            let matches = records.filter { $0.externalIdentifier == external }
            guard matches.count == 1, let record = matches.first, var local = next.metadata[record.id] else { continue }
            // Keep the destination work UUID so its begun work is still credited to this requirement.
            if !record.isRecurring || source.occurrenceKey == record.occurrenceKey {
                taskIDs[source.taskID] = local.taskID
                reminderIDs[sourceID] = record.id
            }
            local.estimatedMinutes = source.estimatedMinutes
            local.deadlineOverride = record.deadline == nil ? source.deadlineOverride : nil
            local.isExcluded = source.isExcluded
            local.availabilityExclusions = source.availabilityExclusions
            next.metadata[record.id] = local
            next.pendingTransfer?.removeValue(forKey: sourceID)
        }
        if next.pendingTransfer?.isEmpty == true { next.pendingTransfer = nil }
        for (source, target) in taskIDs where source != target {
            if next.transferAliases == nil { next.transferAliases = [:] }
            next.transferAliases?[source] = target
        }
        try next.validate()
        return Result(state: next, taskIDs: taskIDs, reminderIDs: reminderIDs)
    }

    static func importState(_ source: ReminderLocalState, into local: ReminderLocalState, sameDevice: Bool,
                            records: [ReminderRecord]) throws -> Result {
        try source.validate(); try local.validate()
        if sameDevice { return Result(state: source, taskIDs: [:], reminderIDs: [:]) }
        var next = local
        // Explicit file import takes precedence over any older transfer waiting on this device.
        var candidates: [String: ReminderTaskMetadata] = [:]
        var seen: Set<UUID> = []
        for (id, value) in source.metadata.sorted(by: { $0.key < $1.key }) {
            if value.estimatedMinutes != nil || value.deadlineOverride != nil || value.isExcluded || !value.availabilityExclusions.isEmpty {
                candidates[id] = value; seen.insert(value.taskID)
            }
        }
        for (id, value) in source.pendingTransfer ?? [:] where !seen.contains(value.taskID) {
            candidates["pending." + id] = value; seen.insert(value.taskID)
        }
        next.pendingTransfer = candidates.isEmpty ? nil : candidates
        return try resolve(next, records: records)
    }
}
