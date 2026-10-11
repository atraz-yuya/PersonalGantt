# 日次作業量・ルーティン

2026-10-12。Siri MVP完了後、v2指示書の第22節に基づく独立機能として実装しました。
本書は導入時の実装記録です。14日固定の記述は、その後の[動的計画期間](DynamicPlanningHorizon.md)で最低14日・最長90暦日に更新しました。

ユーザーの指定により、初期状態は上限なしです。上部の「作業量・ルーティン」から有効化・変更します。

## Git・変更ファイル

ブランチ: `codex/daily-workload-routines`。開始点: `ecf2160`。
コミット名: `Add daily workload limits and recurring routines`。
既存のXcode DEVELOPMENT_TEAM変更は保持し、コミットに含めません。

| ファイル | 役割 |
| --- | --- |
| Models/WorkloadSettings.swift | 任意の日次上限、1分以上の入力検証。nilは上限なし。 |
| Models/Routine.swift | Routine、RecurrenceRule、日ごとの関連付けと安定ID、完了・スキップ状態。 |
| Models/Task.swift | 生成した日別Taskに任意のRoutineOccurrence関連を追加。 |
| Scheduling/DailyWorkload.swift | Calendar・TimeZoneを使った暦日分割と秒単位の集計。 |
| Scheduling/RoutinePlanner.swift | 現在の計画対象期間に日別作業要件を生成。 |
| Scheduling/Scheduler.swift | Taskの総量・締切・日別Routine範囲・日次残容量で配置。 |
| Scheduling/ScheduleReplanner.swift | 開始済み枠を保持し、日次残容量から差し引く。 |
| Scheduling/ScheduleViewModel.swift | 設定、ルーティン操作、日付更新、保存・バックアップ・再計算の接続。 |
| Persistence/PlanSnapshot.swift | payload v2の検証とv1の読み込み互換性。 |
| Services/TaskCreationService.swift | Siriの未配置理由に日次上限・対象期間を反映。 |
| Views/WorkloadRoutineView.swift | 日次上限、ルーティン管理、日別配置時間の一覧。 |
| Views/RoutineEditorView.swift | 名前、分数、毎日・平日・曜日指定・毎週、開始日・終了日。 |
| ContentView.swift | 設定画面の入口と、日別ルーティンのスキップ確認。 |
| Views/TaskListView.swift、TaskRowView.swift、TaskDetailView.swift | 通常Taskと日別Routineを区別し、完了・スキップ・全体編集へ接続。 |
| Views/IntegrationStatusView.swift | 上限と開始済み枠による超過の表示。 |
| Views/BackupFileDocument.swift | 復元前にルーティン数・日次上限も表示。 |
| PersonalGanttTests/DailyWorkloadTests.swift | 日次上限・長期作業・固定予定・DST・開始済み枠の18ケース。 |
| PersonalGanttTests/RoutinePlannerTests.swift | 曜日・期間・日別配置・ID・完了・スキップ等の17ケース。 |
| PersonalGanttTests/WorkloadRoutineIntegrationTests.swift | Siri、UI操作相当のモデル操作、保存・復元・バックアップ等の17ケース。 |
| PersonalGanttTests/PlanPersistenceTests.swift、BackupTests.swift | v2が対応済みになったため、非対応バージョン検証を999へ更新。 |
| README.md、docs/SiriAppIntents.md、このファイル | 操作と検証報告。 |

アプリのファイルパスはPersonalGantt/以下です。Google Calendar・OAuth・RemindersサービスとApp Shortcutのフレーズは変更していません。

## 配置の規則

`WorkloadSettings.maxScheduledMinutesPerDay`は、PersonalGanttが配置する全Taskの合計上限です。
通常Task、Reminders Task、日別Routineが同じ容量を共有します。固定予定はAvailableSlotの生成で回避し、上限には加算しません。
上限なし・Routineなしでは元のSchedulerの配置方法を維持します。

上限がある場合は空き枠を暦日境界で分割し、締切→UUIDの順で早い空き時間へ配置します。
その日の配置済み秒数を差し引き、上限に達したら次の日へ進みます。
所要時間・上限をDoubleの秒数へ変換してから扱うため、Intの乗算オーバーフローはありません。
秒を切り捨てず、端数や夏時間の23/25時間の日にも対応します。

例: 空き時間がある30日間で100時間・1日300分なら、20日間に5時間ずつ配置します。
3日間で18時間・1日300分なら、15時間まで配置し、残り180分を未配置として表示します。
上限を自動で超える処理はありません。均等配分は将来拡張とし、今回の方式は上限付きの早い順の配置です。

開始済みの時間枠は、元の保護仕様を維持します。過去や進行中、削除済みTaskの保持枠も日別容量に数えます。
日付をまたぐ保持枠は実際の暦日ごとに分けて数えます。
上限を引き下げて既存の開始済み枠が超過した場合は枠を保持し、同じ日の追加配置を止めて警告します。
配置時間は作業実績ではありません。completedMinutesは追加していません。

## Routineと通常Taskの違い

通常Taskは締切までに必要な総時間です。Routineは該当する各日ごとに必要な時間です。
`RoutinePlanner`が、現在の14日間とRoutineの開始日・終了日の交差からTaskを生成します。
終了日はその日を含み、日ごとの締切は次の暦日の00:00です。

対応するルールは毎日、平日（月〜金）、任意の曜日集合、毎週指定曜日です。
平日は祝日を除外する意味ではありません。曜日はFoundationの1=日〜7=土を使います。
日別Taskはその日の開始以前や翌日以降に配置しません。不足分を翌日のRoutineへ合算しません。
通常Taskと同じSchedulerへ渡し、同じ日次上限・固定予定回避・開始済み枠保護を適用します。

