# Final Integration 実装報告

後続のUI再設計で、操作入口をサイドバー/メニューと設定へ移しました。最新の導線は[UI再設計の報告](UINavigation.md)を参照してください。本報告の機能本体と外部設定の条件は維持しています。

2026-10-12。ユーザーが指定した「PersonalGantt_FinalIntegration_一括実装指示書.md」を機能要件として実装しました。外部サービスの設定・有料登録・実アカウントへの書き込みは実施していません。初期設定は、日次上限なし・早い空き時間から配置・ローカル最適化OFF・休憩設定なし・iCloud同期OFF・Google書き戻しOFFです。

## 1. Git branch

`codex/final-integration`。動的計画期間の `825ea36` から分岐しました。既存の未コミットの開発Team設定2行は保持し、今回のコミットには含めていません。

## 2. Commit一覧

各機能の単体・統合テストとmacOS / iOS Simulatorコンパイルを確認してから、次へ進みました。

| Commit | 内容 |
| --- | --- |
| `86e2075` | Add automatic replanning triggers |
| `289d3f0` | Add cross-device synchronization |
| `7f1d6c7` | Add actual work tracking |
| `b9edbb0` | Add balanced long-term scheduling |
| `d4b76bb` | Add task priorities and scheduling weights |
| `18f6d23` | Redesign Today experience |
| `c0e4c41` | Add optional Google Calendar writeback |
| `959098d` | Add local schedule optimization engine |

最後に `Harden integration persistence and synchronization` で同期中の編集・Reminders実績の対応付け・同期ペイロード検証・開始済みGoogleイベントのID保護・最終テスト・本報告をまとめています。全体差分は `git diff 825ea36..HEAD` で確認できます。

## 3. 変更ファイル

主要ファイルを用途別に記載します。完全な一覧は `git diff --name-only 825ea36..HEAD` で取得できます。

| 用途 | ファイル（リポジトリ基準） |
| --- | --- |
| 起動・自動更新 | `Config/AppInfo.plist`, `PersonalGantt.xcodeproj/project.pbxproj`, `PersonalGantt/PersonalGanttApp.swift`, `PersonalGantt/ContentView.swift`, `PersonalGantt/Services/BackgroundCalendarRefresh.swift` |
| モデル・移行 | `PersonalGantt/Models/{Task,TaskDraft,TaskPriority,WorkSession,SchedulingSettings,WritebackState}.swift`, `PersonalGantt/Persistence/PlanSnapshot.swift` |
| 配置・統合 | `PersonalGantt/Scheduling/{ScheduleViewModel,ScheduleReplanner,Scheduler,ScheduleOptimizationEngine}.swift` |
| 同期 | `PersonalGantt/Sync/{SyncState,SyncPayloadValidator,CloudKitSyncTransport}.swift` |
| Google | `PersonalGantt/Services/Google/{GoogleOAuthConfiguration,GoogleOAuthClient,GoogleCalendarService,GoogleWritebackService}.swift` |
| 表示 | `PersonalGantt/Presentation/{TodaySummary,ScheduleViewModel+Presentation}.swift`, `PersonalGantt/Views/{TodayView,WorkProgressControls,TaskDetailView,TaskEditorView,TaskRowView,WorkloadRoutineView,ScheduleWorkspaceView}.swift` |
| テスト | `PersonalGanttTests/{BackgroundRefreshTests,SyncTests,WorkSessionTests,BalancedSchedulingTests,PriorityTests,TodayTests,WritebackTests,OptimizationTests,FinalIntegrationIntegrityTests}.swift` と既存の移行テスト |
| ドキュメント | `README.md`, `docs/FinalIntegration.md`, `docs/{BackupTransfer,PersonalDeviceSetup,GoogleOAuthSetup}.md` |

## 4. 自動再配置

起動・前面復帰・日付切替・Google Refresh成功・Task/Routine変更・完了/実績入力・上限/優先度/配置設定変更・バックアップ/同期取り込みで再評価します。Googleの変更は、APIで再取得した時点で反映します。未取得の予定を検知したとは表示しません。

