import Foundation
import Testing
import Security
import CryptoKit
@testable import PersonalGantt

struct LocalSyncProtocolTests {
    @Test func helloAndRecordRoundTrip() throws {
        let value = LocalSyncEnvelope(kind: .records, records: [try localRecord()])
        let decoded = try LocalSyncEnvelope.decode(value.encoded())
        #expect(decoded.messageID == value.messageID && decoded.records == value.records)
    }
    @Test(arguments: [0, 1]) func incompatibleVersionsFail(which: Int) throws {
        var value = LocalSyncEnvelope(kind: .ready)
        if which == 0 { value.protocolVersion = 99 } else { value.schemaVersion = 99 }
        #expect(throws: LocalSyncError.version) { try LocalSyncEnvelope.decode(JSONEncoder().encode(value)) }
    }
    @Test(arguments: ["{}", "not-json", #"{"kind":"unknown"}"#]) func malformedEnvelopesFail(text: String) {
        #expect(throws: LocalSyncError.invalidData) { try LocalSyncEnvelope.decode(Data(text.utf8)) }
    }
    @Test func oversizeDataAndEntityCountFail() throws {
        #expect(throws: LocalSyncError.tooLarge) { try LocalSyncEnvelope.decode(Data(repeating: 0, count: LocalSyncConstants.maximumBytes + 1)) }
        let records = Array(repeating: try localRecord(), count: LocalSyncConstants.maximumRecords + 1)
        #expect(throws: LocalSyncError.tooLarge) { try LocalSyncEnvelope(kind: .records, records: records).encoded() }
    }
    @Test(arguments: [0, 1, 2]) func unexpectedEnvelopeEntityOrRevisionKeysFail(depth: Int) throws {
        let envelope = LocalSyncEnvelope(kind: .records, records: [try localRecord()])
        var object = try #require(JSONSerialization.jsonObject(with: envelope.encoded()) as? [String: Any])
        if depth == 0 { object["accessToken"] = "synthetic" }
        else {
            var records = try #require(object["records"] as? [[String: Any]])
            if depth == 1 { records[0]["accessToken"] = "synthetic" }
            else { var revision = try #require(records[0]["revision"] as? [String: Any]); revision["secret"] = "synthetic"; records[0]["revision"] = revision }
            object["records"] = records
        }
        #expect(throws: LocalSyncError.invalidData) { try LocalSyncEnvelope.decode(JSONSerialization.data(withJSONObject: object)) }
    }
    @Test func sameRevisionDifferentPayloadFailsBeforeApply() throws {
        let first = try localRecord(); var second = first
        second.payload = try SyncState.payloadData(PersonalGantt.Task(id: UUID(uuidString: first.id)!, title: "Changed", estimatedMinutes: 60, deadline: ReminderFixtures.date(23)))
        #expect(throws: LocalSyncError.invalidData) { try LocalSyncEnvelope(kind: .records, records: [first, second]).encoded() }
    }
    @Test(arguments: [0, 1, 2]) func invalidUUIDDateAndPayloadEnumFail(index: Int) throws {
        var record = try localRecord()
        switch index {
        case 0: record.id = "invalid-id"
        case 1: record.revision.date = Date(timeIntervalSinceReferenceDate: .nan)
        default:
            let payload = try #require(record.payload)
            var object = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
            object["priority"] = "unknown-priority"; record.payload = try JSONSerialization.data(withJSONObject: object)
        }
        #expect(throws: LocalSyncError.invalidData) { try LocalSyncEnvelope(kind: .records, records: [record]).encoded() }
    }
    @Test(arguments: ["accessToken", "refreshToken", "fixedEvents", "blocks"])
    func nonSyncFieldsInsideEntityPayloadFailBeforeSending(key: String) throws {
        var record = try localRecord()
        let payload = try #require(record.payload)
        var object = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        object[key] = "synthetic-forbidden-data"
        record.payload = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: LocalSyncError.invalidData) { try LocalSyncEnvelope(kind: .records, records: [record]).encoded() }
    }
    @Test func pairingCodeBindsBothCertificatesAndFreshNonces() {
        let a = LocalHello(deviceID: localA, name: "Mac", nonce: UUID(), pairing: true)
        let b = LocalHello(deviceID: localB, name: "iPhone", nonce: UUID(), pairing: true)
        let code = LocalSyncEnvelope.pairingCode(local: a, localHash: hashA, remote: b, remoteHash: hashB)
        #expect(code == LocalSyncEnvelope.pairingCode(local: b, localHash: hashB, remote: a, remoteHash: hashA))
        #expect(code != LocalSyncEnvelope.pairingCode(local: a, localHash: hashB, remote: b, remoteHash: hashB))
        #expect(code.count == 39)
        let fresh = LocalHello(deviceID: a.deviceID, name: a.name, nonce: UUID(), pairing: true)
        #expect(code != LocalSyncEnvelope.pairingCode(local: fresh, localHash: hashA, remote: b, remoteHash: hashB))
    }
    @Test(arguments: [false, true]) @MainActor func deviceSpecificTLSCertificateHasMatchingPrivateKey(rsa: Bool) throws {
        let attributes: [String: Any] = [kSecAttrKeyType as String: rsa ? kSecAttrKeyTypeRSA : kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits as String: rsa ? 2048 : 256]
        let key = try #require(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let certificate = try LocalSyncIdentity.makeCertificate(key: key, deviceID: localA)
        let identity = try #require(SecIdentityCreate(nil, certificate, key))
        #expect(try LocalSyncIdentity.validate(identity) == Data(SHA256.hash(data: SecCertificateCopyData(certificate) as Data)))
        let values = try LocalSyncIdentity.securityIdentity(identity)
        #expect(values.count == 1 && CFGetTypeID(values[0] as CFTypeRef) == SecIdentityGetTypeID())
        let wrongKey = try #require(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        #expect(SecIdentityCreate(nil, certificate, wrongKey) == nil)
        let second = try LocalSyncIdentity.makeCertificate(key: key, deviceID: localB)
        #expect(SecCertificateCopyData(certificate) as Data != SecCertificateCopyData(second) as Data)
    }
}

struct LocalCertificateDecisionTests {
    @Test func initialPairingAcceptsOnlyKnownPairingCandidates() {
        let peer = LocalPeer(id: localB, name: "iPhone", pairing: true)
        #expect(LocalCertificateDecision.evaluate(hash: hashB, peer: peer, expected: false, anotherPeerExpected: false, pairing: true, trusted: nil) == .pairingCandidate)
        #expect(LocalCertificateDecision.evaluate(hash: hashB, peer: nil, expected: false, anotherPeerExpected: false, pairing: true, trusted: nil) == .unknownPeer)
        #expect(LocalCertificateDecision.evaluate(hash: hashB, peer: peer, expected: false, anotherPeerExpected: true, pairing: true, trusted: nil) == .unexpectedPeer)
        #expect(LocalCertificateDecision.evaluate(hash: hashB, peer: peer, expected: true, anotherPeerExpected: false, pairing: false, trusted: nil) == .notPairing)
        #expect(LocalCertificateDecision.evaluate(hash: nil, peer: peer, expected: true, anotherPeerExpected: false, pairing: true, trusted: nil) == .missingCertificate)
        #expect(LocalCertificateDecision.evaluate(hash: hashB, peer: LocalPeer(id: localB, name: "iPhone", pairing: false), expected: true, anotherPeerExpected: false, pairing: true, trusted: nil) == .notPairing)
    }
    @Test func existingTrustAlwaysRequiresFingerprintAndExpectedDeviceEvenDuringPairing() {
        let trust = LocalTrustedDevice(deviceID: localB, name: "iPhone", certificateHash: hashB, pairedAt: Date())
        let peer = LocalPeer(id: localB, name: "iPhone", pairing: true)
        #expect(LocalCertificateDecision.evaluate(hash: hashB, peer: peer, expected: true, anotherPeerExpected: false, pairing: true, trusted: trust) == .trustedFingerprint)
        #expect(LocalCertificateDecision.evaluate(hash: hashA, peer: peer, expected: true, anotherPeerExpected: false, pairing: true, trusted: trust) == .fingerprintMismatch)
        #expect(LocalCertificateDecision.evaluate(hash: hashB, peer: peer, expected: false, anotherPeerExpected: false, pairing: true, trusted: trust) == .unexpectedPeer)
        #expect(LocalCertificateDecision.evaluate(hash: hashB, peer: LocalPeer(id: localA, name: "iPhone", pairing: true), expected: true, anotherPeerExpected: false, pairing: true, trusted: trust) == .unexpectedPeer)
    }
}

@MainActor struct LocalSyncPairingTests {
    @Test func discoveryAndBothApprovalsAreRequiredBeforeSendingWork() async throws {
        let pair = makeTransportPair(trusted: false)
        pair.a.beginPairing(); pair.b.beginPairing()
        pair.al.onEvent?(.found(peerB)); pair.bl.onEvent?(.found(peerA))
        #expect(pair.a.peers == [peerB] && pair.b.peers == [peerA])
        pair.a.connect(peerB); await settle()
        #expect(pair.a.pairingCode != nil && pair.a.pairingCode == pair.b.pairingCode)
        #expect(!pair.a.isConnected && pair.as_.value.trustedDevice == nil)
        #expect(pair.al.sent.allSatisfy { (try? LocalSyncEnvelope.decode($0).kind) == .hello })
        pair.a.approvePairing(); await settle()
        #expect(pair.as_.value.trustedDevice == nil && !pair.a.isConnected)
        pair.b.approvePairing(); await settle()
        #expect(pair.a.isConnected && pair.b.isConnected && pair.as_.value.trustedDevice?.deviceID == localB)
        #expect(pair.bs.value.trustedDevice?.certificateHash == hashA)
        await pair.a.syncNow()
        #expect(pair.bState.value.records.count == 1 && pair.a.preferences.lastSync != nil)
        pair.a.setAvailable(false); pair.b.setAvailable(false)
    }
    @Test func rejectingPairingNeverPersistsTrustOrSendsRecords() async {
        let pair = makeTransportPair(trusted: false)
        pair.a.beginPairing(); pair.b.beginPairing(); pair.a.connect(peerB); await settle()
        pair.a.rejectPairing(); await settle()
        #expect(pair.as_.value.trustedDevice == nil && pair.bs.value.trustedDevice == nil)
        #expect(!pair.a.isConnected && !pair.a.isPairing)
        #expect(pair.al.sent.allSatisfy { (try? LocalSyncEnvelope.decode($0).kind) != .records })
        pair.a.setAvailable(false); pair.b.setAvailable(false)
    }
    @Test(arguments: [false, true]) func untrustedOrChangedCertificateCannotSendData(changed: Bool) async {
        let pair = makeTransportPair(trusted: changed)
        pair.al.onEvent?(.connected(peerB, certificateHash: changed ? hashA : hashB))
        await settle()
        #expect(pair.al.sent.isEmpty && pair.aState.applies == 0 && !pair.a.isConnected)
        #expect(pair.al.disconnects > 0)
        pair.a.setAvailable(false); pair.b.setAvailable(false)
    }
    @Test func trustedReconnectionSkipsPairingAndUnpairDisablesAuthorization() async throws {
        let pair = makeTransportPair(trusted: true)
        pair.al.onEvent?(.found(peerB)); await settle()
        #expect(pair.a.isConnected && pair.b.isConnected && pair.a.pairingCode == nil)
        await pair.a.syncNow()
        #expect(pair.bState.value.records.count == 1)
        pair.a.unpair(); await settle()
        #expect(pair.as_.value.trustedDevice == nil && !pair.a.isConnected)
        await #expect(throws: LocalSyncError.untrusted) { try await pair.a.exchange([]) }
        pair.a.setAvailable(false); pair.b.setAvailable(false)
    }
    @Test func duplicateRequestAppliesOnceAndStillReceivesAck() async throws {
        let pair = makeTransportPair(trusted: true)
        pair.al.onEvent?(.found(peerB)); await settle()
        let data = try LocalSyncEnvelope(kind: .records, records: [try localRecord()]).encoded()
        let before = pair.bState.applies
        pair.bl.onEvent?(.received(data)); pair.bl.onEvent?(.received(data)); await settle()
        #expect(pair.bState.applies == before + 1)
        #expect(pair.bl.sent.filter { (try? LocalSyncEnvelope.decode($0).kind) == .ack }.count == 2)
        pair.a.setAvailable(false); pair.b.setAvailable(false)
    }
    @Test func failedDurableApplyReturnsFailureAndNeverAck() async throws {
        let pair = makeTransportPair(trusted: true)
        pair.al.onEvent?(.found(peerB)); await settle()
        pair.bState.fail = true
        await pair.a.syncNow()
        #expect(pair.bState.value.records.isEmpty)
        #expect(!pair.bl.sent.contains { (try? LocalSyncEnvelope.decode($0).kind) == .ack })
        #expect(pair.a.preferences.lastSync == nil && pair.a.status == "同期エラー")
        pair.a.setAvailable(false); pair.b.setAvailable(false)
    }
    @Test func lostAckRetriesSameIDAndRemainsIdempotent() async throws {
        let pair = makeTransportPair(trusted: true, delay: .milliseconds(10))
        pair.al.onEvent?(.found(peerB)); await settle()
        pair.bl.dropNextAck = true
        await pair.a.syncNow()
        let requests = try pair.al.sent.map(LocalSyncEnvelope.decode).filter { $0.kind == .records }
        #expect(requests.count == 2 && requests[0].messageID == requests[1].messageID)
        #expect(pair.bState.applies == 1 && pair.a.preferences.lastSync != nil)
        pair.a.setAvailable(false); pair.b.setAvailable(false)
    }
    @Test func missingAckHasBoundedRetriesAndPreservesEdits() async throws {
        let pair = makeTransportPair(trusted: true, delay: .milliseconds(10))
        pair.al.onEvent?(.found(peerB)); await settle(); pair.bl.dropEveryAck = true
        await pair.a.syncNow()
        #expect(pair.al.sent.filter { (try? LocalSyncEnvelope.decode($0).kind) == .records }.count == 3)
        #expect(pair.bState.applies == 1 && pair.aState.value.records.count == 1)
        #expect(pair.a.preferences.lastSync == nil && pair.a.status == "同期エラー")
        pair.a.setAvailable(false); pair.b.setAvailable(false)
    }
    @Test func versionMismatchDiscoveryIsVisibleWithoutAnyRecords() {
        let pair = makeTransportPair(trusted: true)
        pair.al.onEvent?(.incompatiblePeer)
        #expect(pair.a.status == "バージョン不一致" && pair.al.sent.isEmpty)
        pair.a.setAvailable(false); pair.b.setAvailable(false)
    }
    @Test func preferencesLoadFailureCannotOverwriteExistingTrust() {
        let store = LocalPreferenceMemory(value: preferences(localA, trusted: true)); store.fail = true
        let link = LocalTestLink(id: localA, hash: hashA)
        let value = LocalSyncTransport(deviceID: localA, displayName: "Mac", link: link, store: store, snapshot: { [] }, apply: { _ in })
        value.setEnabled(true)
        #expect(store.value.trustedDevice?.deviceID == localB && link.starts == 0)
        store.fail = false; value.setEnabled(true)
        #expect(value.preferences.trustedDevice == store.value.trustedDevice)
        value.setAvailable(false)
    }
    @Test func suspendedAvailabilityStopsNetworkingAndResumesDiscovery() {
        let pair = makeTransportPair(trusted: true)
        pair.a.setAvailable(false)
        #expect(pair.al.stops > 0 && pair.a.status == "オフライン")
        pair.a.setAvailable(true)
        #expect(pair.al.starts == 2)
        pair.a.setEnabled(false); #expect(!pair.as_.value.enabled)
        pair.b.setAvailable(false)
    }
}

@MainActor private func makeTransportPair(trusted: Bool, delay: Duration = .seconds(8)) -> TransportPair {
    let aState = LocalRecordMemory(), bState = LocalRecordMemory()
    aState.value.records = [try! localRecord().key: try! localRecord()]
    // Use one exact record; the helper's task UUID is stable.
    let as_ = LocalPreferenceMemory(value: preferences(localA, trusted: trusted)), bs = LocalPreferenceMemory(value: preferences(localB, trusted: trusted))
    let al = LocalTestLink(id: localA, hash: hashA), bl = LocalTestLink(id: localB, hash: hashB)
    al.other = bl; bl.other = al
    let a = LocalSyncTransport(deviceID: localA, displayName: "Mac", link: al, store: as_, acknowledgementDelay: delay,
        snapshot: { Array(aState.value.records.values) }, apply: { try aState.apply($0) })
    let b = LocalSyncTransport(deviceID: localB, displayName: "iPhone", link: bl, store: bs, acknowledgementDelay: delay,
        snapshot: { Array(bState.value.records.values) }, apply: { try bState.apply($0) })
    a.setAvailable(true); b.setAvailable(true)
    return TransportPair(a: a, b: b, al: al, bl: bl, as_: as_, bs: bs, aState: aState, bState: bState)
}
@MainActor private struct TransportPair {
    let a: LocalSyncTransport, b: LocalSyncTransport
    let al: LocalTestLink, bl: LocalTestLink
    let as_: LocalPreferenceMemory, bs: LocalPreferenceMemory
    let aState: LocalRecordMemory, bState: LocalRecordMemory
}
@MainActor final class LocalTestLink: LocalSyncLink {
    var onEvent: ((LocalLinkEvent) -> Void)?
    let id: UUID, certificateHash: Data
    weak var other: LocalTestLink?
    var sent: [Data] = [], starts = 0, stops = 0, disconnects = 0
    var dropNextAck = false, dropEveryAck = false, holdsRecords = false
    var held: [Data] = []
    private var connected = false
    init(id: UUID, hash: Data) { self.id = id; certificateHash = hash }
    func start(pairing: Bool, trusted: LocalTrustedDevice?) throws { starts += 1 }
    func updateTrust(_ trusted: LocalTrustedDevice) { }
    func stop() { stops += 1; disconnect() }
    func connect(_ peer: LocalPeer) throws {
        guard let other else { throw LocalSyncError.offline }
        connected = true; other.connected = true
        onEvent?(.connected(peer, certificateHash: other.certificateHash))
        other.onEvent?(.connected(LocalPeer(id: id, name: id == localA ? "Mac" : "iPhone", pairing: true), certificateHash: certificateHash))
    }
    func send(_ data: Data) throws {
        sent.append(data)
        let kind = try LocalSyncEnvelope.decode(data).kind
        if kind == .ack && (dropEveryAck || dropNextAck) { dropNextAck = false; return }
        if kind == .records && holdsRecords { held.append(data); return }
        _Concurrency.Task { @MainActor [weak other] in other?.onEvent?(.received(data)) }
    }
    func deliverHeld() {
        let data = held; held = []
        for value in data { _Concurrency.Task { @MainActor [weak other] in other?.onEvent?(.received(value)) } }
    }
    func disconnect() {
        disconnects += 1
        guard connected else { return }
        connected = false; other?.connected = false
        _Concurrency.Task { @MainActor [weak self, weak other] in self?.onEvent?(.disconnected); other?.onEvent?(.disconnected) }
    }
}
@MainActor final class LocalPreferenceMemory: LocalSyncPreferenceStoring {
    var value: LocalSyncPreferences
    var fail = false
    init(value: LocalSyncPreferences = LocalSyncPreferences()) { self.value = value }
    func load() throws -> LocalSyncPreferences { if fail { throw LocalSyncError.storage }; return value }
    func save(_ preferences: LocalSyncPreferences) throws { if fail { throw LocalSyncError.storage }; value = preferences }
}
@MainActor private final class LocalRecordMemory {
    var value = SyncState(), applies = 0, fail = false
    func apply(_ incoming: [SyncRecord]) throws { if fail { throw LocalSyncError.storage }; var next = value; try next.merge(incoming); value = next; applies += 1 }
}
nonisolated private let localA = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
nonisolated private let localB = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
nonisolated private let hashA = Data(repeating: 1, count: 32), hashB = Data(repeating: 2, count: 32)
nonisolated private let peerA = LocalPeer(id: localA, name: "Mac", pairing: true), peerB = LocalPeer(id: localB, name: "iPhone", pairing: true)
nonisolated func localRecord() throws -> SyncRecord {
    let task = PersonalGantt.Task(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, title: "Synthetic", estimatedMinutes: 60, deadline: ReminderFixtures.date(23))
    return try SyncRecord(kind: .task, id: task.id.uuidString, revision: SyncRevision(date: ReminderFixtures.date(0), counter: 0, deviceID: localA), payload: SyncState.payloadData(task))
}
@MainActor private func preferences(_ id: UUID, trusted: Bool) -> LocalSyncPreferences {
    var result = LocalSyncPreferences(); result.enabled = true
    if trusted { result.trustedDevice = LocalTrustedDevice(deviceID: id == localA ? localB : localA, name: id == localA ? "iPhone" : "Mac", certificateHash: id == localA ? hashB : hashA, pairedAt: ReminderFixtures.date(0)) }
    return result
}
@MainActor func settle() async { for _ in 0..<50 { await _Concurrency.Task.yield() } }

@MainActor struct LocalSyncIntegrationTests {
    @Test func tasksFlowBothWaysAndConcurrentAdditionMerges() async throws {
        let pair = await makeModels()
        let a = try pair.a.addTask(TaskDraft(title: "Mac Task", deadline: ReminderFixtures.date(23)))
        let b = try pair.b.addTask(TaskDraft(title: "iPhone Task", deadline: ReminderFixtures.date(23)))
        await pair.a.localSync?.syncNow()
        #expect(Set(pair.a.tasks.map(\.id)) == [a.id, b.id] && Set(pair.b.tasks.map(\.id)) == [a.id, b.id])
        #expect(pair.a.result.blocks.count == 2 && pair.b.result.blocks.count == 2)
        stop(pair)
    }
    @Test func simultaneousEditsUseSharedDeterministicLWWAndConflicts() async throws {
        let pair = await makeModels()
        let task = try pair.a.addTask(TaskDraft(title: "Initial", deadline: ReminderFixtures.date(23)))
        await pair.a.localSync?.syncNow()
        try pair.a.updateTask(id: task.id, draft: TaskDraft(title: "Mac edit", deadline: task.deadline, priority: .high))
        try pair.b.updateTask(id: task.id, draft: TaskDraft(title: "iPhone edit", deadline: task.deadline, priority: .low))
        await pair.a.localSync?.syncNow()
        #expect(pair.a.task(for: task.id)?.title == "iPhone edit" && pair.a.task(for: task.id)?.priority == .low)
        #expect(pair.a.tasks == pair.b.tasks && !pair.a.syncState.conflictKeys.isEmpty && !pair.b.syncState.conflictKeys.isEmpty)
        stop(pair)
    }
    @Test func offlineEditsAndTombstoneMergeWithoutStaleResurrection() async throws {
        let pair = await makeModels()
        let task = try pair.a.addTask(TaskDraft(title: "Initial", deadline: ReminderFixtures.date(23)))
        await pair.a.localSync?.syncNow()
        pair.b.localSync?.setAvailable(false); await settle()
        try pair.b.updateTask(id: task.id, draft: TaskDraft(title: "Offline old edit", deadline: task.deadline))
        try pair.a.updateTask(id: task.id, draft: TaskDraft(title: "Newer Mac edit", deadline: task.deadline))
        pair.a.deleteTask(id: task.id)
        pair.b.localSync?.setAvailable(true); pair.a.localSync?.connect(peerB); await settle()
        await pair.a.localSync?.syncNow()
        #expect(pair.a.task(for: task.id) == nil && pair.b.task(for: task.id) == nil)
        #expect(pair.b.syncState.records["task_" + task.id.uuidString]?.payload == nil)
        stop(pair)
    }
    @Test func routinesSessionsAndAllPlanningSettingsSyncAndRecalculate() async throws {
        let pair = await makeModels()
        let task = try pair.a.addTask(TaskDraft(title: "Work", estimatedMinutesText: "120", deadline: ReminderFixtures.date(23)))
        try pair.a.logWork(taskID: task.id, minutes: 30)
        let routine = try pair.a.saveRoutine(Routine(title: "Daily", estimatedMinutesPerDay: 45, startDate: ReminderFixtures.date(0), endDate: ReminderFixtures.date(0, day: 9), recurrence: .daily))
        pair.a.setDistributionMode(.balanced); pair.a.setLocalOptimization(true)
        try pair.a.setRestSettings(maximumMinutes: 90, minimumBreakMinutes: 15)
        try pair.a.setWorkloadSettings(WorkloadSettings(maxScheduledMinutesPerDay: 300))
        try pair.a.setActivityWindow(ActivityWindow(startMinute: 780, endMinute: 1440), on: ReminderFixtures.date(0))
        await pair.a.localSync?.syncNow()
        #expect(pair.b.routines == [routine] && pair.b.completedMinutes(for: task.id) == 30)
        #expect(pair.b.remainingMinutes(for: try #require(pair.b.task(for: task.id))) == 90)
        #expect(pair.b.schedulingSettings == pair.a.schedulingSettings && pair.b.workloadSettings == pair.a.workloadSettings)
        #expect(pair.b.result.blocks.allSatisfy { $0.start >= ReminderFixtures.date(13) })
        #expect(pair.b.workSessions == pair.a.workSessions && pair.b.lastRecalculation != nil)
        let occurrence = try #require(pair.a.tasks.first { $0.routineOccurrence != nil })
        pair.a.deleteTask(id: occurrence.id)
        await pair.a.localSync?.syncNow()
        #expect(pair.b.routines.first?.skippedOccurrenceIDs.contains(occurrence.id) == true)
        stop(pair)
    }
    @Test func editsDuringExchangeAreSentInNextCoalescedRequest() async throws {
        let pair = await makeModels()
        let task = try pair.a.addTask(TaskDraft(title: "Initial", deadline: ReminderFixtures.date(23)))
        pair.al.holdsRecords = true
        let sync = _Concurrency.Task { await pair.a.localSync?.syncNow() }
        await settle(); #expect(!pair.al.held.isEmpty)
        try pair.a.updateTask(id: task.id, draft: TaskDraft(title: "Edited during sync", deadline: task.deadline))
        pair.al.holdsRecords = false; pair.al.deliverHeld(); await sync.value
        #expect(pair.b.task(for: task.id)?.title == "Edited during sync")
        #expect(pair.al.sent.filter { (try? LocalSyncEnvelope.decode($0).kind) == .records }.count == 2)
        stop(pair)
    }
    @Test func failedSaveRollsBackMemoryAndNeverAcknowledgesUntilRetry() async throws {
        let pair = await makeModels()
        let task = try pair.a.addTask(TaskDraft(title: "Keep until saved", deadline: ReminderFixtures.date(23)))
        let before = pair.b.syncState, plan = pair.b.result
        pair.bStore.fail = true
        await pair.a.localSync?.syncNow()
        #expect(pair.b.task(for: task.id) == nil && pair.b.syncState == before && pair.b.result == plan)
        #expect(pair.a.localSync?.preferences.lastSync == nil && pair.b.persistenceMessage != nil)
        #expect(!pair.bl.sent.contains { (try? LocalSyncEnvelope.decode($0).kind) == .ack })
        pair.bStore.fail = false; pair.b.retryPlanSave()
        await pair.a.localSync?.syncNow()
        #expect(pair.b.task(for: task.id) != nil && pair.bStore.value?.tasks.contains(where: { $0.id == task.id }) == true)
        stop(pair)
    }
    @Test func siriEquivalentCreationUsesNormalSaveTriggerAndLocalTransport() async throws {
        let pair = await makeModels()
        let receipt = try TaskCreationService(model: pair.a).create(title: "Siri synthetic", estimatedMinutes: 60, deadline: ReminderFixtures.date(23))
        await pair.a.localSync?.syncNow()
        #expect(pair.b.task(for: receipt.task.id) == receipt.task)
        #expect(pair.aCalendar.reads == 0 && pair.bCalendar.reads == 0)
        stop(pair)
    }
    @Test func wireAndBackupExcludeCredentialsTrustAndDeviceSchedule() async throws {
        let pair = await makeModels()
        #expect(await pair.a.applyCalendarSelection(["work"]))
        let task = try pair.a.addTask(TaskDraft(title: "Synthetic", deadline: ReminderFixtures.date(23)))
        try pair.a.startWork(taskID: task.id)
        await pair.a.localSync?.syncNow()
        let outgoing = String(decoding: try #require(pair.al.sent.first { (try? LocalSyncEnvelope.decode($0).kind) == .records }), as: UTF8.self)
        for key in ["accessToken", "refreshToken", "clientSecret", "calendarCoverage", "fixedEvents", "availableSlots", "blocks", "writebackState", "activeWorkSession", "trustedDevice", "certificateHash"] {
            #expect(!outgoing.contains(key))
            for record in pair.a.syncState.records.values {
                if let payload = record.payload {
                    let json = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
                    #expect(json[key] == nil)
                }
            }
        }
        #expect(pair.b.activeWorkSession == nil)
        let backup = String(decoding: try pair.a.makeBackup().encoded(), as: UTF8.self)
        #expect(!backup.contains("trustedDevice") && !backup.contains("certificateHash") && !backup.contains("local-sync.identity"))
        #expect(pair.b.selectedCalendarIDs.isEmpty && pair.b.fixedEvents.isEmpty)
        stop(pair)
    }
    @Test func calendarFailureAndIncompleteCoverageDoNotBlockDurableRequirements() async throws {
        let pair = await makeModels()
        #expect(await pair.b.applyCalendarSelection(["work"]))
        let coverage = try #require(pair.b.calendarCoverage)
        pair.bCalendar.fail = true; await pair.b.refreshCalendars()
        let reads = pair.bCalendar.reads
        let task = try pair.a.addTask(TaskDraft(title: "Long", estimatedMinutesText: "30000", deadline: ReminderFixtures.date(23, day: 30)))
        await pair.a.localSync?.syncNow()
        #expect(pair.b.task(for: task.id) != nil && pair.bCalendar.reads == reads && pair.b.calendarCoverage == coverage)
        #expect(pair.b.result.blocks.allSatisfy { $0.end <= coverage.end })
        #expect(pair.b.result.unscheduledTaskIDs.contains(task.id))
        stop(pair)
    }
    @Test func remindersAreNotDuplicatedAndActualMinutesMapAcrossDeviceIDs() async throws {
        let pair = await makeModels()
        for (model, identifier) in [(pair.a, "source"), (pair.b, "target")] {
            let provider = FakeReminderProvider(); provider.records = [ReminderFixtures.record(identifier, external: "same-external")]
            model.attachReminders(provider: provider, storage: MemoryReminderMetadata())
            let reminders = try #require(model.reminders)
            #expect(await reminders.applySelection(["list"]))
            try reminders.configure(identifier: identifier, estimatedMinutesText: "60", deadlineOverride: nil)
        }
        let source = try #require(pair.a.tasks.first), target = try #require(pair.b.tasks.first)
        #expect(source.id != target.id)
        try pair.a.logWork(taskID: source.id, minutes: 30)
        await pair.a.localSync?.syncNow()
        #expect(pair.a.tasks.count == 1 && pair.b.tasks.count == 1)
        #expect(pair.b.completedMinutes(for: target.id) == 30 && pair.b.remainingMinutes(for: target) == 30)
        #expect(pair.a.syncState.records.values.filter { $0.kind == .task && $0.payload != nil }.isEmpty)
        stop(pair)
    }
    @Test func localAndCloudModesAreMutuallyExclusive() async {
        let pair = await makeModels()
        pair.a.attachSyncTransport(LocalNoopCloud())
        pair.a.setSyncEnabled(true)
        #expect(pair.a.syncState.isEnabled && pair.a.localSync?.preferences.enabled == false)
        pair.a.setLocalSyncEnabled(true)
        #expect(!pair.a.syncState.isEnabled && pair.a.localSync?.preferences.enabled == true)
        stop(pair)
    }
    private func makeModels() async -> LocalModelPair {
        func make(id: UUID, link: LocalTestLink) -> (ScheduleViewModel, LocalModelStore, LocalModelCalendar) {
            let store = LocalModelStore(), provider = LocalModelCalendar()
            let seed = ScheduleViewModel(tasks: [], calendarProvider: provider, calendar: ReminderFixtures.calendar,
                clock: { ReminderFixtures.date(0) }, planStore: store)
            seed.recalculate(); store.value?.syncState?.deviceID = id
            let model = ScheduleViewModel(tasks: [], calendarProvider: provider, calendar: ReminderFixtures.calendar,
                clock: { ReminderFixtures.date(0) }, planStore: store)
            model.configureBackup(reminderStore: MemoryReminderMetadata(), journal: LocalModelJournal(), deviceID: id)
            model.configureLocalSync(link: link, store: LocalPreferenceMemory(value: preferences(id, trusted: true)))
            model.localSync?.setAvailable(true)
            return (model, store, provider)
        }
        let al = LocalTestLink(id: localA, hash: hashA), bl = LocalTestLink(id: localB, hash: hashB); al.other = bl; bl.other = al
        let (a, aStore, aCalendar) = make(id: localA, link: al), (b, bStore, bCalendar) = make(id: localB, link: bl)
        a.localSync?.connect(peerB); await settle()
        return LocalModelPair(a: a, b: b, al: al, bl: bl, aStore: aStore, bStore: bStore, aCalendar: aCalendar, bCalendar: bCalendar)
    }
    private func stop(_ pair: LocalModelPair) { pair.a.localSync?.setAvailable(false); pair.b.localSync?.setAvailable(false) }
}
@MainActor private struct LocalModelPair {
    let a: ScheduleViewModel, b: ScheduleViewModel
    let al: LocalTestLink, bl: LocalTestLink
    let aStore: LocalModelStore, bStore: LocalModelStore
    let aCalendar: LocalModelCalendar, bCalendar: LocalModelCalendar
}
@MainActor private final class LocalModelStore: PlanSnapshotStoring {
    var value: PlanSnapshot?, fail = false
    func load() throws -> PlanSnapshot? { value }
    func save(_ snapshot: PlanSnapshot) throws { if fail { throw PlanStorageError.unavailable }; try snapshot.validate(); value = snapshot }
}
@MainActor private final class LocalModelCalendar: CalendarProviding {
    var authorization: CalendarAuthorization = .connected
    var reads = 0, fail = false
    func requestAccess() async throws -> CalendarAuthorization { authorization }
    func loadCalendars() async throws -> [CalendarSource] { [CalendarSource(id: "work", title: "Synthetic", accountTitle: "Test")] }
    func loadEvents(in range: DateInterval, calendarIDs: Set<String>) async throws -> [FixedEvent] {
        reads += 1; if fail { throw CalendarServiceError.calendarUnavailable }
        return [FixedEvent(id: "meeting", calendarID: "work", title: "Synthetic meeting", start: ReminderFixtures.date(12), end: ReminderFixtures.date(13))]
    }
}
@MainActor private final class LocalModelJournal: BackupJournalStoring {
    var value: PersonalGanttBackup?
    func load() throws -> PersonalGanttBackup? { value }
    func save(_ backup: PersonalGanttBackup) throws { value = backup }
    func remove() throws { value = nil }
}
@MainActor private final class LocalNoopCloud: SyncTransport {
    func exchange(_ records: [SyncRecord]) async throws -> [SyncRecord] { records }
}
