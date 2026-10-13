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
    var availabilityExclusions: [TaskAvailabilityExclusion] = []

    var id: String { Self.key(externalIdentifier: externalIdentifier, occurrenceKey: occurrenceKey) }
    static func key(externalIdentifier: String, occurrenceKey: String?) -> String {
        // A JSON tuple avoids delimiter collisions and distinguishes nil from an empty value.
        let tuple: [String?] = [externalIdentifier, occurrenceKey]
        let data = try! JSONEncoder().encode(tuple)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    var hasSettings: Bool { estimatedMinutes != nil || supplementalDeadline != nil || isExcluded || !availabilityExclusions.isEmpty }
    func validate() throws {
        guard AvailabilityExclusion.valid(availabilityExclusions), !externalIdentifier.isEmpty, externalIdentifier.utf8.count <= 4096,
              occurrenceKey.map({ !$0.isEmpty && $0.utf8.count <= 1024 }) ?? true,
              estimatedMinutes.map({ $0 > 0 }) ?? true,
              supplementalDeadline.map({ $0.timeIntervalSinceReferenceDate.isFinite && $0 >= .distantPast && $0 <= .distantFuture }) ?? true
        else { throw SyncError.invalidData }
    }
    init?(metadata: ReminderTaskMetadata) {
        guard let external = metadata.externalIdentifier, !external.isEmpty else { return nil }
        externalIdentifier = external; occurrenceKey = metadata.occurrenceKey
        estimatedMinutes = metadata.estimatedMinutes; supplementalDeadline = metadata.deadlineOverride; isExcluded = metadata.isExcluded
        availabilityExclusions = metadata.availabilityExclusions
        guard (try? validate()) != nil else { return nil }
    }
    func applying(to local: ReminderTaskMetadata) -> ReminderTaskMetadata {
        var result = local
        result.estimatedMinutes = estimatedMinutes; result.deadlineOverride = supplementalDeadline; result.isExcluded = isExcluded
        result.availabilityExclusions = availabilityExclusions
        return result
    }
    static func isValidID(_ id: String) -> Bool {
        id.utf8.count == 64 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

nonisolated extension ReminderSyncMetadata {
    enum CodingKeys: String, CodingKey { case externalIdentifier, occurrenceKey, estimatedMinutes, supplementalDeadline, isExcluded, availabilityExclusions }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        externalIdentifier = try c.decode(String.self, forKey: .externalIdentifier)
        occurrenceKey = try c.decodeIfPresent(String.self, forKey: .occurrenceKey)
        estimatedMinutes = try c.decodeIfPresent(Int.self, forKey: .estimatedMinutes)
        supplementalDeadline = try c.decodeIfPresent(Date.self, forKey: .supplementalDeadline)
        isExcluded = try c.decode(Bool.self, forKey: .isExcluded)
        availabilityExclusions = try c.decodeIfPresent([TaskAvailabilityExclusion].self, forKey: .availabilityExclusions) ?? []
    }
}
