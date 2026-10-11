# 動的計画期間・長期タスク対応

2026-10-12。`PersonalGantt_Phase7_動的計画期間_実装指示書.md`を仕様として、固定14日の計画を、最低14日・最長90暦日の動的計画へ拡張しました。
日次上限の初期状態は、ユーザーが指定した「上限なし」を維持しています。

## Git・変更ファイル

ブランチ: `codex/dynamic-planning-horizon`。開始点: `9aa5746`。
コミット名: `Add dynamic planning horizon for long-term tasks`。
Xcodeの既存の`DEVELOPMENT_TEAM`変更は保持し、このコミットに含めません。

| ファイル | 変更 |
| --- | --- |
| Models/PlanningHorizon.swift | 設定、導出期間、CalendarCoverage、未配置理由。 |
| Scheduling/PlanningHorizonResolver.swift | 未完了の通常Task・Routine・暦日から期間を決定する純粋な処理。 |
| Scheduling/ScheduleViewModel.swift | CRUD・完了・日付・Refresh・復元・日次上限変更から再評価。取得範囲と配置の制限。 |
| Services/AvailabilityService.swift | 明示した期間で空き時間を生成。部分日の終了も切り詰め。 |
| Persistence/PlanSnapshot.swift | JSON payload v3に取得済み範囲を追加、v1/v2互換性と検証。 |
| Presentation/ScheduleViewModel+Presentation.swift | 計画期間、上限、未取得、未配置理由、残り暦日を表示へ提供。 |
| Services/TaskCreationService.swift | Siriの返答で期間外とCalendar未取得を区別。 |
| ContentView.swift | 前面中に期間が変わり、取得範囲が不足する場合の再取得。 |
| Views/WorkloadRoutineView.swift | 計画対象期間、90日上限、Calendar未取得の表示。 |
| Views/IntegrationStatusView.swift | 計画対象期間と上限の常時表示。 |
| Views/TaskDetailView.swift | 残り暦日、期間、日次上限、未配置の説明。 |
| Views/TaskListView.swift、TaskRowView.swift | 「未配置」の表示と理由。期間外を配置不能と断定しない。 |
| Tests/PlanningHorizonTests.swift | 期間・DST・TimeZone・日付・Coverage・Availabilityの検証。 |
| Tests/DynamicPlanningIntegrationTests.swift | 長期配置・取得・失敗・保存・復元・Siriの統合検証。 |
| Tests/ScheduleRefreshTests.swift、WorkloadRoutineIntegrationTests.swift | 固定14日の期待値と未取得表示を動的期間へ更新。 |
| README.md、docs/DailyWorkloadRoutines.md、本書 | 現行仕様、導入時仕様との差分、検証・実機手順。 |

実際のテストファイルは`PersonalGanttTests/`にあります。Xcodeの同期フォルダが新しいSwiftファイルを取り込むため、プロジェクト設定の変更は不要です。

## 期間の決定

`PlanningHorizonResolver.resolve`は、Google API・SwiftData・UIに依存しません。
`PlanningHorizonSettings`はCodableの値モデルです。今回のアプリ設定は`minimumDays = 14`、`maximumDays = 90`で固定し、設定画面は追加していません。
将来の設定導入に備えて値を独立させています。今回、この設定値の保存は不要です。

開始は現在地のCalendarによる今日の00:00です。
終了は次の最大値を求め、今日+90日の00:00で制限します。

1. 今日+14日の00:00。
2. 未完了の通常Taskの最も遠い正確なdeadline。日別Routineから生成したTaskは除外。
3. 入力が有効で終了日が現在以降のRoutineの終了日翌日00:00。

通常Taskのdeadlineは時刻も保ちます。Routineの終了日は従来の包含仕様を保つため、翌日00:00まで必要になります。
例えば「45日後が終了日」のRoutineは今日を含め最大46暦日の要件となります。
終了時刻は含まない区間です。既に過ぎた活動時間は、Availabilityで現在時刻まで切り詰めます。
「14日」「90日」は`Calendar.date(byAdding: .day)`で計算し、秒数による日加算は行いません。

