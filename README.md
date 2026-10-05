# PersonalGantt

タスク名・所要時間・締切から、空き時間へ作業を自動配置する SwiftUI アプリです。
開発仕様書 v1 の初回実装範囲（Phase 1–2 / Scheduler MVP）を実装しています。

## 起動

1. `PersonalGantt.xcodeproj` を Xcode で開く。
2. Scheme を `PersonalGantt`、実行先を `My Mac` または iPhone / iPad Simulator にする。
3. Run（⌘R）を実行する。

既存プロジェクトの対応 OS 設定は macOS / iOS / visionOS 27.0 のままです。
現段階の画面はサンプルデータを表示します。タスクの入力フォームやカレンダー連携は後続の段階です。

## 実装内容と変更ファイル

| ファイル | 役割・変更理由 |
| --- | --- |
| `PersonalGantt/Models/Task.swift` | 作業要件を UI から分離。UUID、名前、完了状態、所要時間、締切を保持。Codable / Equatable 対応。 |
| `PersonalGantt/Models/ScheduledBlock.swift` | Task と別に配置結果を表現。Codable / Equatable 対応。 |
| `PersonalGantt/Models/AvailableSlot.swift` | 空き時間を独立したモデルで表現。 |
| `PersonalGantt/Scheduling/SchedulingResult.swift` | 配置済みブロックと、必要時間を配置しきれない Task ID を返す。 |
| `PersonalGantt/Scheduling/Scheduler.swift` | Foundation のみに依存する決定的なスケジューリング処理。 |
| `PersonalGantt/Scheduling/ScheduleViewModel.swift` | 初期計算、再計算、空き枠差し替え、表示用集計。UI の body で配置計算を行わない。 |
| `PersonalGantt/Scheduling/SampleSchedule.swift` | サンプルを UI から分離。明日から3日間の枠を生成。 |
| `PersonalGantt/ContentView.swift` | 重複した仮配置処理を削除。計算結果、締切、配置済み時間、未配置時間、使用枠を表示。 |
| `PersonalGanttTests/SchedulerTests.swift` | 空のテスト雛形を置き換え、仕様書の6ケースと境界条件を検証。 |

Xcode のファイル同期グループにより、新規 Swift ファイルは自動的に既存ターゲットへ追加されます。
`project.pbxproj` の手編集や外部依存の追加は不要でした。

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

サンプルの表示結果（実行日の翌日を1日目とする）:

| 日 | 時間 | Task |
| --- | --- | --- |
| 1日目 | 18:00–19:30 | 卒論 90分 |
| 1日目 | 19:30–20:00 | Kaggle 30分 |
| 2日目 | 18:00–19:00 | Kaggle 60分 |
| 3日目 | 18:00–20:00 | AtCoder 120分 |

Kaggle は必要150分のうち90分を配置し、残り60分を未配置として表示します。
3日目の枠は Kaggle の締切後のため使用しません。「再計算」は同じ入力から結果を再生成します。
未配置時間は、完了した作業を差し引いた残り時間ではありません。作業実績はまだ管理していません。

## テスト

2026-10-06 の確認結果:

- macOS 向けビルドおよび単体テスト23ケース: 成功。
- iOS Simulator 向けビルド（iPhone / iPad 共通ターゲット）: 成功。
- Mac アプリを実際に起動し、ブロック一覧・未配置60分の表示・「再計算」操作を確認。
- `git diff --check`: 成功。

単体テストは Swift Testing を使用し、18テスト関数・23ケースを用意しています。
仕様書の6ケース、MVPの210分の例、入力順を変えた決定性、重複・隣接枠、空入力、
負/0分、締切で切り詰めた枠の残り、秒境界、ViewModel の更新、JSON 往復を確認します。
さらに6種類の所要時間で、重複なし・締切超過なし・空き枠内・所要時間以下・未配置判定の整合を検証します。

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

## 未実装・制約と次の作業

- タスク追加・編集・削除・完了切替、優先度、分割禁止、最小作業時間。
- 固定予定を引いて AvailableSlot を生成する AvailabilityService と EventKit 連携。
- Calendar の変更検知による自動再計算、Reminders 連携。
- 過去ブロックの保持、進行中ブロック、作業実績の差し引き。現 API は渡された全未完了 Task を再配置します。
- Today / 日別 Timeline / Gantt の専用画面。
- 永続化とデバイス間同期。モデルの Codable 対応のみで、現在は保存しません。
- 実機・visionOS の動作確認。

次は Phase 3 のタスク管理 UI と、入力変更時の再計算を実装するのが適切です。
永続化を追加する段階では仕様書の第一候補である SwiftData を検討し、保存層から今回の純粋モデルへ変換します。
作業実績と過去ブロックの保持は、Calendar の自動再配置を実運用する前に設計・実装します。
