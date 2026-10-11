# Siri / App Intentsによるタスク追加

2026-10-12。ダウンロード済みの「PersonalGantt Phase 5 — Siri / App Intents 音声タスク追加 実装指示書」に基づく追加です。
既存のdocs/Phase5.mdは再スケジューリングの履歴なので、この報告を別ファイルにしました。

同日のv2指示書に基づく追加では、独立した[日次上限・ルーティン機能](DailyWorkloadRoutines.md)を実装しています。
Siriの入力3項目・Shortcutは維持し、共通Schedulerへ日次上限を渡します。
以下は最初のSiri実装時の報告です。追加後のScheduler・保存形式・全374テストの詳細はリンク先を参照してください。

## Gitと変更ファイル

ブランチ: `codex/siri-app-intents`。コミット: `Add Siri task creation with App Intents`。
作業開始時に存在したXcodeのDEVELOPMENT_TEAM変更は保持し、コミット対象から外します。

| ファイル | 変更 |
| --- | --- |
| PersonalGantt/AppIntents/AddPersonalGanttTaskIntent.swift | 必須3項目、入力質問、再入力、実行、結果ダイアログ。 |
| PersonalGantt/AppIntents/PersonalGanttShortcuts.swift | タスク追加のApp Shortcut、英語の起動フレーズ。 |
| PersonalGantt/ja.lproj/AppShortcuts.strings | 日本語の起動フレーズ3種類。 |
| PersonalGantt/Services/TaskCreationService.swift | 既存追加処理の呼び出し、保存と配置の結果を区別。 |
| PersonalGantt/Scheduling/ScheduleViewModel.swift | 共有モデル、Taskを再計算前に確実に保存するオプション。 |
| PersonalGantt/PersonalGanttApp.swift | 共有モデルをUIで使用、ショートカットのパラメータ更新。 |
| PersonalGantt.xcodeproj/project.pbxproj | 日本語リソースのknownRegions登録。 |
| PersonalGanttTests/TaskCreationServiceTests.swift | 共通追加経路の検証。 |
| README.md、docs/SiriAppIntents.md | 操作・設計・検証報告。 |

## IntentとShortcut

Apple純正の`AppIntent`と`AppShortcutsProvider`を使用します。
アクション名は「タスクを追加」、Intent型は`AddPersonalGanttTaskIntent`です。
必須パラメータに既定値を設定せず、App Intentsのパラメータ解決で不足を尋ねます。

| 入力 | Swiftプロパティ | 型 | 質問 |
| --- | --- | --- | --- |
| タスク名 | taskTitle | String | 何を追加しますか？ |
| 所要時間（分） | estimatedMinutes | Int | 何分必要ですか？ |
| 締切 | deadline | Date（dateTime） | 締切はいつですか？ |

タスク名はTask.titleへ対応します。開始・終了時刻のパラメータはありません。
空白だけの名前、0/負数の所要時間、不正Dateは既存TaskDraftで拒否し、Intentでは該当パラメータの`needsValueError`に変換します。
Int最大値も整数乗算や危険なDouble→Int変換を行わず処理します。
UIで許容している過去の締切は引き続き登録でき、未配置として扱います。

`PersonalGanttShortcuts`は1つのApp Shortcutを公開します。
英語ソースフレーズの`${applicationName}`を日本語のAppShortcuts.stringsで翻訳し、日本語Siri用に3フレーズを用意しました。
アイコンは`plus.circle`、表示名は「タスクを追加」です。
起動時に`updateAppShortcutParameters()`を実行します。

## データフローと保存

```text
Siri / Shortcuts
  → AddPersonalGanttTaskIntent.perform（MainActor）
  → TaskCreationService
  → TaskDraft
  → ScheduleViewModel.addTask(requirePersistence: true)
  → UIと同じvalidation / UUID生成 / 通常Task
  → SwiftDataPlanStore.save（Taskを含むcheckpointを先に保存）
  → 同じ共有モデルにTaskを追加
  → recalculate → 既存ScheduleReplanner / Scheduler
  → SwiftDataPlanStore.save（再計算したcheckpointを保存）
  → 保存成功と配置結果をSiriへ返す

UI → ScheduleViewModel.addTask → 同じvalidation / UUID生成 / 再計算
```

UIとIntentは`ScheduleViewModel.shared`を使い、同じメモリ状態と保存先を所有します。
別のSwiftDataストアやSiri専用Task、専用の作成ルールは追加していません。
SiriからのTaskも通常UIで編集・完了・削除・バックアップできます。
既存UIの保存失敗時の警告・再試行仕様を維持し、無人実行のIntentでは保存成功を必須にしています。

最初の保存が失敗した場合や保存データが読み込めない場合は、Taskをモデルへ追加せずエラーを返します。
バックアップ復旧が必要な場合も既存の変更禁止を守ります。
最初の保存後に作業予定の保存が失敗しても、Task自体は再起動後に残ります。
その場合は「タスクは保存済みですが、作業予定の保存を再試行する必要があります」と返します。
メモリ内の再計算結果は既存「保存を再試行」で保存でき、再起動後は次回Calendar更新で再計算できます。

## Scheduler、Calendar、Reminders

タスク追加はネットワークを待たず、現在保持しているAvailableSlotで再計算します。
Google Calendarの固定予定を差し引いたキャッシュがあれば、その予定を避けて配置します。
開始済みのブロック保護も既存ScheduleReplannerの規則を使用します。
キャッシュなしの初回は既存の活動時間による仮配置を使います。
連携設定変更によって利用できるキャッシュがない場合は、Taskを保存し、次の更新を待ちます。
古いキャッシュしかない場合、その後に変更されたGoogle予定との衝突回避は次回Refresh後に確定します。

