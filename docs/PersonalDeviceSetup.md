# iPhone・iPadへの個人用インストールとファイル受け渡し

最新UIではメニュー/サイドバーから設定を開き、連携とバックアップを操作します。[UI再設計後の実機確認手順](UINavigation.md)を参照してください。

2026-10-12追記: Final Integration後も無料Personal Teamのローカル利用とJSON受け渡しを維持しています。CloudKitは現署名では無効です。Google書き戻しは任意で初期OFF、ONの場合だけ追加scope同意が必要です。[新機能13項目の実機確認と追加設定](FinalIntegration.md)を併せて参照してください。

2026-10-07。無料のApple Account / Personal Teamを使い、Xcodeから自分の実機へインストールします。
有料Developer Programへの加入やApp Storeへの公開は行いません。

## 最初に接続する

1. iPhoneまたはiPadをMacへケーブルで接続する。
   - 両方がUSB-CならUSB-C ↔ USB-C。
   - 端末がLightningならMac側の端子に合ったUSB ↔ Lightning。
   - 充電専用ではなく、データ通信にも対応したケーブルを使う。
2. 端末のロックを解除する。
3. 端末に「このコンピュータを信頼しますか？」が出たら「信頼」を選び、端末側でパスコードを入力する。
4. 「設定」→「一般」→「情報」でOSバージョンを確認する。

**現在のプロジェクトの最低対応OSはiOS / iPadOS 27.0です。**
それより古いOSではこの設定のままインストールできません。実機のOSを確認したうえで、対応OSを下げるためのAPI確認とビルド検証を行う必要があります。
インストールのために端末のOSを先に更新する必要はありません。

## Xcodeで実機を選ぶ

1. `PersonalGantt.xcodeproj` をXcodeで開く。
2. 上部のSchemeを `PersonalGantt` にする。
3. 上部の実行先（`My Mac` やSimulatorの名前が表示される場所）を押し、接続した実機を選ぶ。
4. 左の最上段にある青いプロジェクトアイコン → TARGETSの `PersonalGantt` → `Signing & Capabilities` を開く。
5. `Automatically manage signing` を有効にし、Teamで自分の `Personal Team` を選ぶ。既存のTeamが正しく選ばれていれば変更しない。
6. Bundle Identifierは `com.atraz.PersonalGantt` のままにする。Google OAuthのBundle IDと一致させる。
7. 実機にDeveloper Modeが必要と表示されたら、端末側の「設定」→「プライバシーとセキュリティ」→「デベロッパモード」を確認し、ご自身で有効化・再起動・確認を行う。
8. 左上の三角形 ▶︎ または `⌘R` でビルド・インストールする。
9. 「信頼されていないデベロッパ」と表示された場合は、端末の「設定」→「一般」→「VPNとデバイス管理」で、ご自身の開発用アカウントを確認する。

Apple Account、端末パスコード、Macのキーチェーンパスワードは本人が端末上で入力します。チャットへ送る必要はありません。
「No devices」「No profiles」が出た場合は、実機の接続・ロック解除・信頼・実行先の選択を先に確認します。
署名やプロファイルのエラーは、その表示内容を確認して対処します。CloudKitやiCloudのCapabilityは追加しません。

接続・実行先・署名については[Apple公式の実機実行手順](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices)、
Developer Modeについては[Apple公式の設定手順](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)を参照してください。

## アプリで連携を設定する

1. 「連携」→「使用するカレンダーを選択」を開く。
2. Macで使用したGoogle OAuth Client IDを保存し、その端末でGoogleへログインする。
3. 使用Calendarを選び「反映」を押す。
4. 「連携」→「使用するRemindersを選択」を開き、Remindersのアクセスを許可する。
5. 使用リストを選び「反映」を押す。同じReminderを使う場合はApple側でも同じリストが利用できることを確認する。

TokenとOSアクセス許可はバックアップに含まれません。各端末で設定します。
詳しくは[Google OAuth設定](GoogleOAuthSetup.md)を参照してください。

## Mac → 実機 → Macの確認

1. 最初に両端末の現在の状態をそれぞれバックアップとして書き出す。
2. Macから採用する状態のJSONを書き出し、AirDropなどで自分の実機へ渡す。
3. 実機のPersonalGanttで「バックアップ」→「ファイルから読み込む」を選び、FilesのJSONを指定する。
4. 確認画面の日時・Task数・履歴数を確認してから読み込む。
5. 「再読み込み」でGoogle CalendarとRemindersを取得する。
6. 手動Taskのタイトル・所要時間・締切・完了状態と、Google予定を避けた配置を確認する。
7. Reminderの所要時間などが「対応確認待ち」なら、同じ元Reminderがあるリストを選び、再読み込みする。名前では自動照合しない。
8. 検証する場合は合成の手動Taskだけを編集し、実機から別名のJSONを書き出してMacへ戻す。
9. MacでそのJSONの日時・内容を確認して読み込み、編集内容が反映されたことを確認する。

