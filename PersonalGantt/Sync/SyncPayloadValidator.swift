import Foundation

nonisolated enum SyncPayloadValidator {
    static func validate(_ record: SyncRecord) throws {
        let entity = record.kind == .task || record.kind == .routine || record.kind == .workSession
        let validID = record.kind == .reminderMetadata ? ReminderSyncMetadata.isValidID(record.id)
            : (entity ? UUID(uuidString: record.id) != nil : record.id == "settings")
        guard validID else { throw SyncError.invalidData }
        guard let data = record.payload else { return }
        let decoder = JSONDecoder()
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else { throw SyncError.invalidData }
        let allowed: Set<String>
        switch record.kind {
        case .task: allowed = ["id","title","isCompleted","estimatedMinutes","deadline","reminderIdentifier","routineOccurrence","priority","notBefore","availabilityExclusions"]
        case .routine: allowed = ["id","title","estimatedMinutesPerDay","startDate","endDate","recurrence","completedOccurrenceIDs","skippedOccurrenceIDs","fixedStartMinuteOfDay"]
        case .workload: allowed = ["maxScheduledMinutesPerDay"]
        case .workSession: allowed = ["id","taskID","taskTitle","start","end","actualMinutes","reminderExternalIdentifier","reminderOccurrenceKey"]
        case .schedulingSettings: allowed = ["distributionMode","optimizeLocally","maxContinuousMinutes","minimumBreakMinutes","weights","activitySettings"]
        case .reminderMetadata: allowed = ["externalIdentifier", "occurrenceKey", "estimatedMinutes", "supplementalDeadline", "isExcluded", "availabilityExclusions"]
        }
        guard Set(dictionary.keys).isSubset(of: allowed) else { throw SyncError.invalidData }
        switch record.kind {
        case .task:
            let task = try decoder.decode(Task.self, from: data)
            guard task.id.uuidString == record.id, task.reminderIdentifier == nil, task.routineOccurrence == nil,
                  task.notBefore.map({ $0.timeIntervalSinceReferenceDate.isFinite && $0 >= .distantPast && $0 <= .distantFuture }) ?? true
            else { throw SyncError.invalidData }
            _ = try TaskDraft(task: task).validated()
            try validateNestedFields(dictionary, decoded: task)
        case .routine:
            let routine = try decoder.decode(Routine.self, from: data)
            guard routine.id.uuidString == record.id else { throw SyncError.invalidData }; try routine.validate()
            try validateNestedFields(dictionary, decoded: routine)
        case .workload: try decoder.decode(WorkloadSettings.self, from: data).validate()
        case .workSession:
            let session = try decoder.decode(WorkSession.self, from: data)
            guard session.id.uuidString == record.id else { throw SyncError.invalidData }; try session.validate()
        case .schedulingSettings:
            let settings = try decoder.decode(SchedulingSettings.self, from: data)
            guard settings.isValid else { throw SyncError.invalidData }
            try validateNestedFields(dictionary, decoded: settings)
        case .reminderMetadata:
            let value = try decoder.decode(ReminderSyncMetadata.self, from: data)
            try value.validate()
            guard value.id == record.id else { throw SyncError.invalidData }
            try validateNestedFields(dictionary, decoded: value)
        }
    }
    /// Codable ignores unknown keys; reject extra nested fields before retaining
    /// the original sync payload, including fields inside weights/recurrence.
    private static func validateNestedFields<T: Encodable>(_ input: [String: Any], decoded: T) throws {
        let expected = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any] ?? [:]
        func check(_ actual: Any, _ expected: Any) throws {
            if let values = actual as? [Any], let references = expected as? [Any] {
                guard values.count == references.count else { throw SyncError.invalidData }
                for index in values.indices { try check(values[index], references[index]) }
                return
            }
            guard let fields = actual as? [String: Any] else { return }
            guard let known = expected as? [String: Any], Set(fields.keys).isSubset(of: Set(known.keys)) else { throw SyncError.invalidData }
            for (key, value) in fields { if let reference = known[key] { try check(value, reference) } }
        }
        for (key, value) in input {
            if let reference = expected[key] { try check(value, reference) }
        }
    }
}
