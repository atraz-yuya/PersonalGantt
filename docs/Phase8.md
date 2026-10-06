# Phase 8前半：SwiftDataによる端末内の保存・復元

2026-10-07。ユーザー指定により、端末内の保存・復元を先に実装し、CloudKit同期は後続へ分けます。
計画履歴は自動削除しません。連携の取得に失敗した場合は前回の計画を表示します。
Phase 8全体の複数デバイス同期はまだ完了していません。

## 保存内容と責務

`ScheduleViewModel → PlanSnapshotStoring → SwiftDataPlanStore` の順に保存します。
保存層にScheduler/Google/EventKitのオブジェクトを渡さず、Codableな値だけを渡します。
純粋Scheduler・AvailabilityService・ScheduleReplannerのコードは変更していません。

| 保存内容 | 扱い |
| --- | --- |
| 手動Task | UUID、タイトル、所要時間、締切、完了状態を復元。 |
| Reminders Task | 前回取得した表示用Taskと関連UUIDを復元。元のタイトル・締切・完了状態は引き続きRemindersが正。 |
| 計画 | ScheduledBlock、未配置TaskのID、削除/除外Taskの表示タイトル。過去・進行中の枠を再起動後も保護。 |
| Google表示キャッシュ | 前回のCalendar一覧・選択・FixedEvent・AvailableSlot・対象期間・最終取得時刻。Google取得成功時に置換。 |
| 所要時間など | Phase 6のReminderMetadata.jsonをそのまま利用。既存設定を移動・削除しない。 |
| 認証 | 従来どおりTokenはKeychain、Client IDとCalendar選択はUserDefaults。SwiftDataにTokenを入れない。 |

SwiftDataの保存先はApp SandboxのApplication Support配下 `PersonalGantt/LocalPlan.store` とそのSQLite付随ファイルです。
CloudKitは明示的に `.none` に設定します。データベースSchema V1とペイロードversion=1を別々に識別します。
今回の保存は1件の計画全体を1トランザクションで置き換える方式です。行単位のCloudKit競合解決用モデルではありません。
Google予定のキャッシュは前回取得分だけで、固定予定の過去全履歴は蓄積しません。保持対象の計画履歴はScheduledBlockです。

## 保存・復元の流れ

1. 起動時に保存計画を検証し、Task・計画・前回の表示を復元する。追加権限やリモート書き込みは要求しない。
2. 通常の前面復帰処理でReminders/Googleを取得する。成功したサービスだけが表示内容を更新する。
3. Remindersの再取得前は復元Taskの編集・完了・除外を待機させる。取得失敗で手動Taskとして扱わない。
4. 更新時は保存済みBlockを既存ScheduleReplannerに渡し、過去/進行中を保持して未来の未完了作業を再配置する。
5. Task追加・編集・削除・完了切替、Reminders取込/設定更新、Google取得成功・選択変更・切断、明示的再計算の結果を保存する。

表示切替・日付の選択・Task詳細を開く操作では追加保存・取得しません。
CalendarのClient IDまたは選択が保存時から変わっていれば、旧設定の予定/空き枠/未来配置は復元しません。
開始済みBlockは保持し、Google再取得まで未来を新しい旧キャッシュで埋めません。
取得前の計画には「前回保存した計画を表示中」と表示します。最新取得後は通常の表示へ戻ります。
履歴は計画の保持であり、作業実績やcompletedMinutesではありません。

## 保存の失敗

自動保存は無効化し、明示的ModelContext.saveでまとめて書きます。失敗時はrollbackし、前回の正常な保存を保持します。
画面の最新変更はメモリに保持し、「未保存」の警告と「保存を再試行」を表示します。
再試行は最新状態の保存だけを行い、再配置や外部への書き込みを行いません。
未保存のまま終了すると、その変更は失われ、前回の保存から復元されます。

破損・未対応version・保存先を開けない場合は復元失敗を表示し、その起動中の計画保存を停止します。
空の初期状態で上書きしたり、データベースを自動削除したりしません。以後の操作は未保存として案内します。
修復/対応バージョンへの更新後にアプリを再起動してください。今回、破損データの修復・リセットUIは追加していません。
ReminderMetadata.jsonの保存と計画保存は別トランザクションです。途中終了後は次回Reminders取得で保存済みの設定から再構成します。

