import Foundation

nonisolated struct ReminderTaskMetadata: Codable, Equatable, Sendable {
    var taskID: UUID
    var externalIdentifier: String?
    var listID: String
    var estimatedMinutes: Int?
    var deadlineOverride: Date?
    var isExcluded = false
    var occurrenceKey: String?
}

nonisolated struct ReminderLocalState: Codable, Equatable, Sendable {
    var selectedListIDs: Set<String> = []
    var metadata: [String: ReminderTaskMetadata] = [:]

    func validate() throws {
        guard selectedListIDs.allSatisfy({ !$0.isEmpty }),
              Set(metadata.values.map(\.taskID)).count == metadata.count,
              metadata.allSatisfy({ id, value in
                  !id.isEmpty && !value.listID.isEmpty &&
                  (value.estimatedMinutes.map { $0 > 0 } ?? true) &&
                  (value.deadlineOverride.map { $0.timeIntervalSinceReferenceDate.isFinite && $0 >= .distantPast && $0 <= .distantFuture } ?? true)
              }) else { throw ReminderServiceError.localStorage }
    }
}

@MainActor
protocol ReminderMetadataStoring {
    func load() throws -> ReminderLocalState
    func save(_ state: ReminderLocalState) throws
}

/// Device-local requirements and occurrence identity. Reminder text is not cached.
@MainActor
final class FileReminderMetadataStore: ReminderMetadataStoring {
    let url: URL
    init(url: URL) { self.url = url }
    static func live() -> FileReminderMetadataStore {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return FileReminderMetadataStore(url: directory.appendingPathComponent("PersonalGantt/ReminderMetadata.json"))
    }
    func load() throws -> ReminderLocalState {
        guard FileManager.default.fileExists(atPath: url.path) else { return ReminderLocalState() }
        do {
            let value = try JSONDecoder().decode(ReminderLocalState.self, from: Data(contentsOf: url))
            try value.validate()
            return value
        } catch { throw ReminderServiceError.localStorage }
    }
    func save(_ state: ReminderLocalState) throws {
        do {
            try state.validate()
            let data = try JSONEncoder().encode(state)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch { throw ReminderServiceError.localStorage }
    }
}
