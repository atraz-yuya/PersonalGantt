# PersonalGantt

タスク名・所要時間・締切から、空き時間へ作業を自動配置する SwiftUI アプリです。
Phase 1–2（Scheduler MVP）、Phase 3（タスク管理 UI）、Phase 4（AvailabilityService + Calendar連携）を実装しています。
Phase 1–2 の完了地点は Git コミット `e9e05bf` として保存されています。
Phase 3 の完了地点は `8525aee` です。

## 起動

1. `PersonalGantt.xcodeproj` を Xcode で開く。
2. Scheme を `PersonalGantt`、実行先を `My Mac` または iPhone / iPad Simulator にする。
3. Run（⌘R）を実行する。

既存プロジェクトの対応 OS 設定は macOS / iOS / visionOS 27.0 のままです。
起動時にはサンプルタスクを表示します。タスクは追加・編集・削除・完了切替ができます。
空き枠は平日08:00–23:00、土日09:00–23:00で、今日を含む14日分を生成します。
「使用するカレンダーを選択」で権限を許可し、対象Calendarを選んで「反映」すると固定予定を差し引きます。
Calendar側の変更後は「Calendarを再読み込み」で更新します。未選択なら活動時間だけを使います。
TaskとCalendar選択は保存せずアプリ終了時に消えます。

Phase 4 の追加ファイル・責務分離・仕様・検証結果は [Phase 4 実装報告](docs/Phase4.md) を参照してください。

## 実装内容と変更ファイル

| ファイル | 役割・変更理由 |
| --- | --- |
| `PersonalGantt/Models/Task.swift` | 作業要件を UI から分離。UUID、名前、完了状態、所要時間、締切を保持。Codable / Equatable 対応。 |
| `PersonalGantt/Models/ScheduledBlock.swift` | Task と別に配置結果を表現。Codable / Equatable 対応。 |
| `PersonalGantt/Models/AvailableSlot.swift` | 空き時間を独立したモデルで表現。 |
| `PersonalGantt/Models/TaskDraft.swift` | フォームの入力値と共通検証。空白名、0以下/非整数/桁あふれ、無効日時を拒否。 |
| `PersonalGantt/Scheduling/SchedulingResult.swift` | 配置済みブロックと、必要時間を配置しきれない Task ID を返す。 |
| `PersonalGantt/Scheduling/Scheduler.swift` | Foundation のみに依存する決定的なスケジューリング処理。 |
| `PersonalGantt/Scheduling/ScheduleViewModel.swift` | 初期計算、再計算、タスク操作、空き枠差し替え、表示用集計。UI の body で配置計算を行わない。 |
| `PersonalGantt/Scheduling/SampleSchedule.swift` | サンプルタスク。旧3日枠も保持するが、Phase 4のアプリでは使わない。 |
| `PersonalGantt/ContentView.swift` | 計算結果とタスク一覧。追加/編集シート、削除確認、未配置時間、使用枠を表示。 |
| `PersonalGantt/Views/TaskEditorView.swift` | 名前・所要時間・締切のフォーム。エラーを表示し、無効入力では保存を無効化。 |
| `PersonalGantt/Views/TaskRowView.swift` | 完了切替・編集・削除ボタン、配置済み/一部未配置/配置不能/完了の状態表示。 |
| `PersonalGanttTests/SchedulerTests.swift` | 空のテスト雛形を置き換え、仕様書の6ケースと境界条件を検証。 |
| `PersonalGanttTests/TaskManagementTests.swift` | タスク操作の再計算、入力拒否時の非変更、キャンセル、期限切れ等を検証。 |

Xcode のファイル同期グループにより、新規 Swift ファイルは自動的に既存ターゲットへ追加されます。
Phase 4 では `project.pbxproj` にCalendar使用目的説明とMacのentitlement設定を追加しました。外部依存はありません。

## アルゴリズム

1. 未完了 Task を締切の昇順に並べる。同じ締切なら Task UUID の文字列順にする。
2. AvailableSlot を開始日時順に並べ、重複・隣接枠を結合する。終了が開始以前の枠は無視する。
3. 各 Task を早い枠から配置する。終了の上限は枠の終了と締切の早い方。
4. 使用した部分だけ枠の開始を進め、残り時間を次の枠へ送る。
5. 必要時間が残る Task を `unscheduledTaskIDs` に含める。部分配置したブロックも保持する。
6. ブロックを開始日時順に返す。

締切と終了が一致する配置は許可します。時間は秒単位で扱い、分未満の境界でも所要時間を失いません。
0分の Task は配置不要、負の所要時間は配置不能として返します。Task ID は入力内で一意とします。

