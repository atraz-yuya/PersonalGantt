# Reminder補助メタデータの端末間同期（2026-10-13）

ブランチ: `codex/reminder-metadata-sync`。

## 原因と修正

Reminders由来Taskを通常TaskのSyncRecordから除外する既存方針は正しい。一方、所要時間・補助締切・除外は各端末のReminderMetadata.jsonだけに保存され、対応する同期Entityがなかった。そのためiPhoneで入力を済ませても、MacのEventKit項目にはPersonalGanttの設定が付かず、入力待ちに残っていた。

新しい `SyncKind.reminderMetadata` / `ReminderSyncMetadata` を追加した。設定変更を既存SyncStateへrevision付きで保存し、受信側はローカルEventKit項目に設定だけを投影する。Native Reminderが取得済みなら直ちに入力待ち・登録済みTaskを更新して再計算する。未取得なら同期設定を保留し、取得後に適用する。

| wireフィールド | 意味 |
|---|---|
| externalIdentifier | EventKitのcalendarItemExternalIdentifier |
| occurrenceKey | 既存の繰り返し発生キー。非繰り返しはnil |
| estimatedMinutes | PersonalGanttの所要時間 |
| supplementalDeadline | PersonalGanttの補助締切（既存deadlineOverride） |
| isExcluded | PersonalGanttの配置対象外状態 |

登録済みという独立したフラグは送らない。ローカルのnativeタイトル・native締切と、この所要時間・補助締切・除外から既存Mapperで判定する。タイトル、OS側の締切・完了状態、ローカルReminder ID、リストID、Task UUID、選択リスト、権限はEntityに含めない。validatorはこれらのフィールドが混入したpayloadを拒否する。Apple Reminderの作成・更新を受信処理から呼ばない。OS/iCloudがReminder本体の正であり、native締切があれば補助締切より優先する。

## 照合キーと重複防止

Entity IDは `SHA256(JSON([externalIdentifier, occurrenceKey]))` の64桁小文字hex。nilと文字列を区別し、区切り文字の連結による衝突を避ける。取得済みの選択リストに同じ組が1件だけ存在する場合に適用する。外部ID未取得、繰り返しキー不明、重複・曖昧な外部IDではタイトル・ローカルIDから推測せず、端末内設定または保留として扱う。

受信先の既存ReminderTaskMetadata.taskIDを保持し、Mapperが同じTaskを更新する。Reminderを普通のTaskとして二重に送信したり、受信だけを理由に独立したTaskを生成したりしない。既存WorkSessionの外部ID/occurrence対応、履歴UUID、開始済み枠の保護は維持する。

