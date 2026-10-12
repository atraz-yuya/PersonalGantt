# PersonalGantt

名前・所要時間・締切から、空き時間へTaskを配置するSwiftUIアプリです。
Phase 4.5で予定の取得元をGoogle Calendar APIへ切り替えました。
Phase 5でCalendar選択の保存と、起動・前面復帰・日付切替の更新処理を追加しました。
Phase 6でApple Remindersの取り込み、入力待ち、所要時間設定、完了状態の双方向同期を追加しました。
Phase 7でToday・日別Timeline・日単位Gantt・Task詳細を追加しました。
Siri / App Intentsから、タスク名・所要時間・締切を指定する直接追加経路を追加しました。
日次の自動配置上限と、毎日・平日・曜日指定・毎週のルーティンを追加しました。
Final Integrationで実績入力、長期作業の分散、優先度、Today改善、機会的Background Refresh、任意のGoogle書き戻し、ローカル最適化を統合しました。CloudKitの同期処理も実装していますが、現在の署名では無効です。
最新の仕様・追加設定・実機確認は[Final Integration実装報告](docs/FinalIntegration.md)を参照してください。
コード実装・合成データ検証に加え、本人のOAuthログインと実Google Calendarの取得・空き時間生成・手動RefreshをmacOSで確認済みです。

## 起動とGoogle設定

1. PersonalGantt.xcodeprojをXcodeで開き、PersonalGantt Schemeを選ぶ。
2. 実認証に使うAppleの開発TeamとKeychain用署名・Provisioning Profileを設定する。
3. Google CloudでCalendar APIとiOSタイプOAuthクライアントを設定する。
4. アプリ上部の「連携」→「使用するカレンダーを選択」でClient IDを保存し、Googleへログインする。
5. Calendarを複数選び「反映」する。Google側の変更は上部の「再読み込み」から読み直す。

詳しいボタン・Bundle ID・スコープ・確認手順は[OAuth設定手順](docs/GoogleOAuthSetup.md)を参照してください。
無料のPersonal Teamで自分のiPhone/iPadへ入れる手順は[実機インストールとファイル往復](docs/PersonalDeviceSetup.md)を参照してください。
Client Secret/Tokenはチャットやコードへ貼りません。Client IDは公開識別子としてUserDefaults、TokenはKeychainへ保存します。
Google書き戻しは初期OFFです。設定でONにし追加同意した場合だけ、アプリ専用Calendarへ未来の作業枠を反映します。Apple Calendarの同期設定は使いません。

## 現在のデータフロー

    Google Calendar API → GoogleCalendarService → FixedEvent
        → AvailabilityService → AvailableSlot → ScheduleReplanner → Scheduler

配置処理は通信から独立しています。WorkSessionの実績、優先度・分散・日次上限・任意の休憩設定を反映し、開始済みの枠を保護します。

    Apple Reminders → EventKitReminderService → ReminderRecord
        → ReminderSyncViewModel + 端末ローカルの所要時間・補完締切 → Task

Taskのタイトル・元の締切はRemindersを正とし、所要時間をRemindersへ書き込みません。
完了状態だけ双方向に反映します。手動Taskも利用できます。

「連携」→「使用するRemindersを選択」からOSアクセスを許可し、使用リストを複数選んで「反映」します。
不足項目は「入力待ち」です。「所要時間・締切を設定」で必要項目を埋めると配置されます。
日付だけの締切はその日23:59、開始・終了時刻はSchedulerが決定します。
「配置対象から外す」はPersonalGantt内の除外で、ネイティブReminderは削除しません。

## Siri・ショートカットから追加

