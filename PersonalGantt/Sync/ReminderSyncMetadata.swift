import Foundation
import CryptoKit

/// PersonalGantt requirements only. Native IDs, text, completion and native dates
/// remain device-local EventKit data; the destination retains its own work UUID.
nonisolated struct ReminderSyncMetadata: Codable, Equatable, Sendable {
    var externalIdentifier: String
    var occurrenceKey: String?
    var estimatedMinutes: Int?
    var supplementalDeadline: Date?
    var isExcluded: Bool

    var id: String { Self.key(externalIdentifier: externalIdentifier, occurrenceKey: occurrenceKey) }
    static func key(externalIdentifier: String, occurrenceKey: String?) -> String {
        // A JSON tuple avoids delimiter collisions and distinguishes nil from an empty value.
        let tuple: [String?] = [externalIdentifier, occurrenceKey]
        let data = try! JSONEncoder().encode(tuple)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    var hasSettings: Bool { estimatedMinutes != nil || supplementalDeadline != nil || isExcluded }
    func validate() throws {
        guard !externalIdentifier.isEmpty, externalIdentifier.utf8.count <= 4096,
              occurrenceKey.map({ !$0.isEmpty && $0.utf8.count <= 1024 }) ?? true,
              estimatedMinutes.map({ $0 > 0 }) ?? true,
              supplementalDeadline.map({ $0.timeIntervalSinceReferenceDate.isFinite && $0 >= .distantPast && $0 <= .distantFuture }) ?? true
        else { throw SyncError.invalidData }
    }
    init?(metadata: ReminderTaskMetadata) {
        guard let external = metadata.externalIdentifier, !external.isEmpty else { return nil }
        externalIdentifier = external; occurrenceKey = metadata.occurrenceKey
        estimatedMinutes = metadata.estimatedMinutes; supplementalDeadline = metadata.deadlineOverride; isExcluded = metadata.isExcluded
        guard (try? validate()) != nil else { return nil }
    }
    func applying(to local: ReminderTaskMetadata) -> ReminderTaskMetadata {
        var result = local
        result.estimatedMinutes = estimatedMinutes; result.deadlineOverride = supplementalDeadline; result.isExcluded = isExcluded
        return result
    }
    static func isValidID(_ id: String) -> Bool {
        id.utf8.count == 64 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