Taskの追加・編集・削除・完了変更、Remindersの取り込み、Routineの追加・編集・削除、日次上限変更、日付切替、Calendar Refresh、バックアップ復元で再評価します。
復元時は受け取ったTask・Routineを使って期間を求め、復元先が元々持っていた期間に引きずられません。

## Calendar取得・Coverage・オフライン

`PlanningHorizon.interval`を`CalendarProviding.loadEvents(in:calendarIDs:)`に渡します。
既存のGoogleCalendarServiceは可変DateIntervalを受け取れるため、API実装の変更は不要でした。
選択Calendarごとに同じ`timeMin`・`timeMax`を各ページへ渡し、既存のページ分割、GETのみ、読み取り専用scopeを維持します。
Google固有型をAvailabilityやSchedulerへ渡しません。認証情報・実イベントを追加でログ出力する処理もありません。

`CalendarCoverage(start:end:)`は、最後に成功した取得範囲です。
対象期間・選択Calendar・FixedEvent・空き枠・配置結果とともに、全ページ取得成功後だけ更新します。
取得中に締切や日付が変わった場合は新しい期間で再取得し、最大2回で終了します。
古い期間の応答を新しい期間の取得結果として採用しません。

Task編集で期間が14日から30日へ延長された時点では、14日のCoverageがそのまま残ります。
Availabilityには`PlanningHorizon ∩ CalendarCoverage`だけを渡します。
未取得の16日間には新しい確定Blockを作らず、Task・Routineの要件は保存します。
通信失敗・認証失効でもCoverage・固定予定を保持し、UIに取得不足を表示します。
次の再取得に成功すると30日までCoverageを延ばし、その範囲を再配置します。
日付変更後の取得が失敗しても、導出期間だけは現在の日付へ更新します。

期間短縮では、空き枠を新しい対象期間へ切り詰め、未来のBlockを再生成します。
Coverageを破棄しないため、再延長が取得済み期間に収まる場合は保存したFixedEventから枠を再生成できます。
以後の取得成功は、その要求範囲を新しいCoverageとして置き換えます。
Googleの設定変更・ログアウト・別Calendar文脈への復元ではCoverageを引き継ぎません。

Calendar未選択で取得履歴もない場合は、従来の活動時間のみの仮配置が使えます。
保存した選択があるのにCalendarを一度も取得していない場合は、取得まで配置を待ちます。
この場合も未取得区間を「固定予定なし」と判定しません。

前面のUIは、期間変更後に不足するCoverageの再取得を要求します。
既存の同時取得抑制を使い、取得中の要求をまとめます。常時バックグラウンド監視は追加していません。
SiriのTask保存・再計算は通信を待たず完了し、バックグラウンド作成でネットワークを必須にしません。
不足するCalendar情報は、次にアプリを開いた時、または手動Refreshで取得できます。

## Availability・Routine・Scheduler・日次上限

Availabilityに`in: DateInterval`を受け取る経路を追加し、開始・終了・現在時刻で活動枠を切り詰めます。
活動時間、重複結合、終日占有、TimeZone・DSTの処理は共通です。
従来の固定日数APIは、明示的な期間を使わない純粋関数クライアントとの互換用に残しています。アプリの計画には使いません。

RoutinePlannerの既存DateInterval引数に動的期間を渡し、開始日・終了日・繰り返しの交差から日別Taskを生成します。
最大90暦日より先を一括生成しません。生成IDと日別完了・スキップ状態は保持します。
終了日のないRoutineは追加していません。