`ScheduleReplanner` は開始済みの枠を保持し、未来の未完了作業だけを作り直します。開始済みの枠と新しい固定予定の競合は、移動せず警告します。複数ページをすべて検証してからCalendar状態を一括更新し、失敗時は確認済みの計画を保持します。重複要求をまとめ、古い応答で新しい選択・取得範囲を上書きしません。最低14日・最大90暦日の動的期間と、実際に取得済みのCalendar範囲を別々に扱います。

Siri追加はこれまで通り端末内保存を先に行い、通信を成功条件にしません。

## 5. Background refreshとOS制約

iOS/iPadOSのSwiftUI `.backgroundTask(.appRefresh(...))` と `BGTaskScheduler` を使用します。識別子は `com.atraz.PersonalGantt.calendar-refresh`、Background Modesは `fetch`、次回要求は最短30分後です。前の要求を取り消して再登録し、終了時にも次を要求します。既存のGoogle認証だけを利用し、バックグラウンドからOAuth画面を開きません。

実行頻度・時刻はOSが判断します。低電力・利用状況・Background App Refresh設定などによって実行されない場合があります。アプリ前面復帰時の取得で補完します。macOSの常駐監視やGoogle `watch` のHTTPS webhookサーバーは今回追加していません。[AppleのScene backgroundTask](https://developer.apple.com/documentation/swiftui/scene/backgroundtask(_:action:)) を参照してください。

## 6. Device syncの方式

端末内SwiftDataのチェックポイントは維持し、`SyncTransport` を介してCloudKit Private Databaseへ**エンティティ単位**で同期する方式です。巨大なPlanSnapshot全体の勝者選択で、別Taskの編集を失わないようにしています。CloudKitアダプターは実装済みですが、現在の署名設定では有効化していません。

同期対象は手動/Siri Task（優先度・完了・翌日以降指定を含む）、Routine（完了・スキップを含む）、日次上限、WorkSession、配置/最適化/休憩設定です。Google Token・Keychain・OS権限・Calendar選択/キャッシュ・ScheduledBlock・実行中タイマー・Google書き戻し先と同意は端末固有です。各端末がGoogleへ接続し、同じ要件から再計算します。タイムゾーンやCalendar選択が異なる端末では計画が異なる場合があります。

更新日時・同時刻カウンター・端末UUIDの順に比較する決定的LWW、削除tombstone、直前revision、競合履歴を保存します。未知/不正フィールド、同一revisionの異なる内容、不正なバッチを拒否します。CloudKitのchange tag競合は最大3回再読込して解決します。オフライン編集を保持し、前面復帰・編集・手動同期・前面中約2分ごとに再試行します。同時要求はまとめ、同期中の追加編集は次の要求へ送ります。端末の日時を自動設定してください。

ネイティブRemindersのタイトル・締切・完了はApple側が正で、Taskとして二重同期しません。所要時間・補完締切・リスト選択・関連付けは引き続き各端末のローカル設定/JSON受け渡しです。Remindersの実績は、一意で空でない外部識別子と繰り返し回が一致する場合だけ、その端末のTaskへ導出上で対応付けます。同期元のUUIDを変更しないので端末間で実績が往復更新されません。一致しない実績はタイトル付き履歴として保持し、別のTaskへ推測で加算しません。

## 7. Personal Teamでの利用可否

この環境の既存iOS Provisioning Profileは有効期間7日で、CloudKit entitlementを含んでいませんでした。この証拠から現在の署名でCloudKitを利用できないと判断しています。Apple Accountの会員画面や有料契約の状態までは確認していません。

CloudKitを使うiCloud CapabilityはApple Developer Programの対応が必要です。無料Personal Teamのままでは、ローカル保存・Google/Reminders連携・Siri・JSONバックアップを利用してください。利用できないiCloud entitlementを現在のプロジェクトへ強制追加していません。[Appleの対応Capability表](https://developer.apple.com/help/account/reference/supported-capabilities-ios) と [Capabilityの説明](https://developer.apple.com/help/account/capabilities/capabilities-overview) を参照してください。

## 8. WorkSession / 実績モデル

作業実績は `WorkSession(id, taskID, taskTitle, start, end, actualMinutes)` として予定枠から分離しました。30分・60分の入力、開始/停止タイマー、実績一覧/削除を利用できます。1回1〜1440分、開始<終了、実績分数が経過時間以内であることを検証します。未来の実績と0分を拒否します。タイマーは端末内に保存し、別端末には同期しません。

クイック入力はユーザーが申告した分数です。複数回の申告が同じ時刻帯でも、自動的に同一作業だと推測して消しません。作業枠の経過だけでは実績を生成せず、Task全体の完了と部分実績も区別します。Task削除後も実績のタイトルを保持します。

## 9. remainingMinutes

`completedMinutes = そのTaskに対応するWorkSession.actualMinutesの合計`。
`remainingMinutes = max(0, estimatedMinutes - completedMinutes)`。Task全体を完了にすると0です。実績が見積もりに達しても自動的にはTaskを完了にしません。

実績のあるTaskは、過去の予定枠を実績と重ねて二重に差し引きません。進行中枠は保持し、そのうち実績でまだ記録されていない部分だけを予約として扱います。実績未入力の旧Taskは開始済み枠の従来の予約計算を保ち、移行時の既存動作を維持します。

## 10. Balanced scheduling

早い空き時間から埋める `earliestFirst` と、長期作業を分散する `balanced` を切り替えられます。既存データはearliestFirstを維持し、UIでは資格勉強などにbalancedをおすすめします。

残り180分以上、利用可能な日が3日以上ある通常Taskを分散対象にします。締切の早いTaskから、日ごとの実容量（固定予定、先に配置したTask/Routine、日次上限を差し引いた容量）を計算し、水位を揃えるように均等配分します。容量の小さい日を先に満たし、残りを他の日へ再配分します。端数秒は日付順で処理します。短期・少量・Routineは早い空き時間から配置します。

100時間/30日、不均一な空き時間、日次上限、Routine混在、締切直前、容量不足、決定性をテストしました。急な予定で容量が減った場合は、開始済みを保持して残りの期間全体へ再分散します。

## 11. Priority

`low / normal / high / critical` の4段階。配置順は締切が第一、その次に優先度です。同じ締切・同じ非normal優先度では残り必要量による進捗を考慮し、最後はUUIDで決定します。全Taskが既定normalの場合は従来の締切→UUID順を維持します。期限の遅いcriticalが期限の早いlowを無条件に追い越すことはありません。priorityはTask編集から変更でき、バックアップ・手動Taskの同期にも含めます。Siri追加とRoutineは既定normalです。

## 12. Today UI

現在日時、次/現在の作業、今日の残り予定分数、今日の実績、日次上限、未配置・開始済み競合、Calendar更新/再計算状態、作業カードを表示します。カードから実績、タイマー、完了、詳細、スキップを操作できます。通常Taskのスキップは「明日以降へ」として必要量を残します。Routineはその日だけスキップします。今日の固定予定/時間軸も開けます。

iPhoneはTodayを先頭にしたタブ、Mac/iPad通常幅はTask一覧とToday/日別/Ganttを維持しました。Ganttのバー長は引き続きScheduledBlockの開始/終了日時から算出します。

## 13. Google Calendar writeback

初期OFF。設定画面で明示的にONと同意すると、PersonalGanttが作成した専用Calendarの未来の枠だけを作成・変更・削除します。primaryやユーザーの既存Calendarへ書きません。発行元UUIDの専用Calendarマーカーを検証し、同Calendarを読み取り対象から外して自己再配置を防ぎます。

Task/日/当日の分割番号に基づく決定的イベントID、ローカル対応表、Google側private metadataを使用します。POSTの応答を失っても次の取得で再発見し、同じ枠を重複作成しません。Calendar作成の応答を失った場合もCalendar一覧から再発見します。時間はミリ秒へ正規化します。

前回発行内容とGoogle側を比較し、手動編集を検出したら警告して上書きを止めます。更新/削除にはETagのIf-Matchを使用します。開始済みイベントは変更・削除しません。時間が経過しても当日の分割番号を維持し、履歴枠が入力から省略された場合や対応表を失った場合も、開始済みIDを再使用しないようにします。OFFにしても発行済みイベントは残ります。専用Calendarを作り直す操作は新しい発行元としてOFFに戻し、古いCalendarの管理はGoogle側で行います。複数端末では**1台だけを書き戻し元**にしてください。

## 14. OAuth scope

通常の読み取りは従来通り `calendar.calendarlist.readonly` と `calendar.events.readonly`。書き戻しを明示的に有効化した場合だけ、追加で `https://www.googleapis.com/auth/calendar.app.created` を要求します。広い `calendar` / `calendar.events` 書き込み権限を既定にしません。追加同意のキャンセル・scope不足・更新失敗は理由を表示し、OFF/読み取り利用を維持します。Tokenは端末のKeychainにだけ保存します。[Googleのscope一覧](https://developers.google.com/workspace/calendar/api/auth)、[イベント作成](https://developers.google.com/workspace/calendar/api/v3/reference/events/insert)、[Calendar作成](https://developers.google.com/workspace/calendar/api/v3/reference/calendars/insert) を参照してください。

## 15. Optimization score

`LocalScheduleOptimizing` と `ScheduleOptimizationEngine` を追加しました。外部LLM/APIキー/通信を使いません。最適化ONならearliestFirst/balancedの最大2候補を評価し、同点は元のモードを維持します。

Scoreは辞書式に、(1)固定予定/空き枠・締切・翌日以降指定・Routine日範囲・重複・日次上限違反、(2)priorityで重み付けした未配置分数、(3)分割・長期Taskの日別偏り・配置の遅さ、の順で比較します。ソフト制約のためにハード制約を破りません。重みはモデルで設定可能、UIではモードに合った既定値を使用します。候補生成は決定的です。

任意の最大連続作業1〜480分・最低休憩1〜120分を保存できます。未来の空き枠に休憩用の空白を作り、長い開始済み作業や実績の直後にも空白を確保します。既に開始した枠は、後から制限を下げても短縮しません。休憩はGoogleの固定イベントとして登録しません。

## 16. 既存データmigration

PlanSnapshotの新規保存はv4。v1/v2/v3を読み込み、未指定priorityはnormal、実績は空、配置はearliestFirst、最適化/書き戻し/同期はOFF相当、日次上限の既定はなしです。旧Calendar取得範囲の解釈も維持します。未知versionと不正データは拒否し、読めない保存先を上書きしません。SwiftDataの既存保存モデルを作り直したり、ユーザーデータを消したりしていません。

## 17. Backup互換性

外側のJSONバックアップ形式v1を維持し、内部PlanSnapshot v1〜v4を受け付けます。優先度・実績・同期メタデータ・配置/休憩設定を含めます。古いバックアップの読み込みも検証済みです。Tokenを含めません。

復元先の同期端末ID・同期ON/OFF・Google書き戻し先/同意は送り元に置き換えません。復元内容を復元先のローカル編集としてrevision化します。開始済みの枠と実績を保護し、実績はIDで重複排除して統合します。実行中タイマーは復元しません。従来の2保存先ロールバックjournalを維持し、復旧が必要な状態では新しい変更操作を止めます。

## 18. テスト件数・結果

全485ケース成功、失敗0・スキップ0（既存419＋追加66、パラメータ展開後）。定義数376、パラメータ付き38定義が147回実行され、展開後485件です。新規テストはBackground refresh、LWW/競合/削除/オフライン、実績/残量/保護枠、balanced、priority、Today、書き戻し、最適化、移行/バックアップを対象にしています。

最終結果: `/tmp/PersonalGantt-integration-release-check.xcresult`。
テストログ: `/tmp/PersonalGantt-integration-release-check.log`。
同期中の編集取りこぼし、一意なReminders実績の端末間対応、同一revisionの不正差分、余分な同期フィールド、v4往復と再起動、時間経過後の開始済みGoogle ID保護も確認しました。最終ログのコンパイラwarning/errorとxcresultのruntime warningはありません。

Googleは合成HTTP、Remindersは合成provider、CloudKitはメモリtransportで検証しています。実Googleへの書き込みやCloudKitの実端末転送をテスト成功と同一扱いしません。

再実行例:

```sh
xcodebuild -project PersonalGantt.xcodeproj -scheme PersonalGantt \
  -destination 'platform=macOS' -derivedDataPath /tmp/PersonalGantt-integration-mac \
  -only-testing:PersonalGanttTests test CODE_SIGNING_ALLOWED=NO
```

## 19. macOS build

全テスト実行でmacOSアプリ・テストターゲットのビルド成功を確認しました（macOS 27.0.1 / arm64、Xcode 27）。署名なしのコンパイル/単体テスト確認です。既存の実OAuth確認履歴はREADMEの過去検証を参照してください。今回の新UIを実アカウントで操作する確認は残っています。

## 20. iOS Simulator build

汎用iOS Simulator向けにiPhone/iPad共通アプリの署名なしビルド成功を確認しました（SDK 27.0、arm64 / x86_64）。App Intentsのメタデータ生成と、生成Info.plistの `BGTaskSchedulerPermittedIdentifiers` / `UIBackgroundModes=fetch`、iPhone/iPadのDeviceFamilyも確認しました。ログ: `/tmp/PersonalGantt-integration-release-check-ios.log`。iOS Simulator上の画面操作テスト・iPad実機・visionOSビルドは今回実施していません。最低OSは既存のmacOS/iOS/visionOS 27.0のままです。

```sh
xcodebuild -project PersonalGantt.xcodeproj -scheme PersonalGantt \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/PersonalGantt-integration-ios build CODE_SIGNING_ALLOWED=NO
```

## 21. iPhone実機で確認する手順

事前に現行版でJSONバックアップを書き出し、[個人用インストール手順](PersonalDeviceSetup.md)で現在のTeamを使って起動してください。今回、実機へのインストール・実データ変更は行っていません。

1. GoogleへログインしCalendarを選択。Remindersの使用リストを選び、従来の所要時間設定・完了の双方向反映を確認する。
2. Siri/Shortcutsの「タスクを追加」で合成Taskを追加し、保存・画面反映を確認する。
3. Todayの現在/次の作業・残り予定・日次上限・Calendar更新時刻を見る。
4. 300分の合成Taskへ「30分やった」を入力し、実績30・残り270を確認。開始/停止タイマーも1分以上で試す。実績入力とTask全体完了が別操作であることを見る。
5. Googleに未来の作業枠と重なる合成予定を追加し、Refreshと前面復帰で未来の作業が移動することを確認。進行中/過去の作業枠は保持され、競合警告が出ることを見る。
6. 30日後締切・6000分の合成Task、balanced、日次上限300分で日別/Ganttを見る。固定予定の多い日を避け、Routineと合計して上限以内へ配置されることを見る。
7. 同じ締切のlow/high Taskを作り、highが先になることを確認。別の早い締切のlowが後の締切のhighより先になることも確認する。
8. Routineの日別完了/スキップ、普通Taskの「明日以降へ」、未配置分数、最大90日の対象期間を確認する。
9. 必要なら最大90分/最低休憩15分をONにして、未来の枠間に空白ができることを見る。
10. 終了/再起動後にTask・実績・優先度・配置設定・日次上限・Routineが残ること、v4 JSON往復でTokenが含まれないことを確認する。
11. iPadとMacで同じ検証を行う。各端末のGoogleログインは個別に行う。
12. CloudKitを設定した場合のみ、同じApple Accountの2端末で同期ONにし、Task追加/編集/削除・実績・Routine・設定、片方のオフライン編集、同時編集の競合履歴を確認する。
13. 書き戻しは1端末だけでON・追加同意。合成枠の専用Calendarへの作成/変更/削除、繰り返しRefreshで重複しないこと、既存Calendarを変更しないこと、OFFで新たな変更を止めることを確認する。Google側で合成イベントを手動変更し、警告して上書きを止めることも見る。

Background App RefreshはOSにより実行が省略されるため、一定間隔の実行を成功条件にしません。前面復帰/手動Refreshで整合することを確認してください。

## 22. ユーザー側の追加設定

### Google書き戻しを使う場合

Google Cloud Consoleの既存OAuthアプリのData Accessに `calendar.app.created` を追加し、Testingなら本人をテストユーザーに含めます。アプリ設定「専用Calendarへ書き戻す」をONにして追加同意します。読み取りのみなら追加設定不要です。拒否・権限不足の場合は画面の理由を確認してください。Googleの同意/審査要件はアプリ公開状態によります。

### CloudKitを使う場合（任意）

1. Apple Developer Programの対応Team・同じApple Accountで使用する各端末を用意する。現行版のJSONバックアップを先に保存する。
2. XcodeのアプリターゲットへiCloud Capabilityを追加しCloudKitを選択。同じ専用container（例 `iCloud.com.atraz.PersonalGantt`）をiOSとmacOSで選ぶ。既存のmacOS Keychain/SandboxとiOSの署名条件を保つため、各プラットフォームに適切なentitlementsとProvisioning Profileを設定する。
3. Info.plistキー `PersonalGanttCloudContainer` に実際のcontainer識別子を設定し、Swift Active Compilation Conditionsへ `PERSONALGANTT_CLOUDKIT` を追加する。GoogleのBundle IDを変更しない。
4. CloudKit ConsoleでPrivate Databaseの `PersonalGanttSync` Record Type、`payload` のBytesフィールドを用意し、全件queryができるよう `recordName` のQueryable indexを設定する。Developmentで確認し、配布用ならProduction schemaへdeployする。
5. 両端末で保存先とApple Accountに問題がないことを確認し、アプリの「iCloud自動同期」をONにする。追加・削除・同時編集を合成Taskで確認してから日常データへ使う。

現在のコードはこのflagとcontainerキーが揃わない限りCloudKit接続を作りません。現在のプロジェクトには無効なiCloud entitlementを追加していません。必要なCloudKit schemaの実配備は未実施です。[CloudKitのquery API](https://developer.apple.com/documentation/cloudkit/ckdatabase/records(matching:inzonewith:desiredkeys:resultslimit:)) を参照してください。

### Background refresh

コード側でBackground Modes fetchと許可識別子を設定済みです。実機の「Appのバックグラウンド更新」を許可し、Google認証を済ませてください。実行時刻はOS任せです。

## 23. 未実装 / OS・アカウント制約

- 現署名ではCloudKitを有効化していません。現在利用できる端末間受け渡しはJSONです。CloudKitアダプターの実サービス・複数実機検証は追加設定後に必要です。
- Reminders固有の所要時間・補完締切・除外設定の自動同期は対象外です。既存JSONの安全な外部ID対応付けで受け渡せます。
- 常時監視・Google watchのwebhook・push・サーバーは未実装です。Google変更は再取得時に反映されます。
- Google書き戻しは合成応答で検証済み、実アカウントへはまだ書き込んでいません。複数発行元の統合、手動変更の自動採用は対象外です。
- CloudKitは毎回全件queryを行い、1万レコードを超えると安全に停止します。削除tombstoneを自動消去しません。大量履歴の差分同期/安全な圧縮は今後の課題です。端末内履歴保存にこの件数制限はありません。
- 従来の「実績未入力時の開始済み予定を予約とする」互換挙動を残しています。過去の予約を実際に実行したかは、実績入力で確定します。
- 休憩設定は未来の配置制限です。開始済み枠やユーザーの申告実績を後から書き換えません。
- iPhone/iPadでの新UI操作、Siri実音声、Background Refreshの実行、Apple/Googleの権限画面は今回未検証です。コードのビルド成功と区別してください。

## 24. 今後の改善点

差分CloudKit同期・履歴の安全な圧縮、Remindersローカル設定の安全な自動同期、より多い配置候補の探索、スコア内訳の表示、手動Google変更の採用UI、複数書き戻し端末の協調、Google watch用バックエンド、対応OSを下げるAPI監査と実機UIテストが候補です。現行実装はネットワークや有料AIを必要としない配置・ローカル保存・バックアップを基盤にしています。