「Siri、PersonalGanttにタスクを追加」と話しかけ、タスク名、必要な分数、締切を答えます。
「PersonalGanttでタスクを追加」「PersonalGanttに新しいタスクを追加」でも起動できます。
ショートカットアプリのPersonalGantt「タスクを追加」では、同じ3項目を指定できます。
タスクは端末内SwiftDataへ保存し、UIと同じ処理で再計算します。追加処理はGoogleの通信やログインを要求しません。
保存に失敗したら成功を返さず、配置不足は保存成功と区別して通知します。
実機での音声対話・Shortcutsの確認手順と制約は[Siri / App Intents実装報告](docs/SiriAppIntents.md)を参照してください。

## 作業量・ルーティン

上部の「作業量・ルーティン」から、1日の自動配置上限を設定できます。
初期状態は上限なしです。「日次上限を使う」を有効にし、例として300分を保存すると、
通常Task・Reminders Task・ルーティンの合計を暦日ごとに300分以内へ配置します。Googleの固定予定は集計対象に含めません。
開始済みの時間枠は保持し、それが上限を超える日は追加配置を止めて警告します。
締切または現在の対象期間までに入らない作業は未配置分数で表示し、Siriも追加成功と分けて返します。

ルーティンでは名前、1回の分数、繰り返し、開始日・終了日を設定します。
「英語・平日30分」は、平日の各日に30分ずつの独立した作業要件を自動生成します。
その日だけに配置し、不足分は翌日に持ち越しません。タスク一覧の「ルーティン（各日）」から、日ごとの完了やスキップができます。
ルーティン設定の編集・削除は設定画面から行えます。完了・スキップと設定は端末内に保存し、バックアップで受け渡せます。
未完了タスクの締切・ルーティンの終了日に応じて、最低14日・最長90暦日まで計画期間を自動延長します。Google Calendarも同じ期間を取得します。未取得の延長部分には配置せず、90日より先の締切は容量不足と区別して表示します。ルーティンのSiri入力は未対応です。
詳しくは[日次上限・ルーティン](docs/DailyWorkloadRoutines.md)と[動的計画期間の実装報告](docs/DynamicPlanningHorizon.md)を参照してください。

「長期作業の配置」を「長期作業を分散」にすると、残り180分以上・利用可能な日が3日以上ある通常Taskを、日ごとの容量に合わせて分散します。初期設定は従来の早い空き時間からの配置です。
Taskの優先度はlow/normal/high/critical。締切が先、その次に優先度を反映します。
TodayやTask詳細から「30分やった」「60分やった」、開始/停止タイマーを使えます。残り必要分数は見積もりから実績を引いた値です。予定枠の経過だけで実績にはしません。
ローカル最適化と連続作業/休憩の設定は任意で、初期OFFです。外部AIへの通信やAPIキーは不要です。

## 画面

Mac・iPadの通常幅は左にTask、右に「今日 / 日別 / Gantt」です。
iPhoneなどコンパクト幅は「今日 / 日別 / タスク」のタブで、日別からGanttも選択できます。
作業枠またはTask名を選ぶとTask詳細を開きます。
日付選択は動的な計画対象期間内（最長90暦日）です。GanttのTask名を固定し、時間軸を横スクロールできます。
バーの位置・幅はScheduledBlockの実日時で決まり、開始/終了の入力やドラッグ変更はありません。
過去の時間枠は作業実績とは区別して表示します。

## 仕様

