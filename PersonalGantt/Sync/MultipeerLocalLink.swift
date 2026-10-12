import Foundation
import CryptoKit
@preconcurrency import MultipeerConnectivity
@preconcurrency import Security
#if os(iOS)
import UIKit
#endif

/// SDK adapter only: all domain validation, trust and merge are outside this class.
@available(macOS, introduced: 10.10, deprecated: 27.0, message: "The SDK adapter can be replaced with Network framework.")
@available(iOS, introduced: 7.0, deprecated: 27.0, message: "The SDK adapter can be replaced with Network framework.")
@MainActor final class MultipeerLocalLink: NSObject, LocalSyncLink {
    var onEvent: ((LocalLinkEvent) -> Void)?
    private(set) var certificateHash = Data()
    let deviceID: UUID
    let name: String
    private var peerID: MCPeerID?
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var discovered: [UUID: MCPeerID] = [:]
    private var descriptions: [MCPeerID: LocalPeer] = [:]
    private var certificates: [MCPeerID: Data] = [:]
    private var trusted: LocalTrustedDevice?
    private var pairing = false
    private var expectedPeer: MCPeerID?
    private var certificateCallbacks: Set<MCPeerID> = []
    private var states: [MCPeerID: MCSessionState] = [:]
    private let identityAlgorithm: LocalSyncIdentity.KeyAlgorithm?
    init(deviceID: UUID, name: String, identityAlgorithm: LocalSyncIdentity.KeyAlgorithm? = nil) {
        self.deviceID = deviceID; self.name = name; self.identityAlgorithm = identityAlgorithm
    }
    static var deviceName: String {
        #if os(macOS)
        let proposed = Host.current().localizedName ?? "Mac"
        #elseif os(iOS)
        let proposed = UIDevice.current.name
        #else
        let proposed = "PersonalGantt"
        #endif
        var result = ""
        for character in proposed { if (result + String(character)).utf8.count > 63 { break }; result.append(character) }
        return result.isEmpty ? "PersonalGantt" : result
    }
    func start(pairing: Bool, trusted: LocalTrustedDevice?) throws {
        if session != nil { return }
        self.trusted = trusted; self.pairing = pairing
        if identityAlgorithm == nil {
            try LocalSyncIdentity.requireCompatibleIdentity(deviceID: deviceID, trusted: trusted)
        }
        let (identity, hash) = try LocalSyncIdentity.load(deviceID: deviceID, algorithm: identityAlgorithm ?? .rsa)
        certificateHash = hash
        let defaults = UserDefaults.standard
        let key = "personalGantt.localPeer." + deviceID.uuidString
        let ownPeer: MCPeerID
        if let data = defaults.data(forKey: key) {
            guard data.count < 16_384, let value = try? NSKeyedUnarchiver.unarchivedObject(ofClass: MCPeerID.self, from: data) else { throw LocalSyncError.storage }
            ownPeer = value
        } else {
            ownPeer = MCPeerID(displayName: name)
            defaults.set(try NSKeyedArchiver.archivedData(withRootObject: ownPeer, requiringSecureCoding: true), forKey: key)
        }
        peerID = ownPeer
        let values = try LocalSyncIdentity.securityIdentity(identity)
        let connection = MCSession(peer: ownPeer, securityIdentity: values, encryptionPreference: .required)
        guard let first = connection.securityIdentity?.first,
              CFGetTypeID(first as CFTypeRef) == SecIdentityGetTypeID(),
              try LocalSyncIdentity.validate(first as! SecIdentity) == hash else { throw LocalSyncError.storage }
        connection.delegate = self; session = connection
        LocalSyncDiagnostics.log("session.created", peer: ownPeer.displayName, fingerprint: hash,
                                 detail: "firstType=SecIdentity encryption=required delegateAttached=true")
        startAdvertising()
        let browse = MCNearbyServiceBrowser(peer: ownPeer, serviceType: LocalSyncConstants.serviceType)
        browse.delegate = self; browser = browse; browse.startBrowsingForPeers()
    }
    func updateTrust(_ trusted: LocalTrustedDevice) {
        self.trusted = trusted; pairing = false
        advertiser?.stopAdvertisingPeer(); startAdvertising()
    }
    private func startAdvertising() {
        guard let peerID else { return }
        let info = ["id": deviceID.uuidString, "version": String(LocalSyncConstants.protocolVersion), "pair": pairing ? "1" : "0"]
        let advertise = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: info, serviceType: LocalSyncConstants.serviceType)
        advertise.delegate = self; advertiser = advertise; advertise.startAdvertisingPeer()
    }
    func stop() {
        advertiser?.stopAdvertisingPeer(); browser?.stopBrowsingForPeers(); session?.disconnect()
        advertiser?.delegate = nil; browser?.delegate = nil; session?.delegate = nil
        advertiser = nil; browser = nil; session = nil; expectedPeer = nil; discovered = [:]; descriptions = [:]; certificates = [:]
        certificateCallbacks = []; states = [:]
    }
    func disconnect() { session?.disconnect(); expectedPeer = nil; certificates = [:] }
    func connect(_ peer: LocalPeer) throws {
        guard let target = discovered[peer.id], let session, let browser, expectedPeer == nil,
              peer.id == trusted?.deviceID || pairing && peer.pairing else { throw LocalSyncError.untrusted }
        expectedPeer = target
        certificateCallbacks.remove(target); certificates.removeValue(forKey: target)
        LocalSyncDiagnostics.log("invitation.sent", peer: target.displayName)
        let invitation = LocalHello(deviceID: deviceID, name: name, nonce: UUID(), pairing: pairing)
        browser.invitePeer(target, to: session, withContext: try JSONEncoder().encode(invitation), timeout: 15)
    }
    func send(_ data: Data) throws {
        guard data.count <= LocalSyncConstants.maximumBytes, let session, let expectedPeer,
              session.connectedPeers == [expectedPeer] else { throw LocalSyncError.offline }
        try session.send(data, toPeers: [expectedPeer], with: .reliable)
    }
}

