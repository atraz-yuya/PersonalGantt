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
    /// Version 1 checkpoints decode these as nil and retain unlimited one-off scheduling.
    var workloadSettings: WorkloadSettings? = nil
    var routines: [Routine]? = nil
    /// Version 3 separates fetched Calendar range from derived planning range.
    var calendarCoverage: CalendarCoverage? = nil
    var syncState: SyncState? = nil
    var workSessions: [WorkSession]? = nil
    var schedulingSettings: SchedulingSettings? = nil
    var activeWorkSession: ActiveWorkSession? = nil

    var resolvedCalendarCoverage: CalendarCoverage? {
        if version >= 3 { return calendarCoverage }
        guard lastCalendarRefresh != nil, let planningStart, let planningEnd else { return nil }
        return CalendarCoverage(start: planningStart, end: planningEnd)
    }

    func validate() throws {
        func validDate(_ date: Date) -> Bool {
            date.timeIntervalSinceReferenceDate.isFinite && date >= .distantPast && date <= .distantFuture
        }
        let taskIDs = Set(tasks.map(\.id))
        let knownIDs = taskIDs.union(archivedTitles.keys)
        guard (1...4).contains(version) else { throw PlanStorageError.unsupportedVersion }
        if let syncState { guard version >= 4, (try? syncState.validate()) != nil else { throw PlanStorageError.invalidSnapshot } }
        if version < 3 && calendarCoverage != nil { throw PlanStorageError.invalidSnapshot }
        if let coverage = calendarCoverage {
            guard validDate(coverage.start), validDate(coverage.end), coverage.start < coverage.end,
                  lastCalendarRefresh != nil,
                  slots.allSatisfy({ $0.start >= coverage.start && $0.end <= coverage.end })
            else { throw PlanStorageError.invalidSnapshot }
        }
        if version == 1 {
            guard workloadSettings == nil, routines == nil, tasks.allSatisfy({ $0.routineOccurrence == nil })
            else { throw PlanStorageError.invalidSnapshot }
        } else {
            guard let workloadSettings, let routines,
                  (try? workloadSettings.validate()) != nil,
                  Set(routines.map(\.id)).count == routines.count,
                  routines.allSatisfy({ (try? $0.validate()) != nil }) else { throw PlanStorageError.invalidSnapshot }
            for task in tasks {
                guard let occurrence = task.routineOccurrence else { continue }
                guard let routine = routines.first(where: { $0.id == occurrence.routineID }),
                      !occurrence.dayKey.isEmpty, occurrence.taskID == task.id,
                      validDate(occurrence.dayStart), validDate(occurrence.dayEnd), occurrence.dayStart < occurrence.dayEnd,
                      task.deadline == occurrence.dayEnd, task.reminderIdentifier == nil,
                      !reminderTaskIDs.contains(task.id),
                      task.isCompleted == routine.completedOccurrenceIDs.contains(task.id),
                      !routine.skippedOccurrenceIDs.contains(task.id)
                else { throw PlanStorageError.invalidSnapshot }
            }
        }
        if schedulingSettings != nil && version < 4 { throw PlanStorageError.invalidSnapshot }
        if let workSessions {
            guard version >= 4, Set(workSessions.map(\.id)).count == workSessions.count,
                  workSessions.allSatisfy({ (try? $0.validate()) != nil && knownIDs.contains($0.taskID) && $0.end <= savedAt })
            else { throw PlanStorageError.invalidSnapshot }
        }
        if let activeWorkSession {
            guard version >= 4, knownIDs.contains(activeWorkSession.taskID), validDate(activeWorkSession.start), activeWorkSession.start <= savedAt else { throw PlanStorageError.invalidSnapshot }
        }
        guard validDate(savedAt), taskIDs.count == tasks.count,
              reminderTaskIDs.isSubset(of: taskIDs),
              tasks.allSatisfy({ (try? TaskDraft(task: $0).validated()) != nil &&
                  ($0.notBefore.map(validDate) ?? true) &&
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
