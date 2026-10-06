# Phase 7：Today / 日別Timeline / Gantt UI

2026-10-07。Phase 6のGoogle Calendar・Apple Reminders連携を維持し、配置結果を確認する画面を追加しました。
Taskの開始・終了を入力するUIはなく、表示の元は引き続きScheduledBlockです。

## 実装内容とUI構成

| 画面 | 内容 |
| --- | --- |
| Today | 今日に交差する作業と固定予定を時刻順に表示。作業枠数・配置分数・固定予定件数、現在の時間枠、利用可能枠を確認。 |
| 日別Timeline | 対象14日間から日付を選択。前日・翌日・今日への移動、空の日の表示、作業と固定予定を確認。 |
| Gantt | 選択した1日を横軸の時刻で表示。Taskごとに作業枠、Google固定予定、利用可能枠を別の行に描画。 |
| Task詳細 | 必要時間、締切、完了状態、配置時間、未配置時間、Taskに属する各Block、編集・完了操作。 |
| Task一覧 | 未完了/完了、Remindersの入力待ち、未配置Taskと不足分数。Task名から詳細へ移動。 |
| 連携とRefresh | 「連携」からCalendar/Reminders選択。上部の「再読み込み」から各サービスをRefresh。 |

Mac・iPadの通常幅では、左にTask一覧、右に「今日 / 日別 / Gantt」を配置します。
iPhoneなどコンパクト幅では「今日 / 日別 / タスク」のタブを使用し、日別画面からGanttも選択できます。
Todayと各表示の日時ラベルは1分ごとに更新します。これによってサービスを追加取得することはありません。
アプリ前面復帰・日付変更・連携変更・Refreshの取得処理はPhase 5–6のものを維持しています。

GanttではTask名・固定予定名の列を固定し、時間軸だけを横スクロールします。
初回はその日の最初の予定付近へ表示を合わせます。短いバーでもTask名から詳細へ移動できます。
「利用可能枠」はGoogle固定予定を除いた活動時間で、Taskに割り当てた時間も含みます。
未完了Taskが自動で「完了」になることはありません。「過去/現在/今後の時間枠」は配置日時の分類です。
過去の薄いバーと配置時間の合計は作業実績ではありません。completedMinutesは追加していません。

## 変更ファイル

| ファイル | 内容 |
| --- | --- |
| PersonalGantt/Presentation/SchedulePresentation.swift | 日別の表示用値、交差区間の抽出、時刻順、日時からのGantt位置・幅。Foundationのみ。 |
| PersonalGantt/Presentation/ScheduleViewModel+Presentation.swift | 既存結果の表示用取得、Task検索、既存完了同期の操作可否。 |
| PersonalGantt/Views/ScheduleWorkspaceView.swift | Today、表示切替、日付選択、前日/翌日/今日への移動。 |
| PersonalGantt/Views/ScheduleTimelineView.swift | Today/日別の時刻順一覧、固定予定・作業、詳細・完了への導線。 |
| PersonalGantt/Views/GanttView.swift | 日単位の横スクロールGantt。固定ラベル列、時刻軸、予定/作業/利用可能枠。 |
| PersonalGantt/Views/TaskDetailView.swift | 最新TaskとBlockの詳細、既存編集フォームへの遷移。 |
| PersonalGantt/Views/TaskListView.swift | 未完了/完了Task、入力待ち、未配置、Task詳細への導線。 |
| PersonalGantt/Views/IntegrationStatusView.swift | 連携選択メニュー、状態・警告・入力待ち、接続時刻と保存の説明。 |
| PersonalGantt/ContentView.swift | Mac/iPad分割・iPhoneタブを接続。Sheet/Alertと既存ライフサイクルを保持。 |
| PersonalGantt/Views/TaskRowView.swift | Task名から詳細へ移動、狭い幅に合わせた操作の折返し。 |
| PersonalGantt/Scheduling/ScheduleViewModel.swift | 表示用に現在のCalendarを公開するプロパティのみ追加。 |
| PersonalGanttTests/SchedulePresentationTests.swift | 日付境界、日跨ぎ、時刻順、空の日、不正区間、終日、TZ/DST、Gantt位置。 |
| PersonalGanttTests/ScheduleDisplayIntegrationTests.swift | 編集/完了/削除、保持ブロック、Reminders完了同期の表示への反映。 |
| README.md、docs/Phase7.md | 操作と検証結果、次の課題。 |

Scheduler・AvailabilityService・ScheduleReplanner・Google/Reminders Service・保存モデルは変更していません。
ユーザー固有のXcode Team設定は以前からの作業ツリー変更として保持し、コミットに含めません。

## 表示用データの流れ

    Google Calendar → FixedEvent → AvailabilityService → AvailableSlot
    Apple Reminders + PersonalGanttの所要時間 → Task
    Task + AvailableSlot → ScheduleReplanner → Scheduler → ScheduledBlock
    ScheduledBlock + FixedEvent + AvailableSlot → SchedulePresentation
        → Today / 日別Timeline / Gantt / Task詳細

