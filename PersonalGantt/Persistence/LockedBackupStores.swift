import Foundation

/// Recovery failure must not publish or overwrite a half-restored pair of stores.
@MainActor
struct LockedPlanStore: PlanSnapshotStoring {
    func load() throws -> PlanSnapshot? { throw BackupError.recoveryRequired }
    func save(_ snapshot: PlanSnapshot) throws { throw BackupError.recoveryRequired }
}

@MainActor
struct LockedReminderStore: ReminderMetadataStoring {
    func load() throws -> ReminderLocalState { throw BackupError.recoveryRequired }
    func save(_ state: ReminderLocalState) throws { throw BackupError.recoveryRequired }
}