読み込みは、選んだファイル時点の手動Task状態を採用する操作です。複数端末の同時編集を自動統合しません。
開始済みの時間枠は保持されるため、実機とMacの未来の配置が常に完全一致するとは限りません。
検証前のファイルを読み戻しても開始済みの履歴は消えません。テストTaskを追加する場合はこの点を確認してください。
通常のReminderの完了ボタンは押さず、専用の検証データだけを使います。
ファイルの内容と照合・保留・復元失敗時の動作は[バックアップ手順](BackupTransfer.md)を参照してください。

## 署名期限と更新

Personal Teamの実機用Provisioning Profileは発行から7日で期限切れになります。
[Apple公式のPersonal Teamの制約](https://developer.apple.com/help/account/basics/about-your-developer-account)を参照してください。

### コマンド1回で更新する

このMacのXcodeにご自身のApple Accountが登録され、`Config/Signing.local.xcconfig` にこれまでと同じTeam IDが設定されていることが前提です。Macをインターネットへ接続します。

1. 更新するiPhoneをUSB接続し、ロックを解除してホーム画面を表示する。作業タイマーを使っている場合は先に停止する。
2. リポジトリ直下の **`update-iphone.command` をダブルクリック**する。またはターミナルで次を実行する。

   ```sh
   ./update-iphone.command
   ```

3. 完了までロックを解除しておく。途中でロックされた場合は画面の案内に従って解除し、Enterで再確認する。
4. 必要な場合だけ「設定 → 一般 → VPNとデバイス管理」で、ご自身の開発者を信頼・検証する。アプリやプロファイルは削除しない。
5. 表示された実際の署名期限と、次回更新の目安（期限の前日）を確認する。

実行内容は、接続確認 → 対象アプリの署名キャッシュ退避 → 再ビルド → アプリ終了 → 全保存領域のバックアップ → 同じアプリへの上書きインストール → データ照合 → 起動確認です。対象はUSB接続された物理iPhone/iPadです。複数接続時は1台だけにするか、`--device` で指定します。初回インストールはXcodeで行ってください。

Xcodeは条件を満たすローカル署名を再利用するため、同じTeam・アプリIDのPersonal Team用iOSプロファイルだけをバックアップへ移し、新しい発行を要求します。証明書の失効操作は行いません。[Apple公式のプロファイル更新手順](https://developer.apple.com/help/account/provisioning-profiles/edit-download-or-delete-profiles/)に基づきます。発行結果の実際の期限を確認し、期限が延びなければその旨を表示します。残り48時間以下の署名ではインストールを止めます。無料署名の7日制限をなくす処理ではありません。

バックアップ・ログ・署名期限の記録は、Git対象外の `PrivateVerification/iPhoneUpdate/` に保存します。このフォルダには個人データ・端末識別子・署名情報が入るため、Gitへ追加したり公開したりしないでください。各回のバックアップは自動削除しません。容量が増えたら、最新の正常なバックアップを残して過去分を整理してください。

保存データ本体がない、バックアップに失敗した、署名が一致しない場合は上書きしません。更新後にデータの差が見つかった場合は起動せず停止します。エラー時は表示されたログの場所を確認し、アプリを削除せずバックアップを保持してください。

接続や期限だけを確認する場合:

```sh
./update-iphone.command --check   # 接続・ロック・既存アプリ確認。更新しない
./update-iphone.command --status  # 最後に記録した期限。接続不要
```

更新が済み、信頼確認のために起動だけ保留された場合:

```sh
./update-iphone.command --launch-only
```

`--status` は最後の更新記録です。別途Xcodeで更新した結果や端末の現在の信頼状態は取得しません。`--non-interactive` を付けると入力待ちせず、必要な操作を案内して終了します。

macOSがダウンロードしたコマンドの実行を止める場合は、内容を確認したうえでターミナルから `zsh update-iphone.command` を実行できます。Xcodeのログインやキーチェーンの確認が求められた場合は、ご本人がMac上で入力します。

## 確認済み範囲

- 2026-10-19: 署名済みmacOS版・iOS Simulatorビルド成功。今日画面改善後の全687テスト成功。
- 2026-10-20: iPhoneへ同一Team・アプリIDで上書き更新し、保存データと設定の一致、開発者の再信頼後の起動を確認。実機のアプリは削除していません。
- 同日: 更新コマンドで新しいプロファイルの発行、署名検証、更新前後のバックアップと保存データ照合、上書き更新、起動確認を実施。更新処理の13テストも成功。通常の再実行時には生成済みアプリを作り直し、増分ビルドで古い署名が残ることを防ぎます。
- MacとiPhoneのファイル受け渡し・同期の過去の確認結果は [ローカル同期の実装報告と実機手順](LocalDeviceSync.md) を参照してください。
