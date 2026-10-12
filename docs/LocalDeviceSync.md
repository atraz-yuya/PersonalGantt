# Mac ↔ iPhone ローカル自動同期（2026-10-12）

ブランチ: `codex/local-device-sync`。コミットは実装完了メッセージに記載します。

## 実装と変更ファイル

| ファイル | 役割 |
|---|---|
| `Sync/LocalSyncProtocol.swift` | protocol/schema version、envelope、サイズ上限、payload検証、確認コード |
| `Sync/LocalSyncTransport.swift` | 発見・承認・信頼・ACK・再送・重複抑止・debounceと双方向exchange |
| `Sync/LocalSyncKeychain.swift` | 端末固有TLS identity、Keychainの設定・信頼情報 |
| `Sync/MultipeerLocalLink.swift` | MultipeerConnectivityだけを担当するSDK adapter |
| `Scheduling/ScheduleViewModel.swift` | 共通LWW/再計算、保存確認と失敗時rollback、変更・lifecycleのトリガー |
| `Views/DeviceSyncSettingsView.swift`, `Views/AppSettingsView.swift` | ローカル同期の設定、初回確認、最終同期、解除、iCloud設定への導線 |
| `Presentation/NavigationPreview.swift` | 通信・Keychainを使わない合成peerのUI確認用モデル |
| `Config/AppInfo.plist`, `PersonalGantt.entitlements` | ローカルネットワーク説明、Bonjour、Macのserver権限 |
| Xcode project / `Package.resolved` | Appleの証明書ライブラリと再現可能な依存関係 |
| `PersonalGanttTests/LocalSyncTests.swift` | protocol、信頼・再送、2端末を模したモデル統合テスト |

## 通信と信頼

`LocalSyncTransport`は既存`SyncTransport.exchange([SyncRecord])`を実装します。CloudKitSyncTransportを残し、SyncState・SyncRevision・SyncPayloadValidator・決定的LWW・tombstoneを共用します。ローカルの受信側はModelへ適用を委譲し、保存が確認できるまでACKを返しません。競合ロジックの別実装はありません。

MCNearbyServiceAdvertiserとMCNearbyServiceBrowserを両端末で利用し、1つのMCSessionで1対1の同期を行います。serviceTypeは定数 `pgantt-sync`、Bonjourは `_pgantt-sync._tcp`、暗号化は `.required`です。UUIDの小さい側を自動接続の開始側とし、相互inviteの接続ループを避けます。新規ペアリングは2分間だけ受け付けます。

各端末でSecurityのRSA 2048秘密鍵を生成し、Appleのswift-certificatesで自己署名X.509証明書を作成します。共通秘密鍵の埋め込みや独自暗号方式は使用しません。TLS identityをMCSessionへ渡し、証明書callbackで信頼済みfingerprintを照合します。初回はペアリング操作中の候補だけTLS接続を許可し、HELLO・承認・READY以外の作業データを承認前に送受信しません。旧EC方式からの修正・実行時検証・再ペアリング手順は[DTLS修正報告](LocalSyncDTLS.md)を参照してください。

双方のUUID・新しいnonce・実際のTLS証明書hashから、128-bit（4桁×8組）の同一確認コードを表示します。両端末での明示的な許可が揃い、信頼情報の保存が成功した後にREADYを交換します。UUIDを偽るだけでは再接続できません。証明書が変わった相手を自動で再信頼しません。

信頼済みdevice UUID・name・certificate hash・pairedAt、ON/OFF、lastSyncを、非同期化・WhenUnlockedThisDeviceOnlyのKeychain項目へ保存します。秘密鍵・証明書も端末内のKeychainへ保存します。MCPeerIDは安全なarchiveとして当該アプリのUserDefaultsへ保持します。信頼先はMVPとして1端末です。設定の解除は接続と信頼を停止し、作業データを保持します。別の相手や再ペアリングには、既存のペアリングを両端末で解除してください。

