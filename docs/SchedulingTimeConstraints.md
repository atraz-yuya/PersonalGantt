# Routine固定時間・Task個別／共通の配置禁止時間

2026-10-13〜14。ブランチ `codex/scheduling-time-constraints`。

## モデルと入力

- `AvailabilityExclusion`（Task用／Global用typealias）: UUID、曜日集合（Foundationの1=日〜7=土）、開始・終了のローカル分数。毎日・平日・任意曜日。開始0〜1439、終了1〜1440、開始<終了、曜日必須。重複IDは不可、1配列1000件まで。
- `Task.availabilityExclusions`、ローカル`ReminderTaskMetadata`・同期用`ReminderSyncMetadata.availabilityExclusions`: 初期／旧データは空配列。
- `ActivitySettings.globalAvailabilityExclusions`: 稼働時間とは独立。初期／旧データは空配列。
- `Routine.fixedStartMinuteOfDay`: nilで従来の自動配置。固定時は0〜1439、所要時間1〜1440分。終端は開始+所要時間。各発生日の`RoutineOccurrence`に開始Dateを導出する。
- 固定Routineの設定はRoutine編集、個別禁止はTask編集、共通禁止は設定→稼働時間。追加・編集・削除。禁止時間の編集は親のNavigationStackから遷移し、Taskの未保存入力を保持する。

## 配置と競合

`ActivityHours → 共通禁止をsubtract → Calendar固定予定をsubtract → 固定Routine予約 → Task別禁止をsubtract → 通常配置`。

区間差分は既存`IntervalSubtraction`を使用し、重複・隣接区間をまとめる。個別禁止で差し引いた時間は他のTaskへ残し、実際に配置した枠だけを共有slotから消費する。分割・締切・優先度・分散・日次上限・休憩を従来の処理で適用する。

固定Routineは予約を先に行い、通常Task／柔軟Routineに渡す枠から除去する。Calendar予定、共通禁止、他の固定Routine、稼働時間外、開始済み作業との重なりは固定位置を維持して警告する。上限には固定枠を先に算入し、固定枠自体が上限を超えても削除・移動しない。通常配置は残った上限内で行う。競合はTask行・詳細に表示し、チェックポイントにも保存する。

開始済み枠は既存の保護を維持し、予約・上限を二重計上しない。完了済み／スキップ済みは生成・予約しない。固定時刻を過ぎた未開始分は別時間へ再配置しない。Calendar選択時に固定枠全体が未取得範囲なら、取得済みとみなさず未配置・警告にする。

## 暦・時刻の制約

曜日・時刻は端末のローカルCalendarで計算する。日付越えの固定Routineは翌日まで一つの枠を保持し、日次上限は各暦日に分けて算入する。夏時間で開始時刻が存在しなければ移動せず警告、重複する時刻は最初の発生で一度だけ予約する。禁止時間は夏時間の重複時間を両方除外し、存在する実時間に適用する。日をまたぐ禁止時間は24:00までと翌日0:00からの2件に分ける。

固定Routineは部分実績があっても元の固定窓を縮めず、全量完了まで維持する。終了日に発生する固定Routineが日をまたぐ場合、計画期間を固定枠の実際の終了まで延ばす。最大90日で打ち切る場合は新規固定枠を範囲外へ配置せず、未配置・警告にする。開始済み枠は従来どおり保持する。Calendar選択時は延長部分も全体を取得するまで配置しない。

## Reminder・同期・バックアップ

Reminderのタイトル／OS側締切／本体はEventKit・iCloudが正。個別禁止はPG補助メタデータだけに保存し、EventKitへ書き込まない。既存external identifier+occurrence keyのハッシュで照合し、各端末のTask UUID・実績を維持する。入力待ちで所要時間のみ再設定しても、既存の禁止時間を消さない。

| 設定 | 既存同期Entity |
| --- | --- |
| 通常Taskの個別禁止 | `task` |
| Routine固定開始 | `routine` |
| Reminderの個別禁止 | `reminderMetadata` |
| 共通禁止 | `schedulingSettings.activitySettings` |

新Entity／別通信方式は追加しない。既存revision（日時→counter→device UUID）、LWW、競合記録、tombstone、原子的な保存・ACKを使う。制約配列の内部も未知キーを拒否する。旧端末が新設定を消すことを避けるため、ローカルprotocol/schemaの定数を2→3へ更新。両端末の最新版への更新が必要で、既存ペアリングは維持する。Network／Multipeer transport・Keychain・OAuthへの変更なし。

JSON backup／PlanSnapshotに含める。旧キー欠落時は空配列／nilで復元し、旧snapshot／backupバージョン互換を維持する。新しい固定枠の競合情報は旧snapshotでnilとして読む。

## 自動検証

追加33テスト関数・展開47ケース。既存610+追加47=657ケース（499関数）が成功。

`TimeConstraintTests`: 毎日／平日／曜日指定、複数／重複／隣接／稼働時間外、Calendarとの重複、Taskとの組合せ、90分の17:30–18:00+19:00–20:00分割、禁止削除、締切不足、日次上限、Balanced、無効入力、固定時刻OFF、各曜日発生ID維持、固定優先予約、各競合、固定上限超過、日付越え、完了／スキップ／開始済み、未取得Calendar、休憩、夏時間、最終発生日の日付越えと14／90日上限・全Calendar範囲取得・開始済み保護、旧モデル読み込み、JSON往復、同期payload内の未知フィールド拒否。

