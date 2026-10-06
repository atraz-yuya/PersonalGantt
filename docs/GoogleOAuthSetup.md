# Google Calendar OAuth設定（Phase 4.5）

PersonalGanttはGoogle Calendar APIへ直接接続します。Apple Calendarへの同期は不要です。
Calendarに予定を書き込む処理はありません。Mac/iOSとも、iOSタイプのOAuthクライアントを使います。

## Google Cloud側

1. [Google Cloud Console](https://console.cloud.google.com/)で個人利用用プロジェクトを作成または選択する。
2. APIとサービス → ライブラリ → Google Calendar APIを有効にする。
3. Google Auth PlatformのBrandingでアプリ名PersonalGanttと連絡先を設定する。
4. Audienceを個人Googleアカウントで使えるExternalにし、Testingのテストユーザーへ自分のGoogleアカウントを追加する。
5. Data Accessへ以下の2つの読み取り専用スコープを追加する。

   - https://www.googleapis.com/auth/calendar.calendarlist.readonly
   - https://www.googleapis.com/auth/calendar.events.readonly

6. Clients → Create client → Application typeをiOSにする。
7. Bundle IDをcom.atraz.PersonalGanttにする。Macでもこのクライアント種別を使う。
8. 発行されたClient IDを控える。Client Secret、Access Token、Refresh Tokenをチャットやソースへ貼らない。

この構成は公開ネイティブクライアントでClient Secretを使用しません。Web application/Service account/Desktopタイプの設定とは異なります。
Testing状態では期限やGoogle側ポリシーによって再ログインが必要になる場合があります。外部配布時は公開・検証要件を別途確認してください。
参照: [GoogleのiOS/macOS設定](https://developers.google.com/identity/sign-in/ios/start-integrating)、[ネイティブOAuth](https://developers.google.com/identity/protocols/oauth2/native-app)。

## XcodeとPersonalGantt

1. MacのSigning & CapabilitiesでAppleの開発Teamを指定し、Keychain Sharingを有効にする。アクセスグループは既定のアプリ用グループ（TeamのAppIdentifierPrefix + com.atraz.PersonalGantt）。
   Data Protection Keychainには、このアクセスグループを許可する署名・Provisioning Profileが必要です。adhoc署名のコンパイル確認だけでは実際のToken保存を確認できません。
2. iOS実機では同じBundle IDを使い、実機用の署名を設定する。
3. アプリの「使用するカレンダーを選択」を開く。
4. OAuthクライアントIDだけを入力し「クライアントIDを保存」を押す。
5. 「Googleにログイン」でAppleの認証セッションを開き、自分のGoogleアカウントで同意する。
6. Calendarを複数選択し「反映」を押す。

クライアントIDは公開識別子としてUserDefaultsへ保存します。Tokenはこの端末のKeychainにだけ保存します。
選択CalendarのIDもUserDefaultsへ保存し、次回起動時に復元します。実予定の内容とTaskは保存しません。
認証はASWebAuthenticationSession、Authorization Code、PKCE S256、ランダムstateの検証を使用します。
コールバックは逆順Client IDスキームの /oauthredirect を認証セッションが受け取ります。
「この端末からログアウト」はKeychainの認証情報と保存したCalendar選択を削除します。Google側の許可取り消しは[Googleアカウントの接続管理](https://myaccount.google.com/connections)で行えます。
「Google接続を確認」は同じ読み取り権限のままTokenを更新し、Calendarを再取得します。Tokenは画面やログへ表示しません。

## 実Google Calendarの確認

1. Google Calendarに、未来の平日10:00–12:00「授業」、14:00–16:00「バイト」を用意する。アプリからは作成しない。
2. そのCalendarを選択してRefreshする。他の選択Calendarに予定がない日を使う。
3. 対象日の空き枠が08:00–10:00、12:00–14:00、16:00–23:00になることを確認する。
4. 所要時間・締切を指定したTaskを追加し、授業/バイトと重ならないことを確認する。
5. Google側で予定を変更し、Refreshで空き枠と未来の配置が変わることを確認する。
6. アプリを終了・起動し、追加ログインなしで認証とCalendar選択が復元されることを確認する。Taskと計画はサンプルへ戻る。
7. 「使用するカレンダーを選択」→「Google接続を確認」で認証更新と再取得が成功することを確認する。

起動・前面復帰・前面中の日付切替でも取得します。バックグラウンドの常時監視はありません。

今日を使う場合、すでに過ぎた活動時間は表示対象から切り詰めます。開始済みの作業は移動しません。
実データをGitへ入れないでください。スクリーンショット等を保存するなら無視対象のPrivateVerification/やリポジトリ外を使います。
実アカウントが未設定の段階では、APIの合成応答による検証結果と実アカウントの確認結果を区別します。
