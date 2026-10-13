import Foundation
import CryptoKit

nonisolated enum LocalSyncConstants {
    static let serviceType = "pgantt-sync"
    static let protocolVersion = 3
    static let schemaVersion = 3
    static let maximumBytes = 8 * 1024 * 1024
    static let maximumRecords = 10_000
    static let rememberedMessages = 256
}
nonisolated enum LocalSyncError: LocalizedError, Equatable {
    case offline, version, invalidData, tooLarge, untrusted, storage, timeout, network, identityUpgrade
    var errorDescription: String? {
        switch self {
        case .offline: "相手が見つかりません。両端末でPersonalGanttを開いてください。"
        case .version: "PersonalGanttのバージョンが異なるため同期できません。"
        case .invalidData: "同期データを検証できません。端末内のデータを保持します。"
        case .tooLarge: "同期データがサイズ上限を超えています。JSONバックアップで受け渡せます。"
        case .untrusted: "信頼済み端末を確認できないため接続を停止しました。"
        case .storage: "同期データを保存できません。端末内の保存状態を確認してください。"
        case .timeout: "同期の確認応答がありません。編集を保持し、次の接続で再試行します。"
        case .network: "ローカル同期に接続できません。Wi-Fiとローカルネットワークの許可を確認してください。"
        case .identityUpgrade: "同期証明書の更新が必要です。両端末のPersonalGanttを更新し、設定でペアリングを解除してから再登録してください。作業データは保持されます。"
        }
    }
}
nonisolated struct LocalTrustedDevice: Codable, Equatable, Identifiable, Sendable {
    let deviceID: UUID
    var name: String
    let certificateHash: Data
    let pairedAt: Date
    var id: UUID { deviceID }
}
nonisolated struct LocalSyncPreferences: Codable, Equatable, Sendable {
    var enabled = false
    var trustedDevice: LocalTrustedDevice?
    var lastSync: Date?
    var isValid: Bool {
        func dateValid(_ date: Date) -> Bool { date.timeIntervalSinceReferenceDate.isFinite && date >= .distantPast && date <= .distantFuture }
        return (lastSync.map(dateValid) ?? true) && (trustedDevice.map { $0.certificateHash.count == 32 && !$0.name.isEmpty && $0.name.utf8.count <= 63 && dateValid($0.pairedAt) } ?? true)
    }
}
@MainActor protocol LocalSyncPreferenceStoring {
    func load() throws -> LocalSyncPreferences
    func save(_ preferences: LocalSyncPreferences) throws
}
nonisolated struct LocalPeer: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let pairing: Bool
}
nonisolated enum LocalLinkEvent: Sendable {
    case found(LocalPeer), lost(UUID), connecting
    case connected(LocalPeer, certificateHash: Data)
    case disconnected, received(Data), failed(LocalSyncError), incompatiblePeer
}
@MainActor protocol LocalSyncLink: AnyObject {
    var onEvent: ((LocalLinkEvent) -> Void)? { get set }
    var certificateHash: Data { get }
    func start(pairing: Bool, trusted: LocalTrustedDevice?) throws
    func updateTrust(_ trusted: LocalTrustedDevice)
    func stop()
    func connect(_ peer: LocalPeer) throws
    func send(_ data: Data) throws
    func disconnect()
}
nonisolated struct LocalHello: Codable, Equatable, Sendable {
    let deviceID: UUID
    let name: String
    let nonce: UUID
    let pairing: Bool
}
nonisolated enum LocalMessageKind: String, Codable, Sendable { case hello, approve, ready, records, ack, failure }
nonisolated struct LocalSyncEnvelope: Codable, Sendable {
    var protocolVersion = LocalSyncConstants.protocolVersion
    var schemaVersion = LocalSyncConstants.schemaVersion
    var messageID = UUID()
    let kind: LocalMessageKind
    var hello: LocalHello?
    var records: [SyncRecord]?
    var failure: LocalFailureCategory?
    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= LocalSyncConstants.maximumBytes else { throw LocalSyncError.tooLarge }
        return data
    }
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= LocalSyncConstants.maximumBytes else { throw LocalSyncError.tooLarge }
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys).isSubset(of: ["protocolVersion", "schemaVersion", "messageID", "kind", "hello", "records", "failure"]) else { throw LocalSyncError.invalidData }
            if let hello = object["hello"] as? [String: Any], !Set(hello.keys).isSubset(of: ["deviceID", "name", "nonce", "pairing"]) { throw LocalSyncError.invalidData }
            if let records = object["records"] as? [[String: Any]] {
                for record in records {
                    guard Set(record.keys).isSubset(of: ["kind", "id", "revision", "baseRevision", "payload"]) else { throw LocalSyncError.invalidData }
                    for key in ["revision", "baseRevision"] {
                        if let revision = record[key] as? [String: Any], !Set(revision.keys).isSubset(of: ["date", "counter", "deviceID"]) { throw LocalSyncError.invalidData }
                    }
                }
            }
            let value = try JSONDecoder().decode(Self.self, from: data)
            try value.validate(); return value
        } catch let error as LocalSyncError { throw error }
        catch { throw LocalSyncError.invalidData }
    }
    func validate() throws {
        guard protocolVersion == LocalSyncConstants.protocolVersion, schemaVersion == LocalSyncConstants.schemaVersion else { throw LocalSyncError.version }
        switch kind {
        case .hello:
            guard let hello, !hello.name.isEmpty, hello.name.utf8.count <= 63, records == nil, failure == nil else { throw LocalSyncError.invalidData }
        case .records, .ack:
            guard let records, hello == nil, failure == nil else { throw LocalSyncError.invalidData }
            try Self.validateRecords(records)
        case .failure:
            guard failure != nil, hello == nil, records == nil else { throw LocalSyncError.invalidData }
        case .approve, .ready:
            guard hello == nil, records == nil, failure == nil else { throw LocalSyncError.invalidData }
        }
    }
    static func validateRecords(_ records: [SyncRecord]) throws {
        guard records.count <= LocalSyncConstants.maximumRecords else { throw LocalSyncError.tooLarge }
        do {
            for record in records { try SyncState.validate(record); try SyncPayloadValidator.validate(record) }
            // Also reject inconsistent duplicates before any publication or persistence.
            var validation = SyncState(); try validation.merge(records)
        } catch { throw LocalSyncError.invalidData }
    }
    static func pairingCode(local: LocalHello, localHash: Data, remote: LocalHello, remoteHash: Data) -> String {
        let entries = [(local.deviceID.uuidString, local.nonce.uuidString, localHash), (remote.deviceID.uuidString, remote.nonce.uuidString, remoteHash)]
            .sorted { $0.0 < $1.0 }
        var transcript = Data("PersonalGantt pairing v1|".utf8)
        for (id, nonce, hash) in entries { transcript.append(Data((id + "|" + nonce + "|").utf8)); transcript.append(hash) }
        let hex = SHA256.hash(data: transcript).prefix(16).map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: 32, by: 4).map { index in
            let start = hex.index(hex.startIndex, offsetBy: index)
            return String(hex[start..<hex.index(start, offsetBy: 4)])
        }.joined(separator: " ")
    }
}
nonisolated enum LocalFailureCategory: String, Codable, Sendable { case storage, invalidData, tooLarge }