Schedulerのアルゴリズム・結果APIは変更していません。
締切→UUID、早い空き時間順、日次残容量という既存の決定的な配置を、長いAvailabilityで使います。
通常Task・Reminders・Routineは同じ日次上限を共有し、固定予定はこの上限に含みません。
開始済みBlockは既存Replannerで保護します。保護した時間は日次消費へ算入し、新しい上限や短いdeadlineを理由に移動しません。
保護した履歴が対象期間より前にある場合も、削除せず保持します。

100時間・30日締切・上限300分の合成ケースは、空き時間が十分なら20日に各300分で全6000分を配置できます。
30日すべてが使えることや均等配置を前提にせず、固定予定と実際の活動時間から容量を計算します。

## 90日を超える締切・未配置理由・UI

最大期間で切った場合は`wasCapped = true`です。
取得・枠生成は90日までに限定し、さらに先を「予定なし」と仮定しません。
締切が対象期間より先の場合は「現在の計画期間より先」と表示し、90日内の未配置だけで締切不足と断定しません。

Presentation側で`UnscheduledReason`を集計し、Schedulerの既存APIを維持します。

| 理由 | 表示・判定 |
| --- | --- |
| deadlineBeyondPlanningHorizon | 締切が対象期間より先。残り期間を未評価。 |
| calendarCoveragePending | 締切までのCalendar情報が足りず、未配置の評価を保留。 |
| dailyWorkloadLimit | 関係する空き枠の日次上限が消費され、未配置が残る。 |
| noAvailability | 対象日時に利用可能な枠がない。 |
| insufficientCapacityBeforeDeadline | 対象期間内の締切に対して、現在の空き時間で必要時間を配置しきれない。 |

日次上限と他Taskとの競合を唯一の原因として厳密に分離する分析は行いません。
対象期間外・Calendar未取得の判定を容量不足より優先し、日次上限については「現在の空き時間と日次上限では」と表示します。

「作業量・ルーティン」と上部の連携表示に対象期間と90日上限を追加しました。
Task詳細には必要・配置・未配置時間、締切までの暦日数、現在の対象期間、日次上限、未配置の説明を表示します。
一覧の「締切までに配置できない作業」は「未配置の作業」へ変更し、理由を併記します。
日別・Ganttの日付候補も動的な対象期間に従います。
Siriの未配置返答も、Calendar未取得・期間外・容量不足を区別します。Intent引数・Shortcutフレーズは変更していません。

## 永続化・バックアップ

SwiftDataのモデルスキーマは既存のままです。保存しているJSON payloadだけをv3にしました。
`calendarCoverage`を保存し、再起動後に30日の対象期間を14日の取得済み範囲と取り違えないようにします。
Coverageは有効な開始・終了、最終取得日時、空き枠がCoverage内にあることを検証します。
Task・Routine・日次上限から導出するHorizonは、独立した新しい保存フィールドにしていません。
従来のplanningStart/planningEndは表示用チェックポイントとして引き続き保存しますが、取得済み範囲の判定にはv3のCoverageを使います。

旧payload v1/v2は読み込み可能です。
明示的なCoverageがないため、Google最終取得日時とplanningStart/planningEndがそろう場合に限り、その旧取得期間をCoverageとして引き継ぎます。
新しい対象期間を使って旧キャッシュ範囲を拡張することはありません。
未知version・不正なCoverageは拒否し、保存済みデータを上書きしません。

バックアップの外側のformat/versionは従来のv1、内側のplan payloadはv1/v2/v3を扱います。
既存の二つの保存先のトランザクション・復旧ジャーナル・Remindersの受け渡し・開始済み履歴保護を維持します。
旧アプリは新しいpayload v3を読み込めないため、受け渡す双方を今回の版へ更新してください。

## 検証結果

Swift Testingのパラメーター展開後で419ケースすべて成功、失敗0・スキップ0です。
既存374ケースを維持し、45ケースを追加しました。Xcodeの定義単位の集計は319件です。
固定14日を前提とする期待値は新仕様に更新し、オフラインの日付切替テストは90日のローリング上限で未取得の次の日を検証する構成へ更新しました。