表示する日のローカル00:00から翌00:00までと交差する区間だけを抽出します。
翌00:00に終了するBlock/イベントを、翌日の画面へ重複表示しません。
日跨ぎBlockは元のBlockを変更せず、各日に見える区間と分数を切り出します。
FixedEventの終日/キャンセルの判定は既存AvailabilityServiceと同じルールを使います。
表示では重複固定予定のタイトルを統合せず、それぞれの予定を確認できます。

Ganttの開始位置は「表示区間start−その日のstart」、幅は「表示区間end−start」を、当日の実秒数で正規化します。
estimatedMinutesから直接ピクセル幅を決めません。
夏時間の23/25時間の日も、Calendarが返した日区間とDateの差を使用します。
空の日も日付選択に残し、その日の空表示を出します。別の日のTaskを混ぜません。

詳細表示はTask UUIDで最新のモデルを参照します。元のTaskが消えた保持Blockではアーカイブしたタイトルと時間枠を表示し、編集できないことを案内します。
詳細から編集する場合は詳細Sheetを閉じ、既存Taskフォームへ移動します。
Reminders由来のタイトルと元の締切は編集不可、所要時間と不足締切の補完は従来どおり変更できます。
完了操作は従来のtoggleTaskCompletionを経由するため、Reminders同期と失敗時の保持規則がそのまま適用されます。
表示切替や日付選択はScheduler再計算・Google取得・Reminders取得を発生させません。

## テストとビルド

最終結果は**全261ケース成功、失敗0、スキップ0**です。
Phase 6の242ケースを維持し、表示用19ケースを追加しました。
Xcodeの定義数208、パラメータ展開後の実行数261です。
結果: `/tmp/PersonalGantt-phase7-final-tests.xcresult`。

| 確認 | 結果 |
| --- | --- |
| macOS単体テスト | 成功。サービス応答・Taskは合成データのみ。 |
| macOS署名付き最終ビルド | 成功。Apple Development署名。 |
| iOS Simulator最終ビルド | 成功。 |
| iPhone/iPadの実表示・実機 | 未確認。Simulatorの画面アプリをこの環境で開けず、起動確認も完了しませんでした。検証用Simulatorは停止状態へ戻しました。 |

確認した境界は、日跨ぎの分数保存、翌00:00の排他的境界、空の日、不正区間、重複固定予定の表示、終日・キャンセル、時刻順と同時刻の安定順、TZ、DSTの23/25時間、サブ分の幅です。
統合テストでは編集・完了・削除後に表示が更新され、サービスへの追加取得がなく、開始済みブロックとタイトルを保持することを確認しています。

## 実macOSでの確認

ユーザー承認済みの専用検証データだけを再利用しました。
実Google Calendarの検証予定08:00–12:00と、実Remindersから取り込んだ60分Taskを使用しました。

- Todayで固定予定08:00–12:00と作業12:00–13:00を時刻順に表示。
- Ganttで固定予定とTaskを別の行に描画。Task名を固定したまま、時間軸を横スクロール。
- GanttのTask名から詳細へ移動し、必要時間・締切・配置時間・各Blockを確認。
- 詳細から編集へ移動し、所要時間60→90分を変更。Reminders由来のタイトルと締切は編集不可。
- 再計算後の12:00–13:30を、GanttとTodayの両方で確認。
- Todayから完了にすると作業枠が消え、未完了へ戻すと再配置されることを確認。
- 日別で翌日の空表示を確認。「今日へ」で今日の予定へ戻ることを確認。
- 検証後、所要時間を60分へ戻し、検証Taskを配置対象から外しました。Google/Remindersの選択も元の2件ずつへ戻しました。

通常のReminder内容・完了状態、Google予定の内容は変更していません。
画面証拠は`/tmp/PersonalGantt-phase7-*.png`に保存し、Gitには含めていません。
ソースにToken、Client Secret、実Calendar/Reminderのスナップショットを追加していません。

## 未実装・制約と次のPhase

- Ganttは選択日の結果表示MVPです。複数日を横に並べる全体図、ズーム、ドラッグ再配置、手動固定は未実装です。
- iPhone/iPadのUIはコンパイル確認までです。Simulator/実機での表示と操作、文字サイズを大きくした状態の確認が残っています。
- 手動TaskとScheduledBlock履歴は引き続きメモリ内です。アプリ終了後の過去/進行中ブロック保護は計画履歴の保存が必要です。
- 所要時間・補完締切・関連付け・除外状態は端末ローカルのままです。
- Siri専用機能、CloudKit、SwiftData、Google書き込み、Reminder新規作成/削除/タイトル・締切書き込み、completedMinutes、priority、常時バックグラウンド監視は追加していません。

次は仕様書のPhase 8：永続化・複数デバイスです。
先に、手動Taskも保存するか、計画履歴の保存期間と再起動後の復元規則、端末間でのReminderと所要時間の対応付け、
同期対象と競合解決、連携取得に失敗した状態での配置を決める必要があります。
端末内の保存・復元を先に固め、純粋Schedulerとは独立した保存層として実装し、その後Apple側の同期を接続する順序を推奨します。
