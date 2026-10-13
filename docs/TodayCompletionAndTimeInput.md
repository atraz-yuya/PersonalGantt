# 完了TaskのToday表示と4桁時刻入力

2026-10-14。

## 完了後の表示

開始済みの予定枠は履歴のために保存するが、以前の`TodaySummary`はその枠もTodayの作業カードへ返していた。完了を除外していたのは「次の作業」と残り予定時間だけだった。

Todayのカードは、現在存在する未完了Taskの枠だけにする。通常Task・Routineの当日分・Reminder由来Taskに共通して適用し、分割された同じTaskの全カードを除く。ReminderがApple側で完了・削除されて再取得された場合も除く。完了の取り消しは既存のタスク画面からできる。

Task本体・予定履歴・WorkSessionは削除しない。日別Timelineや実績集計へ残す。所要時間分の実績を記録しただけでTaskを自動完了にはしない既存方針も維持する。

## 時刻入力

`ClockTime`で`HHmm`と従来の`HH:mm`を受け付ける。入力欄で4桁が揃うと時刻表示に整える。

- `0930` → `09:30`
- `1900` → `19:00`
- `2400` → `24:00`（稼働時間・禁止時間の終了のみ）

通常／日別稼働時間、共通／Task個別禁止時間、Routine固定開始時刻へ適用する。締切は日付のDatePickerと時刻入力に分け、Task編集・入力待ち・Reminder補助設定にも適用する。締切の4桁入力は選んだ日付を変えず、表示Calendarの時刻だけを変更する。Apple側に締切があるReminderは従来どおり変更不可。

不完全な入力、25時、60分、逆転した時間範囲は保存できない。日付付き時刻でDSTにより存在しない時刻は別時間へ動かさず、保存を止める。フォーム表示や日付更新だけでは時刻を独自に書き換えず、ユーザーの時刻入力で更新する。

保存形式・同期Entity・LWW・Scheduler・OAuth・署名・アイコンの変更なし。

## 自動検証

追加7テスト関数・展開25ケース。以前の657ケースを含め全682ケース（506関数）が成功、失敗0・スキップ0。

- 通常Taskの開始済み枠を保持した完了、Today非表示、実績保持、再起動、未完了へ戻す操作。
- Routine当日分の完了と翌日分の維持。
- Apple側Reminder完了／削除で、保存済み枠があってもTodayへ残らないこと。
- 4桁／コロン付き時刻、先頭ゼロ、日付保持、24:00終了、無効入力、DST gap。

結果: `/tmp/PersonalGantt-today-clock-final-tests.xcresult`。

## ビルド・実機

署名済みmacOS／iOS実機buildが成功。Mac NeoとiPhone 15を更新して起動済み。

Macの未保存Taskフォームで0930→09:30、1900→19:00、締切日が変わらないこと、2401で保存無効→1900で再び有効になることを確認。Routineの未保存フォームで2330→23:30、所要時間60分のプレビューが23:30〜00:30（翌日）になることを確認。検証用の入力はキャンセルし、ユーザーの作業データは変更しない。

iPhone上の入力操作は、この修正では実機UI操作による検証未実施。iPhone build・更新インストール・起動は完了している。

ビルド記録: `/tmp/PersonalGantt-today-clock-mac-build.log`、`/tmp/PersonalGantt-today-clock-ios-build.log`。

## 変更ファイル

`Models/ClockTime.swift`（新規）、`Models/ActivitySettings.swift`、`Presentation/TodaySummary.swift`。

`Views/ClockTimeFields.swift`（新規）、`ActivitySettingsView.swift`、`AvailabilityExclusionEditor.swift`、`RoutineEditorView.swift`、`TaskEditorView.swift`、`InputQueueView.swift`、`ReminderSelectionView.swift`。

`Tests/ClockTimeTests.swift`（新規）、`TodayTests.swift`、`ReminderScheduleIntegrationTests.swift`、README、本書。

既存の`Config/AppInfo.plist`整形と`project.pbxproj`のSigning Teamの変更はこのcommitへ含めない。

ブランチ: `codex/today-completion-time-input`。commit IDは最終回答に記載する。