| 項目 | 現在の仕様 |
| --- | --- |
| 活動時間 | 平日08:00–23:00、土日09:00–23:00。ActivitySettingsで変更可能。 |
| 対象期間 | 今日の00:00から最低14日・最長90暦日。未完了の通常Taskの正確な締切、Routineの終了日翌日00:00で延長。終了時刻は対象外。 |
| 予定 | 選択Google Calendarのイベント。キャンセル除外、終日は全日占有。 |
| 重複 | 重複/隣接予定を結合して活動時間から差し引く。 |
| 優先順 | deadline → priority → 進捗（非normal同順位）→ UUID。既定normal同士は従来のdeadline → UUID。 |
| 日次上限 | 初期状態は上限なし。設定した場合、通常・Reminders・ルーティンの合計をローカル暦日ごとに制限。固定予定は含めない。 |
| ルーティン | 毎日・平日・曜日指定・毎週。各日の作業要件を自動生成し、その日の中で配置。 |
| 再配置 | 過去/進行中を保持し、未来の未完了作業を再生成。 |
| 実績 | WorkSessionを別保存。remaining = max(0, estimate - actual)。Task全体完了と区別。 |
| 配置モード | 初期earliestFirst、任意balanced。ローカル最適化で最大2候補を評価可能。 |
| Google書き戻し | 初期OFF。明示ONと追加scope同意時のみ専用Calendarの未来枠を発行。複数端末では1台だけON。 |
| 自動同期 | CloudKit Private Databaseの実装済み。現在の署名では無効。JSONバックアップを利用可能。 |
| 入力 | title、1分以上の整数estimatedMinutes、deadline。開始/終了はSchedulerが決める。 |
| 失敗 | 取得・権限・不正応答の失敗は直前の結果を保持し理由を表示。 |
| Refresh | 起動・前面復帰・前面中の日付切替・選択反映・手動Refresh・前面中の期間延長で取得。iOS/iPadOSは機会的Background App Refreshも要求。実行時刻はOS判断。Siriの保存は通信不要。 |
| 保存 | Calendar選択IDはUserDefaults、認証TokenはKeychain。Reminderとの関連付け・所要時間・補完締切・除外はSandbox内のJSON。手動Task・計画・開始済みの履歴と前回の予定表示は端末内SwiftData。 |

起動時に前回のTask・計画を読み戻してから、保存した選択でGoogle/Remindersを取得します。
取得失敗時も前回の計画を保持します。復元したReminders Taskの変更は、元データの再取得を待ちます。
Calendar未選択の初回は活動時間のみの仮配置です。選択済みCalendarが未取得の場合は取得まで配置を待ちます。
開始済みの計画は再起動後も保護し、未来の未完了作業だけを再配置します。履歴は自動削除しません。
「接続状況と保存」で最終保存時刻を確認できます。保存失敗時は警告と「保存を再試行」を表示します。
読み込めない保存データは上書きしません。CloudKit同期のコードは用意していますが、現在のProvisioning Profileには必要なentitlementがないため有効化していません。Developer ProgramとCloudKit設定が必要です。無料Personal Teamでの利用を維持しています。
上部の「バックアップ」でJSONを書き出し、Mac・iPhone・iPadへ手動で渡せます。
受け取り先で「ファイルから読み込む」を選び、内容を確認してから復元します。Task・設定・履歴を引き継ぎ、認証Tokenは含めません。
別端末のReminder設定は外部IDが安全に一致したものだけ適用します。詳細は[バックアップと受け渡し手順](docs/BackupTransfer.md)を参照してください。
開始済みと新しい固定予定が衝突すれば保持して警告します。保持時間は実際の作業完了記録ではありません。
対応OS設定はmacOS/iOS/visionOS 27.0のままです。

## 検証

2026-10-12、Final Integrationの全485ケース成功（既存419＋追加66、パラメータ展開後）。macOSアプリ/単体テストとiOS Simulatorビルドが成功しました。Google書き戻し・CloudKitの実サービス、新UI/Siri/Background Refreshの実機確認は残っています。詳細は[最終実装報告](docs/FinalIntegration.md)を参照してください。

2026-10-12、Siri / App Intents追加後の全322ケース成功（既存303＋追加19）。
macOSビルドとiOS Simulatorビルドも成功し、日本語のShortcutメタデータ生成を確認しました。
Siri実機対話とShortcutsアプリからの実行は実機での確認が残っています。

同日、日次上限・ルーティン追加後の全374ケース成功（既存322＋追加52）。
macOSビルドとiOS Simulatorビルドも成功しています。新しい画面の実操作は実機での確認が残っています。