extension MultipeerLocalLink: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        _Concurrency.Task { @MainActor [weak self] in
            guard let self, self.browser === browser, let info,
                  let id = info["id"].flatMap(UUID.init(uuidString:)), id != self.deviceID,
                  self.pairing || self.trusted?.deviceID == id else { return }
            guard info["version"] == String(LocalSyncConstants.protocolVersion) else { self.onEvent?(.incompatiblePeer); return }
            let peer = LocalPeer(id: id, name: peerID.displayName, pairing: info["pair"] == "1")
            LocalSyncDiagnostics.log("discovery.found", peer: peer.name, detail: "pairing=\(peer.pairing)")
            // Discovery updates may arrive after an invitation (including an
            // old pair=0 advertisement). Keep that invitation's accepted peer
            // identity until the active session ends.
            let active = peerID == self.expectedPeer ? self.descriptions[peerID] ?? peer : peer
            self.discovered[active.id] = peerID; self.descriptions[peerID] = active; self.onEvent?(.found(active))
        }
    }
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        _Concurrency.Task { @MainActor [weak self] in
            guard let self, self.browser === browser, let peer = self.descriptions[peerID] else { return }
            if peerID != self.expectedPeer { self.descriptions.removeValue(forKey: peerID) }
            self.discovered.removeValue(forKey: peer.id); self.onEvent?(.lost(peer.id))
        }
    }
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: any Error) {
        _Concurrency.Task { @MainActor [weak self] in self?.onEvent?(.failed(.network)) }
    }
}
extension MultipeerLocalLink: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        _Concurrency.Task { @MainActor [weak self] in
            guard let self, self.advertiser === advertiser, self.expectedPeer == nil, let context, context.count < 4096,
                  let hello = try? JSONDecoder().decode(LocalHello.self, from: context), hello.deviceID != self.deviceID,
                  self.trusted?.deviceID == hello.deviceID || self.pairing && hello.pairing else {
                LocalSyncDiagnostics.log("invitation.rejected", peer: peerID.displayName, detail: "reason=inactiveOrBusyOrUnauthorized")
                invitationHandler(false, nil); return
            }
            self.expectedPeer = peerID
            self.certificateCallbacks.remove(peerID); self.certificates.removeValue(forKey: peerID)
            self.descriptions[peerID] = LocalPeer(id: hello.deviceID, name: peerID.displayName, pairing: hello.pairing)
            LocalSyncDiagnostics.log("invitation.accepted", peer: peerID.displayName)
            invitationHandler(true, self.session)
        }
    }
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: any Error) {
        _Concurrency.Task { @MainActor [weak self] in self?.onEvent?(.failed(.network)) }
    }
}
extension MultipeerLocalLink: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, didReceiveCertificate certificates: [Any]?, fromPeer peerID: MCPeerID, certificateHandler: @escaping (Bool) -> Void) {
        let hash: Data?
        if let first = certificates?.first, CFGetTypeID(first as CFTypeRef) == SecCertificateGetTypeID() {
            hash = Data(SHA256.hash(data: SecCertificateCopyData(first as! SecCertificate) as Data))
        } else { hash = nil }
        LocalSyncDiagnostics.log("certificate.callback", peer: peerID.displayName, fingerprint: hash,
                                 detail: "chainCount=\(certificates?.count ?? 0)")
        _Concurrency.Task { @MainActor [weak self] in
            guard let self, self.session === session else {
                LocalSyncDiagnostics.log("certificate.rejected", peer: peerID.displayName, fingerprint: hash, detail: "reason=staleSession")
                certificateHandler(false); return
            }
            self.certificateCallbacks.insert(peerID)
            let decision = LocalCertificateDecision.evaluate(hash: hash, peer: self.descriptions[peerID],
                expected: self.expectedPeer == peerID,
                anotherPeerExpected: self.expectedPeer != nil && self.expectedPeer != peerID,
                pairing: self.pairing, trusted: self.trusted)
            LocalSyncDiagnostics.log(decision.accepted ? "certificate.accepted" : "certificate.rejected",
                                     peer: peerID.displayName, fingerprint: hash, detail: "reason=\(decision.rawValue)")
            if decision.accepted { self.certificates[peerID] = hash }
            certificateHandler(decision.accepted)
        }
    }
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        _Concurrency.Task { @MainActor [weak self] in
            guard let self, self.session === session else { return }
            let previous = self.states[peerID]?.rawValue ?? MCSessionState.notConnected.rawValue
            self.states[peerID] = state
            let names = ["notConnected", "connecting", "connected"]
            LocalSyncDiagnostics.log("session.state", peer: peerID.displayName, fingerprint: self.certificates[peerID],
                detail: "\(names.indices.contains(previous) ? names[previous] : "unknown")->\(names.indices.contains(state.rawValue) ? names[state.rawValue] : "unknown") certificateCallback=\(self.certificateCallbacks.contains(peerID)) expected=\(self.expectedPeer == peerID)")
            switch state {
            case .connected:
                guard peerID == self.expectedPeer, let peer = self.descriptions[peerID], let hash = self.certificates[peerID] else { self.disconnect(); self.onEvent?(.failed(.untrusted)); return }
                self.onEvent?(.connected(peer, certificateHash: hash))
            case .connecting: self.onEvent?(.connecting)
            case .notConnected:
                if self.expectedPeer == peerID { self.expectedPeer = nil; self.certificates.removeValue(forKey: peerID); self.onEvent?(.disconnected) }
            @unknown default: self.onEvent?(.failed(.network))
            }
        }
    }
    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard data.count <= LocalSyncConstants.maximumBytes else {
            _Concurrency.Task { @MainActor [weak self] in self?.onEvent?(.failed(.tooLarge)) }; return
        }
        _Concurrency.Task { @MainActor [weak self] in
            guard let self, self.session === session, peerID == self.expectedPeer else { return }
            self.onEvent?(.received(data))
        }
    }
    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) { stream.close() }
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) { progress.cancel() }
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: (any Error)?) { }
}
