# 個人利用：バックアップとMac・iPhone・iPadの手動受け渡し

2026-10-07。有料Developer Programへの加入を行わず、CloudKitの自動同期を見送る方針へ変更しました。
各端末でGoogle Calendar・Apple Remindersへ接続し、PersonalGantt固有のデータはファイルで受け渡します。
個人利用を想定しており、App Storeへの公開やCloudKit Containerの作成は行っていません。

## 操作

1. 送り元の上部「バックアップ」から「バックアップを書き出す」を選ぶ。
2. 保存先を選び、`PersonalGantt-Backup-日付.json` を保存する。
3. AirDropやご自身が管理するFilesの保存先などで、受け取り先の端末へファイルを渡す。
4. 受け取り先でGoogleにログインし、使用Calendarを選ぶ。Remindersも許可して使用リストを選ぶ。
5. 「バックアップ」→「ファイルから読み込む」でJSONを選ぶ。
6. 書き出し日時・Task数・履歴数・所要時間設定数を確認し、「このファイルを読み込む」を押す。
7. RemindersとGoogleの最新データを再取得し、未来の作業を再計算する。

同じ端末でのバックアップ復元にも使えます。
端末内のTaskをファイルの内容で置き換えるため、受け取り先のTaskを残したいときは、先にその端末のファイルを書き出してください。
選んだファイルが今回採用する状態です。複数ファイルの自動マージ・変更時刻による競合解決・自動同期は行いません。
古いファイルを選ぶと、そのファイル時点のTask状態を復元します。確認画面の日時を確認してください。

## 引き継ぐもの

| 対象 | 動作 |
| --- | --- |
| 手動Task | UUID、タイトル、所要時間、締切、完了状態をファイルから復元。ファイルにない手動Taskは配置対象から外れる。 |
| Reminder設定 | 所要時間、補完締切、配置対象外、繰り返し回の識別情報。別端末では外部識別子で確認する。 |
| 計画・履歴 | ScheduledBlock、未配置情報、配置対象外Taskの表示タイトル。開始済みの受け取り先の枠も保持する。 |
| 前回のGoogle表示 | Calendar・FixedEvent・AvailableSlot・対象期間。現在のClient IDとCalendar選択が同じ場合だけ使用する。 |
| 受け取り先の連携 | Google認証・Client ID・使用Calendarは変更しない。別端末のRemindersの許可・使用リストも変更しない。 |

同じ端末へ戻す場合はReminderの端末内IDとリスト選択も復元します。
別端末では、受け取り先のリスト選択と既存のReminder設定を維持し、一致した設定をファイルの値で更新します。
別端末ではローカルID・リストID・Task名による推測で関連付けません。
ファイル側と、選択したネイティブReminder側の両方で外部識別子が一意な設定だけを適用します。
受け取り先のTask UUIDを維持し、受け渡した履歴の対応UUIDを変換します。作業枠の開始・終了をユーザーが入力する方式には変えません。
対応UUIDも端末内へ保存し、設定保存後・計画更新前に終了しても次回取得で履歴との対応を回復します。
繰り返しの次の回には所要時間を引き継ぎますが、前の回の履歴を次の回の配置分として数えません。

まだ対象リストを取得していない場合、外部IDがない場合、同じIDが複数ある場合は設定を「対応確認待ち」として端末内に保存します。
対象リストを選択して再読み込みすると、安全に一致した設定を適用します。不明な設定は残し、名前では照合しません。
Reminders側のタイトル・元の締切・完了状態は再取得したRemindersを正とします。
読み込みによってネイティブReminderの完了/未完了を変更したり、Google予定を書き換えたりしません。

開始済みの時間枠は両端末のものを保持します。重複する保持枠があれば警告し、Ganttで確認できます。
これらは予定の履歴であり、作業実績やcompletedMinutesではありません。
将来の時間枠は既存ScheduleReplannerに渡して再生成し、現在の予定を取得後に再計算します。
連携設定が異なる場合は旧Calendarの空き枠を使わず、最新取得を待ちます。

## ファイル・認証・保存の安全性

- ファイルはversion=1のJSONです。日時・ID・Task・区間・Reminder設定を検証し、不正/未対応形式は受け付けません。
- 最大50MB。読み込み前にサイズを確認します。
- Token、Refresh Token、Client Secret、Keychain、OSアクセス許可は含めません。
- Task名・予定名などの個人データは含みます。暗号化形式ではないため、ご自身が管理する場所へ保存してください。
- ファイルはOS標準の保存/選択画面で指定します。Appが自動送信する処理はありません。
- ログやGitに実バックアップを追加しません。既定のバックアップ名は.gitignoreで除外します。