[Appleのexternal identifier仕様](https://developer.apple.com/documentation/eventkit/ekcalendaritem/calendaritemexternalidentifier)では、同じサーバー項目の識別子は端末間で利用できるが、インポートや複数アカウント等で重複し得る。Exchange ReminderはiOS/macOS間で値が異なる場合がある。この方式は同じ外部IDを取得できる項目が対象であり、異なるIDをタイトル照合で補完しない。

## 保存・競合・削除

- SyncRecordと再計算結果を同じSwiftData計画checkpointへ保存し、保存成功後だけ既存transportがACKする。ローカル変更も同じ経路を使う。ローカルのNative ID→作業UUID関連付けを保存できない場合は登録を確定しない。受信後の設定はSyncStateが正であり、古いJSONキャッシュより優先する。
- 既存のLWWを共用する。revision.date、counter、device UUIDの順で比較し、補助設定Entity全体について決定的に採用する。baseRevisionとconflictKeysも共用する。独立した競合解決方式は追加しない。
- 既存の設定済みローカルmetadataだけを、未知の過去更新としてdistantPastで初回移行する。入力待ちの空設定は送らない。既存revision/tombstoneがあるキーを古いキャッシュで再作成しない。明示したバックアップ復元は新しい編集として記録するが、ファイル内の曖昧な関連付けはportableな編集にしない。
- tombstoneを受信した場合は所要時間・補助締切・除外をリセットし、native Reminder本体は削除しない。
- Native Reminderが削除・未取得になった場合、対応Taskと入力待ち行はnative snapshotから消える。対応先のないmetadataは保持して非適用とする。選択リスト変更・権限・iCloud反映の遅延・繰り返し更新を削除と誤認し、相手の設定をtombstoneで消すことを避ける。Native項目が再び同じキーで取得できれば、元のローカル作業UUIDで適用する。孤立metadataの期限付き物理削除は行わない。

## 互換性

ローカルprotocolVersion/schemaVersionを2へ更新した。旧アプリが知らないSyncKindを送信する前に、既存HELLO/discoveryの互換性チェックで停止する。Mac/iPhoneを両方更新する。Keychain identity、証明書検証、既存信頼情報、READY前の送信禁止、TCP/TLSとMPCの経路選択・再接続は変更していない。再ペアリングは不要。

## 検証

全610件成功（466個のテスト関数、引数展開込み610）、失敗0、skip0。既存586件と今回追加24件を含む。最終結果: `/tmp/PersonalGantt-reminder-sync-verified-tests.xcresult`、ログ: `/tmp/PersonalGantt-reminder-sync-verified-tests.log`。

| 試験 | 自動テスト |
|---|---|
| iPhone所要時間30分→Mac・入力待ち解除 | 成功。異なるnative ID/list ID/titleで照合、受信先UUID・native title保持 |
| Mac変更→iPhone | 成功。設定変更と実績の反映、同一Task UUID・Task件数保持 |
| supplementalDeadline | 成功。反映とnative締切優先、OSデータを送らないこと |
| exclusion / 再設定 | 成功。双方向除外・配置復帰 |
| 再起動後の保持 | 成功。JSON関連付けキャッシュ未更新でも復元、実SwiftData/JSONファイルで再読込 |
| Task変換済みの重複防止 | 成功。既存UUID、Task件数、WorkSession計上を保持 |
| Native削除・孤立metadata | 成功。Task消失・設定の非適用、相手の設定保持、再取得で同じUUID |
| tombstone・競合 | 成功。古いキャッシュ非復活、LWW収束・競合記録 |
| 未取得/曖昧ID/異なるoccurrence | 成功。保留・誤適用防止 |
| 入力待ち画面の即時更新 | 成功。未登録Reminderの除外受信をObservationで検証 |
| 保存失敗 | 成功。登録未確定、受信rollback、保存再試行 |
| バックアップ復元 | 成功。同期済み古い設定への明示復元、曖昧なファイル設定の移送防止 |
| Task / Routine / WorkSession既存同期 | 既存回帰テスト成功 |

署名済みmacOS/iOS実機向けbuildは成功。アイコン、Bundle ID、署名Team、entitlements、OAuth、Keychain、EventKit providerへの変更なし。MPC非推奨等の既存SDK警告は残る。

## 実機確認

MacBook Neo / iPhone 15（OS 27.0.1）、通常アプリ・既存のペアリング情報で確認。iPhoneへ署名済み最新版をインストールし、Macも正式な.appから起動した。診断専用アプリではない。

| 操作 | 結果と証拠 |
|---|---|
| iPhoneでテストReminderの所要時間30分を設定 | MacのTaskに30分・Apple Reminders連携として1件表示。入力待ちから消失をMac UIで確認 |
| Macで90分へ変更して「今すぐ同期」1回 | iPhoneの90分への反映をユーザー確認。Macの90分表示もUI確認 |
| Apple側の日付・時刻を外し、iPhoneで補助締切を「明日」に設定 | MacのReminders画面は「Reminders側の締切は未設定」のまま配置対象。Taskは90分・10月14日23:59として1件表示 |
| 両アプリを最終版へ更新・再起動 | 設定を保持して再接続。従来の同じfingerprintをtrustedFingerprintとして確認し、HELLO/READY/ACK・同期成功。再ペアリングなし |
| USBを外し、MacをiPhoneのテザリングへ接続。Macで補助締切を10月15日23:00に変更し「今すぐ同期」1回 | iPhoneへの反映をユーザー確認。Macの通信ログにen0:wifi、相互TLSとREADY/ACK・同期成功 |
| Macで「配置対象から外す」・同期1回 | iPhoneのTaskと入力待ちから消え、Apple Reminder本体が残ることをユーザー確認。Mac Task一覧からも消失を確認 |
| iPhoneから除外を解除して再設定・同期1回 | 両端末に1件だけ復帰をユーザー確認。Mac UIで90分・10月15日23:00の1件を確認 |
| Apple側のテストReminderを完了 | Macで完了済みとして取得。OS側の完了はEventKit/iCloudから反映されることを確認 |
| MacのApple Remindersで、検索結果のテスト項目1件だけを「削除」 | 完了済みを含む検索結果が0件、最近削除した項目が9→10件。復元可能な通常削除であり、完全削除は行わない |
| Native削除後、MacのPersonalGanttを再起動・前面へ戻し再取得 | 完了済みも含むTask一覧から消失をユーザー確認し、Mac UIでも存在しないことを確認。補助設定だけからTaskが生成されない |

Mac UI操作ツールの背景起動中はEventKit再取得が前面復帰まで待つため、最後はユーザーがDockから前面に出して「Remindersを更新」を操作した。Native本体の削除反映と補助metadataの通信を同一経路として扱わない。通信ログだけからReminder設定の内容を判定せず、Mac UI観測とiPhoneのユーザー確認を区別する。通常Wi-Fiは利用できないため未検証。iPhoneのbackground中やUSB/経路の切替中にはtimeoutが出ることがある。foreground・接続成立時の反映を確認している。

[実機の匿名化通信ログ](verification/ReminderMetadataSync-2026-10-13.log)。

## 変更ファイル

`Sync/ReminderSyncMetadata.swift`、`Sync/SyncState.swift`、`Sync/SyncPayloadValidator.swift`、`Sync/LocalSyncProtocol.swift`、`Scheduling/ReminderSyncViewModel.swift`、`Scheduling/ScheduleViewModel.swift`、`PersonalGanttTests/ReminderMetadataSyncTests.swift`、`Views/ReminderSelectionView.swift`（同期対象の説明）、本書、`LocalDeviceSync.md`、`verification/ReminderMetadataSync-2026-10-13.log`（実機通常アプリの通信ログを匿名化）。
