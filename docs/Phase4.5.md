# Phase 4.5：Google Calendar移行 実装報告

2026-10-06。ブランチ: codex/google-calendar-integration。
コード実装と合成API応答による検証は完了しています。
本人のCloud設定とOAuthログイン後、macOSで実Calendar一覧・選択予定取得・空き時間生成・手動Refreshを確認しました。
実Tokenの期限切れ更新、認証後の再起動復元、iOS実機での認証は未検証です。

## 1. 変更ファイル

| ファイル | 内容 |
| --- | --- |
| Services/CalendarService.swift | 非同期CalendarProvidingと共通エラーへ整理。EventKit Calendar実装を削除。 |
| Services/Google/GoogleOAuthConfiguration.swift | 公開Client ID、読み取りスコープ、PKCE、state、callback検証。 |
| Services/Google/GoogleWebAuthenticator.swift | Appleの認証セッション、キャンセル処理。 |
| Services/Google/GoogleOAuthClient.swift | Code交換、Token期限・Refresh、許可スコープ確認、ログアウト。 |
| Services/Google/GoogleCredentialStore.swift | KeychainへのToken保存・取得・削除。 |
| Services/Google/GoogleHTTP.swift | ephemeral URLSession、リダイレクト拒否、安全な固定エラー。 |
| Services/Google/GoogleCalendarService.swift | Calendar一覧・選択Calendarの14日分・ページ分割取得。 |
| Services/Google/GoogleCalendarEvent.swift | Google Eventの日時とFixedEventへの変換。 |
| Services/Reminders/ReminderIdentity.swift | 将来のEKReminder識別子取得境界のみ。取得・権限・同期なし。 |
| Models/Task.swift | PersonalGantt側の任意reminderIdentifierを追加。 |
| Models/CalendarSource.swift | Google接続状態の案内へ変更。 |
| Scheduling/ScheduleViewModel.swift | Googleを既定にし、非同期取得・設定・ログアウトを接続。 |
| Views/CalendarSelectionView.swift | Client ID設定、Googleログイン、複数選択、Refresh。 |
| ContentView.swift | 非同期起動・Refresh。 |
| PersonalGantt.entitlements、project.pbxproj | Calendar権限/説明を除去、ネットワークとMac Keychainアクセスグループ。 |
| CalendarIntegrationTests.swift | 既存16ケースを維持し、非同期取得へ適応。 |
| LegacyEventKitCalendarFixture.swift | 旧EventKit変換のメモリ内テストだけをテストターゲットへ残置。 |
| GoogleOAuthTests.swift、GoogleCalendarTests.swift、GoogleEventConversionTests.swift | Google連携51ケース。 |
| GoogleTestDoubles.swift | 合成Token・API応答・認証画面の差し替え。 |
| ReminderAssociationTests.swift | ローカル関連IDと旧JSON互換2ケース。 |
| .gitignore、README.md、docs/GoogleOAuthSetup.md、docs/Phase4.5.md | 秘密情報の除外と現在の仕様・設定手順。 |

SwiftソースのパスはPersonalGantt/配下、テストはPersonalGanttTests/配下です。
Scheduler、AvailabilityService、ScheduleReplannerおよび既存Scheduler/TaskManagementテストは変更していません。

## 2. Google OAuthの構成

OAuth 2.0 Authorization Code + PKCE S256を使い、毎回CSPRNGからverifierとstateを生成します。
ASWebAuthenticationSessionでOS所有のブラウザ認証画面を開き、アプリがGoogleパスワードを受け取りません。
callbackのスキーム・path・host・state・重複パラメータを検証してからCodeを交換します。
キャンセル時は交換しません。認証処理の古いcallbackが次の認証へ入り込まないよう試行IDで区別します。

