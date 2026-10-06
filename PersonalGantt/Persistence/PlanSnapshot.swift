import Foundation

/// A device-local checkpoint, not a source of truth for Google or Reminders.
/// Keep storage types out of the pure scheduling pipeline.
nonisolated struct PlanSnapshot: Codable, Equatable, Sendable {
    var version = 1
    var savedAt: Date
    var tasks: [Task]
    var reminderTaskIDs: Set<UUID>
    var blocks: [ScheduledBlock]
    var unscheduledTaskIDs: [UUID]
    var archivedTitles: [UUID: String]
    var slots: [AvailableSlot]
    var calendars: [CalendarSource]
    var selectedCalendarIDs: Set<String>
    var fixedEvents: [FixedEvent]
    var planningStart: Date?
    var planningEnd: Date?
    var lastCalendarRefresh: Date?
    var hasConfirmedPlan: Bool
    var calendarScope: String

    func validate() throws {
        func validDate(_ date: Date) -> Bool {
            date.timeIntervalSinceReferenceDate.isFinite && date >= .distantPast && date <= .distantFuture
        }
        let taskIDs = Set(tasks.map(\.id))
        let knownIDs = taskIDs.union(archivedTitles.keys)
        guard version == 1 else { throw PlanStorageError.unsupportedVersion }
        guard validDate(savedAt), taskIDs.count == tasks.count,
              reminderTaskIDs.isSubset(of: taskIDs),
              tasks.allSatisfy({ (try? TaskDraft(task: $0).validated()) != nil &&
                  (!reminderTaskIDs.contains($0.id) || !($0.reminderIdentifier ?? "").isEmpty) }),
              Set(tasks.filter { reminderTaskIDs.contains($0.id) }.compactMap(\.reminderIdentifier)).count == reminderTaskIDs.count,
              Set(blocks.map(\.id)).count == blocks.count,
              blocks.allSatisfy({ knownIDs.contains($0.taskID) && validDate($0.start) && validDate($0.end) && $0.start < $0.end }),
              Set(unscheduledTaskIDs).count == unscheduledTaskIDs.count,
              unscheduledTaskIDs.allSatisfy({ taskIDs.contains($0) }),
              slots.allSatisfy({ validDate($0.start) && validDate($0.end) && $0.start < $0.end }),
              Set(calendars.map(\.id)).count == calendars.count,
              calendars.allSatisfy({ !$0.id.isEmpty }),
              selectedCalendarIDs.allSatisfy({ !$0.isEmpty }),
              fixedEvents.allSatisfy({ !$0.id.isEmpty && selectedCalendarIDs.contains($0.calendarID) &&
                  validDate($0.start) && validDate($0.end) && $0.start < $0.end }),
              (lastCalendarRefresh.map(validDate) ?? true),
              (planningStart == nil) == (planningEnd == nil),
              (planningStart.map(validDate) ?? true), (planningEnd.map(validDate) ?? true),
              (planningStart == nil || planningStart! < planningEnd!)
        else { throw PlanStorageError.invalidSnapshot }
    }
}

nonisolated enum PlanStorageError: LocalizedError, Equatable {
    case unavailable, invalidSnapshot, unsupportedVersion
    var errorDescription: String? {
        switch self {
        case .unavailable: "端末内の保存先を読み書きできません。"
        case .invalidSnapshot: "保存済みの計画を確認できません。保存データは上書きしません。"
        case .unsupportedVersion: "このバージョンでは保存済みの計画を読み込めません。保存データは上書きしません。"
        }
    }
}

@MainActor
protocol PlanSnapshotStoring {
    func load() throws -> PlanSnapshot?
    func save(_ snapshot: PlanSnapshot) throws
}
