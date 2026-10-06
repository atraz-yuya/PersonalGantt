# Phase 6：Apple Reminders連携

2026-10-06。予定はGoogle Calendar API、Taskの取得元はApple Remindersとする構成を接続しました。
ユーザー指定は「不足項目は入力待ち」「日付のみの締切はその日23:59」「完了状態だけ双方向同期」です。

## 変更ファイル

| ファイル | 役割 |
| --- | --- |
| PersonalGantt/Models/ReminderRecord.swift | Reminderリスト・Reminder・権限の値モデル。 |
| PersonalGantt/Services/Reminders/ReminderService.swift | Reminders専用Providerと安全なエラーの境界。 |
| PersonalGantt/Services/Reminders/EventKitReminderService.swift | 権限、リスト一覧、選択リストの取得、完了状態のみの書き込み。 |
| PersonalGantt/Services/Reminders/ReminderEventKitConverter.swift | EventKitの日付要素と識別子をSwift値へ変換。 |
| PersonalGantt/Services/Reminders/ReminderTaskMapper.swift | 不足項目の判定、Task変換、識別子移行、繰り返し作業の識別。 |
| PersonalGantt/Services/Reminders/ReminderMetadataStore.swift | 選択・所要時間・補完締切・関連付けUUID・除外状態を端末に保存。 |
| PersonalGantt/Services/Reminders/ReminderIdentity.swift | 使用中の識別子の位置付けを更新。 |
| PersonalGantt/Scheduling/ReminderSyncViewModel.swift | 取得と設定保存、入力待ち、完了同期、失敗時の状態保持。 |
| PersonalGantt/Scheduling/ScheduleViewModel.swift | 手動Taskと取り込みTaskの統合、既存の空き枠を利用した再計算。 |
| PersonalGantt/Views/ReminderSelectionView.swift | 複数リスト選択、入力待ち一覧、所要時間と補完締切の設定。 |
| PersonalGantt/Views/TaskEditorView.swift | Reminder側のタイトル・締切の編集を制限。 |
| PersonalGantt/Views/TaskRowView.swift | 連携元の表示、完了同期、配置対象から外す操作。 |
| PersonalGantt/ContentView.swift | Reminders選択・Refresh・前面中のEventKit変更通知を接続。 |
| PersonalGantt/PersonalGantt.entitlements | macOSのEventKit Reminders用Sandbox権限。 |
| PersonalGantt.xcodeproj/project.pbxproj | Debug/ReleaseのReminders用途説明。 |
| PersonalGanttTests/ReminderConversionTests.swift | 締切、入力待ち、識別子・繰り返しの純粋テスト。 |
| PersonalGanttTests/ReminderMetadataStoreTests.swift | 保存復元、不正値、破損時の保護。 |
| PersonalGanttTests/ReminderSyncTests.swift | 選択、設定、同期、取消・失敗・権限・同時要求。 |
| PersonalGanttTests/ReminderScheduleIntegrationTests.swift | Google→空き枠→Reminders Task→再配置の統合テスト。 |
| PersonalGanttTests/ReminderTestDoubles.swift | 合成Provider・ローカルストア・固定時計。 |
| .gitignore、README.md、docs/Phase6.md | 私的設定ファイルの除外、操作と検証結果。 |

Scheduler、AvailabilityService、ScheduleReplanner、Google OAuth/APIのコードは変更していません。
既存のXcode Personal Team設定は作業ツリーに残し、今回のコミットには含めません。

## 権限とEventKitの責務

「使用するRemindersを選択」→「Remindersへのアクセスを許可」から明示的に要求します。
起動・前面復帰・Refreshでは権限確認だけを行い、OS許可画面を自動で開きません。
`requestFullAccessToReminders()`と`NSRemindersFullAccessUsageDescription`を使用します。
AppleのReminders権限は読み書きをまとめたfull accessです。読み取り専用の別権限はありません。
実際の書き込みAPIは、選択したリストの対象Reminderの`isCompleted`変更だけです。
拒否・制限・権限取り消しは案内を表示し、そのセッションの以前のTaskと計画を保持します。

macOS Sandboxでは`com.apple.security.personal-information.calendars`がEventKit Remindersにも必要です。
名前にcalendarsが含まれますが、Apple Calendarのイベント取得・権限要求は追加していません。
Phase 4のCalendar取得用EventKit実装は引き続き削除済みです。旧変換だけ合成テストのfixtureに残っています。
Reminders用EventKitは`Services/Reminders`にあり、Google CalendarのProviderとは独立しています。

