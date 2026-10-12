import Foundation
@preconcurrency import Network
@preconcurrency import Security
import CryptoKit

/// Mutual TLS over Bonjour TCP. Uses precisely the same RSA identity and pins as MPC.
@MainActor final class NetworkLocalLink: LocalSyncLink {
    static let serviceType = "_pgantt-link._tcp" // MPC's service carries a different wire protocol.
    var onEvent: ((LocalLinkEvent) -> Void)?
    private(set) var certificateHash = Data()
    private let deviceID: UUID
    private let name: String
    private let queue = DispatchQueue(label: "com.atraz.PersonalGantt.network-link")
    private var identity: SecIdentity?
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var outgoingID: UUID?
    private var token = UUID()
    private var generation = UUID()
    private var trusted: LocalTrustedDevice?
    private var pairing = false
    private var discovered: [UUID: (LocalPeer, NWEndpoint)] = [:]
    private var activePeer: LocalPeer?
    private var framer = LocalSyncFrame()
    private var deadline: _Concurrency.Task<Void, Never>?
    init(deviceID: UUID, name: String) { self.deviceID = deviceID; self.name = name }

    func start(pairing: Bool, trusted: LocalTrustedDevice?) throws {
        stop(); self.pairing = pairing; self.trusted = trusted
        try LocalSyncIdentity.requireCompatibleIdentity(deviceID: deviceID, trusted: trusted)
        let (identity, hash) = try LocalSyncIdentity.load(deviceID: deviceID)
        self.identity = identity; certificateHash = hash
        let listener = try NWListener(using: parameters(expected: nil))
        self.listener = listener
        listener.service = NWListener.Service(name: deviceID.uuidString, type: Self.serviceType,
            txtRecord: NWTXTRecord(["id": deviceID.uuidString, "name": name,
                "version": String(LocalSyncConstants.protocolVersion), "pair": pairing ? "1" : "0"]))
        let generation = self.generation
        listener.stateUpdateHandler = { [weak self] state in
            _Concurrency.Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                if case .failed(let error) = state { self.logError("listener.failed", error); self.onEvent?(.failed(.network)) }
                if case .ready = state { LocalSyncDiagnostics.log("network.listener.ready", detail: "includePeerToPeer=true") }
            }
        }
        listener.newConnectionHandler = { [weak self] incoming in
            _Concurrency.Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { incoming.cancel(); return }
                // If both ends dial, the smaller UUID's outbound connection wins.
                if self.connection != nil {
                    guard self.activePeer == nil, let id = self.outgoingID, self.deviceID.uuidString > id.uuidString else { incoming.cancel(); return }
                    self.cancelConnection()
                }
                self.begin(incoming, outgoing: nil)
            }
        }
        listener.start(queue: queue); startBrowser()
    }
    func updateTrust(_ trusted: LocalTrustedDevice) { self.trusted = trusted; pairing = false }
    func stop() {
        generation = UUID(); listener?.cancel(); listener = nil; browser?.cancel(); browser = nil
        cancelConnection(); discovered = [:]; identity = nil
    }
    func disconnect() { cancelConnection(); if listener != nil { startBrowser() } }
    func connect(_ peer: LocalPeer) throws {
        guard connection == nil, let (_, endpoint) = discovered[peer.id] else { throw LocalSyncError.offline }
        guard trusted?.deviceID == peer.id || pairing && peer.pairing else { throw LocalSyncError.untrusted }
        begin(NWConnection(to: endpoint, using: try parameters(expected: peer.id)), outgoing: peer.id)
    }
    func send(_ data: Data) throws {
        guard let connection, activePeer != nil else { throw LocalSyncError.offline }
        let frame = try LocalSyncFrame.encode(data), token = self.token
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            _Concurrency.Task { @MainActor [weak self] in
                guard let self, self.token == token else { return }
                self.logError("send.failed", error); self.connectionFailed(.network)
            }
        })
    }
    private func parameters(expected: UUID?) throws -> NWParameters {
        guard let identity, let secIdentity = sec_identity_create(identity) else { throw LocalSyncError.storage }
        let tls = NWProtocolTLS.Options(), options = tls.securityProtocolOptions
        sec_protocol_options_set_local_identity(options, secIdentity)
        sec_protocol_options_set_peer_authentication_required(options, true)
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_tls_tickets_enabled(options, false)
        sec_protocol_options_set_tls_resumption_enabled(options, false)
        let generation = self.generation
        sec_protocol_options_set_verify_block(options, { [weak self] _, trust, complete in
            let chain = SecTrustCopyCertificateChain(sec_trust_copy_ref(trust).takeRetainedValue()) as? [SecCertificate]
            let proof = chain?.first.flatMap(Self.proof)
            _Concurrency.Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { complete(false); return }
                let decision = self.decision(proof, expected: expected)
                LocalSyncDiagnostics.log("network.certificate.callback", peer: proof?.id.uuidString,
                    fingerprint: proof?.hash, detail: "accept=\(decision.accepted) reason=\(decision.rawValue) outgoing=\(expected != nil)")
                complete(decision.accepted)
            }
        }, queue)
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true; tcp.connectionTimeout = 8
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }
    nonisolated private static func proof(_ certificate: SecCertificate) -> (id: UUID, hash: Data)? {
        guard let subject = SecCertificateCopySubjectSummary(certificate) as String?, let id = UUID(uuidString: subject) else { return nil }
        return (id, Data(SHA256.hash(data: SecCertificateCopyData(certificate) as Data)))
    }
    private func decision(_ proof: (id: UUID, hash: Data)?, expected: UUID?) -> LocalCertificateDecision {
        let peer = proof.flatMap { knownPeer($0.id) }
        return LocalCertificateDecision.evaluate(hash: proof?.hash, peer: peer,
            expected: proof?.id == (expected ?? trusted?.deviceID),
            anotherPeerExpected: expected.map { proof?.id != $0 } ?? false,
            pairing: pairing, trusted: trusted)
    }
    private func knownPeer(_ id: UUID) -> LocalPeer? {
        if let peer = discovered[id]?.0 { return peer }
        if let trusted, trusted.deviceID == id { return LocalPeer(id: id, name: trusted.name, pairing: false) }
        return nil
    }
    private func startBrowser() {
        guard browser == nil, listener != nil else { return }
        let parameters = NWParameters.tcp; parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: parameters)
        self.browser = browser; let generation = self.generation
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            _Concurrency.Task { @MainActor [weak self] in
                guard let self, self.generation == generation, self.browser === browser else { return }
                var found: Set<UUID> = []
                for result in results {
                    guard case .bonjour(let txt) = result.metadata, let idString = txt["id"], let id = UUID(uuidString: idString), id != self.deviceID,
                          self.pairing || self.trusted?.deviceID == id else { continue }
                    guard txt["version"] == String(LocalSyncConstants.protocolVersion) else { self.onEvent?(.incompatiblePeer); continue }
                    guard let name = txt["name"], !name.isEmpty, name.utf8.count <= 63, txt["pair"] == "0" || txt["pair"] == "1",
                          self.discovered.count < 64 || self.discovered[id] != nil else { continue }
                    let peer = LocalPeer(id: id, name: name, pairing: txt["pair"] == "1")
                    found.insert(id); self.discovered[id] = (peer, result.endpoint)
                    let interfaces = result.interfaces.map { "\($0.name):\($0.type)" }.joined(separator: ",")
                    LocalSyncDiagnostics.log("network.discovery", peer: name, detail: "id=\(id) interfaces=\(interfaces) includePeerToPeer=true")
                    self.onEvent?(.found(peer))
                }
                for id in Array(self.discovered.keys) where !found.contains(id) && self.activePeer?.id != id && self.outgoingID != id {
                    self.discovered.removeValue(forKey: id); self.onEvent?(.lost(id))
                }
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            _Concurrency.Task { @MainActor [weak self] in
                guard let self, self.generation == generation, self.browser === browser else { return }
                if case .failed(let error) = state { self.logError("browser.failed", error); self.onEvent?(.failed(.network)) }
                if case .waiting(let error) = state { self.logError("browser.waiting", error) }
            }
        }
        browser.start(queue: queue)
    }
    private func begin(_ connection: NWConnection, outgoing: UUID?) {
        browser?.cancel(); browser = nil // TN3213: stop P2P browsing before connecting.
        self.connection = connection; outgoingID = outgoing; token = UUID(); let token = self.token
        framer = LocalSyncFrame(); onEvent?(.connecting)
        LocalSyncDiagnostics.log("network.connection.start", peer: outgoing?.uuidString, detail: "includePeerToPeer=true direction=\(outgoing == nil ? "incoming" : "outgoing")")
        connection.stateUpdateHandler = { [weak self] state in
            _Concurrency.Task { @MainActor [weak self] in
                guard let self, self.token == token, self.connection === connection else { return }
                switch state {
                case .ready: self.ready(connection)
                case .failed(let error): self.logError("connection.failed", error); self.connectionFailed(.network)
                case .waiting(let error): self.logError("connection.waiting", error)
                case .cancelled: self.connectionFailed(.offline)
                default: LocalSyncDiagnostics.log("network.connection.state", detail: "state=\(state)")
                }
            }
        }
        connection.pathUpdateHandler = { path in
            LocalSyncDiagnostics.log("network.path", detail: "status=\(path.status) interfaces=\(path.availableInterfaces.map { "\($0.name):\($0.type)" }.joined(separator: ",")) includePeerToPeer=true")
        }
        deadline = _Concurrency.Task { [weak self] in
            do { try await _Concurrency.Task.sleep(for: .seconds(8)) } catch { return }
            guard let self, self.token == token, self.activePeer == nil else { return }
            LocalSyncDiagnostics.log("network.connection.timeout"); self.connectionFailed(.timeout)
        }
        connection.start(queue: queue)
    }
    private func ready(_ connection: NWConnection) {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { connectionFailed(.untrusted); return }
        var proof: (id: UUID, hash: Data)?
        sec_protocol_metadata_access_peer_certificate_chain(metadata.securityProtocolMetadata) { certificate in
            if proof == nil { proof = Self.proof(sec_certificate_copy_ref(certificate).takeRetainedValue()) }
        }
        guard let proof, decision(proof, expected: outgoingID).accepted, let peer = knownPeer(proof.id) else { connectionFailed(.untrusted); return }
        deadline?.cancel(); activePeer = peer
        LocalSyncDiagnostics.log("network.connection.connected", peer: peer.name, fingerprint: proof.hash, detail: "id=\(peer.id) mutualTLS=true")
        onEvent?(.connected(peer, certificateHash: proof.hash)); read(connection, token: token)
    }
    private func read(_ connection: NWConnection, token: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            _Concurrency.Task { @MainActor [weak self] in
                guard let self, self.token == token, self.connection === connection else { return }
                do {
                    var messages: [Data] = []
                    if let data { try self.framer.append(data) { messages.append($0) } }
                    for message in messages {
                        guard self.token == token else { return }; self.onEvent?(.received(message))
                    }
                    if let error { self.logError("receive.failed", error); self.connectionFailed(.network); return }
                    if complete { try self.framer.finish(); self.connectionFailed(.offline); return }
                    self.read(connection, token: token)
                } catch { self.connectionFailed(error as? LocalSyncError ?? .invalidData) }
            }
        }
    }
    private func cancelConnection() {
        token = UUID(); deadline?.cancel(); deadline = nil; connection?.cancel(); connection = nil
        outgoingID = nil; activePeer = nil; framer = LocalSyncFrame()
    }
    private func connectionFailed(_ error: LocalSyncError) {
        cancelConnection(); startBrowser()
        if error == .offline { onEvent?(.disconnected) } else { onEvent?(.failed(error)) }
    }
    private func logError(_ event: String, _ error: NWError) {
        let detail: String
        switch error {
        case .posix(let code): detail = "posix=\(code.rawValue)"
        case .dns(let code): detail = "dns=\(code)"
        case .tls(let code): detail = "tls=\(code)"
        @unknown default: detail = "unknown"
        }
        LocalSyncDiagnostics.log("network." + event, detail: detail)
    }
}