Calendar更新失敗・オフラインでも追加は成功できます。IntentからOAuth、API取得、Remindersの許可要求を呼びません。
UIが前面で行う既存の自動Refreshは独立して実行される場合があります。
利用可能な時間が不足した場合は、保存成功の確認に続けて「現在の空き時間では締切までに○分配置できませんでした」と返します。
Google Calendarサービス、OAuth scope、予定書き込み機能、既存Schedulerの純粋ロジックは変更していません。
Apple Remindersの取り込み・所要時間設定・完了同期も既存のままです。

## バックグラウンドとプライバシー

`supportedModes = .background`を指定します。App Intentはアプリのターゲットに置き、独立した拡張は追加していません。
アプリプロセスを必要に応じて起動し、画面を前面に出す要求をせずにMainActorで保存します。
MainActorはスレッドの制約であり、前面表示の要求ではありません。
UIとIntentの同期処理にはawaitを挟まず、Calendar取得中でも追加したTaskを後続の再計算へ反映できます。
終了状態からの起動、OSの実行制限、ロック中のSiriなどの挙動は実機で確認が必要です。
App Group、SiriKitの独自Intent、音声認識UI、LLM、外部サーバー送信を追加していません。
Task、Token、Keychain、実Calendar内容の新規ログもありません。

## 検証結果

最終コードの全322ケース成功（既存303＋追加19、パラメータ展開後）。失敗・スキップは0です。
結果バンドルの定義数は251で、動的パラメータの展開後が322です。
macOSビルド成功、iOS Simulatorビルド成功。最終ビルド・テストログにコンパイラの警告・エラーはありません。
いずれも`CODE_SIGNING_ALLOWED=NO`で検証し、今回の実機署名ビルド・インストールは行っていません。
生成された`Metadata.appintents/extract.actionsdata`で、3つの必須パラメータ、アクション公開、
backgroundモード、前面起動要求なしを確認しました。
`root.ssu.yaml`と`ja.lproj/nlu.appintents`で日本語の3つの起動フレーズが生成されていることも確認しました。

```text
macOSビルドログ: /tmp/PersonalGantt-siri-mac-final-build.log
テストログ: /tmp/PersonalGantt-siri-final-tests.log
結果バンドル: /tmp/PersonalGantt-siri-final-tests.xcresult
iOS Simulatorビルドログ: /tmp/PersonalGantt-siri-ios-final-build.log
```

追加テストはvalidation、UUID、Date、Int最大値、SwiftDataの再オープン、共有モデルへの即時反映、
Calendar回避、キャッシュなし、更新失敗、配置不足、Task保存失敗、作業予定保存失敗、読み込み不能を対象とします。
App Intentsの音声認識・システム側の対話は単体テスト対象にせず、共通UseCaseを検証します。
実アカウント・実Calendar・実Keychainをテストデータとして使用しません。

## iPhone実機の確認手順

1. 既存のPersonal Team設定でこのブランチをiPhoneへビルド・インストールします。アプリを一度開きます。
2. iPhoneのSiri言語を日本語にし、「Siri、PersonalGanttにタスクを追加」と言います。
   「卒論」「90分」「明日の18時」と質問に答え、追加結果を確認します。
3. PersonalGanttのタスク一覧で卒論・90分・指定締切を確認します。アプリを終了し、再起動後にも残ることを確認します。
4. ショートカットアプリで新しいショートカットを作り、アクション検索からPersonalGanttの「タスクを追加」を選びます。
   「Kaggle」「60」「明日の23時」を設定して実行し、通常Taskとして表示されることを確認します。
5. 所要時間0で実行し、再入力要求または入力エラーが出て、Taskが追加されないことを確認します。
6. Google Calendarを一度反映してからアプリをバックグラウンドにし、SiriでTaskを追加します。
   アプリを開き、保持している固定予定との重複がないことを確認します。
7. 機内モードでまずShortcutsから直接実行し、Taskが保存されることを確認します。
   Siri自体のオフライン音声認識可否は端末・OSによるため、アプリの保存経路と分けて確認します。
8. バックグラウンド状態とアプリ終了状態のそれぞれで追加し、前面起動を要求されるか、再起動時に残るか確認します。
9. 既存Remindersの取り込みと完了同期が従来どおり動くことを確認します。

## 制約と日本語フレーズ

実機Siriの聞き取りとShortcutsアプリ上での表示・実行は未確認です。
MVPは登録済みフレーズで起動し、必要項目を質問で補う方式です。
「卒論を90分、明日の18時まで」のような任意の一文から3項目すべてを確実に抽出する機能は保証しません。
独自の自由文章解析、開始/終了指定、Google予定作成、priority、completedMinutes、自動端末間同期は追加していません。

実機で試す起動フレーズは次の3つです。

- 「Siri、PersonalGanttにタスクを追加」
- 「Siri、PersonalGanttでタスクを追加」
- 「Siri、PersonalGanttに新しいタスクを追加」

続く質問には、たとえば「卒論」「90分」「明日の18時」と答えます。

Appleの参考資料: [AppIntent](https://developer.apple.com/documentation/appintents/appintent)、
[App Shortcuts](https://developer.apple.com/documentation/appintents/app-shortcuts)、
[supportedModes](https://developer.apple.com/documentation/appintents/appintent/supportedmodes)、
[App Shortcutsのローカライズ](https://developer.apple.com/videos/play/tech-talks/10168/)。
