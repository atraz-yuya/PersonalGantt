import Foundation
import CloudKit

/// Per-entity records in the user's private database, with CloudKit change-tag
/// checks in addition to our deterministic last-write-wins domain merge.
@MainActor final class CloudKitSyncTransport: SyncTransport {
    private let database: CKDatabase
    init(containerIdentifier: String) { database = CKContainer(identifier: containerIdentifier).privateCloudDatabase }
    static func configured() -> (any SyncTransport)? {
        #if PERSONALGANTT_CLOUDKIT
        guard let id = Bundle.main.object(forInfoDictionaryKey: "PersonalGanttCloudContainer") as? String,
              id.hasPrefix("iCloud.") else { return nil }
        return CloudKitSyncTransport(containerIdentifier: id)
        #else
        return nil
        #endif
    }
    func exchange(_ records: [SyncRecord]) async throws -> [SyncRecord] {
        var cloud: [String: CKRecord] = [:]
        var page = try await database.records(matching: CKQuery(recordType: "PersonalGanttSync", predicate: NSPredicate(value: true)))
        while true {
            for (_, result) in page.matchResults {
                let record = try result.get()
                guard cloud.count < 10000 else { throw SyncError.invalidData }
                cloud[record.recordID.recordName] = record
            }
            guard let cursor = page.queryCursor else { break }
            page = try await database.records(continuingMatchFrom: cursor)
        }
        for local in records.sorted(by: { $0.key < $1.key }) {
            try SyncState.validate(local)
            var existing = cloud[local.key]
            for attempt in 0..<3 {
                if let existing {
                    let remote = try decode(existing)
                    if remote.revision >= local.revision { break }
                }
                let record = existing ?? CKRecord(recordType: "PersonalGanttSync", recordID: CKRecord.ID(recordName: local.key))
                record["payload"] = try SyncState.payloadData(local) as CKRecordValue
                do { cloud[local.key] = try await database.save(record); break }
                catch let error as CKError where error.code == .serverRecordChanged && attempt < 2 {
                    existing = error.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord
                    if let existing { cloud[local.key] = existing }
                }
            }
        }
        return try cloud.values.map(decode)
    }
    private func decode(_ record: CKRecord) throws -> SyncRecord {
        guard let data = record["payload"] as? Data, data.count <= 2_000_000 else { throw SyncError.invalidData }
        let value = try JSONDecoder().decode(SyncRecord.self, from: data)
        try SyncState.validate(value)
        guard value.key == record.recordID.recordName else { throw SyncError.invalidData }
        return value
    }
}
