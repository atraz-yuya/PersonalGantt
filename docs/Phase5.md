# Phase 5：再スケジューリングの仕上げ

2026-10-06。Google予定取得から未来のTask配置までの更新処理を整理しました。
Google Calendarへの書き込み、Reminders、Task/計画の永続化は追加していません。

## 変更ファイルと役割

| ファイル | 内容 |
| --- | --- |
| PersonalGantt/Services/CalendarSelectionStore.swift | OAuthクライアントごとのCalendar選択IDをUserDefaultsへ保存・復元。 |
| PersonalGantt/Scheduling/ScheduleViewModel.swift | 取得・再配置の集約、復帰・日付更新、取得中の要求集約、初回仮配置の置換。 |
| PersonalGantt/ContentView.swift | scenePhaseとMacのAppKit活動状態通知による前面復帰、前面中の日付切替通知・タイマー。 |
| PersonalGantt/Views/CalendarSelectionView.swift | 選択保存の案内、消えたCalendarの選択除去、Google接続確認。 |
| PersonalGantt/Services/CalendarService.swift | 接続確認の境界と期間変更時の安全なエラー。 |
| PersonalGantt/Services/Google/GoogleCalendarService.swift | 接続確認でToken更新を実行。ライブ環境は現在のタイムゾーン変更に追従。 |
| PersonalGanttTests/CalendarSelectionStoreTests.swift | 選択保存・クライアント分離・不正設定・空選択。 |
| PersonalGanttTests/ScheduleRefreshTests.swift | 起動・復帰・日付切替・取得中の競合・保護・失敗・DST。 |
| PersonalGanttTests/GoogleSessionIntegrationTests.swift | 認証復元・期限切れ更新・接続確認・失効・ログアウトの統合検証。 |
| README.md、docs/Phase5.md、docs/GoogleOAuthSetup.md | 現在の操作と検証結果。 |

既存Scheduler、AvailabilityService、ScheduleReplannerの純粋ロジックは変更していません。
ユーザーのXcode Team設定は手元に保持し、この変更にはコミットしません。

## 保存と初回配置

保存するのは選択CalendarのIDだけです。OAuthクライアントIDごとに分離し、
Token・実予定・Task・ScheduledBlockはこの設定ストアへ入れません。
Tokenは従来どおりKeychainです。実Calendarの内容はメモリ内だけです。
反映・Refreshが完全に成功した後に選択を保存します。失敗時は以前の選択・予定・空き枠・計画・最終更新時刻を保持します。
削除・利用不可になったCalendarは、一覧取得成功時に選択から除外して保存します。
明示的ログアウトで選択を消去し、別アカウントへ意図しない選択を持ち越しません。
クライアントID変更時も旧選択を消去します。失効による再認証待ちでは選択を保持します。

最初のCalendar取得までは仮配置として表示します。
初回取得成功時には仮配置全体を置き換えます。仮配置の開始時刻だけで作業開始とみなしません。
一度取得に成功した計画は従来の保護規則を適用します。
過去・進行中をそのまま保持し、未来の未完了作業だけを再生成します。
進行中と新しい固定予定が重なれば、ブロックを保持して警告します。
保持する予約時間は作業実績ではありません。completedMinutesは追加していません。

## 再計算のタイミング

| 操作・状況 | Calendar取得 | 配置 |
| --- | --- | --- |
| 起動・アプリが前面へ戻る | 保存した認証と選択で取得。OAuth画面は自動表示しない。 | 成功後に再計算。 |
| 前面中の日付切替 | 今日を含む14日間で再取得。 | 新しい期間で再計算。過去・進行中は保持。 |
| 手動Refresh | 選択Calendarを再取得。 | 成功後に再計算。 |
| Calendar選択の反映 | 新しい選択で取得。 | 成功後に再計算し、選択を保存。 |
| Google接続を確認 | 同じ読み取り権限のままToken更新後に再取得。 | 成功後に再計算。 |
| Task追加・編集・削除・完了切替／再計算 | 取得しない。 | 最後に成功した空き枠で再計算。 |
| 非アクティブ・バックグラウンド | 自動取得を開始しない。 | 復帰後に更新。 |

日付タイマーは前面のSwiftUIタスクだけが持ち、非アクティブ化でキャンセルします。
MacではNSApplicationのdidBecomeActive/didResignActive通知も使い、他アプリとの切り替えを判定します。
Calendarの日付境界を使うためDSTで23/25時間になる日にも対応します。
タイムゾーン変更も前面で再取得します。常時バックグラウンド監視はありません。

