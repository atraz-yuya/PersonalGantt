import Foundation

nonisolated enum ReminderTaskMapper {
    /// Identity migration requires a unique external ID in the same list. Never match titles.
    static func reconcile(_ records: [ReminderRecord], state: ReminderLocalState, makeID: () -> UUID = { UUID() }) throws -> ReminderLocalState {
        guard Set(records.map(\.id)).count == records.count,
              records.allSatisfy({ !$0.id.isEmpty && !$0.listID.isEmpty &&
                  ($0.deadline.map { $0.timeIntervalSinceReferenceDate.isFinite } ?? true) })
        else { throw ReminderServiceError.invalidSnapshot }
        var updated = state
        let currentIDs = Set(records.map(\.id))
        for record in records {
            if var value = updated.metadata[record.id] {
                // A reused local ID in another list requires a new association.
                let externalIDChanged = value.externalIdentifier != nil && record.externalIdentifier != nil &&
                    value.externalIdentifier != record.externalIdentifier
                if value.listID == record.listID && !externalIDChanged {
                    value.externalIdentifier = record.externalIdentifier
                    if record.isRecurring && value.occurrenceKey != record.occurrenceKey {
                        value.taskID = makeID()
                    }
                    value.occurrenceKey = record.occurrenceKey
                    updated.metadata[record.id] = value
                    continue
                }
                updated.metadata.removeValue(forKey: record.id)
            }
            let candidates = updated.metadata.filter { id, value in
                !currentIDs.contains(id) && !(record.externalIdentifier?.isEmpty ?? true) &&
                value.externalIdentifier == record.externalIdentifier && value.listID == record.listID
            }
            let occurrences = records.filter { $0.externalIdentifier == record.externalIdentifier && $0.listID == record.listID }
            if candidates.count == 1, occurrences.count == 1, let old = candidates.first {
                var value = old.value
                if record.isRecurring && value.occurrenceKey != record.occurrenceKey { value.taskID = makeID() }
                value.occurrenceKey = record.occurrenceKey
                updated.metadata[record.id] = value
                updated.metadata.removeValue(forKey: old.key)
            } else {
                updated.metadata[record.id] = ReminderTaskMetadata(taskID: makeID(), externalIdentifier: record.externalIdentifier,
                                                                listID: record.listID, estimatedMinutes: nil, deadlineOverride: nil,
                                                                occurrenceKey: record.occurrenceKey)
            }
        }
        try updated.validate()
        return updated
    }

    static func task(for record: ReminderRecord, metadata: ReminderTaskMetadata) -> Task? {
        let title = record.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !metadata.isExcluded, !title.isEmpty, let minutes = metadata.estimatedMinutes, minutes > 0,
              !record.isRecurring || record.occurrenceKey != nil,
              let deadline = record.deadline ?? metadata.deadlineOverride,
              deadline.timeIntervalSinceReferenceDate.isFinite, deadline >= .distantPast, deadline <= .distantFuture else { return nil }
        return Task(id: metadata.taskID, title: title, isCompleted: record.isCompleted,
                    estimatedMinutes: minutes, deadline: deadline, reminderIdentifier: record.id)
    }

    static func tasks(records: [ReminderRecord], state: ReminderLocalState) -> [Task] {
        records.compactMap { record in
            state.metadata[record.id].flatMap { task(for: record, metadata: $0) }
        }.sorted { $0.deadline == $1.deadline ? $0.id.uuidString < $1.id.uuidString : $0.deadline < $1.deadline }
    }
}