2026-10-07、全303ケース成功（Phase 8前半の283 + ファイル受け渡しの追加20、パラメータ展開後）。
macOSアプリ・単体テスト、iOS Simulatorビルドが成功しています。
Apple Development署名のMacアプリで、実OAuth、Keychain保存・読み出し、複数Calendar選択、実予定取得、手動Refreshを確認しました。
表示された実予定からの空き枠を既存Schedulerへ渡し、合成Taskの複数日配置も確認しました。
iOS実機は未検証です。Phase 5では認証と選択の再起動復元、実Refresh Tokenによる更新、Google予定の変更に伴うTaskの再配置も確認しました。
合成Google応答による「10–12授業、14–16バイト → 08–10/12–14/16–23空き枠」とTask配置を検証済みです。
Phase 6では実Remindersの入力待ち→60分設定→Google予定回避配置、両アプリ間の完了/未完了、再起動復元、配置解除を確認済みです。
Phase 7ではMacでToday・Gantt・詳細・編集・完了・日別移動を実確認済みです。iPhone/iPadの画面・実機確認は残っています。
Phase 8前半ではMacでTask追加・編集・完了・削除後の終了/再起動復元を実確認済みです。CloudKit同期は個人利用の方針により見送っています。
ファイル受け渡しでは、MacでJSON書き出し→Task編集→確認画面→元のTaskと配置へ復元する操作を実確認しました。

単体テスト:

    xcodebuild -project PersonalGantt.xcodeproj -scheme PersonalGantt -destination 'platform=macOS' -derivedDataPath /tmp/PersonalGantt-derived -only-testing:PersonalGanttTests test CODE_SIGNING_ALLOWED=NO

iOSコンパイル:

    xcodebuild -project PersonalGantt.xcodeproj -scheme PersonalGantt -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/PersonalGantt-ios-derived build CODE_SIGNING_ALLOWED=NO

## 未実装と報告

Reminderの新規作成・削除・タイトル/締切の書き込み、複数日Gantt・ズーム・ドラッグ操作、常時バックグラウンド監視は未実装です。
CloudKitの有効化には追加設定が必要です。Reminders固有の所要時間・補完締切・除外設定は自動同期対象外で、JSONによる手動受け渡しを維持しています。
日次上限を一時的に超える締切優先と、ルーティンのSiri音声入力は未対応です。
EventKit Calendarの取得・権限要求は削除済みです。EventKitはReminders専用サービスと旧Calendar変換の合成テストで使用します。
認証情報・個人データはGitへ追加しません。

- [Phase 4.5の変更ファイル・OAuth・検証・残課題](docs/Phase4.5.md)
- [Phase 5の変更ファイル・更新タイミング・検証・残課題](docs/Phase5.md)
- [Phase 6の変更ファイル・Reminders権限・同期・実検証・残課題](docs/Phase6.md)
- [Phase 7の画面構成・変更ファイル・検証・残課題](docs/Phase7.md)
- [Phase 8前半の端末内保存・復元・検証・同期の課題](docs/Phase8.md)
- [個人利用のバックアップとMac・iPhone・iPadの手動受け渡し](docs/BackupTransfer.md)
- [iPhone・iPadへの個人用インストールとファイル往復の確認](docs/PersonalDeviceSetup.md)
- [Google OAuth設定手順](docs/GoogleOAuthSetup.md)
- [Siri / App Intentsの構成・検証・実機確認手順](docs/SiriAppIntents.md)
- [日次上限・ルーティンの構成・保存互換性・確認手順](docs/DailyWorkloadRoutines.md)
- [Final Integrationの仕様・検証・CloudKit/Google追加設定・実機確認手順](docs/FinalIntegration.md)
- [Phase 4の履歴](docs/Phase4.md)
- [Phase 3の履歴](docs/Phase3.md)

Gitの区切り: Scheduler MVP e9e05bf、Phase 3 8525aee、Phase 4 b03e186。
