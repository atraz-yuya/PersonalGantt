import Foundation

nonisolated enum SyncKind: String, Codable, Sendable { case task, routine, workload, workSession, schedulingSettings, reminderMetadata }
nonisolated struct SyncRevision: Codable, Equatable, Comparable, Sendable {
    var date: Date
    var counter: Int
    var deviceID: UUID
    static func < (a: Self, b: Self) -> Bool {
        if a.date != b.date { return a.date < b.date }
        if a.counter != b.counter { return a.counter < b.counter }
        return a.deviceID.uuidString < b.deviceID.uuidString
    }
}
nonisolated struct SyncRecord: Codable, Equatable, Sendable {
    var kind: SyncKind
    var id: String
    var revision: SyncRevision
    var baseRevision: SyncRevision?
    /// nil is a durable deletion tombstone. No credentials or calendar cache.
    var payload: Data?
    var key: String { kind.rawValue + "_" + id }
}
nonisolated struct SyncState: Codable, Equatable, Sendable {
    var deviceID = UUID()
    var records: [String: SyncRecord] = [:]
    var conflictKeys: Set<String> = []
    var isEnabled = false
    var lastSync: Date? = nil

    /// A partial edit must not tombstone entities absent from this device's native snapshot.
    mutating func captureValue(kind: SyncKind, id: String, payload: Data?, now: Date) {
        replace(kind: kind, id: id, payload: payload, now: now)
    }

    mutating func capture(kind: SyncKind, values: [String: Data], now: Date) {
        let liveKeys = Set(values.keys.map { kind.rawValue + "_" + $0 })
        for id in values.keys.sorted() { replace(kind: kind, id: id, payload: values[id], now: now) }
        for record in records.values.filter({ $0.kind == kind && $0.payload != nil && !liveKeys.contains($0.key) }) {
            replace(kind: kind, id: record.id, payload: nil, now: now)
        }
    }
    private mutating func replace(kind: SyncKind, id: String, payload: Data?, now: Date) {
        let key = kind.rawValue + "_" + id
        let previous = records[key]
        guard previous?.payload != payload || previous == nil else { return }
        let date = max(now, previous?.revision.date ?? now)
        let counter = previous?.revision.date == date ? (previous?.revision.counter ?? 0) + 1 : 0
        records[key] = SyncRecord(kind: kind, id: id, revision: SyncRevision(date: date, counter: counter, deviceID: deviceID),
                                 baseRevision: previous?.revision, payload: payload)
    }
    mutating func merge(_ incoming: [SyncRecord]) throws {
        var seen: [String: SyncRecord] = [:]
        for record in incoming {
            try Self.validate(record)
            let revisionKey = "\(record.key)|\(record.revision.date.timeIntervalSinceReferenceDate.bitPattern)|\(record.revision.counter)|\(record.revision.deviceID)"
            if let previous = seen[revisionKey], previous != record { throw SyncError.invalidData }
            if let local = records[record.key], local.revision == record.revision, local != record { throw SyncError.invalidData }
            seen[revisionKey] = record
        }
        for record in incoming.sorted(by: { $0.key < $1.key }) {
            if let local = records[record.key] {
                if local.revision != record.revision && local.payload != record.payload &&
                    local.baseRevision != record.revision && record.baseRevision != local.revision {
                    conflictKeys.insert(record.key)
                }
                if local.revision >= record.revision { continue }
            }
            records[record.key] = record
        }
    }
    func validate() throws {
        guard (lastSync.map { $0.timeIntervalSinceReferenceDate.isFinite && $0 >= .distantPast && $0 <= .distantFuture } ?? true), conflictKeys.allSatisfy({ records[$0] != nil }) else { throw SyncError.invalidData }
        for (key, record) in records { guard key == record.key else { throw SyncError.invalidData }; try Self.validate(record) }
    }
    static func validate(_ record: SyncRecord) throws {
        guard !record.id.isEmpty, record.id.count < 200, record.revision.counter >= 0, record.revision.counter < 1_000_000_000,
              record.revision.date.timeIntervalSinceReferenceDate.isFinite,
              record.revision.date >= .distantPast, record.revision.date <= .distantFuture,
              (record.payload?.count ?? 0) <= 2_000_000 else { throw SyncError.invalidData }
        if let base = record.baseRevision {
            guard base.counter >= 0, base.counter < 1_000_000_000, base.date.timeIntervalSinceReferenceDate.isFinite,
                  base.date >= .distantPast, base.date <= .distantFuture, base < record.revision else { throw SyncError.invalidData }
        }
    }
    static func payloadData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let raw = try JSONSerialization.jsonObject(with: encoder.encode(value), options: [.fragmentsAllowed])
        func canonical(_ object: Any) -> Any {
            if let dictionary = object as? [String: Any] { return dictionary.mapValues(canonical) }
            if let array = object as? [Any] {
                return array.map(canonical).sorted {
                    let a = (try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .fragmentsAllowed])) ?? Data()
                    let b = (try? JSONSerialization.data(withJSONObject: $1, options: [.sortedKeys, .fragmentsAllowed])) ?? Data()
                    return a.lexicographicallyPrecedes(b)
                }
            }
            return object
        }
        return try JSONSerialization.data(withJSONObject: canonical(raw), options: [.sortedKeys, .fragmentsAllowed])
    }
}
nonisolated enum SyncError: LocalizedError { case unavailable, invalidData, network
    var errorDescription: String? {
        switch self {
        case .unavailable: "現在の署名設定ではiCloud同期を利用できません。JSONバックアップで受け渡せます。"
        case .invalidData: "同期データを検証できません。端末内のデータを保持します。"
        case .network: "同期できませんでした。端末内の編集を保持し、次の同期で再試行します。"
        }
    }
}
@MainActor protocol SyncTransport {
    func exchange(_ records: [SyncRecord]) async throws -> [SyncRecord]
}