SwiftDataの計画とJSONのReminder設定を両方置き換える前に、復元前の状態をSandbox内 `BackupRollback.json` へ原子的に保存します。
両方の更新とJournal削除が成功してから、画面に新しい状態を公開します。
保存に失敗したら両方を復元前へ戻します。巻き戻しも失敗したら追加操作を止め、起動時に復元前の状態へ戻します。
復元中にアプリが終了した場合も、次の起動時に同じJournalから巻き戻します。
読み込めないJournalは勝手に削除せず、保存処理を停止して案内します。

## 変更ファイル

- `Persistence/PersonalGanttBackup.swift`：ファイル形式・検証・復元前Journal・巻き戻し。
- `Persistence/LockedBackupStores.swift`：起動時の回復に失敗した場合の保存停止。
- `Services/Reminders/ReminderTransferMapper.swift`：別端末の外部ID照合・UUID対応・繰り返し回。
- `Services/Reminders/ReminderMetadataStore.swift`：対応確認待ちの保存、旧JSONの読み込み互換性。
- `Scheduling/ReminderSyncViewModel.swift`：設定の書き出し/復元・再取得後の照合・回復失敗時の変更停止。
- `Scheduling/ScheduleViewModel.swift`：バックアップ作成、開始済み枠の保持、復元後の再計算、起動時の回復。
- `Views/BackupFileDocument.swift`：JSONのFileDocumentと読み込み前の確認画面。
- `ContentView.swift`：書き出し・ファイル選択・確認・エラー表示。
- `Views/IntegrationStatusView.swift`：対応待ち・読み込み結果・個人データ保存の説明。
- `Presentation/ScheduleViewModel+Presentation.swift`：回復失敗中の操作を無効化。
- `PersonalGantt.entitlements`、Xcode project：ユーザーが選んだ保存先への書き込みを許可。CloudKitは追加しない。
- `PersonalGanttTests/BackupTests.swift`：ファイル往復、移行、照合の境界、失敗、中断、実ディスクの回復。
- `.gitignore`、README、Phase 8報告書、この手順書。

Scheduler・AvailabilityService・ScheduleReplannerの純粋なコードは変更していません。
ユーザーの既存Team設定は維持し、コミットには含めません。

## 検証・制約

全303ケース成功、失敗0・スキップ0。既存283ケースに20ケースを追加しました。
結果：`/tmp/PersonalGantt-backup-final3-tests.xcresult`。定義数237、パラメータ展開後303です。
不正形式/値の拒否、旧JSON互換、別端末Taskの完了/削除の引継ぎ、開始済み保持、外部IDの一意/欠落/重複、繰り返しの次の回、
保留設定の後日の適用、不足締切での履歴保持、保存失敗の巻き戻し、実SwiftData+JSONの起動時回復、UUID対応の中断回復を検証しました。

Macでは元の状態をファイルへ退避し、合成Taskを60分/12:00–13:00へ配置して書き出しました。
90分/12:00–13:30へ編集した後、選択画面から元の60分のファイルを読み込み、確認画面・60分への復元・連携の再取得を確認しました。
検証後に最初のファイルを読み込み、Task 0件・元の2 Calendar選択へ戻しました。通常の予定/Reminderに書き込みは行っていません。
証拠は `/tmp/PersonalGantt-backup-preview.png` と `/tmp/PersonalGantt-backup-restored.png`。
実ファイルで認証Token/Client Secretのフィールドがないことを確認しました。実ファイル・画面証拠はGitに含めません。
最終macOSコンパイルとiOS Simulatorビルドは成功しました。
ファイルの実操作に使用したMacビルドはApple Development署名付きです。
最終調整版も現在のソースで署名付きビルド成功（`/tmp/PersonalGantt-backup-mac-current-build.log`）。`codesign --verify --deep --strict` も成功しました。
最新版の再起動後、保存済みの選択によるGoogle/Remindersの再取得、端末内保存、バックアップメニューを確認しました。
画面証拠は `/tmp/PersonalGantt-backup-final-launch.png`。既存Taskや通常の予定・Reminderの変更は行っていません。
iPhone/iPadはビルドと合成データによる受け渡しテストまでで、実機間でのファイル受け渡しは未確認です。
初回のiPhone/iPadインストールはXcodeからの個人用署名と実機の接続が必要です。
[接続・実機インストール・ファイル往復の手順](PersonalDeviceSetup.md)を用意しました。現在の最低対応OSはiOS/iPadOS 27.0で、接続する実機のOS確認が必要です。
無料Appleアカウントの実機用Provisioning Profileは発行から7日で期限が切れるため、再ビルド・再インストールが必要になる場合があります。
[Apple公式のPersonal Teamの制約](https://developer.apple.com/support/compare-memberships/)を参照してください。
複数端末で同時に編集した内容の自動統合、常時同期、保留設定の手動ペアリングUI、ファイル暗号化は未実装です。
