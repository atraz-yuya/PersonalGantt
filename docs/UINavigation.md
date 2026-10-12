# UI再設計：サイドバー・入力待ち・設定集約

2026-10-12。指定されたUI再設計指示書を機能要件として実装しました。既存のCalendar取得・配置・Reminders・保存・同期・書き戻しの処理を、役割別の画面から呼び出します。

## 1. Git branch / commit

ブランチ: `codex/ui-navigation`。`60ffcc3`（アプリアイコン）から分岐しました。
コミット名: `Redesign navigation, input queue, and settings`。
作業開始前からの `Config/AppInfo.plist` と `PersonalGantt.xcodeproj/project.pbxproj` の未コミット変更は保持し、このUIコミットに含めません。

## 2. 変更ファイル

| 対象 | ファイル（リポジトリ基準） |
| --- | --- |
| 画面構成・メニュー | `PersonalGantt/ContentView.swift`, `PersonalGantt/Views/AppSidebarView.swift` |
| 入力待ち・期限・通知のPresentation | `PersonalGantt/Presentation/AppNavigation.swift`, `PersonalGantt/Views/InputQueueView.swift` |
| 設定・データ | `PersonalGantt/Views/AppSettingsView.swift`, `PersonalGantt/Views/DataSettingsView.swift` |
| 既存設定の埋め込み | `PersonalGantt/Views/{CalendarSelectionView,ReminderSelectionView,WorkloadRoutineView}.swift` |
| Today・Task・バックアップ案内 | `PersonalGantt/Views/{TodayView,TaskListView,BackupFileDocument}.swift` |
| 簡潔な異常通知の状態 | `PersonalGantt/Scheduling/{ScheduleViewModel,ReminderSyncViewModel}.swift` |
| 視覚確認用の合成モデル | `PersonalGantt/Presentation/NavigationPreview.swift`, `PersonalGantt/PersonalGanttApp.swift` |
| テスト | `PersonalGanttTests/InputQueuePresentationTests.swift` |
| 削除 | `PersonalGantt/Views/IntegrationStatusView.swift`（内容を設定・データとTodayの短い通知へ分割） |
| ドキュメント | `README.md`, `docs/{UINavigation,GoogleOAuthSetup,BackupTransfer,PersonalDeviceSetup,FinalIntegration}.md` |

Scheduler / ScheduleReplanner / Google OAuth / Backupのトランザクション / Sync transport / Writeback service / Routine / WorkSession / Horizon / Coverageのアルゴリズム・モデル形式は変更していません。追加した失敗フラグは表示用で、チェックポイント形式には追加しません。

## 3. iPhoneサイドバー構造

主要タブは「今日 / 日別 / タスク」の3つを維持し、最初は今日です。上部のアイコン列はメニューボタン1つへ置き換えました。メニューはNavigationStackを持つシートです。メニューを閉じてから選択した操作や画面を開き、モーダルの重複提示を避けます。

メニューは「画面」（今日・日別・タスク）、「日常操作」（タスクを追加・入力待ち・カレンダーを更新・予定を再計算）、「設定」です。入力待ちと設定は常設タブを増やさず、メニューやTodayの短い導線から開きます。

## 4. iPad / Macのナビゲーション

通常幅ではNavigationSplitViewを使用します。左に同じ項目の常設サイドバー、右に選択した画面を表示します。以前の左Task一覧/右Schedule固定構成を、画面選択用のサイドバーへ変更しました。日別画面には日付選択・Timeline/Gantt切り替えを残します。iPadのコンパクト幅ではiPhoneと同じ構成になります。

## 5. 旧アイコンと新ラベルの対応

既存handlerを読んで対応を確定しました。