`ScheduledBlock.id` は仕様書の UUID 例から変更し、Task ID・開始・終了の組を使っています。
再計算するたびにランダムな UUID が変わることを避け、同じ入力では ID と結果全体が一致します。
モデルと Scheduler は `nonisolated` / `Sendable` とし、アプリの MainActor 設定から純粋ロジックを独立させています。

計算量は Task 数を T、Slot 数を S として O(T log T + S log S + T×S)、出力ソートはブロック数 B に対して O(B log B) です。

## 動作確認

以下は Phase 1–3 のサンプル空き枠での結果です。Phase 4 のアプリではこの3日枠を利用せず、活動時間とCalendarから枠を生成します。

| 日 | 時間 | Task |
| --- | --- | --- |
| 1日目 | 18:00–19:30 | 卒論 90分 |
| 1日目 | 19:30–20:00 | Kaggle 30分 |
| 2日目 | 18:00–19:00 | Kaggle 60分 |
| 3日目 | 18:00–20:00 | AtCoder 120分 |

Kaggle は必要150分のうち90分を配置し、残り60分を未配置として表示します。
3日目の枠は Kaggle の締切後のため使用しません。Phase 4 の「再計算」は取得済み空き枠を利用し、開始済みブロックを保持します。
未配置時間は、完了した作業を差し引いた残り時間ではありません。作業実績はまだ管理していません。

## テスト

2026-10-06 の Phase 4 確認結果:

- 単体テスト100ケース（既存50 + 追加50）: 全件成功。
- macOSビルド・Calendar entitlementを含む署名: 成功。
- iOS Simulatorビルド: 成功。
- Mac実画面: 未許可の選択画面・反映無効化・未許可Refreshで結果を保持する表示を確認。
- OS権限付与と個人Calendar取得、iOS実機操作は未検証。統合テストはメモリ内EKEventと差し替えProviderを利用。

以下は Phase 3 の検証記録です:

- macOS 向けビルドおよび単体テスト50ケース（既存23 + 追加27）: 成功。
- iOS Simulator 向けビルド（iPhone / iPad 共通ターゲット）: 成功。
- Mac アプリを実際に起動し、追加、3項目の編集、完了/未完了、削除、未配置表示と入力検証を確認。
- `git diff --check`: 成功。

単体テストは Swift Testing を使用し、33テスト関数・50ケースを用意しています。
既存の `SchedulerTests` の23ケースを維持し、`TaskManagementTests` に27ケースを追加しました。
仕様書の6ケース、MVPの210分の例、入力順を変えた決定性、重複・隣接枠、空入力、
負/0分、締切で切り詰めた枠の残り、秒境界、ViewModel の更新、JSON 往復を確認します。
さらに6種類の所要時間で、重複なし・締切超過なし・空き枠内・所要時間以下・未配置判定の整合を検証します。
追加テストでは、追加による他タスクの移動、3項目の編集、削除時の空き枠回復、完了/未完了の復元、
不正入力でデータと配置が変わらないこと、キャンセル、削除済みタスクの編集、期限切れの未配置を確認します。

Phase 3 の UI・データフロー・入力仕様・次の検討事項は [Phase 3 実装報告](docs/Phase3.md) を参照してください。

Xcode の Test（⌘U）または次のコマンドで単体テストを実行できます。

```sh
xcodebuild -project PersonalGantt.xcodeproj \
  -scheme PersonalGantt -destination 'platform=macOS' \
  -derivedDataPath /tmp/PersonalGantt-derived \
  -only-testing:PersonalGanttTests test CODE_SIGNING_ALLOWED=NO
```

iPhone / iPad 向けのコンパイル確認:

```sh
xcodebuild -project PersonalGantt.xcodeproj \
  -scheme PersonalGantt -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/PersonalGantt-ios-derived \
  build CODE_SIGNING_ALLOWED=NO
```

## Phase 4 の制約と次の作業

EventKit → FixedEvent → AvailabilityService → AvailableSlot → Schedulerの分離を維持しています。
今日を1日目とする14日間（例: 10月6日〜19日）が対象です。設定はActivitySettingsから注入できます。
過去/進行中ブロックは保持し、未来の未完了作業を再生成します。保持する計画時間は作業実績ではありません。
固定予定が進行中の作業に重なる場合は保持して警告します。自動監視は行わず、手動Refreshを利用します。

Google Calendar API、Reminders、SwiftData、CloudKit、Siri、本格的Gantt UI、completedMinutes、priority、食事/休憩自動生成は未実装です。
実機・visionOSは未検証。OS標準Calendarに同期済みのGoogle CalendarはEventKit経由で扱います。
次の自動再配置では計画履歴と実績の分離、通知の集約、古い取得結果の排除、進行中競合の操作方針を決める必要があります。
