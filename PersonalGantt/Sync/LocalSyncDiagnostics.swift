import Foundation
import OSLog

/// Deliberately excludes payloads, nonces, confirmation codes and key material.
enum LocalSyncDiagnostics {
    private static let logger = Logger(subsystem: "com.atraz.PersonalGantt", category: "LocalSync")
    static func log(_ event: String, peer: String? = nil, fingerprint: Data? = nil, detail: String = "") {
        #if DEBUG
        let safeName = (peer ?? "-").unicodeScalars.prefix(63).map {
            CharacterSet.controlCharacters.contains($0) ? " " : String($0)
        }.joined()
        let hash = fingerprint?.map { String(format: "%02x", $0) }.joined() ?? "-"
        let line = "[LocalSync] \(event) peer=\(safeName) fingerprint=\(hash) \(detail)"
        logger.debug("\(line, privacy: .public)")
        // devicectl --console also captures this on a physical iPhone.
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
        #endif
    }
}

/// Certificate acceptance only opens TLS. LocalSyncTransport separately gates
/// work records on mutual approval, a pinned identity and the READY exchange.
enum LocalCertificateDecision: String {
    case pairingCandidate, trustedFingerprint
    case missingCertificate, unknownPeer, unexpectedPeer, fingerprintMismatch, notPairing
    var accepted: Bool { self == .pairingCandidate || self == .trustedFingerprint }
    static func evaluate(hash: Data?, peer: LocalPeer?, expected: Bool, anotherPeerExpected: Bool,
                         pairing: Bool, trusted: LocalTrustedDevice?) -> Self {
        guard let hash, hash.count == 32 else { return .missingCertificate }
        guard let peer else { return .unknownPeer }
        guard !anotherPeerExpected else { return .unexpectedPeer }
        if let trusted {
            guard expected, peer.id == trusted.deviceID else { return .unexpectedPeer }
            return hash == trusted.certificateHash ? .trustedFingerprint : .fingerprintMismatch
        }
        guard pairing, peer.pairing else { return .notPairing }
        return .pairingCandidate
    }
}