追加検証は、空・短期・30日・90日・上限超過・複数Task・完了/生成Task除外、Routine包含終了・混在・終了/不正/将来のRoutine、DSTの23/25時間日、TimeZone・日付変更、期間設定検証、部分日のAvailability、Coverage一致/交差/不足を含みます。
統合では100時間/30日/300分、容量不足、90日超の表示、取得失敗後の保存・再起動、再取得による拡張、3週間後の固定予定回避、短縮/再延長と開始済み保護、完了/削除/Routine編集、Routine混在/上限、前面の取得・通信不要Siri、取得中の編集、受け取ったHorizonと部分Coverageの復元、旧v1/v2・不正Coverage・未知version、手動Refresh時の日付切替失敗を検証しました。
Googleサービス本体を合成HTTP応答で動かし、30日/120日締切の両ケースで、各ページのtimeMin/timeMaxが30日/90日に一致することも確認しました。

macOSの署名なしビルド・単体テスト成功。iOS Simulator向け署名なしビルド成功。
最終のビルドログにコンパイラ警告・エラーはなく、xcresultのruntimeWarningsも空です。

- macOS: `/tmp/PersonalGantt-horizon-final-tests.log`
- xcresult: `/tmp/PersonalGantt-horizon-final-tests.xcresult`
- iOS Simulator build: `/tmp/PersonalGantt-horizon-ios-final-build.log`

実際のGoogleアカウント・iPhone・Siriによる動作と画面操作は未検証です。合成予定だけをテストで使い、実Calendarへの書き込みは行っていません。

## iPhone実機での確認手順

1. 今回の版をビルド・インストールし、Googleへ接続して使うCalendarを選ぶ。
2. 今日から30日後を締切として「資格勉強・6000分」を追加する。
3. 「作業量・ルーティン」の計画対象期間が30日後まで伸びることを確認する。
4. 日次上限を300分に設定し、取得完了後の各日の合計が300分以内であることを確認する。
5. Google Calendar側で3週間後にテスト用固定予定を作り、PersonalGanttをRefreshして、その時間帯を避けることを確認する。
6. 平日30分・約1か月のRoutineを追加し、14日より先にも日別Taskが生成されることを確認する。
7. 通常Taskの締切を短くし、未来の配置と計画期間が更新されることを確認する。他に長期要件があれば、その要件まで期間が残る。
8. 締切を延ばし、計画期間とGoogle取得が伸びることを確認する。既に取得済みの範囲への再延長はキャッシュを使える。
9. 通信を切り、取得済み期間より遠い締切またはRoutine終了日を設定する。要件の保存、未取得表示、その期間への新規配置がないことを確認する。
10. 通信を戻してRefreshし、未取得表示が消え、延長部分も配置対象になることを確認する。
11. 締切を120日後にし、期間が90日で止まり「締切が期間より先」と表示されることを確認する。容量不足と断定する表示がないことを確認する。
12. 作業開始後に締切・上限を変更し、開始済みBlockが保持されることを確認する。
13. 部分Coverageの状態で終了・再起動、バックアップ書き出し・読み込みを行い、未取得期間を空きとみなさないことを確認する。
14. Siriの既存フレーズから長期Taskを追加し、保存されること、未取得Calendarがある場合にその旨を案内することを確認する。

## 制約

90日より先は、日付が進んだ後の取得・再計算で扱います。
均等配分、学習量のAI最適化、priority、completedMinutes、祝日API、無期限Routine、Google書き込み、常時バックグラウンド監視、上限を超えて締切を優先する配置は追加していません。
Calendarキャッシュは時点の取得結果であり、期間内のGoogle予定変更はRefreshで反映します。
日次上限・ルーティン生成・基本Schedulerの既存仕様と、作業枠が実績を表さないことは変わりません。
