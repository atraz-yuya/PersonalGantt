#if DEBUG
import SwiftUI

/// Real MCSession + real persistent Keychain identity, isolated from work stores.
/// Explicit debug launch argument only; never approves or transfers work records.
struct LocalSyncHandshakeCheckView: View {
    @State private var transport: LocalSyncTransport
    @State private var loopback: LocalSyncTransport?
    init() {
        _transport = State(initialValue: Self.makeTransport(suffix: "", name: "PGTLS " + MultipeerLocalLink.deviceName))
        _loopback = State(initialValue: ProcessInfo.processInfo.arguments.contains("--local-sync-loopback-check")
            ? Self.makeTransport(suffix: ".loopback", name: "PGTLS loopback") : nil)
    }
    @MainActor private static func makeTransport(suffix: String, name: String) -> LocalSyncTransport {
        let key = "personalGantt.handshakeCheck.deviceID" + suffix
        let id = UserDefaults.standard.string(forKey: key).flatMap(UUID.init(uuidString:)) ?? UUID()
        UserDefaults.standard.set(id.uuidString, forKey: key)
        let link = MultipeerLocalLink(deviceID: id, name: name,
            identityAlgorithm: ProcessInfo.processInfo.arguments.contains("--local-sync-legacy-ec-check") ? .legacyEC : nil)
        return LocalSyncTransport(deviceID: id, displayName: name, link: link,
            store: HandshakeCheckPreferences(), snapshot: { throw LocalSyncError.untrusted },
            apply: { _ in throw LocalSyncError.untrusted })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("実機TLS接続の診断").font(.title)
            Text("作業データを読み出さず、確認コードの表示まで接続を検証します。")
            Text(transport.status)
            if let message = transport.message { Text(message).foregroundStyle(.red) }
            if let code = transport.pairingCode {
                Text("確認コード").font(.headline)
                Text(code).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    .accessibilityIdentifier("handshake-check-code")
            }
            ForEach(transport.peers) { peer in Text(peer.name) }
            if let loopback {
                Text("Mac内の実MCSession比較: " + loopback.status)
                Text(loopback.pairingCode == transport.pairingCode && transport.pairingCode != nil
                     ? "両セッションの確認コード一致" : "接続確認中")
            }
            Button("再検証") {
                transport.endPairing(); loopback?.endPairing()
                transport.beginPairing(); loopback?.beginPairing()
            }
        }.padding(28)
        .task {
            transport.setAvailable(true); transport.beginPairing()
            loopback?.setAvailable(true); loopback?.beginPairing()
        }
        .onChange(of: transport.peers) { _, peers in
            guard transport.pairingCode == nil,
                  let peer = peers.first(where: { $0.pairing && $0.name.hasPrefix("PGTLS ") && (loopback == nil || $0.id == loopback?.deviceID) && shouldInvite($0) }) else { return }
            transport.connect(peer)
        }
        .onChange(of: loopback?.peers) { _, peers in
            guard let loopback, loopback.pairingCode == nil,
                  let peer = peers?.first(where: { $0.id == transport.deviceID && loopback.deviceID.uuidString < $0.id.uuidString }) else { return }
            loopback.connect(peer)
        }
    }
    private func shouldInvite(_ peer: LocalPeer) -> Bool {
        if ProcessInfo.processInfo.arguments.contains("--local-sync-invite-from-iphone") {
            #if os(iOS)
            return true
            #else
            return false
            #endif
        }
        return transport.deviceID.uuidString < peer.id.uuidString
    }
}
@MainActor private final class HandshakeCheckPreferences: LocalSyncPreferenceStoring {
    private var value = LocalSyncPreferences()
    func load() throws -> LocalSyncPreferences { value }
    func save(_ preferences: LocalSyncPreferences) throws { value = preferences }
}
#endif
