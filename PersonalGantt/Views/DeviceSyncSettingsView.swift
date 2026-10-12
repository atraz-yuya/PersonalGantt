import SwiftUI

struct DeviceSyncSettingsView: View {
    @Bindable var model: ScheduleViewModel
    var body: some View {
        List {
            if let local = model.localSync {
                LocalSyncSettingsSections(model: model, local: local)
            } else {
                Section("ローカル同期") { Text("このプレビューでは端末との通信を行いません。").foregroundStyle(.secondary) }
            }
            Section("iCloud同期") {
                NavigationLink("iCloud同期の設定") { WorkloadRoutineView(model: model, page: .sync, embedded: true) }
                Text("ローカル同期とiCloud同期は、どちらか一方を有効にします。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle("端末間の同期").accessibilityIdentifier("device-sync-settings")
    }
}
private struct LocalSyncSettingsSections: View {
    @Bindable var model: ScheduleViewModel
    @Bindable var local: LocalSyncTransport
    @State private var confirmsUnpair = false
    var body: some View {
        Section("ローカル同期") {
            Toggle("ローカル自動同期", isOn: Binding(get: { local.preferences.enabled }, set: { model.setLocalSyncEnabled($0) }))
                .disabled(!model.canEnableLocalSync).accessibilityIdentifier("local-sync-enabled")
            LabeledContent("この端末", value: local.displayName)
            LabeledContent("状態", value: local.status)
            if let peer = local.preferences.trustedDevice {
                LabeledContent("接続先", value: peer.name)
            }
            if let date = local.preferences.lastSync {
                LabeledContent("最終同期", value: date.formatted(date: .abbreviated, time: .shortened))
            }
            if let message = local.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            if let message = model.persistenceMessage { Text(message).font(.caption).foregroundStyle(.orange) }
            if local.isSyncing { ProgressView("同期中…") }
            Button("今すぐ同期") { _Concurrency.Task { await local.syncNow() } }
                .disabled(!local.preferences.enabled || local.isSyncing || !model.canEnableLocalSync || local.preferences.trustedDevice == nil)
                .accessibilityIdentifier("local-sync-now")
            Text("両端末でPersonalGanttを開くと自動接続します。iPhoneがバックグラウンドの間は同期を停止し、次に開いたときに再開します。Macはアプリ起動中に待ち受けます。スリープ中は同期できません。")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("ペアリング") {
            if local.canPair {
                if local.isPairing {
                    if let peer = local.pairingPeer, let code = local.pairingCode {
                        Text("\(peer.name)と同期しますか？").font(.headline)
                        Text(code).font(.title3.monospaced().bold()).textSelection(.enabled)
                        Text("相手の画面にも同じ確認コードが表示されていることを確かめ、両端末で許可してください。")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("同じコードを確認して許可") { local.approvePairing() }
                            .accessibilityIdentifier("local-pair-approve")
                        Button("拒否", role: .cancel) { local.rejectPairing() }
                    } else {
                        Text("相手でも「新しい端末とペアリング」を開いてください。2分間検索します。")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(local.peers.filter(\.pairing)) { peer in
                            Button("\(peer.name)と接続") { local.connect(peer) }
                        }
                    }
                    Button("ペアリングを終了") { local.endPairing() }
                } else {
                    Button("新しい端末とペアリング") { model.beginLocalPairing() }
                        .disabled(!model.canEnableLocalSync).accessibilityIdentifier("local-pair-start")
                }
            }
            if let trusted = local.preferences.trustedDevice {
                LabeledContent("信頼済み端末", value: trusted.name)
                LabeledContent("登録日", value: trusted.pairedAt.formatted(date: .abbreviated, time: .omitted))
                Button("\(trusted.name)との同期を解除", role: .destructive) { confirmsUnpair = true }
                    .accessibilityIdentifier("local-unpair")
            }
        }
        .alert("ペアリングを解除しますか？", isPresented: $confirmsUnpair) {
            Button("解除", role: .destructive) { local.unpair() }
            Button("キャンセル", role: .cancel) { }
        } message: { Text("この端末から相手への自動接続を停止します。作業データは削除しません。再接続には両端末でペアリングが必要です。") }
        if !model.syncState.conflictKeys.isEmpty {
            Section("競合履歴") {
                Text("\(model.syncState.conflictKeys.count)件。更新日時の新しい内容を採用しています。")
                Button("競合履歴を確認済みにする") { model.acknowledgeSyncConflicts() }
            }
        }
    }
}