Routine UUIDとグレゴリオ暦のローカル日付から、決定的な日別Task UUIDを生成します。
再計算・再起動・入力順序でIDを変えず、同じ日付はタイムゾーンのオフセットが変わっても同じIDです。
生成したTaskには日別Routineの関連付けと暦日の範囲を保持し、通常Taskの意味と区別します。
日別Taskを手動の一回限りTaskとして編集する処理は拒否し、UIの編集はRoutine全体の設定を開きます。

完了操作はその日の分だけに適用します。「この日をスキップ」もその日の分だけを除外します。
状態はRoutine側に保存し、再生成や再起動で完了・スキップを取り消しません。
設定画面の「スキップを解除」で除外を戻せます。Routineの削除は将来の要件を止め、開始済み枠とそのタイトルは保持します。

## 保存・バックアップの互換性

SwiftDataのCheckpointモデルと保存先は維持し、JSON payloadをv2へ拡張しました。
v1を読み込むと上限なし・Routineなしとして復元します。新しい保存はv2です。
TaskのRoutine関連はoptionalなので、既存Task JSONはそのまま読み込めます。
v2では設定・Routineの重複ID、日別TaskのID・日範囲・完了状態・関連先などを検証します。
未知のバージョン・読み込めないデータは既存の保存禁止仕様で保護します。

バックアップの外側の形式はv1を維持し、内側のPlanSnapshotバージョンで判別します。
旧バックアップは読み込み可能です。新バックアップには上限、Routine、完了・スキップ状態が含まれます。
復元先の暦日・現在の14日間でRoutineを再生成し、開始済みの端末内の時間枠を保持します。
古いアプリはPlanSnapshot v2を非対応として拒否するので、新しいバックアップは更新済みアプリで復元してください。
保存失敗の警告、保存再試行、バックアップ復旧ジャーナルは既存経路を使います。

## Siri・Calendar・Reminders

SiriのAppIntent、AppShortcut、必須パラメータ（タスク名、Intの分数、Dateの締切）、background実行は維持します。
通常のSiri Task追加から共通Schedulerへ日次上限を渡し、保存成功と未配置を分けて返します。
日次上限がある場合は返答に「1日○分の上限」を含めます。
締切が現在の計画期間より先の場合は「締切まで」ではなく「対象期間内」の未配置として伝えます。
RoutineのSiri音声入力は追加していません。3つの既存起動フレーズを引き続き使用できます。

Intent実行ではGoogleのネットワークを要求しません。Calendar更新失敗時も現在の空き枠を使えます。
日付切替時は、オフラインでも新しい14日間のRoutine要件を生成します。
キャッシュに空き枠がない新しい日は未配置とし、Calendarの次回取得を待ちます。未取得の空き枠を推測して確定配置しません。
Googleサービス・OAuth scope・書き込み権限・Remindersの取り込みと完了同期は変更していません。
新しい外部送信やTask・Token・実Calendarのログは追加していません。

## テスト・ビルド

全374ケース成功（既存322＋追加52、パラメータ展開後）。失敗・スキップは0です。
結果バンドルの定義数は288で、動的パラメータ展開後が374です。
macOSビルドとiOS Simulatorビルドが成功しています。CODE_SIGNING_ALLOWED=NOで検証しました。
新しい画面の実操作とiPhone実機のSiri対話は未確認です。この実行環境ではSimulator GUIが利用できませんでした。
テストは注入したCalendar・時計・合成予定・一時SwiftDataを使い、実GoogleアカウントやKeychainを変更しません。

```text
macOS全テスト: /tmp/PersonalGantt-workload-final-tests.log
結果バンドル: /tmp/PersonalGantt-workload-final-tests.xcresult
iOSビルド: /tmp/PersonalGantt-workload-ios-final-build.log
```

## 実機での確認

1. ブランチをビルド・インストールし、「作業量・ルーティン」を開きます。最初は上限なしです。
2. 日次上限を有効にして300分を保存します。既存の未来の作業が1日300分以内へ移ることを確認します。
3. 「英語・30分・平日・今日〜今月末」のRoutineを追加し、タスク一覧に平日の日別作業が生成されることを確認します。
4. 1日分を完了にし、別の日をスキップします。アプリの終了・再起動後にも両方が維持されることを確認します。
5. Routineの編集から45分へ変更し、将来の必要時間が変わることを確認します。
6. 「日ごとの配置時間」で、通常・Reminders・Routineの合計が上限以内であることを確認します。
7. 今日締切の大きなTaskを追加し、未配置分数が出ることを確認します。Siriからも同じ上限が反映されます。
8. バックアップを書き出して復元し、上限・Routine・日別の完了状態が引き継がれることを確認します。
9. 開始済み枠がある日に上限を引き下げ、枠が保持され、同日の追加配置が止まることを確認します。

## 制約・音声フレーズ

計画期間は既存の14日間です。1か月先までの一括表示・Calendar取得期間拡張は行っていません。
均等配分、上限超過を許可する締切優先、祝日ルール、RoutineのSiri入力、自動端末間同期は未実装です。
Siriのフレーズは次の3つです。続く質問に「卒論」「90分」「明日の18時」などと答えます。

- 「Siri、PersonalGanttにタスクを追加」
- 「Siri、PersonalGanttでタスクを追加」
- 「Siri、PersonalGanttに新しいタスクを追加」
