# PersonalGantt

名前・所要時間・締切から、空き時間へTaskを配置するSwiftUIアプリです。
Phase 4.5で予定の取得元をGoogle Calendar APIへ切り替えました。
Phase 5でCalendar選択の保存と、起動・前面復帰・日付切替の更新処理を追加しました。
Phase 6でApple Remindersの取り込み、入力待ち、所要時間設定、完了状態の双方向同期を追加しました。
Phase 7でToday・日別Timeline・日単位Gantt・Task詳細を追加しました。
コード実装・合成データ検証に加え、本人のOAuthログインと実Google Calendarの取得・空き時間生成・手動RefreshをmacOSで確認済みです。

## 起動とGoogle設定

1. PersonalGantt.xcodeprojをXcodeで開き、PersonalGantt Schemeを選ぶ。
2. 実認証に使うAppleの開発TeamとKeychain用署名・Provisioning Profileを設定する。
3. Google CloudでCalendar APIとiOSタイプOAuthクライアントを設定する。
4. アプリ上部の「連携」→「使用するカレンダーを選択」でClient IDを保存し、Googleへログインする。
5. Calendarを複数選び「反映」する。Google側の変更は上部の「再読み込み」から読み直す。

詳しいボタン・Bundle ID・スコープ・確認手順は[OAuth設定手順](docs/GoogleOAuthSetup.md)を参照してください。
Client Secret/Tokenはチャットやコードへ貼りません。Client IDは公開識別子としてUserDefaults、TokenはKeychainへ保存します。
Calendarへの書き込みはありません。Apple Calendarの同期設定は使いません。

## 現在のデータフロー

    Google Calendar API → GoogleCalendarService → FixedEvent
        → AvailabilityService → AvailableSlot → ScheduleReplanner → Scheduler

純粋なAvailabilityService・ScheduleReplanner・SchedulerはGoogle移行で変更していません。

    Apple Reminders → EventKitReminderService → ReminderRecord
        → ReminderSyncViewModel + 端末ローカルの所要時間・補完締切 → Task

Taskのタイトル・元の締切はRemindersを正とし、所要時間をRemindersへ書き込みません。
完了状態だけ双方向に反映します。手動Taskも利用できます。

「連携」→「使用するRemindersを選択」からOSアクセスを許可し、使用リストを複数選んで「反映」します。
不足項目は「入力待ち」です。「所要時間・締切を設定」で必要項目を埋めると配置されます。
日付だけの締切はその日23:59、開始・終了時刻はSchedulerが決定します。
「配置対象から外す」はPersonalGantt内の除外で、ネイティブReminderは削除しません。

## 画面

Mac・iPadの通常幅は左にTask、右に「今日 / 日別 / Gantt」です。
iPhoneなどコンパクト幅は「今日 / 日別 / タスク」のタブで、日別からGanttも選択できます。
作業枠またはTask名を選ぶとTask詳細を開きます。
日付選択は対象14日間です。GanttのTask名を固定し、時間軸を横スクロールできます。
バーの位置・幅はScheduledBlockの実日時で決まり、開始/終了の入力やドラッグ変更はありません。
過去の時間枠は作業実績とは区別して表示します。

## 仕様

| 項目 | 現在の仕様 |
| --- | --- |
| 活動時間 | 平日08:00–23:00、土日09:00–23:00。ActivitySettingsで変更可能。 |
| 対象期間 | 今日を含む14日間。今日+14日の00:00は対象外。 |
| 予定 | 選択Google Calendarのイベント。キャンセル除外、終日は全日占有。 |
| 重複 | 重複/隣接予定を結合して活動時間から差し引く。 |
| 優先順 | deadline → UUID。 |
| 再配置 | 過去/進行中を保持し、未来の未完了作業を再生成。 |
| 入力 | title、1分以上の整数estimatedMinutes、deadline。開始/終了はSchedulerが決める。 |
| 失敗 | 取得・権限・不正応答の失敗は直前の結果を保持し理由を表示。 |
| Refresh | 起動・前面復帰・前面中の日付切替・選択反映・手動RefreshでGoogleを取得。Task操作は取得済み枠を利用。 |
| 保存 | Calendar選択IDはUserDefaults、認証TokenはKeychain。Reminderとの関連付け・所要時間・補完締切・除外はSandbox内のJSON。手動Task・計画・開始済みの履歴と前回の予定表示は端末内SwiftData。 |

起動時に前回のTask・計画を読み戻してから、保存した選択でGoogle/Remindersを取得します。
取得失敗時も前回の計画を保持します。復元したReminders Taskの変更は、元データの再取得を待ちます。
保存データがない初回は活動時間のみの仮配置です。
開始済みの計画は再起動後も保護し、未来の未完了作業だけを再配置します。履歴は自動削除しません。
「接続状況と保存」で最終保存時刻を確認できます。保存失敗時は警告と「保存を再試行」を表示します。
読み込めない保存データは上書きしません。有料登録を行わず個人利用を優先する方針により、CloudKitによる端末間同期は見送ります。
上部の「バックアップ」でJSONを書き出し、Mac・iPhone・iPadへ手動で渡せます。
受け取り先で「ファイルから読み込む」を選び、内容を確認してから復元します。Task・設定・履歴を引き継ぎ、認証Tokenは含めません。
別端末のReminder設定は外部IDが安全に一致したものだけ適用します。詳細は[バックアップと受け渡し手順](docs/BackupTransfer.md)を参照してください。
開始済みと新しい固定予定が衝突すれば保持して警告します。保持時間は実際の作業完了記録ではありません。
対応OS設定はmacOS/iOS/visionOS 27.0のままです。

## 検証

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

Googleへの予定書き込み、Reminderの新規作成・削除・タイトル/締切の書き込み、Siri専用機能、CloudKit、複数日Gantt・ズーム・ドラッグ操作、常時バックグラウンド監視、completedMinutesは未実装です。
所要時間設定と手動Taskのデバイス間自動同期は未対応です。端末内の保存・復元とファイルによる手動受け渡しを利用できます。
EventKit Calendarの取得・権限要求は削除済みです。EventKitはReminders専用サービスと旧Calendar変換の合成テストで使用します。
認証情報・個人データはGitへ追加しません。

- [Phase 4.5の変更ファイル・OAuth・検証・残課題](docs/Phase4.5.md)
- [Phase 5の変更ファイル・更新タイミング・検証・残課題](docs/Phase5.md)
- [Phase 6の変更ファイル・Reminders権限・同期・実検証・残課題](docs/Phase6.md)
- [Phase 7の画面構成・変更ファイル・検証・残課題](docs/Phase7.md)
- [Phase 8前半の端末内保存・復元・検証・同期の課題](docs/Phase8.md)
- [個人利用のバックアップとMac・iPhone・iPadの手動受け渡し](docs/BackupTransfer.md)
- [Google OAuth設定手順](docs/GoogleOAuthSetup.md)
- [Phase 4の履歴](docs/Phase4.md)
- [Phase 3の履歴](docs/Phase3.md)

Gitの区切り: Scheduler MVP e9e05bf、Phase 3 8525aee、Phase 4 b03e186。
