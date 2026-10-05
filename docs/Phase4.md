# Phase 4：AvailabilityService + Calendar連携 実装報告

実装・検証日: 2026-10-06。Phase 3コミット8525aeeを起点に、codex/calendar-availabilityブランチで実装しました。

## 1. 変更ファイル

| ファイル | 内容 |
| --- | --- |
| PersonalGantt/Models/ActivitySettings.swift | 平日/土日の活動時間と対象日数。 |
| PersonalGantt/Models/CalendarSource.swift | カレンダー識別情報と権限状態。 |
| PersonalGantt/Models/FixedEvent.swift | EventKitに依存しない固定予定。 |
| PersonalGantt/Services/CalendarService.swift | 権限・一覧・選択したイベント取得と値モデルへの変換。 |
| PersonalGantt/Services/AvailabilityService.swift | 活動枠生成・占有区間の結合と差し引き。 |
| PersonalGantt/Scheduling/ScheduleReplanner.swift | 過去/進行中の保持と未来計画の再生成。 |
| PersonalGantt/Scheduling/Scheduler.swift | 保持済み計画時間を秒単位の任意引数で受け取る。 |
| PersonalGantt/Scheduling/ScheduleViewModel.swift | 選択・Refresh・空き枠生成・再計算の接続。 |
| PersonalGantt/Views/CalendarSelectionView.swift | 権限案内・複数選択・手動更新。 |
| PersonalGantt/ContentView.swift | 選択シート、Refresh、期間、取得状況、競合警告。 |
| PersonalGantt/PersonalGantt.entitlements | Mac sandboxのCalendar権限。 |
| PersonalGantt.xcodeproj/project.pbxproj | 使用目的説明・Mac限定entitlement設定。 |
| PersonalGanttTests/AvailabilityServiceTests.swift | 25ケース追加。 |
| PersonalGanttTests/CalendarIntegrationTests.swift | 16ケース追加。 |
| PersonalGanttTests/ScheduleReplannerTests.swift | 9ケース追加。 |
| README.md、docs/Phase4.md | 仕様・検証・制約。 |

既存のSchedulerTestsとTaskManagementTestsは変更していません。

## 2. EventKit権限処理

