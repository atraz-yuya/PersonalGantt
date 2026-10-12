# ローカル同期のDTLSハンドシェイク修正（2026-10-12）

## 原因と修正

`securityIdentity` は元から `[SecIdentity]` であり、証明書だけを渡す誤りではありませんでした。実Mac NeoのKeychainから読み出したEC identityでは、公開鍵の一致と署名検証が成功しても、実MCSession同士の接続でローカル側 `errSSLCrypto (-9809)`、相手側 `errSSLPeerDecryptError (-9834)` が発生し、証明書callbackより前に切断しました。

同じMac内のMCSession接続でRSA 2048 identityに変更すると、両方の証明書callback、connected、HELLO、確認コード生成まで成功しました。この比較はMPCのDTLS経路とEC identityの互換性問題を示しています。Appleの仕様全般としてEC証明書が禁止されている、という意味ではありません。

- 通常経路をRSA 2048・SHA256署名の自己署名証明書へ変更。KeyUsageはdigitalSignatureとkeyEncipherment。
- RSA identityを `.rsa-v2` の別Keychain項目へ保存。古いEC項目を削除せず、既存のpinや信頼情報を自動で更新しない。
- 既存の信頼情報があるのにRSA鍵・証明書が存在しない場合は接続を停止し、両端末の更新と明示的な再ペアリングを案内。
- 秘密鍵の検索に `kSecAttrKeyClassPrivate` を指定。
- 生のSecIdentityから証明書・秘密鍵を取り出し、公開鍵の一致とランダムchallengeの署名検証を毎回実施。秘密鍵は書き出さない。
- MCSessionに渡す配列、および生成後の `session.securityIdentity` の先頭が実際のSecIdentityであることと、その証明書hashを実行時に検証。
- 接続中のpeer情報を古いdiscovery情報（pair=0など）で上書きしない。接続中peerのlost通知でも証明書検証用情報を保持。

## 証明書の受け入れとデータ保護

初回ペアリング中は発見・招待で把握したペアリング候補の証明書を一時受け入れます。未発見・不正証明書・別の接続対象は拒否します。信頼済みpeerでは、ペアリング中でもdevice IDと期待peer、保存済みfingerprintの一致が必須です。

TLSがconnectedになっても、作業データの交換は両端末の承認・pin保存・READY受信後だけです。この条件は変更していません。診断モードには承認操作がなく、作業snapshotと適用処理は必ずエラーとなるため、実作業データを送信できません。

## デバッグログ

Debugビルドで、subsystem `com.atraz.PersonalGantt`、category `LocalSync` に以下を出力します。devicectlのconsoleでも取得できます。

- identityの方式、先頭型、公開鍵一致、署名検証結果、証明書のSHA256 fingerprint
- discovery、招待、証明書callbackの入口（chain数）、accept/reject理由
- MCSession状態の前後、callbackを受けたか、期待peerか
- HELLOなどのmessage kindと確認コード表示到達

秘密鍵、証明書の全文、nonce、確認コード、作業payload、OAuth情報はログに出しません。peer名と証明書hashはDebugログに含まれるので、ログを共有する際は端末名を必要に応じて伏せてください。Releaseでは診断ログと診断画面を無効にします。

## 検証結果と残る範囲

| 検証 | 結果 |
|---|---|
| 全回帰テスト | 570ケース成功（432関数、パラメータ展開後）、失敗0 |
| 署名済みMac Neo/iPhone 15のビルド | 成功。OSは両方27.0.1 |
| 両実機のKeychain読出し・identity型・公開鍵一致・署名検証 | EC/RSAとも成功、保存後の再起動でも同じfingerprint |
| Mac内の実MCSession比較・EC | connecting後、-9809/-9834で切断。callbackなし |
| Mac内の実MCSession比較・RSA | discovery → connecting → certificate callback/accept → connected → HELLO → 確認コード生成 |
| 最終版Mac診断画面 | 確認コード表示と両セッションのコード一致を実UIで確認 |
| 診断引数を外した通常のMac/iPhoneアプリ | 本来のdevice IDに対応するRSA identityの型・鍵対応・署名検証とMCSession生成が成功 |
| Mac Neo ↔ iPhone 15 | 双方向でdiscoveryと招待・connectingまで確認。確認コード表示には未到達 |

今回のMacはiPhoneのテザリングを使用しており、実機間試行ではMacのMPCログに `Sendmsg failed with error No route to host (65)` が出ています。通常の同一Wi-Fiは利用できず、その環境での実機確認は残っています。テザリングだけが原因と断定したり、実機間接続が成功したとは報告していません。

比較ログ（端末名は置換、秘密情報なし）は [LocalSyncDTLS-2026-10-12.log](verification/LocalSyncDTLS-2026-10-12.log) に保存しています。

## 同じ実機経路の再検証

1. Mac/iPhoneの両方に最新Debugビルドを入れ、同じ通常Wi-Fiへ接続。ローカルネットワーク許可を確認し、iPhoneを前面にする。
2. XcodeのScheme → Run → Argumentsで `--local-sync-handshake-check` を両端末に追加。実データから独立した端末IDと実Keychain identityを使い、自動で診断候補に接続する。
3. 両画面の確認コード表示と一致を確認。ログではcertificate.callback/accepted、connected、hello、pairing.codeDisplayedを確認する。確認コード自体は記録しない。
4. 招待方向を逆にする場合は両端末へ `--local-sync-invite-from-iphone` を追加。
5. Mac内で比較する場合は `--local-sync-loopback-check` を追加。旧ECの再現時だけ `--local-sync-legacy-ec-check` を追加。
6. 通常利用に戻すときは診断引数を外す。旧ペアリングがある場合は、両端末で設定から解除して再登録する。作業データは保持される。

参考: [AppleのMCSession initializer仕様](https://developer.apple.com/documentation/multipeerconnectivity/mcsession/init(peer:securityidentity:encryptionpreference:))、[Secure Transport result codes](https://developer.apple.com/documentation/security/secure-transport-result-codes)。配列の先頭はSecIdentity、その後は必要な中間SecCertificateという仕様に従っています。