| 旧操作 | 新しい入口 | 呼び出す処理 |
| --- | --- | --- |
| `plus` | タスクを追加 | 既存TaskEditingSheetを開く |
| `arrow.clockwise` / 再計算 | 予定を再計算 | `ScheduleViewModel.recalculate()` |
| `arrow.triangle.2.circlepath` メニュー内Google更新 | カレンダーを更新 | `refreshCalendars()` |
| 同メニュー内Reminders更新 | 入力待ちの「Remindersを更新」/設定内Reminders | `ReminderSyncViewModel.refresh()` |
| 連携メニュー | 設定 → 連携 | 既存CalendarSelectionView / ReminderSelectionView |
| 作業量・ルーティン | 設定 → タスク・計画 | 既存上限・Routine・配置・休憩のhandler |
| バックアップメニュー | 設定 → データ → バックアップと保存 | `makeBackup()` / 確認後の `restoreBackup()` |
| 入力待ちN件を設定 | 入力待ち | 専用一覧で不足項目を補完 |

Calendar更新はGoogle取得です。Reminders更新や再計算と同一の処理だと推測してまとめていません。

## 6. 入力待ちの判定

既存 `ReminderSyncViewModel.waitingRecords` をそのまま使用します。条件は「未完了・配置対象外にしていない・変換できるTaskがないReminder」です。必要なタイトル、正の所要時間、有効な締切、繰り返し回の識別が揃わないものが該当します。完了済み・除外済みは件数に入りません。手動Task/Siri Taskは既存validationで必須項目を持って保存するので、このキューへ別の判定を追加していません。

不足説明も既存 `waitingDescription(for:)` を再利用します。Reminders側のタイトルや繰り返しの締切を、PersonalGanttで勝手に変更しません。

## 7. 件数とバッジ

`inputQueueCount = reminders?.waitingRecords.count ?? 0`。件数が1以上の場合だけ、サイドバーの右端に中立色のバッジを表示します。0件は項目名のみです。読み込み・補完・除外に合わせてObservable modelから更新します。VoiceOverラベルは「入力待ち、3件」のように一まとまりで読み、装飾バッジの数字を二重に読ませません。

## 8. deadline直接入力

一覧の各行に所要時間の入力、クイック期限、日付を選ぶボタン、日付/時刻のDatePicker、「保存して配置」を置きました。画面内で複数不足項目をまとめて補完できます。既存のReminders締切があれば読み取り表示とし、PersonalGanttから上書きしません。通常Reminderで締切がない場合だけ補完値を保存します。

日付を選ぶだけで勝手に永続化しません。未設定の締切はユーザーがクイック期限または日付選択を選び、日時を確認して保存します。入力用の初期候補は翌日23:59です。DatePickerは配置と同じCalendar/TimeZoneを使い、指定した日時を保持します。

## 9. Quick deadlineのルール

既存の日付のみReminderの扱い（23:59）と揃えています。

| ボタン | 補完する期限 |
| --- | --- |
| 今日 | 現在のローカル暦日の23:59 |
| 明日 | 次の暦日の23:59 |
| 今週末 | 次の日曜の23:59。今日が日曜なら今日 |
| 3日後 | 3暦日後の23:59 |
| 1週間後 | 7暦日後の23:59 |
| 日付を選ぶ | DatePickerで日付と時刻を選択 |

日数加算はCalendarで行い、24時間の秒数加算によるDSTの時刻ずれを避けます。時刻と今週末の意味は入力画面にも表示します。クイック入力後でも日時を変更できます。

## 10. キュー解消後のScheduler接続

`InputQueueDraft.save` → 既存 `ReminderSyncViewModel.configure` → `TaskDraft.validated()` → Reminder設定保存 → `publishTasks()` → 既存ScheduleViewModelの取り込み/再計算 → ScheduledBlock/計画保存、という既存経路です。validationを別実装していません。無効な分数・日時、保存失敗では、キューや確認済み計画を変更しません。成功時は入力待ちから消えて通常Taskになります。

この保存処理はGoogleの通信を必須にしません。取得済みCoverage/AvailableSlotを利用できることをテストしています。既存の前面中の期間延長・Calendar更新は継続し、未取得部分へ確認済みとして配置することはありません。

## 11. Todayから削除・移動した情報

画面共通のIntegrationStatusViewを廃止し、Calendar件数、固定予定件数、Reminders取り込み件数、長い接続文、連携メニュー、計画期間、バックアップ/保存状態をTodayの常設表示から外しました。手動更新/再計算の重複ボタンと、取得/再計算日時、OS更新説明も設定へ移しました。