`ReminderMetadataSyncTests`追加: 通常Task・Routine・共通禁止の双方向同期と競合反映、Reminder補助制約の双方向同期／削除／所要時間再設定／UUID・実績保持／再起動／EventKit書込みなし、実SwiftData・JSONファイル保存、新旧backup round-trip・復元。

最終結果 `/tmp/PersonalGantt-time-tests-final-4.xcresult`: 499関数／展開657ケース、失敗0・スキップ0。署名済みmacOS／iOS実機向けの最終build双方成功。最終ソースを両端末へ更新して起動済み。更新後、Macの同期画面で信頼済みiPhoneと「同期済み」を確認。ビルド記録: `/tmp/PersonalGantt-time-mac-final-4-build.log`、`/tmp/PersonalGantt-time-ios-final-4-build.log`。既存Multipeer非推奨等のSDK警告は残る。Simulator追加buildは実機版更新を優先して途中停止し、UIは両実機で検証した。

## 実機検証（Mac Neo・iPhone 15、OS 27.0.1）

- iPhoneの毎週火曜19:00・60分RoutineをMacで10月20日19:00〜20:00として確認。
- テスト90分Taskは、毎日00:00〜17:30と18:00〜19:00を除外し、締切10月14日20:00に設定。両端末の詳細で17:30〜18:00（30分）＋19:00〜20:00（60分）を確認。追加の00:00〜17:30ルールは検証用の候補時間を限定するため。Macの禁止時間編集も動作。
- 実機検証中、iPhoneでTask編集内の禁止時間sheetが即閉じる不具合を検出。親NavigationStackでのページ遷移へ修正し、iPhoneで入力・保存・分割配置を再確認。Macでも同じ編集ページの追加・保存を確認。
- Mac再起動後も固定設定とTaskの2枠／制約を保持。
- 共通禁止19:00〜20:00をMacで設定。固定Routineは同じ時刻を維持し、Task行に「共通の配置禁止時間と重複しています。」を表示。
- 通常Wi-Fiで「今すぐ同期」1回。iPhoneで共通禁止19:00〜20:00と、`TimeRules-Reminder`が1件・30分・補助締切10月15日23:59・個別禁止18:00〜19:00で届いたことを本人確認。
- USBを外しMacをiPhoneのテザリングへ切替。iPhoneで共通禁止を12:00〜13:00、Reminderの個別禁止を18:00〜18:45へ変更し、「今すぐ同期」1回。Macの編集画面で18:00〜18:45・30分・同じ補助締切を確認。共通禁止の競合警告も解消。再ペアリングは不要。
- Reminder本体のタイトル・Apple側日時は変更せず、補助設定だけを同期。Apple側の新規テストReminderは日時なしで作成した。通常Taskとして二重同期・追加生成なし。
- 検証後、今回のテストRoutine・90分Task・共通禁止・AppleテストReminderを片付け、削除の同期を確認。Macのタスク一覧からテスト項目が消え、共通禁止は「設定なし」。既存の作業データと日別稼働時間の変更は保持。

[匿名化した検証記録](verification/SchedulingTimeConstraints-2026-10-14.log)。JSON書き出しによる実機固定枠の確認も行い、個人の完全なbackup／予定はGitへ含めない。

現在のGoogleログインが未接続のため、新規取得した実Google予定との競合はこの回では未検証。実機は前回取得済みのCalendar範囲を利用し、Calendar衝突・未取得範囲ガードは自動テストで確認した。OAuth設定は変更していない。

## 変更範囲

Models: `AvailabilityExclusion`（新規）、`ActivitySettings`、`Routine`、`Task`、`TaskDraft`。
Scheduling: `FixedRoutinePlacement`（新規）、`PlanningHorizonResolver`、`RoutinePlanner`、`Scheduler`、`ScheduleOptimizationEngine`、`ScheduleReplanner`、`SchedulingResult`、`ScheduleViewModel`、`ReminderSyncViewModel`。
Persistence／Presentation: `PlanSnapshot`、`ScheduleViewModel+Presentation`。
Services／Sync: `AvailabilityService`、`ReminderMetadataStore`、`ReminderTaskMapper`、`ReminderTransferMapper`、`ReminderSyncMetadata`、`SyncPayloadValidator`、`LocalSyncProtocol`（定数のみ）。
Views: `AvailabilityExclusionEditor`（新規）、`ActivitySettingsView`、`TaskEditorView`、`RoutineEditorView`、`TaskRowView`、`TaskDetailView`、`WorkloadRoutineView`。
Tests: `TimeConstraintTests`（新規）、`ReminderMetadataSyncTests`。
Docs: 本書、README、匿名化した検証記録。

既存ユーザー変更の`Config/AppInfo.plist`整形と`project.pbxproj`のTeam設定は保持し、この機能のcommitから除外する。アプリのデータコンテナ／設定は削除・初期化しない。

## Git

ブランチ: `codex/scheduling-time-constraints`。機能・テスト・本報告を一つのcommitにまとめる。commit IDは最終回答に記載する。