証明書の生成・TLS認証の方針は[Apple TN3213](https://developer.apple.com/documentation/technotes/tn3213-moving-from-multipeer-connectivity-to-network-framework)、Bonjour/説明文は[Apple TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)を確認しています。現在のSDK 27ではMultipeerConnectivityは非推奨です。指示書の第一候補として使用し、SDK adapterをNetwork frameworkへ置き換えられる構造にしました。ビルドにはこの非推奨の警告があります。

## プロトコル・安全な適用

protocolVersion=1、ローカルpayload schemaVersion=1です。HELLOで互換性とdevice UUIDを確認し、不一致なら通信を停止して短い説明を表示します。発見段階でも不一致を表示します。

MVPではmanifest差分方式を採用せず、共通SyncRecordの全件を交換します。envelope全体は8 MiB、1回10,000 entity、各entity payloadは既存の2,000,000 bytes上限です。上限超過で切り詰めや部分適用を行いません。通常のTask数・実績数に余裕を持たせ、巨大なデータにはJSONバックアップを案内します。

受信は、サイズ・envelope形状・version・enum・UUID・日時・未知フィールド・entity payload・同一revisionの異なる内容を検証します。SyncState.mergeでbatch全体を検証し、既存のLWWへ渡します。要件と再計算結果を同じcheckpointに保存します。保存失敗では同期前のmodel状態へ同期的にrollbackし、ACKを返しません。SwiftDataPlanStore自身も失敗時にcontext.rollbackする既存設計です。

受信成功のACKには受信側の最新SyncRecordを含め、送信側も既存mergeと保存確認を行います。受信messageIDとhashを最大256件保持し、同じ送信の再受信を二重適用しません。IDが同じで内容が異なるものを拒否します。再接続後もentity revisionとUUIDによって冪等です。

ACKがなければ8秒ごとに同じmessageIDで最大2回再送（初回を含め3回）し、その後は編集を保持して終了します。自動接続は1分あたり最大3回、最低10秒間隔と切断後15秒の待機で制限します。再発見・foreground復帰・手動操作で接続を再試行します。無制限な即時retryは行いません。

保存したentityに変更があれば700ms debounceで同期します。同期中の編集はdirtyとして次のexchangeに含めます。受信適用が自分自身を同期させ続けるecho loopを抑止します。起動/foreground、手動「今すぐ同期」、Task/Routine/WorkSession/設定の保存で動きます。Siriは従来どおりTaskCreationServiceで保存するだけで、Intentに通信を追加していません。

## 同期対象と端末固有のデータ

| 同期する | 同期しない |
|---|---|
| 通常Task、手動/Siri Task、priority、完了状態、deadline、notBefore | OAuth Access/Refresh Token、Keychain内容、OS権限 |
| Routine規則・期間・完了/スキップのoccurrence UUID | Calendar選択・キャッシュ・Coverage・FixedEvent・AvailableSlot |
| WorkSessionのUUID・実績・Remindersの外部対応キー | ScheduledBlock/Gantt、Google書き戻し先・同意 |
| WorkloadSettings、SchedulingSettings、分散/最適化/休憩、日別稼働時間 | 実行中タイマー、端末UI、ペアリング情報 |
| revision・baseRevision・device UUID・tombstone | MCSession、秘密鍵、証明書、信頼済み端末設定 |

Apple RemindersはOS/iCloud側を正として各端末が取得します。Reminders由来Taskを通常Taskとして通信しません。実績は既存のexternal identifier/occurrence keyの対応付けで相手のTaskへ計上します。Reminders固有の所要時間・補完締切・除外設定は、従来どおりJSONバックアップで受け渡せます。

各端末の取得済みGoogle予定・Coverageを使ってScheduler/Replannerを再計算します。Google取得失敗でもTask等の保存と同期はできます。未取得期間へ確定配置しない方針と開始済み枠の保護を維持します。Calendar選択が違えばGanttが違うことがあります。

ローカルとiCloudは設定からどちらか一方をONにできます。初期状態は両方OFFで、初回ペアリング操作がローカル同期をONにします。CloudKitを今回有効化していません。JSONバックアップの形式を変更せず、信頼・秘密情報を追加しません。ログへTask本文、Token、証明書/秘密鍵値、実イベント内容を出しません。

## lifecycleと設定画面

サイドバー → 設定 → 連携 → 端末間の同期に、ON/OFF、この端末、接続先、状態、最終同期、今すぐ同期、信頼済み端末、ペアリングと解除を追加しました。詳細は設定へ集約し、Todayへ通信情報を追加していません。

iPhoneではforegroundでだけ通信し、background/inactiveで切断します。次に開くと保存した信頼先を自動発見します。Siriを完全backgroundで実行した場合は次のforegroundで同期します。Macはアプリを起動している間、他アプリへ切り替えても待ち受けます。終了・スリープ・圏外で常時同期を保証しません。daemon、インターネット越し同期、独自サーバーはありません。

## 検証

全567ケース（既存524＋追加43、パラメータ展開後）が成功しました。macOS test buildとiOS Simulator（arm64/x86_64）buildが成功しています。証明書と秘密鍵の対応確認はSecurity/X509の実オブジェクトで、Keychain・ネットワーク・2端末の適用は独立したメモリtest doubleで検証しました。

追加ケースは、version/形状/UUID/日時/enum/未知フィールド/サイズ制限、双方の承認・拒否・信頼再接続・解除、重複message・ACK消失・有限再送・保存失敗、双方向/同時追加・同時編集LWW・競合・tombstone・offline編集・同期中編集・Routine/スキップ・WorkSession/設定/稼働時間・Siri相当・Reminders対応・機密フィールド拒否・各端末再計算・Google失敗/不足Coverage・方式切替を含みます。

結果bundleは `/tmp/PersonalGantt-local-final-tests.xcresult`、ログは `/tmp/PersonalGantt-local-final-tests.log` と `/tmp/PersonalGantt-local-final-ios.log` です。swift-certificates 1.21.0、swift-crypto 5.0.0、swift-asn1 1.7.3の解決済みrevisionをPackage.resolvedに固定しました。生成されたiOS Info.plistにBonjour宣言も反映されています。

Macの別Bundle IDのDebug確認用コピーで、メモリ保存・合成peerのみを使い、設定 → ペアリング検索 → peer選択 → 確認コード → 承認 → 同期済み/最終同期 → 解除確認/キャンセルまで操作確認しました。このUI確認ではMultipeer通信・実Keychain・実Taskを使用していません。

その後、実Mac/iPhoneのKeychain identity検証とdiscovery・connectingを確認しました。テザリング環境で実機間の接続が切れるため、確認コード表示は未達です。Mac内の実MCSession同士ではRSAへの修正後に証明書callback・connected・HELLO・確認コード生成が成功しました。実機間成功としては報告していません。[最新の検証範囲](LocalSyncDTLS.md)を参照してください。

## Mac + iPhoneの実機確認手順

1. Xcodeで両端末に同じcommitのアプリを署名してインストールします。通常のApple Development/Personal TeamとKeychain署名を使用でき、CloudKit entitlementやDeveloper Program加入はローカル同期の条件にしません。端末OSはこのプロジェクトのdeployment target（現在27.0）以上が必要です。
2. 同じWi-Fiへ接続し、MacとiPhoneでPersonalGanttを開きます。両方で設定 → 連携 → 端末間の同期 → 新しい端末とペアリングを開きます。
3. OSのローカルネットワーク利用を許可し、相手を選択します。両画面の8組の確認コードが一致することを確かめ、両端末で許可します。信頼先、同期済み、最終同期を確認します。
4. iPhoneで合成Taskを追加し、Macへ反映することを確認します。必要なら今すぐ同期を押します。Macでdeadline/priorityを変え、iPhoneへの反映を確認します。
5. iPhoneで30分の実績を入力し、MacのremainingMinutesを確認します。MacでRoutineを追加・編集し、iPhoneの各日要件を確認します。完了・スキップも試します。
6. iPhoneを一時オフラインにして編集し、再接続・foregroundでmergeを確認します。同じTaskを両方で編集して、同じ採用内容と競合履歴を確認します。
7. テストTaskを削除し、相手へtombstoneが反映することを確認します。途中切断と今すぐ同期でも二重Task/WorkSessionが生じないことを確認します。
8. 各端末のGoogle認証・Calendar選択が維持され、TokenやGanttがコピーされず、各端末で再計算されることを確認します。設定で解除すると自動接続しないこと、再ペアリングが必要なことを確認します。

## 制約

1対1・全件交換のMVPです。manifest/chunkによる大規模差分同期は未実装です。無線通信/OS権限の実機検証とNetwork frameworkへの移行が残ります。iPhone完全background同期、Mac常駐daemon、インターネット越し接続、CloudKit有効化、iPad実機確認、ScheduledBlockの直接同期、共同編集UIは今回の範囲に含めていません。
