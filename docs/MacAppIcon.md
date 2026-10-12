# macOS App Icon 修正・検証（2026-10-12）

## 1. 調査結果と原因の範囲

既存の `AppIcon.appiconset` は、iOS用の1024px画像とmac idiomの10枠を含んでいました。変更前のmacOSビルドにも `AppIcon.icns` と `CFBundleIconName=AppIcon` があり、icnsを展開すると正しいPersonalGantt画像でした。画像欠落・mac idiomの未設定ではありません。

古いBundle参照・起動登録・アイコンキャッシュが残っていた可能性があります。以前はビルド生成物内の実行ファイルから直接起動していた経路もありました。今回はmacOSのアイコン参照を専用assetへ分離し、ビルド出力をクリーンして旧アプリを終了、Finderから正式な `.app` Bundleを起動しました。この変更と再起動後、Dock・アプリスイッチャー・Finderの正常表示を確認しています。キャッシュと起動経路のどちらが単独の原因だったかは断定していません。

## 2. 変更したファイル

- `PersonalGantt/Assets.xcassets/AppIconMac.appiconset/Contents.json`
- 同フォルダの `AppIconMac-{16,32,64,128,256,512,1024}.png`（7枚）
- `PersonalGantt.xcodeproj/project.pbxproj`（Debug/ReleaseのmacOS専用App Icon設定のみ）
- この検証記録

アプリ本体のSwiftコード、同期・Keychain・OAuth・Scheduler・Task・Routine・Calendar・Reminders・Siri・entitlementsは変更していません。

## 3. iOS側の保持

既存 `AppIcon.appiconset` の画像7枚とContents.jsonは一切変更せず、変更前後のSHA-256一致を確認しました。iOSの実効設定と生成Info.plistは引き続き `AppIcon` です。Bundle ID `com.atraz.PersonalGantt`、Signing Team、署名設定、entitlementsも変更していません。iPhoneへの再インストールは行っていません。

作業開始時からあったInfo.plistの整形変更とSigning Team設定はそのまま保持し、今回のコミットには含めていません。

## 4. macOS assetの構成

既存の最高解像度 `AppIcon-1024.png` を唯一の元画像として使用しました。1024px版はバイト単位で同じ画像です。他のサイズはsipsで縮小し、引き伸ばしは行っていません。

| 論理サイズ | 1xの画素数 | 2xの画素数 |
|---|---:|---:|
| 16×16 | 16×16 | 32×32 |
| 32×32 | 32×32 | 64×64 |
| 128×128 | 128×128 | 256×256 |
| 256×256 | 256×256 | 512×512 |
| 512×512 | 512×512 | 1024×1024 |

Contents.jsonの全10枠は `idiom=mac`、適切なsize/scale/filenameを設定しています。実際のPNG寸法も全枠で照合しました。

## 5. Build Settings

Debug/Releaseの両方で、従来の既定値を保持し、macOS SDKだけ上書きします。

```text
ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon
ASSETCATALOG_COMPILER_APPICON_NAME[sdk=macosx*] = AppIconMac
```

`xcodebuild -showBuildSettings` でmacOS=AppIconMac、iOS=AppIconを確認しました。

## 6. macOSビルド・生成物・表示確認

署名済みmacOSビルドで `xcodebuild clean build` が成功しました。対象プロジェクトのビルド出力だけをクリーンし、データコンテナ・保存済み作業・アプリ設定は削除していません。

- actoolは `--app-icon AppIconMac` で成功。アイコン関連warning/errorなし。
- 生成Info.plistの `CFBundleIconFile` / `CFBundleIconName` は両方 `AppIconMac`。
- `Contents/Resources/AppIconMac.icns` を確認。
- Assets.carをassetutilで調べ、AppIconMacの10枠すべて（16〜1024px、各scale）を確認。未使用assetではありません。
- Finderの「情報を見る」の小アイコンと大きいプレビューで正しいデザインを視覚確認。
- 起動中アプリのBundle URLが最新ビルドであることと、NSRunningApplication.iconが正しい1024px画像を返すことを確認。
- MacのユーザーがDock、⌘Tabのアプリスイッチャーの両方で正常表示を確認。

ビルド生成物:

`/tmp/PersonalGantt-dtls-mac/Build/Products/Debug/PersonalGantt.app`

## 7. iOSビルド

iPhone 15向けの署名済みiOSビルドが成功しました。actoolは従来どおり `--app-icon AppIcon` です。生成Info.plistのiPhone/iPad両方のprimary icon名も `AppIcon` のままです。アイコン関連warning/errorはありません。

## 8. Macで今後行う操作

今回のクリーンビルド、旧アプリ終了、最新版のBundle起動、Dock/アプリスイッチャー/Finder確認は実施済みです。

今後はXcodeで実行先をMy MacにしてRunするか、最新の `PersonalGantt.app` 自体をFinderから開いてください。`Contents/MacOS/PersonalGantt` という実行ファイルを直接起動する経路は避けます。Dockの固定項目が別の古いコピーを指している場合は、新しいBundleで起動し直してから固定し直してください。アプリのデータコンテナや設定の初期化は不要です。
