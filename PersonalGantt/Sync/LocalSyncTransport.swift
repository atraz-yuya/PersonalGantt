import Foundation
import Observation
import CryptoKit

/// Same entity exchange interface as CloudKit; inbound application is delegated
/// to the model's existing validated LWW merge, with durable-save confirmation.
@MainActor @Observable final class LocalSyncTransport: SyncTransport {
    private(set) var preferences = LocalSyncPreferences()
    private(set) var peers: [LocalPeer] = []
    private(set) var status = "未設定"
    private(set) var message: String?
    private(set) var pairingPeer: LocalPeer?
    private(set) var pairingCode: String?
    private(set) var isPairing = false
    private(set) var isSyncing = false
    private(set) var isConnected = false
    let deviceID: UUID
    let displayName: String
    @ObservationIgnored private let link: any LocalSyncLink
    @ObservationIgnored private let store: any LocalSyncPreferenceStoring
    @ObservationIgnored private let snapshot: () throws -> [SyncRecord]
    @ObservationIgnored private let apply: ([SyncRecord]) throws -> Void
    @ObservationIgnored private var available = false
    @ObservationIgnored private var preferencesLoaded = false
    @ObservationIgnored private var running = false
    @ObservationIgnored private var currentPeer: LocalPeer?
    @ObservationIgnored private var remoteHash: Data?
    @ObservationIgnored private var localHello: LocalHello?
    @ObservationIgnored private var remoteHello: LocalHello?
    @ObservationIgnored private var approved = false
    @ObservationIgnored private var remoteApproved = false
    @ObservationIgnored private var remoteReady = false
    @ObservationIgnored private var applying = false
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var pendingID: UUID?
    @ObservationIgnored private var continuation: CheckedContinuation<[SyncRecord], any Error>?
    @ObservationIgnored private var debounce: _Concurrency.Task<Void, Never>?
    @ObservationIgnored private var timeout: _Concurrency.Task<Void, Never>?
    @ObservationIgnored private var pairingExpiry: _Concurrency.Task<Void, Never>?
    @ObservationIgnored private var handshakeTimeout: _Concurrency.Task<Void, Never>?
    @ObservationIgnored private var retryTimer: _Concurrency.Task<Void, Never>?
    @ObservationIgnored private var attemptedAt: [Date] = []
    @ObservationIgnored private var received: [UUID: Data] = [:]
    @ObservationIgnored private var receivedOrder: [UUID] = []
    @ObservationIgnored private let acknowledgementDelay: Duration

