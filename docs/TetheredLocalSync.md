# テザリング環境でのローカル同期（2026-10-12）

ブランチ: `codex/tethered-local-sync`。MacBook Neo / iPhone 15、両方OS 27.0.1、Xcode 27で検証。

テザリング中の実機2台で、通常アプリから初回登録、READY、SyncRecord交換、ACK、保存、Taskの往復と削除、WorkSessionの往復に成功。通常Wi-Fiを利用できないため、指示書の全完了条件を満たしたとは扱わない。

## 最終報告の18項目

1. **原因**: 従来はMPCだけを使い、さらに「今すぐ同期」が接続開始後に戻っていた。未接続時は探索・READY・保存まで待たず、UUIDの大小によって手動操作側から接続開始できない場合もあった。
2. **MPC失敗**: 以前の実機ログで、discovery/invitation後のMPC接続確立に`No route to host (65)`が発生。MPC内部の候補・UDP/ICE経路選択の詳細は公開APIだけでは断定できない。今回TCP/TLSの実機成功により、Personal Hotspotでアプリ間通信が一律禁止されているという説明は成立しない。RSA対応を戻してはいない。
3. **構成**: `LocalSyncTransport → AdaptiveLocalLink → NetworkLocalLink / MultipeerLocalLink`。モデル、SyncTransport、SyncState、revision、LWW、tombstone、validator、WorkSessionの統合処理は共用したまま。
4. **Network実装**: NWListenerでTLS/TCP待受、NWBrowserでBonjour TXT検索、NWConnectionで接続。独自wire protocolのため専用`_pgantt-link._tcp`を追加し、MPCの`_pgantt-sync._tcp`も維持。TLS 1.2以上、相互証明書認証、再接続ごとのpin確認。40-byte header（magic/version、32-bit長、SHA256）で8MiB上限。分割・連結受信、破損、過大長、途中EOFを検証する。
5. **includePeerToPeer**: listener、browser、connection全てのNWParametersでtrue。特定interfaceへ固定しない。discoveryではMacの`en0/awdl0`、iPhoneの`bridge100/awdl0`を観測。成立した接続のNWPath.availableInterfacesはMac `en0:wifi`、iPhone `bridge100:wiredEthernet`。AWDLでデータを送れたことまでは主張しない。接続前にP2P browserを停止する。
6. **MPC**: 暗号化required、RSA SecIdentity、既存pin確認を保持しfallbackとして残す。MPCが返すエラーはdomain/codeだけDEBUG出力。OS内部の`Sendmsg`エラーはMCSession delegateへ直接渡されないため、必要時はOSログも併用する。
7. **順序**: Networkを優先。Network候補が後から届く場合も短時間待つ。3秒で未成立ならMPC候補へ移行、primary失敗時は候補があれば即移行。winnerは1本だけ、他経路の受信・切断を同期protocolへ渡さない。UUIDで両側同時dialの方向を決め、同じpeerの候補を統合する。
8. **信頼**: 全経路で同じdevice UUID、KeychainのRSA 2048 SecIdentityとSHA256 fingerprint、trustedDevice、pairedAtを使用。秘密鍵と証明書の対応検証も既存処理を共用。信頼済みpeerはUUID・fingerprint一致が必須。初回は双方がペアリング中の既知候補だけTLSを許可し、確認コードと双方の明示承認、Keychain保存、READYが揃うまで作業データを送らない。初期探索は2分、コード表示後はそこから2分の承認待ち。
9. **今すぐ同期**: 信頼済みなら未接続でも操作できる。探索開始→接続待ち→READY→既存exchange→保存/ACKをawaitする。手動操作はどちらのUUID側からも開始可能。20秒で探索/READY待ちを終え、ボタンを再操作可能にする。接続14秒、Network TLS8秒、HELLO15秒、ACK8秒×最大3回も上限あり。background/cancel/切断で待機continuationを解放。未登録時は初回ペアリングを案内。
10. **通常Wi-Fi実機**: 未検証。利用可能なのはテザリングだけとのユーザー回答。通常Wi-Fiからテザリングへの切替試験も未検証。
11. **テザリング実機**: Mac NeoがiPhone Personal Hotspotに接続した状態で発見→相互TLS certificate callback→connected→HELLO→確認コード。ユーザーが同じコードを確認して双方を承認後、READY→records→ACK→同期済みを通常アプリで確認。診断モードだけの成功ではない。
12. **双方向**: iPhoneで追加した15分/10月13日23:00締切のテストTaskがMacへ到着。Macで`TetherSync-Mac`/30分へ変更し、iPhone反映をユーザー確認。iPhone削除後、Macの未完了Taskから消失をUI確認。実績用テストTaskはiPhone30分→Mac受信、Mac追加60分→iPhone実績90分/残り30分をユーザー確認し、テストTaskを削除。既存モデル統合テストでもWorkSessionとtombstoneを検証。
13. **再接続**: Macを再起動し、双方で`trustedFingerprint`として相互TLS、HELLO、READY、ACK、同期成功をログ確認。iPhoneをホームへ戻す→Macの「今すぐ同期」を1回→iPhoneを前面に戻す操作で、再ペアリング不要・双方同期済みをユーザー確認。さらに長時間background中の失敗後も15秒間隔で探索を再開するよう修正し、同じ信頼を保つ回帰テストを追加。自動接続は3回/分に制限。
14. **テスト**: 586件成功、失敗0、skip0（448個のテスト関数、引数展開込み586）。`/tmp/PersonalGantt-tether-reconnect-tests.xcresult`。既存570件にフレーム・経路統合・安全なfallback・後発discovery・どちらの端末からの手動開始・timeout/cancel/background・再探索テストを追加。ACK再送テストの10ms待ちは負荷下で不安定だったため100msへ変更し、同じmessage IDでの再送と一回適用のassertionを維持。接続timeoutテストは固定時間sleepで判定せず、実際の終了イベントを待つ。
15. **build**: 署名済みmacOS/iPhone実機向けbuild双方成功。iOSアイコン、Mac AppIconMac、Bundle ID、Team、entitlements、依存ライブラリに変更なし。
16. **制約**: iPhoneアプリ前面、Mac起動中が必要。OS権限、スリープ、電波品質、他機種/OSに依存。iPhone終了・background中の常時同期は保証しない。相互TLS成立は確認済みなので今回はCloudKit/外部serverへの退避は不要。1対1・8MiBまでの全件交換という既存制限を維持。
17. **変更ファイル**: 下表参照。署名TeamとInfo.plist整形の既存ユーザー変更は保持し、コミットには含めない。データコンテナ削除・設定初期化は行わない。
18. **commit**: この報告と検証結果を含むコミットは完了メッセージに記載する。