GoogleのiOSタイプClient IDをMac/iOS両方で使う公開ネイティブクライアント構成です。Client Secretは使用しません。
Client IDはアプリ内で入力し、公開識別子としてUserDefaultsへ保存します。個人のClient IDをリポジトリへ埋め込みません。
Google API固有の知識はServices/Google/へ閉じ込めています。
参考: [Google iOS/macOS設定](https://developers.google.com/identity/sign-in/ios/start-integrating)、[ネイティブOAuth](https://developers.google.com/identity/protocols/oauth2/native-app)。

## 3. Tokenの保存方法

Access Token、Refresh Token、期限、許可スコープ、対応Client IDをまとめてKeychainへ保存します。
SecItem APIとData Protection Keychainを使用し、WhenUnlockedThisDeviceOnly、Synchronizable=falseとしています。
平文ファイル・UserDefaults・ログへのToken保存はありません。保存失敗時はエラーにし、別の保存先へフォールバックしません。

期限の60秒前からRefreshし、Refresh Tokenが省略された更新応答では直前のRefresh Tokenを維持します。
新規ログインには別アカウントのRefresh Tokenを流用しません。
invalid_grantでは端末の認証情報を消去し、再ログインを要求します。一時的な通信失敗では認証情報を保持します。
ローカルログアウトはKeychainと現在取得済みイベントを消去します。Google側の許可取り消しはGoogleアカウント側で行います。

MacのData Protection Keychainには、アクセスグループを許可した署名・Provisioning Profileが必要です。
アプリ用のKeychainアクセスグループとKeychain Sharing設定を追加し、本人がXcodeでPersonal Teamを設定しました。
2026-10-06にApple Development証明書でMacビルド・署名検証が成功し、Keychainアクセスグループ、ネットワーク権限、Provisioning Profileの埋め込みを確認しました。
本人のOAuthログインが成功し、その後のCalendar一覧・予定取得と手動RefreshでKeychainの保存・読み出し経路が成功しました。
認証後の再起動復元と実Tokenの期限切れ更新は未検証です。更新処理は合成応答の単体テストで確認しています。
参考: [Apple TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)。

## 4. 要求したGoogle権限

- https://www.googleapis.com/auth/calendar.calendarlist.readonly
- https://www.googleapis.com/auth/calendar.events.readonly

一覧とイベントの読み取りだけです。作成・編集・削除の権限、People/Gmail/Drive、email/profileスコープは要求しません。
Token応答で両方のスコープを実際に許可されたことも確認します。

## 5. Calendar一覧取得

GET /calendar/v3/users/me/calendarListをminAccessRole=readerで取得し、nextPageTokenの全ページを読みます。
削除済みとfreeBusyReaderだけのCalendarを除外し、summaryOverrideまたはsummaryを表示します。
返されたURLへ追従せず、固定GoogleホストへpageTokenだけを渡します。循環ページTokenは取得失敗として扱います。
OAuthは1アカウントで、Calendarは複数選択できます。未選択ではイベントリクエストをしません。

## 6. Google Event → FixedEvent

選択したCalendarごとにGET /calendar/v3/calendars/{encodedID}/eventsを取得します。
timeMin/timeMaxを14日境界にし、singleEvents=true、showDeleted=false、orderBy=startTimeで繰り返しを各instanceへ展開します。
全ページ取得後に値モデルへ変換し、status=cancelledは除外します。
dateTimeのoffset・秒・小数秒を保持し、offsetなしはGoogleのIANA timeZoneが必要です。
dateだけの終日は活動Calendarのタイムゾーンでその暦日を塞ぎ、終了日を排他的に扱います。
Googleの日付はGregorianとして検証し、不正・混在・逆転区間はスナップショット全体を失敗させて直前結果を保持します。
IDはCalendar ID + Google event ID + occurrence開始を使います。
参考: [Events.list](https://developers.google.com/workspace/calendar/api/v3/reference/events/list)、[CalendarList.list](https://developers.google.com/workspace/calendar/api/v3/reference/calendarList/list)。

## 7. AvailabilityServiceとの接続

GoogleCalendarService → [FixedEvent] → 既存AvailabilityService → [AvailableSlot]です。
平日08:00–23:00、土日09:00–23:00、今日を含む14日間、重複結合・終日占有・現在時刻切り詰めをそのまま利用します。
GoogleのDTO、Token、URLSessionはAvailabilityServiceへ渡しません。

## 8. Schedulerとの接続

AvailableSlot → 既存ScheduleReplanner → 既存Scheduler → ScheduledBlockを維持しています。
一覧・予定・空き枠がすべて取得できた後に結果をまとめて置換し、失敗時に部分更新しません。
取得中のTask編集は、取得完了時点のTask配列を使って計算します。重複RefreshはisLoadingCalendarsで抑止します。
過去・進行中は保持し、未来だけ再生成します。新しい固定予定と進行中作業が衝突すれば保持して警告します。
Task操作と「再計算」は最後の空き枠を利用し、Googleへの再取得は「Google Calendarを再読み込み」で行います。

## 9. テスト結果

全153ケース成功。既存100ケースを維持し、53ケース追加しました。

| スイート | ケース数 |
| --- | ---: |
| SchedulerTests | 23 |
| TaskManagementTests | 27 |
| AvailabilityServiceTests | 25 |
| CalendarIntegrationTests | 16 |
| ScheduleReplannerTests | 9 |
| GoogleOAuthTests | 25 |
| GoogleCalendarTests | 14 |
| GoogleEventConversionTests | 12 |
| ReminderAssociationTests | 2 |

PKCE既知ベクトル、state/callback拒否、認証キャンセル、許可不足、Refresh保持/失効、保存失敗、アカウント分離、
API一覧・選択・pagination・401再試行・HTTP失敗、日時変換、Refresh失敗時の保持、取得中編集を検証します。
指定例の10:00–12:00授業/14:00–16:00バイトを合成Google応答として読み、
08:00–10:00/12:00–14:00/16:00–23:00の空き枠と300分Taskの非重複配置を確認しました。
この指定例は合成データによる単体テストです。Token/データのテスト値はすべて合成です。
別途、実アプリに表示された空き枠を読み取り、既存Schedulerへ渡す一時的な検証を行いました。
合成Task 3件・合計2,800分を8ブロックへ配置でき、枠内への配置、締切、非重複、終日予定の除外を確認しました。
この検証ではアプリ内Taskを変更せず、実予定を含む一時スクリプトを検証後に削除しました。実予定の日時・識別子・タイトルはリポジトリへ保存していません。

結果バンドル: /tmp/PersonalGantt-phase45-keychain-tests.xcresult。
ログ: /tmp/PersonalGantt-phase45-keychain-test.log。

## 10. macOS/iOSビルド結果

macOSアプリ・単体テスト成功。iOS Simulator（iPhone/iPad）ビルド成功。
Macで未設定時のGoogle設定シート・操作の無効化に加え、開発署名アプリで実ログイン・Calendar反映・Refreshを画面確認しました。
iOS画面操作・実機・visionOSは未検証。既存deployment targetは27.0のままです。

iOSログ: /tmp/PersonalGantt-phase45-keychain-ios-build.log。
MacのKeychainアクセスグループ追加後は署名無しのビルド/テストで確認しました。
adhoc署名ビルドは、Keychainに開発証明書が必要なためXcodeの署名検証で失敗します（/tmp/PersonalGantt-phase45-keychain-build.log）。
本人のApple Team設定後、Macの開発署名ビルドと署名検証も成功しました（/tmp/PersonalGantt-phase45-development-build.log）。
iOS/visionOS実機用Profileは端末未登録のため未作成です。Macでの実OAuth・Keychain保存・読み出しは成功しました。

## 11. 実Google Calendarの確認結果

本人がCalendar API、読み取り専用スコープ、OAuthクライアント、Appleの開発署名を設定し、Googleへのログインと許可を完了しました。
実Calendar一覧から複数選択して反映でき、選択したCalendarの固定予定がアプリへ取り込まれました。
通常予定で空き枠が分割され、終日予定の日には空き枠が生成されないことを画面で確認しました。
アプリ内の既存Taskが取得後の枠へ配置され、進行中のブロックは保持されました。手動Refreshも成功し、最終読み込み時刻が更新されました。
さらに、表示された実空き枠を既存Schedulerへ渡す検証で、合成Taskの複数日配置が固定予定を避けることを確認しました。
指定の授業・バイト例は合成テストで確認済みです。本人のGoogle Calendarへ確認用予定の作成・編集・削除は行っていません。
実予定をGoogle側で変更した後の差分反映、実Tokenの期限切れ更新、認証後の再起動復元は未検証です。
Cloud設定とアプリ設定の手順はdocs/GoogleOAuthSetup.mdにあります。

## 12. Gitへ秘密情報が含まれていないこと

実Token、Client Secret、実CalendarデータはGitへ追加していません。OAuth Client IDも実値は埋め込みません。
実認証情報は端末のKeychain、実Calendarデータは動作中のアプリのメモリで扱います。実データ検証用の一時スクリプトは削除しました。
TokenはKeychainのみ、Calendarスナップショットはメモリのみです。アプリに認証情報を出すログ処理はありません。
URLSessionはephemeral、cache/cookieなし、redirect拒否。TokenはAuthorizationヘッダーに入れ、API URLへ載せません。
UIエラーは固定の既知メッセージだけを使い、Googleの応答bodyや認証URLを表示しません。
.gitignoreでclient_secret*.json、GoogleOAuth.local.*、.env、PrivateVerification/等を除外します。
追加・既存追跡ファイルを確認し、合成テスト値以外の秘密情報・実Calendarデータがないことを検査しました。

## 13. Reminders連携前の残課題とEventKit整理

Calendar用EventKitのOS権限要求・一覧・イベント取得・sandbox権限・使用目的説明を削除しました。
旧Calendar変換はPhase 4の回帰確認のためテストターゲットにだけ残置しています。
EventKit自体は削除せず、Reminders/ReminderIdentityを別の責務として置きました。これはidentifier取得境界だけで、連携はまだありません。
Task.reminderIdentifierはPersonalGantt側に保存するための任意フィールドです。想定所要時間はPersonalGantt側のままです。
旧Task JSONにidentifierがなくても読め、編集・完了切替で関連IDを維持します。

実OAuth・Keychain保存/読み出し・実Calendar取得の基本経路は確認済みです。
残る実環境検証は認証後の再起動復元、Tokenの期限切れ更新、Google側の予定変更後のRefresh、iOS実機です。
Calendar選択はメモリ内のため再起動すると解除されます。選択の保存方法とTaskの所要時間・Reminder関連IDの保存方法を決める必要があります。
Reminder識別子変化/削除、締切なし・日付だけの締切、複数リスト選択、Taskとの対応も決めます。
Remindersの権限・取得・Task変換・所要時間メタデータはCalendarとは別のServiceへ実装する方針です。
Siri、Google予定書き込み、CloudKit、本格的Gantt、自動常時監視、completedMinutesは今回実装していません。
