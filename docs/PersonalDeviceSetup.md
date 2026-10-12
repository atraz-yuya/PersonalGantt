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
期限切れの場合は、同じTeam・Bundle IdentifierのままXcodeから再ビルド・再インストールします。
アプリを先に削除する必要はありません。更新や削除の前にはバックアップを書き出してください。
[Apple公式のPersonal Teamの制約](https://developer.apple.com/help/account/basics/about-your-developer-account)を参照してください。

## 確認済み範囲

- Mac：現在のソースでApple Development署名付きビルド成功、strict署名検証成功。再起動後のGoogle/Reminders取得・端末内保存・バックアップメニューを確認。
- 単体テスト：既存を含む303ケース成功。別端末のデータ照合・保留・巻き戻しは合成データで検証済み。
- iOS：Simulator向けコンパイル成功。実機用署名・インストール・実機間のファイル往復は未確認。

この手順を作成した時点では、Macから認識できる物理iPhone/iPadは未接続です。実機確認後にこの欄を更新します。
