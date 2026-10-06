# PersonalGantt

名前・所要時間・締切から、空き時間へTaskを配置するSwiftUIアプリです。
Phase 4.5で予定の取得元をGoogle Calendar APIへ切り替えました。
Phase 5でCalendar選択の保存と、起動・前面復帰・日付切替の更新処理を追加しました。
コード実装・合成データ検証に加え、本人のOAuthログインと実Google Calendarの取得・空き時間生成・手動RefreshをmacOSで確認済みです。

## 起動とGoogle設定

1. PersonalGantt.xcodeprojをXcodeで開き、PersonalGantt Schemeを選ぶ。
2. 実認証に使うAppleの開発TeamとKeychain用署名・Provisioning Profileを設定する。
3. Google CloudでCalendar APIとiOSタイプOAuthクライアントを設定する。
4. アプリの「使用するカレンダーを選択」でClient IDを保存し、Googleへログインする。
5. Calendarを複数選び「反映」する。Google側の変更は手動Refreshで読み直す。

詳しいボタン・Bundle ID・スコープ・確認手順は[OAuth設定手順](docs/GoogleOAuthSetup.md)を参照してください。
Client Secret/Tokenはチャットやコードへ貼りません。Client IDは公開識別子としてUserDefaults、TokenはKeychainへ保存します。
Calendarへの書き込みはありません。Apple Calendarの同期設定は使いません。

## 現在のデータフロー

    Google Calendar API → GoogleCalendarService → FixedEvent
        → AvailabilityService → AvailableSlot → ScheduleReplanner → Scheduler

純粋なAvailabilityService・ScheduleReplanner・SchedulerはGoogle移行で変更していません。
将来のTask取得元はApple Remindersですが、現在のTaskはアプリ内サンプルと手動入力です。
Task.reminderIdentifierだけを関連付け準備として追加し、想定所要時間はPersonalGantt側に保持します。

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
| 保存 | Calendar選択IDはUserDefaults、認証TokenはKeychain。Task・計画・実予定の内容はメモリ内のみ。 |

起動時は3件のサンプルTaskと活動時間のみの仮配置を作り、保存したCalendar選択を復元して取得します。
最初の取得成功時に仮配置を置き換え、その後の更新では開始済みの計画を保護します。
開始済みと新しい固定予定が衝突すれば保持して警告します。保持時間は実際の作業完了記録ではありません。
対応OS設定はmacOS/iOS/visionOS 27.0のままです。

## 検証

2026-10-06、全181ケース成功（Phase 4.5の153 + Phase 5の追加28）。
macOSアプリ・単体テスト、iOS Simulatorビルドが成功しています。
Apple Development署名のMacアプリで、実OAuth、Keychain保存・読み出し、複数Calendar選択、実予定取得、手動Refreshを確認しました。
表示された実予定からの空き枠を既存Schedulerへ渡し、合成Taskの複数日配置も確認しました。
iOS実機は未検証です。Phase 5では認証と選択の再起動復元、実Refresh Tokenによる更新、Google予定の変更に伴うTaskの再配置も確認しました。
合成Google応答による「10–12授業、14–16バイト → 08–10/12–14/16–23空き枠」とTask配置を検証済みです。

単体テスト:

    xcodebuild -project PersonalGantt.xcodeproj -scheme PersonalGantt -destination 'platform=macOS' -derivedDataPath /tmp/PersonalGantt-derived -only-testing:PersonalGanttTests test CODE_SIGNING_ALLOWED=NO

iOSコンパイル:

    xcodebuild -project PersonalGantt.xcodeproj -scheme PersonalGantt -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/PersonalGantt-ios-derived build CODE_SIGNING_ALLOWED=NO

## 未実装と報告

Googleへの予定書き込み、Reminders連携、Siri、CloudKit、本格的Gantt、常時バックグラウンド監視、completedMinutesは未実装です。
EventKit Calendarの取得・権限は削除し、EventKitは将来のReminders用境界と旧変換のテストに残しています。
認証情報・個人データはGitへ追加しません。

- [Phase 4.5の変更ファイル・OAuth・検証・残課題](docs/Phase4.5.md)
- [Phase 5の変更ファイル・更新タイミング・検証・残課題](docs/Phase5.md)
- [Google OAuth設定手順](docs/GoogleOAuthSetup.md)
- [Phase 4の履歴](docs/Phase4.md)
- [Phase 3の履歴](docs/Phase3.md)

Gitの区切り: Scheduler MVP e9e05bf、Phase 3 8525aee、Phase 4 b03e186。