参考: [AppleのEventKitアクセス説明](https://developer.apple.com/documentation/EventKit/accessing-the-event-store)、
[Remindersのfull access API](https://developer.apple.com/documentation/eventkit/ekeventstore/requestfullaccesstoreminders(completion:))。

## UIとデータの所有元

1. 使用するReminderリストを複数選び「反映」します。空選択では全リストのReminderを取得しません。
2. 所要時間または締切が不足する未完了Reminderを「入力待ち」として表示します。
3. 「所要時間・締切を設定」で1分以上の整数を入力します。元の締切がない場合だけPersonalGanttで補完できます。
4. 必要項目がそろうとTaskが生成され、既存のGoogle空き枠へ配置されます。
5. Taskの完了／未完了操作はRemindersへの保存成功後に反映します。
6. 「配置対象から外す」はPersonalGanttの除外設定です。ネイティブReminderを削除しません。再度設定して配置対象へ戻せます。

タイトルと元の締切の正はApple Remindersです。変更はRemindersアプリで行います。
Remindersに所要時間を書き込まず、タイトル・締切・メモ・priorityも書き換えません。
空タイトル、0以下・小数・整数範囲を超える所要時間、不正な締切ではTaskを作りません。
日付だけなら23:59:00、時刻付きならその時刻、浮動日付なら現在の活動Calendarのタイムゾーンを使用します。
存在しない日付やDSTで存在しない時刻は入力待ちです。
繰り返しReminderはReminders側の有効な締切が必要です。締切なしの繰り返しをローカル補完だけで配置しません。
開始／終了時刻の入力UIはありません。ScheduledBlockはSchedulerが決定します。

サンプルTaskの自動追加を終了し、起動時のTaskはRemindersの取得後に復元します。
手動で追加するTaskは引き続き利用できますが、ネイティブRemindersへの新規作成は行いません。

## 保存と識別子

SandboxのApplication Support配下`PersonalGantt/ReminderMetadata.json`へJSONを原子的に保存します。
保存内容は選択リストID、ReminderローカルID・外部ID・リストID、Task UUID、所要時間、補完締切、除外状態、繰り返しの発生識別用締切要素です。
Reminderのタイトル・メモ、Googleイベント、Token、ScheduledBlockは保存しません。
書き込み失敗時は設定とTaskを公開せず、以前の状態を保ちます。破損ファイルは自動上書きしません。
起動時に設定を復元し、EventKitから最新のReminderを取得してTaskを再生成します。
Google認証Tokenは従来のKeychain、Google Calendar選択は従来のUserDefaultsのままです。

通常は`calendarItemIdentifier`に対応するTask UUIDを保存・再利用します。
ローカルIDが変わった場合の移行は「同じリスト・一意で空でない外部ID・旧ローカルIDが今回の取得に存在しない」を満たす場合だけです。
タイトルの類似や締切から関連付けを推測しません。曖昧な場合や異なるリストへの移動は入力待ちとして新規関連付けします。
同じローカルIDでもリストまたは既知の外部IDが変われば、別のReminderとして扱います。
繰り返しの締切要素が次の発生へ変わるとTask UUIDを更新し、所要時間は引き継ぎます。
前回の保護ブロックの予約時間を次回の必要時間から差し引かないためです。

## 接続と再計算

    Google Calendar API → FixedEvent → AvailabilityService → AvailableSlot
    Apple Reminders → EventKitReminderService → ReminderRecord
        → ReminderSyncViewModel + ローカル設定 → Task
    AvailableSlot + Task + 既存ScheduledBlock → ScheduleReplanner → Scheduler

Task生成・所要時間設定・補完締切変更・配置解除・完了保存成功・外部Reminderの変更取得で再計算します。
これらのTask操作ではGoogle APIを再呼び出しせず、直近の空き枠を再利用します。
起動・前面復帰、前面中の日付切替・タイムゾーン変更、手動Refresh、リスト選択反映でRemindersを読み直します。
`EKEventStoreChanged`は前面中だけ読み直します。取得／保存中の通知はまとめ、同時取得をしません。
バックグラウンドでの常時監視は追加していません。
取得中のキャンセル・不正スナップショット・一覧/Reminder/設定保存の失敗は以前の状態を保持します。
完了保存直前に、識別子・リスト・書き込み可否・読み取り時の完了状態を検査します。
競合する完了変更は上書きせず、Refreshを案内します。
完了時に次の繰り返し発生が返る場合も、Task識別子を保存してから公開します。
そのローカル保存が失敗した場合、ネイティブの完了操作は成功している可能性があります。
PersonalGanttは以前のTaskを保持し、保存先の復旧後のRefreshで最新の状態に追従します。
過去と進行中のブロックは既存Replannerが保護し、未来の未完了作業のみ再配置します。

## テストとビルド

最終結果バンドルの集計で**全242ケース成功、失敗0、スキップ0**です。
既存181ケースを維持し、追加61ケース。Xcodeの定義数190をパラメータ展開すると242ケースです。
テキストログの行数では一部の出力が重なるため、件数はxcresultのデバイス別集計を採用しています。
結果: `/tmp/PersonalGantt-phase6-completion-tests.xcresult`。

追加検証は権限、リスト選択、不足項目、日付/TZ/DST、不正入力、保存復元、破損、取得取消、完了同期失敗・競合、
外部変更・削除、識別子変更・再利用、繰り返し、Googleとの統合、過去/進行中の保護です。

| 検証 | 結果 |
| --- | --- |
| macOS単体テスト | 成功。実EventKitの読み書きは行わず合成データで実行。 |
| macOS Apple Development署名付きビルド | 成功。codesignのstrict/deep検証も成功。 |
| iOS Simulatorビルド | 成功。実機・Simulatorでの権限操作は未検証。 |
| コンパイラエラー・Swift警告 | なし。AppIntents.framework未使用によるメタデータ抽出スキップ警告のみ。 |

## 実macOSでの確認

ユーザーがOSアクセスを許可した後、選択リストの実Reminderを取得できました。
ユーザー承認の専用リスト「PersonalGantt検証」とReminder「Phase 6確認」だけで以下を実施しました。
通常のReminderの内容・完了状態は変更していません。

- ネイティブRemindersで日付のみの締切を10月7日に設定 → PersonalGanttで10月7日23:59と表示。
- 未設定の所要時間を「入力待ち」と表示 → 60分を設定するとTaskとして08:00–09:00に配置。
- Googleの既存検証Calendarにある10月7日08:00–12:00の予定を選択 → 同じTaskを12:00–13:00へ再配置。
- PersonalGanttで完了 → Apple Remindersの検証リストでも実行済みになり、未来の配置を除去。
- Apple Remindersで未完了へ戻す → PersonalGanttでも未完了に戻り、12:00–13:00へ再配置。
- 手動Reminders Refresh → 成功。
- アプリ終了・再起動・前面復帰 → 選択と60分設定、締切、最新完了状態を復元し、12:00–13:00に配置。
- PersonalGanttで配置対象から外す → Task/未来配置を除去し、ネイティブReminderが未完了のまま残ることを確認。

検証後はGoogle・Remindersとも検証前の2つの選択へ戻しました。
検証用Calendar/Reminderリストは選択対象外で残しています。
実データの画面証拠は`/tmp`だけに保存し、Gitには含めていません。

## Gitと残課題

差分と追加ファイルを検査し、実Token、Client Secret、実予定/Reminderのスナップショット、アカウントIDはコミット対象に含めていません。
テストの識別子・応答・認証値はすべて合成です。実Reminder設定ファイルはアプリSandboxの外部保存先にあり、Git管理外です。

- iOS実機の権限・ネイティブ完了同期、複数Appleデバイスでの確認は未実施。
- 所要時間・補完締切・除外・Task UUIDは端末ローカルです。Reminders自身の内容と完了状態はApple側の同期に従います。
- 手動TaskとScheduledBlock履歴は終了時に消えます。再起動後の過去/進行中ブロック保護は、計画履歴保存を設計する次のPhaseの課題です。
- 古い/削除済みReminderのローカル設定は自動消去しません。将来の整理とバックアップ/データ移行を検討します。
- 外部IDが曖昧・リスト移動・全面同期で識別子が変化した場合、所要時間の再設定が必要になることがあります。
- 繰り返しは取得された次の発生だけを扱います。複数回分の先行展開や作業実績、厳密な同時更新トランザクションは未実装です。
- Googleへの書き込み、Reminder新規作成・削除・タイトル/締切の書き込み、Siri専用機能、CloudKit、SwiftData、本格Gantt、常時バックグラウンド監視、completedMinutes、priorityは追加していません。

次のPhaseの前に、計画履歴の保存範囲、端末間の所要時間同期方法、Reminder識別子移行のユーザー操作、
繰り返し作業と実績の扱い、Google/Remindersが取得できない状態で新規配置を許すかを決める必要があります。