Todayは次/現在の作業、今日の予定、残り予定/実績/日次上限、未配置・競合、実績/完了操作を維持します。入力待ちがあれば短いリンクだけを表示します。保存・Calendar更新・Reminders処理の失敗は短い設定リンクにし、詳細は設定へ誘導します。通常の成功メッセージやログアウト成功を、異常警告として表示しません。

## 12. Settingsへ移した項目

| Section | 内容 |
| --- | --- |
| 連携 | Google Calendar、Reminders使用リスト/更新、端末間の同期 |
| カレンダー | 取得状況、最終取得、手動更新、専用Calendar書き戻し、OS更新の説明 |
| タスク・計画 | 上限、Routine、分散、最適化、休憩、計画期間、再計算日時、日別配置量 |
| データ | JSON書き出し/確認付き読み込み、保存状態、再試行、対応確認待ち、同期状態 |
| Siri・ショートカット | 利用フレーズ、入力項目、Shortcutsからの使い方 |

WorkloadRoutineViewは計画・同期・書き戻しの3ページに分割表示し、既存の各コントロールとhandlerを再利用しています。優先度はTask編集に残し、存在しない全体優先度設定を追加していません。

## 13. Google Calendar / Reminders導線

設定 → 連携 → Google Calendar / Remindersで、既存の選択画面をNavigationLinkの先に埋め込みます。画面内にNavigationStackを二重に置かず、戻るナビゲーションと既存「反映」処理を利用します。読み取りscope、OAuth、OS権限、リスト選択の処理は維持しました。Reminders設定には従来の各Reminderの所要時間編集も残します。

## 14. Backup / Sync導線

設定 → データ → バックアップと保存で書き出し・読み込み・保存再試行を行います。FileExporter/FileImporterをこの画面へ移したので、設定シートを開いた状態からもその画面上で操作できます。サイズ検証・security-scoped URL・確認シート・ロールバックjournal・読み込み後の再取得は既存処理です。

設定 → 連携 → 端末間の同期に、ON/OFF・即時同期・理由・競合履歴をまとめました。既存の署名/保存条件を維持します。Google書き戻しは別ページで、明示ONと追加同意を維持します。バックアップ確認文も、復元先の書き戻しがONの場合の実際の動作を説明するよう修正しました。

## 15. Accessibility

日常操作はLabelで日本語とSF Symbolを併記し、行全体を押せる領域にしています。メニューボタンは「サイドメニューを開く」と読みます。入力待ちバッジは一体のVoiceOverラベル、入力欄/締切はTask名付きラベルです。選択中のサイドバー項目にはselected trait、主要画面/操作にはaccessibilityIdentifierを付けました。クイック期限は短い文字ボタン、日付を選ぶ操作は独立行です。Todayの集計は狭い幅で縦並びにできるViewThatFitsを使用します。

## 16. テスト件数と結果

全505ケース成功（既存485＋追加20）、失敗0・スキップ0。定義数388、パラメータ40定義が157回実行され、展開後505件です。

結果: `/tmp/PersonalGantt-ui-final-tests.xcresult`。
ログ: `/tmp/PersonalGantt-ui-final-tests.log`。

締切のみ不足、所要時間のみ不足、複数不足、正確なDatePicker日時、元締切優先、繰り返し制限、完了/除外/バッジ、無効分数、保存失敗、保存成功時の再配置/Calendar取得不要、Quick deadline/DST、Todayの失敗通知と回復、OSアクセス前でも読めないReminder保存先を通知することを検証しました。

最終テスト・ビルドログのerror/warningとruntime warningはありません。初回のテストビルドでは、テストターゲットにAppIntents.frameworkがないためメタデータ抽出をスキップするwarningが1件ありました。アプリのApp Intentsメタデータ生成は成功しています。