取得中の復帰・日付更新は集約し、並行した取得を開始しません。
キャンセルされた旧取得は結果を公開せず、次の復帰を取りこぼしません。
日付が取得中に変わった場合は現在の14日間で再取得します。
期間が繰り返し変わる場合は2回で停止し、安全なエラーと以前の結果を残します。
空き枠の現在時刻切り詰めと保護判定には取得完了時点の同じ時刻を使い、最新のTask入力を反映します。

## テストとビルド

全181ケース成功（既存153＋追加28）。パラメータ展開後の実行ケース数です。
Xcode結果バンドルの定義数は139で、動的パラメータを展開すると181になります。
結果: /tmp/PersonalGantt-phase5-lifecycle-tests.xcresult
ログ: /tmp/PersonalGantt-phase5-lifecycle-test.log

追加28ケース: CalendarSelectionStoreTests 4、ScheduleRefreshTests 20、
GoogleSessionIntegrationTests 4。すべて合成予定・合成認証情報を使い、実Keychainを変更しません。
選択の復元、期限切れTokenの更新後のGoogle取得と配置、invalid_grantによる認証解除、
取得失敗時の保持、初回仮配置の置換、過去・進行中保持、日付切替、取得中キャンセルを確認しました。

iOS Simulatorビルド成功: /tmp/PersonalGantt-phase5-lifecycle-ios-build.log。
macOSのApple Development署名ビルドとcodesignの署名検証も成功しました。
Macログ: /tmp/PersonalGantt-phase5-lifecycle-mac-build.log。
Swiftの警告・エラーはありません。AppIntents.framework未使用によるmetadata extraction skippedの案内だけがあります。

## 実環境の確認

Phase 4.5では本人のGoogle OAuth・Keychain保存/読み出し・複数Calendar取得・Refreshを確認済みです。
Phase 5では以下を追加で確認しました。本人の追加・変更依頼に基づき、ブラウザのGoogle Calendar画面で専用テストCalendarと予定を作成しました。
PersonalGanttのAPI・OAuth権限には書き込みを追加していません。

- 開発署名Macアプリで、追加ログインなしに認証を復元できました。
- 複数Calendarを反映し、終了・起動後も選択と実予定の取得結果を復元できました。
- Google接続確認で実Refresh Tokenによる更新と再取得が成功しました。Token自体は読み出して表示していません。
- Macの前面切り替え後、自動取得が成功して最終読み込み時刻が更新されました。
- 専用テスト予定を延長してRefreshすると、翌日の確認Taskの開始時刻が延長分だけ後ろへ移動しました。
- 確認Taskの600分の総配置量と今日の進行中ブロックは保持されました。未配置は発生しませんでした。

検証後、アプリ内の確認Taskを削除し、テストCalendarをPersonalGanttの選択から外して通常の2Calendarへ戻しました。
専用テストCalendarとその確認予定はGoogle側に残し、今後も確認に使える状態にしています。
確認画像はリポジトリ外の/tmp/PersonalGantt-phase5-google-event.pngと/tmp/PersonalGantt-phase5-schedule.pngに保存しました。
実時間での深夜境界と自然なToken期限到来は待っていません。日付変更・DST・期限切れ更新の条件は注入した時計と合成API応答で確認しました。
指定のイベントの日時・Calendar ID・アカウント名・TokenはGitへ記録しません。
追跡済み・追加ファイルの秘密情報パターン検査と差分確認を行い、実Token・Client Secret・実Calendarスナップショットが含まれていないことを確認しました。

## 制約とRemindersへ進む前の仕様

Task・所要時間・Reminder関連ID・計画履歴はまだメモリ内です。
アプリ終了後の過去/進行中ブロック保持は保証しません。再起動は新しい計画として扱います。
Taskの開始・終了時刻の入力欄はなく、Schedulerが決定します。
バックグラウンド監視、Google書き込み、Reminders、Siri、CloudKit、本格的Gantt、
completedMinutesは未実装です。iOS実機での認証は未検証です。

Remindersへ進む前に以下を決めます。

1. 締切なしのReminderを配置するか、締切入力待ちにするか。
2. 日付だけの締切を何時とみなすか。
3. 想定所要時間の初期値と、PersonalGantt側での保存方法。
4. 使用するReminderリストの選択、識別子変更・削除・重複の扱い。
5. 完了状態をRemindersへ書き戻すか、初期段階は読み取りだけにするか。
6. 再起動後も保持するTaskメタデータ・計画履歴の範囲。

EventKitのCalendar取得は復活させず、Reminders用の独立したService境界を使います。