## 変更ファイル

- Persistence/PlanSnapshot.swift：保存用値、versionと内容の検証、保存Protocol、安全なエラー。
- Persistence/SwiftDataPlanStore.swift：ローカルSchema、明示的save/rollback、保存先、CloudKit無効化。
- Scheduling/ScheduleViewModel.swift：復元、更新後の保存、失敗表示、再試行、開始済み保護、未取得Reminderの操作ガード。
- Models/AvailableSlot.swift、Models/CalendarSource.swift：Codable追加のみ。
- Presentation/ScheduleViewModel+Presentation.swift：未取得Reminderの変更待機。
- Views/IntegrationStatusView.swift：保存時刻、前回表示、未保存警告、再試行。
- PersonalGanttApp.swift、ContentView.swift：AppがViewModelを保持・画面へ渡す。Macは単一Windowで保存担当を共有。
- PersonalGanttTests/PlanPersistenceTests.swift：SwiftData実ディスクの再オープン、復元・CRUD・障害・連携の統合テスト。
- .gitignore、README.md、docs/Phase8.md：ローカルDB除外、仕様・検証・残課題。

## 検証

全283ケース成功、失敗0、スキップ0。Phase 7の261ケースを維持し、22ケースを追加しました。
Xcodeの定義数221、パラメータ展開後283です。
最終結果は `/tmp/PersonalGantt-phase8-final2-tests.xcresult`、ビルドログは
`/tmp/PersonalGantt-phase8-mac-final-build.log` と `/tmp/PersonalGantt-phase8-ios-final2-build.log` です。
テストは合成Task/イベント/Reminderのみを使用し、保存先はテストごとに一時ディレクトリを分離します。
既存261ケースを維持し、ディスク再オープン、入力/ID/日時/versionの検証、CRUD復元、履歴保持、取得失敗、保存失敗と再試行、
読込失敗の上書き防止、Calendarコンテキスト変更、復元Reminderの待機と完了同期を追加しています。

macOS署名付きビルド・codesignの厳密検証、iOS Simulatorビルドは成功しました。
iOS実機の保存復元・表示は未確認です。
実Macでは合成の手動Task「Phase 8保存確認」を追加し、アプリ終了・再起動後に60分/08:00–09:00を復元しました。
90分へ編集後に再起動して08:00–09:30を復元し、完了後も再起動すると完了状態・作業0枠が復元されました。
最後に検証用Taskだけを削除し、再起動後に戻らないことを確認しました。
実Google/Reminders取得は従来の選択のまま成功し、通常の予定・Reminderを変更していません。
画面証拠 `/tmp/PersonalGantt-phase8-restored90.png` などと実データベースはGitに含めません。

## CloudKitへ進む前の課題

- 手動Task・所要時間・補完締切・除外のどれを同期するかを確定する。
- EventKitローカルIDを端末間の共通キーにしない。外部識別子・リスト・繰り返し回を使った対応を実デバイスで検証する。
- 時間枠は端末ごとの計算結果か共有計画かを決める。複数端末が同時に再計算した場合の開始済み枠の競合を定義する。
- 計画全体のチェックポイントを、そのままCloudKitへ同期しない。共有する設定と端末固有キャッシュ/認証を分離する。
- 削除・除外・完了・見積変更の競合、変更時刻、削除の伝播、オフライン復帰を定義する。
- CloudKit Container・署名/Entitlement・iCloud環境と、Mac/iPhone/iPad実機を準備する。
- 履歴が増えた場合の読み出し・保存性能、過去日を閲覧するUI、エクスポート/削除操作を検討する。
- iOS実機での保存・権限・再起動・表示の確認は残っている。

Googleへの書き込み、Reminderの新規作成/削除/タイトル・締切書き込み、Siri、priority、completedMinutes、常時監視は追加していません。

実装で参照したApple公式API：[ModelConfiguration](https://developer.apple.com/documentation/swiftdata/modelconfiguration)、
[ModelContext.save](https://developer.apple.com/documentation/swiftdata/modelcontext/save())。
