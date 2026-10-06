import Foundation
import SwiftData

/// Version both the database schema and the checkpoint payload before changing either.
enum LocalPlanSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [Checkpoint.self] }

    @Model
    final class Checkpoint {
        @Attribute(.unique) var key: String
        var payload: Data
        init(payload: Data) { key = "current"; self.payload = payload }
    }
}

enum LocalPlanMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [LocalPlanSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

@MainActor
final class SwiftDataPlanStore: PlanSnapshotStoring {
    private let context: ModelContext

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let schema = Schema(versionedSchema: LocalPlanSchemaV1.self)
        let configuration = ModelConfiguration("LocalPlan", schema: schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, migrationPlan: LocalPlanMigrationPlan.self, configurations: [configuration])
        context = ModelContext(container)
        // Every checkpoint is an explicit transaction. Failed writes must not autosave later.
        context.autosaveEnabled = false
    }

    static func live() -> any PlanSnapshotStoring {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        do { return try SwiftDataPlanStore(url: directory.appendingPathComponent("PersonalGantt/LocalPlan.store")) }
        catch { return UnavailablePlanStore() }
    }

    func load() throws -> PlanSnapshot? {
        let rows = try context.fetch(FetchDescriptor<LocalPlanSchemaV1.Checkpoint>())
        guard rows.count <= 1, rows.allSatisfy({ $0.key == "current" }) else { throw PlanStorageError.invalidSnapshot }
        guard let row = rows.first else { return nil }
        let snapshot: PlanSnapshot
        do { snapshot = try JSONDecoder().decode(PlanSnapshot.self, from: row.payload) }
        catch { throw PlanStorageError.invalidSnapshot }
        try snapshot.validate()
        return snapshot
    }

    func save(_ snapshot: PlanSnapshot) throws {
        try snapshot.validate()
        let payload = try JSONEncoder().encode(snapshot)
        do {
            let rows = try context.fetch(FetchDescriptor<LocalPlanSchemaV1.Checkpoint>())
            guard rows.count <= 1, rows.allSatisfy({ $0.key == "current" }) else { throw PlanStorageError.invalidSnapshot }
            if let row = rows.first { row.payload = payload }
            else { context.insert(LocalPlanSchemaV1.Checkpoint(payload: payload)) }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
}

@MainActor
private struct UnavailablePlanStore: PlanSnapshotStoring {
    func load() throws -> PlanSnapshot? { throw PlanStorageError.unavailable }
    func save(_ snapshot: PlanSnapshot) throws { throw PlanStorageError.unavailable }
}