EventKitはCalendarServiceに閉じ込め、ViewModelはCalendarProvidingを利用します。起動時は権限確認のみで、自動でOSダイアログを表示しません。
選択画面で「カレンダーへのアクセスを許可」を押すと、未決定/write-onlyの場合にrequestFullAccessToEvents()を呼びます。
読み取りにはfull accessが必要です。denied/restricted/write-onlyでは取得せず、OS設定から許可する案内や制限理由を表示します。
両OSの生成Info.plistにNSCalendarsFullAccessUsageDescription、Mac署名にcom.apple.security.personal-information.calendarsを設定しています。
APIはfull accessを要求しますが、実装にイベントの追加・変更・削除はありません。
API仕様はAppleの[Accessing the event store](https://developer.apple.com/documentation/eventkit/accessing-the-event-store)に基づきます。
権限/取得失敗では最後の成功スナップショットと結果を保持し、未取得なら活動時間だけの暫定配置と明示します。

## 3. FixedEvent → AvailableSlot

FixedEventはID、calendarID、title、start、end、isAllDay、isCancelledを持つ値モデルです。選択Calendarを明示したpredicateで対象期間を取得します。
キャンセル・非有限日時・長さ0以下を除外し、繰り返し予定は各occurrenceを開始/終了込みのIDで区別します。

1. 今日を含む14日間を暦の日加算で生成する。今日+14日の00:00は対象外。
2. 平日08:00–23:00、土日09:00–23:00の活動枠を生成する。
3. 今日の開始を現在時刻まで切り詰める。
4. 通常予定を占有区間へ、終日予定を対象日の全日占有へ変換する。
5. 重複・隣接した占有区間を結合し、活動枠から差し引く。
6. 正の長さの残り枠を開始日時順に返す。

活動時間外の予定は枠を減らさず、日跨ぎ予定は各日の重なる部分を塞ぎます。完全占有日は枠が0件です。
終日予定の終了が翌日00:00なら翌日を塞がず、EventKitが23:59:59へ正規化した終了でも当日全体を塞ぎます。
Calendar.current/EventKit/Dateに従い、DSTでも24時間固定加算をせず暦の日で扱います。
時間帯・日数はActivitySettingsで変更可能。設定UIはありません。睡眠は活動時間外で、食事/休憩は生成しません。
AvailabilityServiceはFoundationのみで、Calendar・現在時刻・設定を注入してテストできます。

## 4. Calendar選択UI

メインの「使用するカレンダーを選択」でシートを開き、権限取得後はアカウント名・Calendar名を表示します。Toggleで複数選択し「反映」で取得・再計算します。
初期は0件選択で、未選択は全Calendar取得を意味しません。選択途中は下書きで、キャンセルでは選択変更を反映しません。
メインの「Calendarを再読み込み」とシート内の「一覧と固定予定を再読み込み」で手動更新します。
シート内Refreshは反映済みの選択を更新し、下書きは「反映」で適用します。利用不能のCalendarは選択から除外し理由を表示します。
期間・最終取得時刻・取得状況・エラーを表示します。選択はメモリ内のみです。

## 5. Schedulerとの接続

```text
EventKit → CalendarService → FixedEvent → AvailabilityService
  → AvailableSlot → ScheduleReplanner → Scheduler → SchedulingResult → UI
```

一覧・イベント取得・空き枠生成がすべて成功してからViewModelが結果をまとめて置換します。途中失敗で選択や配置だけが変わることを防ぎます。
選択反映とRefresh成功時に再計算します。Task追加・編集・削除・完了切替と「再計算」は取得済み枠を利用し、Calendarを追加取得しません。
start <= nowの既存ブロックはそのまま保持します。進行中の終了までは枠から差し引き、二重配置を防ぎます。
保持秒数をTaskごとに集計してalreadyAllocatedSecondsとしてSchedulerに渡し、残りだけ未来へ配置します。これは計画の予約時間であり、完了実績ではありません。
任意引数の既定値は空辞書で、既存呼び出しは従来結果を維持します。SchedulerにEventKit・現在時刻・ViewModelの知識はありません。
削除/完了Taskも開始済みブロックを保持し、未来のブロックは除きます。削除後も保持ブロックは削除前の名前を表示します。
新しい固定予定が進行中作業と衝突しても移動せず警告します。completedMinutesは導入せず、同一締切はUUID順です。

## 6. テスト結果

Swift Testingの全100ケース成功。既存50ケースを維持しています。

| スイート | ケース数 |
| --- | ---: |
| SchedulerTests（既存） | 23 |
| TaskManagementTests（既存） | 27 |
| AvailabilityServiceTests | 25 |
| CalendarIntegrationTests | 16 |
| ScheduleReplannerTests | 9 |

指定の全ケース（予定なし・1件・複数・重複・隣接・活動時間外・日跨ぎ・終日・完全占有）と、キャンセル、不正区間、土日、14日境界、現在時刻、設定変更/不正設定、タイムゾーン、DSTを検証します。
メモリ内の実際のEKEventをFixedEventへ変換し、AvailabilityServiceとSchedulerへ渡す統合テストがあります。
Provider差し替えで選択、更新、権限拒否、取得失敗時の非変更、Calendar消失、Task操作のキャッシュ利用、開始済み保持/競合警告を検証します。
秒境界、推定短縮、完了/削除、決定性も確認しています。git diff --checkも成功しました。
実行結果: /tmp/PersonalGantt-phase4-verified-tests.xcresult。ログ: /tmp/PersonalGantt-phase4-verified-test.log。

## 7. macOS/iOSビルド結果

- macOS: ビルド・単体テスト成功。署名付きビルド成功。Calendar entitlementと使用目的説明を確認。
- iOS Simulator: iPhone/iPad共通ターゲットのビルド成功。
- Mac実画面: 未許可の選択シート、反映無効化、未許可Refreshで結果を保持する表示を確認。
- OS権限付与と個人Calendar取得は未検証。統合テストは個人データ・OS権限に依存しません。
- iOS画面操作・実機・visionOSは未検証。deployment targetは27.0のまま。

ビルドログ: /tmp/PersonalGantt-phase4-signed-build.log、/tmp/PersonalGantt-phase4-ios-build.log。

## 8. 制約・未実装

Google Calendar API、Reminders、SwiftData、CloudKit、Siri、本格的Gantt UI、自動バックグラウンド監視、completedMinutes、priority、食事/休憩自動生成は未実装です。
OS標準Calendarに同期済みGoogle CalendarはEventKit経由で選択する設計です。大量イベント向け最適化はなく、MainActorで14日分を取得します。
時刻経過・日付切替を監視しないため、対象期間更新には手動Refreshを使います。Task操作はキャッシュを利用し、権限失効でも最後の結果を保持して警告します。
活動時間は1日1枠で夜跨ぎは設定できません。Task・選択・保持ブロックは再起動すると失われます。
開始済み判定は計画日時によるもので、実際に作業を始めた記録はありません。推定を保持時間より短くしても縮めず、過去締切へ編集しても過去ブロックを保持します。

## 9. 次Phaseの自動再配置に必要な設計変更

1. **計画履歴の分離**: 保護済み履歴と未来計画を別管理する層を設け、削除Taskの名前・再起動後の保持も決める。
2. **計画と実績の分離**: 予約時間と実際の開始/中断/完了を分け、過去に実行しなかった計画の扱いを決める。Schedulerには確定した残り要件を渡す。
3. **更新トリガーの集約**: EventKit変更通知・復帰・日付切替をcoordinatorでまとめ、古い取得結果が新しいTask編集を上書きしないよう制御する。
4. **進行中の競合方針**: 現在は保持して警告。固定予定との衝突・締切変更・推定短縮・削除時に提供する操作を決める。
5. **失敗時の方針**: Calendar削除・権限失効・一時失敗で直前結果をいつまで使うか、選択IDとoccurrenceの差分をどう扱うかを決める。

純粋なAvailabilityService/ScheduleReplanner/SchedulerとCalendarProviderの注入境界を維持し、UIやEventKitへ密結合させず追加できる構成です。