    init(deviceID: UUID, displayName: String, link: any LocalSyncLink, store: any LocalSyncPreferenceStoring,
         acknowledgementDelay: Duration = .seconds(8), snapshot: @escaping () throws -> [SyncRecord], apply: @escaping ([SyncRecord]) throws -> Void) {
        self.deviceID = deviceID; self.displayName = displayName; self.link = link; self.store = store
        self.snapshot = snapshot; self.apply = apply; self.acknowledgementDelay = acknowledgementDelay
        do {
            let value = try store.load(); guard value.isValid else { throw LocalSyncError.storage }
            preferences = value; preferencesLoaded = true; status = value.enabled ? "オフライン" : "未設定"
        } catch { message = LocalSyncError.storage.localizedDescription }
        link.onEvent = { [weak self] event in self?.receive(event) }
    }
    var canPair: Bool { preferences.trustedDevice == nil }
    func setEnabled(_ enabled: Bool) {
        do {
            if !preferencesLoaded {
                let value = try store.load(); guard value.isValid else { throw LocalSyncError.storage }
                preferences = value; preferencesLoaded = true
            }
            var next = preferences; next.enabled = enabled; try store.save(next); preferences = next
            message = nil
            if enabled { startIfAvailable() } else { stop(); status = "未設定" }
        } catch { message = LocalSyncError.storage.localizedDescription }
    }
    /// iOS stops when backgrounded. Mac remains available while its app is running.
    func setAvailable(_ available: Bool) {
        self.available = available
        if available { attemptedAt = []; startIfAvailable(); localRecordsDidChange() }
        else { stop(); status = preferences.enabled ? "オフライン" : "未設定" }
    }
    func beginPairing() {
        guard canPair else { return }
        if !preferences.enabled { setEnabled(true) }
        guard preferences.enabled, canPair else { return }
        isPairing = true; attemptedAt = []; message = nil
        restartDiscovery()
        pairingExpiry?.cancel()
        pairingExpiry = _Concurrency.Task { [weak self] in
            do { try await _Concurrency.Task.sleep(for: .seconds(120)) } catch { return }
            self?.endPairing()
        }
    }
    func endPairing() {
        isPairing = false; pairingExpiry?.cancel(); pairingExpiry = nil
        if preferences.trustedDevice == nil { link.disconnect(); clearConnection(); restartDiscovery() }
    }
    func connect(_ peer: LocalPeer) {
        guard running, isPairing || preferences.trustedDevice?.deviceID == peer.id, !isConnected else { return }
        do { status = "接続中"; try link.connect(peer) } catch { fail(.network) }
    }
    func approvePairing() {
        guard isPairing, pairingPeer != nil, pairingCode != nil, remoteHello != nil else { return }
        do {
            approved = true
            try send(LocalSyncEnvelope(kind: .approve))
            try finishPairingIfReady()
        } catch { fail(error as? LocalSyncError ?? .network) }
    }
    func rejectPairing() { endPairing(); message = "ペアリングを拒否しました。" }
    func unpair() {
        do {
            var next = preferences; next.trustedDevice = nil; next.lastSync = nil
            try store.save(next); preferences = next
            isPairing = false; stop(); status = "未設定"; message = "ペアリングを解除しました。端末内の作業は保持します。"
            startIfAvailable()
        } catch { message = LocalSyncError.storage.localizedDescription }
    }
    func localRecordsDidChange() {
        guard !applying, available, preferences.enabled else { return }
        dirty = true
        guard !isSyncing else { return }
        debounce?.cancel()
        debounce = _Concurrency.Task { [weak self] in
            do { try await _Concurrency.Task.sleep(for: .milliseconds(700)) } catch { return }
            await self?.syncNow()
        }
    }
    func syncNow() async {
        guard available, preferences.enabled else { return }
        startIfAvailable()
        guard preferences.trustedDevice != nil else { if !isPairing { status = "未設定" }; return }
        guard isConnected else {
            autoConnect()
            if currentPeer == nil { status = peers.isEmpty ? "相手が見つからない" : "接続待ち"; message = LocalSyncError.offline.localizedDescription }
            return
        }
        guard !isSyncing else { dirty = true; return }
        isSyncing = true
        defer { isSyncing = false }
        repeat {
            dirty = false
            do { _ = try await exchange(snapshot()) }
            catch {
                guard available, preferences.enabled, preferences.trustedDevice != nil else { return }
                message = (error as? LocalSyncError ?? .network).localizedDescription; status = "同期エラー"; return
            }
        } while dirty && available && preferences.enabled && isConnected && !_Concurrency.Task.isCancelled
    }
    func exchange(_ records: [SyncRecord]) async throws -> [SyncRecord] {
        guard authorized, remoteReady else { throw LocalSyncError.untrusted }
        guard continuation == nil else { throw LocalSyncError.network }
        let envelope = LocalSyncEnvelope(kind: .records, records: records), data = try envelope.encoded()
        let id = envelope.messageID
        status = "同期中"; pendingID = id
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { promise in
                continuation = promise
                do { try link.send(data) }
                catch { finishRequest(.failure(LocalSyncError.network)); return }
                timeout = _Concurrency.Task { [weak self] in
                    for attempt in 0..<3 {
                        do { try await _Concurrency.Task.sleep(for: self?.acknowledgementDelay ?? .seconds(8)) } catch { return }
                        guard let self, self.pendingID == id else { return }
                        if attempt == 2 { self.finishRequest(.failure(LocalSyncError.timeout)); return }
                        do { try self.link.send(data) } catch { self.finishRequest(.failure(LocalSyncError.network)); return }
                    }
                }
            }
        } onCancel: { [weak self] in
            _Concurrency.Task { @MainActor in if self?.pendingID == id { self?.finishRequest(.failure(CancellationError())) } }
        }
    }
    private var authorized: Bool {
        guard let trusted = preferences.trustedDevice, let currentPeer, let remoteHash, let remoteHello else { return false }
        return trusted.deviceID == currentPeer.id && trusted.deviceID == remoteHello.deviceID && trusted.certificateHash == remoteHash
    }
    private func startIfAvailable() {
        guard available, preferences.enabled, !running else { return }
        do {
            try link.start(pairing: isPairing, trusted: preferences.trustedDevice)
            running = true; status = isPairing || preferences.trustedDevice != nil ? "検索中" : "未設定"
        } catch { fail(error as? LocalSyncError ?? .network) }
    }
    private func restartDiscovery() {
        link.stop(); running = false; clearConnection(); peers = []; startIfAvailable()
    }
    private func stop() {
        debounce?.cancel(); timeout?.cancel(); pairingExpiry?.cancel(); retryTimer?.cancel(); handshakeTimeout?.cancel()
        isPairing = false; link.stop(); running = false; peers = []; clearConnection()
    }
    private func clearConnection() {
        finishRequest(.failure(LocalSyncError.offline))
        currentPeer = nil; remoteHash = nil; localHello = nil; remoteHello = nil
        approved = false; remoteApproved = false; remoteReady = false
        pairingPeer = nil; pairingCode = nil; isConnected = false
        handshakeTimeout?.cancel(); received = [:]; receivedOrder = []
    }
    private func autoConnect() {
        guard running, currentPeer == nil, let trusted = preferences.trustedDevice,
              deviceID.uuidString < trusted.deviceID.uuidString, let peer = peers.first(where: { $0.id == trusted.deviceID }) else { return }
        attemptedAt.removeAll { Date().timeIntervalSince($0) >= 60 }
        guard attemptedAt.count < 3, attemptedAt.last.map({ Date().timeIntervalSince($0) >= 10 }) ?? true else { return }
        attemptedAt.append(Date()); connect(peer)
    }
    private func receive(_ event: LocalLinkEvent) {
        guard running else { return }
        switch event {
        case .found(let peer):
            guard peer.id != deviceID, isPairing || preferences.trustedDevice?.deviceID == peer.id, peers.count < 64 || peers.contains(where: { $0.id == peer.id }) else { return }
            peers.removeAll { $0.id == peer.id }; peers.append(peer); peers.sort { $0.name < $1.name }; autoConnect()
        case .lost(let id): peers.removeAll { $0.id == id }
        case .connecting: status = "接続中"
        case .connected(let peer, let hash):
            guard hash.count == 32, peer.id != deviceID, currentPeer == nil,
                  isPairing || preferences.trustedDevice.map({ $0.deviceID == peer.id && $0.certificateHash == hash }) == true else { fail(.untrusted); return }
            currentPeer = peer; remoteHash = hash
            localHello = LocalHello(deviceID: deviceID, name: displayName, nonce: UUID(), pairing: isPairing)
            do { try send(LocalSyncEnvelope(kind: .hello, hello: localHello)) } catch { fail(.network); return }
            handshakeTimeout = _Concurrency.Task { [weak self] in
                do { try await _Concurrency.Task.sleep(for: .seconds(15)) } catch { return }
                guard let self, !self.isConnected, self.pairingPeer == nil else { return }; self.fail(.timeout)
            }
        case .received(let data):
            do { try handle(LocalSyncEnvelope.decode(data), raw: data) }
            catch { fail(error as? LocalSyncError ?? .invalidData) }
        case .disconnected:
            clearConnection(); if message == nil { status = "オフライン" }
            retryTimer?.cancel()
            retryTimer = _Concurrency.Task { [weak self] in
                do { try await _Concurrency.Task.sleep(for: .seconds(15)) } catch { return }
                self?.autoConnect()
            }
        case .failed(let error):
            link.stop(); running = false; fail(error)
        case .incompatiblePeer:
            if currentPeer == nil { status = "バージョン不一致"; message = LocalSyncError.version.localizedDescription }
        }
    }
    private func handle(_ envelope: LocalSyncEnvelope, raw: Data) throws {
        guard currentPeer != nil else { throw LocalSyncError.untrusted }
        switch envelope.kind {
        case .hello:
            guard remoteHello == nil, let hello = envelope.hello, hello.deviceID == currentPeer?.id, let localHello, let remoteHash else { throw LocalSyncError.untrusted }
            remoteHello = hello
            if authorized && !isPairing && !hello.pairing {
                try send(LocalSyncEnvelope(kind: .ready))
            } else {
                guard isPairing, preferences.trustedDevice == nil else { throw LocalSyncError.untrusted }
                pairingPeer = currentPeer
                pairingCode = LocalSyncEnvelope.pairingCode(local: localHello, localHash: link.certificateHash, remote: hello, remoteHash: remoteHash)
                status = "両端末で確認待ち"
            }
        case .approve:
            guard pairingPeer != nil else { throw LocalSyncError.untrusted }
            remoteApproved = true; try finishPairingIfReady()
        case .ready:
            guard authorized else { throw LocalSyncError.untrusted }
            remoteReady = true; isConnected = true; handshakeTimeout?.cancel(); status = "接続済み"; message = nil
            localRecordsDidChange()
        case .records:
            guard authorized, remoteReady, let records = envelope.records else { throw LocalSyncError.untrusted }
            let digest = Data(SHA256.hash(data: raw))
            if let previous = received[envelope.messageID], previous != digest { throw LocalSyncError.invalidData }
            do {
                if received[envelope.messageID] == nil {
                    try applyIncoming(records)
                    received[envelope.messageID] = digest; receivedOrder.append(envelope.messageID)
                    if receivedOrder.count > LocalSyncConstants.rememberedMessages { received.removeValue(forKey: receivedOrder.removeFirst()) }
                }
                try recordSuccess()
                try send(LocalSyncEnvelope(messageID: envelope.messageID, kind: .ack, records: snapshot()))
            } catch {
                try? send(LocalSyncEnvelope(messageID: envelope.messageID, kind: .failure, failure: .storage))
                message = LocalSyncError.storage.localizedDescription; status = "同期エラー"
            }
        case .ack:
            guard authorized, remoteReady, pendingID == envelope.messageID, let records = envelope.records else { return }
            do { try applyIncoming(records); try recordSuccess(); finishRequest(.success(records)) }
            catch { finishRequest(.failure(LocalSyncError.storage)); throw LocalSyncError.storage }
        case .failure:
            guard authorized, pendingID == envelope.messageID else { return }
            finishRequest(.failure(LocalSyncError.storage))
        }
    }
    private func finishPairingIfReady() throws {
        guard approved, remoteApproved, let peer = currentPeer, let hash = remoteHash else { return }
        var next = preferences
        next.trustedDevice = LocalTrustedDevice(deviceID: peer.id, name: remoteHello?.name ?? peer.name, certificateHash: hash, pairedAt: Date())
        try store.save(next); preferences = next
        link.updateTrust(next.trustedDevice!)
        pairingPeer = nil; pairingCode = nil; isPairing = false; pairingExpiry?.cancel()
        // Keep the active encrypted session; discovery metadata updates on the next start.
        try send(LocalSyncEnvelope(kind: .ready))
    }
    private func applyIncoming(_ records: [SyncRecord]) throws {
        applying = true; defer { applying = false }
        try apply(records)
    }
    private func recordSuccess() throws {
        var next = preferences; next.lastSync = Date(); try store.save(next); preferences = next
        status = "同期済み"; message = nil
    }
    private func send(_ envelope: LocalSyncEnvelope) throws { try link.send(envelope.encoded()) }
    private func finishRequest(_ result: Result<[SyncRecord], any Error>) {
        guard let promise = continuation else { pendingID = nil; return }
        continuation = nil; pendingID = nil; timeout?.cancel(); timeout = nil; promise.resume(with: result)
    }
    private func fail(_ error: LocalSyncError) {
        message = error.localizedDescription; status = error == .version ? "バージョン不一致" : "同期エラー"
        clearConnection(); link.disconnect()
    }
}