Macでは別Bundle ID `com.atraz.PersonalGantt.UIPreview` のDebug確認用コピーを起動し、メモリ保存・合成Calendar/Remindersだけを使用しました。既存の共有モデル、Google Token、実Reminder、SwiftData保存先を使いません。サイドバー、3件の入力待ち、資格勉強の「今日」→23:59のDatePicker→保存→2件へ減少→通常Taskに90分配置、Todayの簡潔な導線を実操作確認しました。設定からGoogle・Reminders・計画・同期・書き戻し・データ・Siriの各ページへの遷移も確認しました。実アカウントのログイン/権限変更やGoogle書き込みは実施していません。

この確認用モデルはDebugかつ上記の明示的なpreview Bundle IDの場合だけ使用します。通常のPersonalGanttとReleaseは従来の共有モデルを使用します。

## 17. macOS build

成功。入力ボタン・表示幅調整は `/tmp/PersonalGantt-ui-final-mac.log`、最終の通知調整も含むアプリ/テストビルドは `/tmp/PersonalGantt-ui-final-tests.log`。署名なしのビルドです。

## 18. iOS Simulator build

成功。iPhone/iPad共通、SDK 27.0、arm64/x86_64。最終ログは `/tmp/PersonalGantt-ui-final-verified-ios.log`。Simulatorの画面操作・iPhone/iPad実機は今回未確認です。最低OSは既存の27.0を維持しています。

再実行例:

```sh
xcodebuild -project PersonalGantt.xcodeproj -scheme PersonalGantt \
  -destination 'platform=macOS' -derivedDataPath /tmp/PersonalGantt-ui-mac \
  -only-testing:PersonalGanttTests test CODE_SIGNING_ALLOWED=NO
xcodebuild -project PersonalGantt.xcodeproj -scheme PersonalGantt \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/PersonalGantt-ui-ios build CODE_SIGNING_ALLOWED=NO
```

## 19. iPhone実機で確認する手順

既存版のバックアップを保存し、現在のTeamでXcodeからビルド・インストールします。

1. 最初にTodayが開き、上部に大量の操作アイコンがないことを確認する。
2. メニューを開き、ラベル付きの追加・入力待ち・Calendar更新・再計算・設定を確認する。
3. 3つの主要タブを切り替え、メニューから入力待ち/設定を開いた後も戻れることを見る。
4. Remindersに合成の「締切なし・所要時間あり」「締切あり・所要時間なし」「両方なし」を用意し、設定で使用リストを反映する。
5. 入力待ち一覧でクイック期限を選び、23:59と時刻変更を確認する。日付を選ぶから任意日時も試す。
6. 所要時間を入力して保存し、件数が減り、通常Task/Today/日別へ配置されることを見る。無効な分数では保存できないことを見る。
7. Todayに接続件数や長い設定文がなく、入力待ちへの小さい導線と行動に必要な警告だけが出ることを確認する。
8. 設定の連携からGoogle Calendar/Reminders選択を開き、戻る/反映/再取得を確認する。
9. 設定のデータから合成バックアップを書き出し、確認して読み込む。読み込みをキャンセルした場合は変化しないことを見る。
10. 上限/Routine/配置/休憩、同期、任意の書き戻し、Siri案内へ進めることを見る。不要な同期/書き戻しをONにする必要はない。
11. カレンダーを更新・予定を再計算、Siri追加・実績入力・完了の従来動作を確認する。
12. VoiceOverで入力待ち件数と入力欄名を確認し、大きい文字サイズ、iPad通常幅/コンパクト幅、Macでも操作する。

## 20. 未実装事項・制約

- iPhone/iPad実機のシート遷移、VoiceOverの読み上げ実音、最大文字サイズでの全画面は未検証です。標準SwiftUIとアクセシビリティツリーでの確認を、実機完了とは扱いません。
- タイトルと繰り返しの元締切はApple Remindersで修正します。今回、入力待ちのために元データの所有ルールを変更していません。
- 未保存の入力用draftは画面内だけで保持します。画面を離れる前に保存してください。入力途中の値を外部サービスへ送信しません。
- CloudKit署名条件、Google追加scope、バックグラウンド実行のOS制約は従来通りです。このUI変更で外部設定・接続の有効化は行っていません。
- Mac確認は合成データ用アプリです。既存の実アカウントとの連携を含む実機確認は上記手順で行ってください。
