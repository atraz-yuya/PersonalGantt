import Foundation

/// One peer identity, one active transport. Non-winning callbacks never reach the protocol.
@MainActor final class AdaptiveLocalLink: LocalSyncLink {
    private enum Route: String { case network, multipeer }
    var onEvent: ((LocalLinkEvent) -> Void)?
    var certificateHash: Data { networkAvailable ? network.certificateHash : multipeer.certificateHash }
    private let network: any LocalSyncLink
    private let multipeer: any LocalSyncLink
    private var candidates: [Route: [UUID: LocalPeer]] = [:]
    private var winner: Route?
    private var connecting: Route?
    private var target: LocalPeer?
    private var fallbackEligible = false
    private var running = false
    private var networkAvailable = false
    private var multipeerAvailable = false
    private var fallback: _Concurrency.Task<Void, Never>?
    private var deadline: _Concurrency.Task<Void, Never>?
    private let fallbackDelay: Duration
    private let connectionDelay: Duration
    init(deviceID: UUID, name: String) {
        network = NetworkLocalLink(deviceID: deviceID, name: name)
        multipeer = MultipeerLocalLink(deviceID: deviceID, name: name)
        fallbackDelay = .seconds(3); connectionDelay = .seconds(14); installHandlers()
    }
    init(network: any LocalSyncLink, multipeer: any LocalSyncLink,
         fallbackDelay: Duration = .seconds(3), connectionDelay: Duration = .seconds(14)) {
        self.network = network; self.multipeer = multipeer
        self.fallbackDelay = fallbackDelay; self.connectionDelay = connectionDelay; installHandlers()
    }
    private func installHandlers() {
        network.onEvent = { [weak self] in self?.receive($0, route: .network) }
        multipeer.onEvent = { [weak self] in self?.receive($0, route: .multipeer) }
    }
    func start(pairing: Bool, trusted: LocalTrustedDevice?) throws {
        stop(); running = true
        do { try network.start(pairing: pairing, trusted: trusted); networkAvailable = true }
        catch let error as LocalSyncError where error == .storage || error == .identityUpgrade || error == .untrusted { stop(); throw error }
        catch { LocalSyncDiagnostics.log("transport.unavailable", detail: "route=network") }
        do { try multipeer.start(pairing: pairing, trusted: trusted); multipeerAvailable = true }
        catch { LocalSyncDiagnostics.log("transport.unavailable", detail: "route=multipeer") }
        guard networkAvailable || multipeerAvailable else { stop(); throw LocalSyncError.network }
        if networkAvailable, multipeerAvailable, network.certificateHash != multipeer.certificateHash { stop(); throw LocalSyncError.untrusted }
    }
    func updateTrust(_ trusted: LocalTrustedDevice) { network.updateTrust(trusted); multipeer.updateTrust(trusted) }
    func stop() {
        running = false; reset(); candidates = [:]; networkAvailable = false; multipeerAvailable = false
        network.stop(); multipeer.stop()
    }
    func disconnect() { reset(); network.disconnect(); multipeer.disconnect() }
    func connect(_ peer: LocalPeer) throws {
        guard running, winner == nil, target == nil else { throw LocalSyncError.network }
        target = peer; onEvent?(.connecting); armDeadline()
        if networkAvailable, candidates[.network]?[peer.id] != nil { dial(.network, peer: peer) }
        else {
            // Briefly allow the primary discovery to catch up with MPC discovery.
            LocalSyncDiagnostics.log("transport.primary.search", peer: peer.name)
        }
        fallback = _Concurrency.Task { [weak self] in
            do { try await _Concurrency.Task.sleep(for: self?.fallbackDelay ?? .seconds(3)) } catch { return }
            guard let self, self.winner == nil else { return }; self.fallbackEligible = true; self.tryFallback(reason: "primaryTimeout")
        }
    }
    func send(_ data: Data) throws {
        guard let winner else { throw LocalSyncError.offline }; try link(winner).send(data)
    }
    private func link(_ route: Route) -> any LocalSyncLink { route == .network ? network : multipeer }
    private func dial(_ route: Route, peer: LocalPeer) {
        connecting = route
        LocalSyncDiagnostics.log("transport.connect", peer: peer.name, detail: "id=\(peer.id) route=\(route.rawValue)")
        do { try link(route).connect(peer) }
        catch { receive(.failed(error as? LocalSyncError ?? .network), route: route) }
    }
    private func tryFallback(reason: String) {
        guard winner == nil, connecting != .multipeer, let target,
              multipeerAvailable, let peer = candidates[.multipeer]?[target.id] else { return }
        LocalSyncDiagnostics.log("transport.fallback", peer: peer.name, detail: "from=network to=multipeer reason=\(reason)")
        // Cancel the pending primary before dialing the fallback.
        connecting = .multipeer; network.disconnect(); dial(.multipeer, peer: peer)
    }
    private func armDeadline() {
        deadline?.cancel()
        deadline = _Concurrency.Task { [weak self] in
            do { try await _Concurrency.Task.sleep(for: self?.connectionDelay ?? .seconds(14)) } catch { return }
            guard let self, self.winner == nil else { return }
            LocalSyncDiagnostics.log("transport.connection.timeout"); self.disconnect(); self.onEvent?(.failed(.timeout))
        }
    }
    private func reset() {
        fallbackEligible = false; winner = nil; connecting = nil; target = nil; fallback?.cancel(); fallback = nil; deadline?.cancel(); deadline = nil
    }
    private func receive(_ event: LocalLinkEvent, route: Route) {
        guard running else { return }
        switch event {
        case .found(let peer):
            guard candidates[route]?[peer.id] != nil || (candidates[route]?.count ?? 0) < 64 else { return }
            candidates[route, default: [:]][peer.id] = peer
            LocalSyncDiagnostics.log("transport.candidate", peer: peer.name, detail: "id=\(peer.id) route=\(route.rawValue)")
            if winner == nil, target?.id == peer.id {
                if route == .network, connecting == nil { dial(.network, peer: peer) }
                if route == .multipeer, connecting != .multipeer, (!networkAvailable || fallbackEligible) { tryFallback(reason: "primaryUnavailable") }
            }
            onEvent?(.found(candidates[.network]?[peer.id] ?? peer))
        case .lost(let id):
            candidates[route]?.removeValue(forKey: id)
            if let peer = candidates[.network]?[id] ?? candidates[.multipeer]?[id] { onEvent?(.found(peer)) }
            else { onEvent?(.lost(id)) }
        case .connecting:
            if winner == nil { if target == nil { armDeadline() }; onEvent?(.connecting) }
        case .connected(let peer, let hash):
            guard winner == nil else { if winner != route { link(route).disconnect() }; return }
            guard target == nil || target?.id == peer.id, hash.count == 32 else { link(route).disconnect(); return }
            winner = route; target = peer; connecting = nil; deadline?.cancel(); fallback?.cancel()
            LocalSyncDiagnostics.log("transport.winner", peer: peer.name, fingerprint: hash, detail: "id=\(peer.id) route=\(route.rawValue)")
            link(route == .network ? .multipeer : .network).disconnect()
            onEvent?(.connected(peer, certificateHash: hash))
        case .received:
            if winner == route { onEvent?(event) }
        case .disconnected, .failed:
            guard winner == nil || winner == route else { return }
            if winner == route { reset(); onEvent?(event); return }
            guard connecting == route else { return }
            if case .failed(let error) = event, error == .untrusted || error == .identityUpgrade || error == .storage {
                disconnect(); onEvent?(event); return
            }
            if route == .network { connecting = nil; tryFallback(reason: "primaryFailed") }
            else { reset(); onEvent?(event) }
        case .incompatiblePeer: onEvent?(event)
        }
    }
}