| ファイル | 変更 |
|---|---|
| `PersonalGantt/Sync/NetworkLocalLink.swift` | Bonjour、相互TLS/TCP、P2Pパラメータ、bounded receive、pin確認、path/errorログ |
| `PersonalGantt/Sync/AdaptiveLocalLink.swift` | 自動経路選択・fallback・winner・候補統合・timeout |
| `PersonalGantt/Sync/LocalSyncFrame.swift` | bounded TCP framing、SHA256、分割/連結/EOF検証 |
| `PersonalGantt/Sync/LocalSyncTransport.swift` | 接続とREADYのawait、双方から手動接続、待機解除、承認期限、同期ログ |
| `PersonalGantt/Sync/MultipeerLocalLink.swift` | MPC errorのdomain/codeログのみ、send失敗の分類 |
| `PersonalGantt/Sync/LocalSyncHandshakeCheckView.swift` | DEBUG限定のNetwork実機診断argument（承認/作業データ送信なし） |
| `PersonalGantt/Scheduling/ScheduleViewModel.swift` | default linkをAdaptiveに変更する1行のみ |
| `PersonalGantt/Views/DeviceSyncSettingsView.swift` | 未登録時もボタンから案内可能にする |
| `Config/AppInfo.plist` | Network用Bonjour serviceの追加のみ |
| `PersonalGanttTests/LocalLinkTests.swift`, `LocalSyncTests.swift` | 境界・fallback・接続待ちと既存統合の回帰検証 |
| `docs/TetheredLocalSync.md`, `docs/LocalDeviceSync.md`, `docs/verification/TetheredLocalSync-2026-10-12.log` | 実装と実機検証の範囲、匿名化ログ |

## Apple仕様と診断時の注意

- [TN3213: Moving from Multipeer Connectivity to Network framework](https://developer.apple.com/documentation/technotes/tn3213-moving-from-multipeer-connectivity-to-network-framework)：相互TLS、includePeerToPeer、接続前のbrowser停止。
- [NWParameters.includePeerToPeer](https://developer.apple.com/documentation/network/nwparameters/includepeertopeer)：P2Pの利用許可は実際にAWDLでデータを送った証明とは異なる。
- [Network security options](https://developer.apple.com/documentation/network/security-options)：local identity、peer authentication、verify block。

今回Macの診断バイナリを直接起動した際に`dns=-65555`が発生したが、OS設定上PersonalGanttのローカルネットワーク許可はON。正式な.appを起動すると検索・TLS接続が成功した。起動元への権限帰属が原因の可能性があり、通常アプリの権限を無効化/リセットして回避する操作は行っていない。

ログはDEBUG時だけ。private key、OAuth token、nonce、確認コード、Task本文、SyncRecord payloadを含めない。検証保存ログはpeer名、device UUID、certificate fingerprintを匿名化し、実機のプロセスだけを抽出。ユニットテストhostの成功ログと実機成功を混在させない。

## 検証の区別

| 試験 | 結果・証拠 |
|---|---|
| 通常Wi-Fiでの双方向同期 | 未検証（通常Wi-Fiを利用できない） |
| iPhone Personal Hotspot中の初回登録 | 実機両端末のTLS/HELLOログ、コード一致・双方承認のユーザー確認 |
| テザリング中のTask双方向と削除 | Mac UI観測、iPhoneへの編集反映・削除のユーザー確認 |
| WorkSession双方向 | Macに30分到着をUI観測、Mac追加60分がiPhoneで90分になることをユーザー確認 |
| Mac再起動・再ペアリング不要 | trustedFingerprint/READY/ACKログ、1回操作で双方同期済みのユーザー確認 |
| 最後の再探索修正を入れた版 | 両端末を通常起動し、自動再接続からACK・同期成功を再確認（22:08） |
| Wi-Fi→テザリング切替 | 未検証（通常Wi-Fiを利用できない） |
| Network↔MPC切替・競争時の二重適用防止 | ユニットテスト成功。実機のMPC経路成立・実機での経路切替は未確認 |
| AWDLのみでのデータ通信 | 未確認。discoveryでawdl0を観測、今回の成立したTCP経路はen0/bridge100 |

実機検証ログ: [匿名化したログ](verification/TetheredLocalSync-2026-10-12.log)。通常利用では診断argument、再ペアリング、通信方式の選択は必要ない。
