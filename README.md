# Mihako

Mihako は macOS 向けのファイルマネージャーです。Finder の雰囲気を保ちながら、Windows Explorer のようにパス入力、階層移動、切り取り/貼り付け、詳細表示を扱いやすくすることを目指しています。

## このプロジェクトについて

Mihako は Swift / SwiftUI / AppKit で作っている macOS アプリです。Swift Package Manager でそのままビルドできます。Xcode プロジェクトではなく `Package.swift` を中心にした構成なので、ターミナルから `swift run` や `swift build` で扱えます。

主な狙いは次の通りです。

- Finder に近い見た目と操作感にする
- パス入力や階層移動を Finder よりわかりやすくする
- 業務ファイル管理でよく使うコピー、移動、リネーム、詳細表示を読みやすくする
- NAS、SFTP、S3、クラウドストレージを左メニューから扱いやすくする
- Terminal、iTerm、IDE、エディタなどの外部ツールと連携しやすくする
- 日本語/英語の表示に対応し、通常は OS の言語設定に従う

## 主な機能

- アドレスバーへ直接パスを入力して移動
- 通常のフォルダ表示と検索結果表示の切り替え
- パンくずリストで上位階層へ移動
- 戻る、進む、上の階層へ移動
- 一覧表示、アイコン表示、カラム表示、ギャラリー表示の切り替え
- 種類、変更日、サイズによるグループ表示
- 業務ファイル向けの詳細表示
- ファイル/フォルダの新規作成、名前変更、複製、削除
- Command+C / Command+X / Command+V によるコピー、切り取り、貼り付け
- 右クリックメニューからコピー、切り取り、貼り付け、パスコピー、Finder 表示
- `.app` などのパッケージを右クリックして内容を表示
- 右クリックメニューから ZIP / TAR / TAR.GZ / TAR.BZ2 / TAR.XZ 形式で圧縮、同じ形式を解凍
- サイドバーの Favorites へフォルダをドラッグ&ドロップで追加
- Locations に Google Drive、OneDrive、SharePoint、マウント済みボリューム、NAS などを表示
- SMB、SFTP、S3 接続
- SFTP 上のフォルダを Terminal / iTerm で開く
- 選択フォルダを WebStorm、PyCharm、VSCode などの外部アプリで開く
- 外部ツールボタンの追加、変更、削除、並び替え
- 外部ツールボタンに起動先アプリのアイコン、または任意の SF Symbol を表示
- 日本語/英語の表示切り替え
- システム、ライト、ダークの外観切り替え

## 必要なもの

- macOS 14 以降
- Xcode または Xcode Command Line Tools
- Swift Package Manager
- S3 を使う場合は AWS CLI

## インストール方法

### 1. リポジトリを取得する

GitHub から clone します。

```sh
git clone git@github.com:MasakiFUJISAWA/mihako.git
cd mihako
```

すでにリポジトリがある場合は、最新版に更新します。

```sh
git pull
```

### 2. 必要な開発ツールを入れる

Xcode または Xcode Command Line Tools が必要です。未インストールの場合は次を実行します。

```sh
xcode-select --install
```

確認するには次です。

```sh
swift --version
```

### 3. app ファイルを作る

次のコマンドで release build と `.app` 作成をまとめて行います。

```sh
scripts/package-app.sh
```

作成される場所:

```text
.build/release/Mihako.app
```

起動確認:

```sh
open .build/release/Mihako.app
```

Applications フォルダへ入れる場合:

```sh
cp -R .build/release/Mihako.app /Applications/
```

これで Launchpad や Finder の Applications から `Mihako` を起動できます。

### 4. 更新するとき

リポジトリを更新して、もう一度 app を作り直します。

```sh
git pull
scripts/package-app.sh
cp -R .build/release/Mihako.app /Applications/
```

## 基本的な使い方

画面は大きく左のサイドバーと右のファイル一覧に分かれています。

左のサイドバーには `Favorites` と `Locations` が表示されます。よく使うフォルダは `Favorites` にドラッグ&ドロップで追加できます。追加した項目は右クリックメニューから削除できます。`Locations` には Mac 本体、外部ドライブ、クラウドストレージ、NAS、SFTP、S3 などの接続先が表示されます。

右側の上部にはアドレスバーがあります。ここへ `/Users/yourname/Documents` のようなローカルパス、`sftp://...`、`s3://...` のようなリモートパスを入力して移動できます。

アドレスバー行の左端には、通常のフォルダ表示と検索結果表示を切り替えるボタンがあります。検索結果表示に切り替えると、アドレスバー行は検索欄と検索ボタンになり、パンくずリストは隠れます。ローカルフォルダでは現在表示しているフォルダ配下を再帰検索し、SFTP/S3 では現在表示中の一覧から名前で絞り込みます。

ファイル一覧の上には操作ボタンがあります。

- 表示形式の切り替え: 一覧、アイコン、カラム、ギャラリー
- グループ表示: なし、種類、変更日、サイズ
- フォルダ作成
- ファイル作成
- 削除
- AirDrop
- Terminal / iTerm で開く
- WebStorm / PyCharm / VSCode など登録済み外部ツールで開く
- 外部ツール設定を開く

ファイルやフォルダはクリックで選択できます。Shift+クリックで範囲選択、Command+クリックで追加選択または選択解除ができます。

## 外部ツール設定

ファイル一覧の上部にある歯車ボタン、またはメニューバーの `External Tools...` から外部ツールを設定できます。

初期状態では次のツールが登録されています。

- Terminal: 現在表示しているフォルダを Terminal で開く
- iTerm: 現在表示しているフォルダを iTerm で開く
- WebStorm: 選択中のフォルダを WebStorm で開く
- PyCharm: 選択中のフォルダを PyCharm で開く
- VSCode: 選択中のフォルダを VSCode で開く

設定画面では、ツールの追加、削除、名前変更、並び替え、アイコン変更ができます。

`Tool Type` は次から選びます。

- `Terminal`: macOS 標準の Terminal で開く
- `iTerm`: iTerm で開く
- `Application`: 指定したアプリでフォルダを開く

`Open Target` は次から選びます。

- `Current Folder`: 現在表示しているフォルダを開く
- `Selected Folder`: ファイル一覧で選択しているフォルダを開く

`Icon` は次から選びます。

- `Application Icon`: 起動先アプリのアイコンを表示する
- `SF Symbol`: `terminal`、`hammer`、`chevron.left.forwardslash.chevron.right` などの SF Symbol 名を指定して表示する

`Application` タイプでは `Choose Application...` から `.app` を選ぶのが簡単です。選択すると、アプリのパスと Bundle ID が自動で入ります。アプリが移動された場合に備えて、Bundle ID が分かるアプリは Bundle ID でも探します。

外部ツール設定は UserDefaults に保存されます。壊れた場合や初期状態に戻したい場合は、設定画面の `Restore Defaults` を押してください。

## キーボードショートカット

- `Command+C`: コピー
- `Command+X`: 切り取り
- `Command+V`: 貼り付け
- `Command+A`: 全選択
- `Command+N`: 新しいウィンドウ
- `Command+Shift+N`: 新規フォルダ
- `Command+Delete`: 削除
- `Return`: 開く
- `Command+Return`: 名前変更

アドレスバーや Connect Server ダイアログの入力欄では、`Command+A`、`Command+C`、`Command+X`、`Command+V` はテキスト編集として動作します。

## 言語設定

Mihako は日本語と英語に対応しています。初期状態は `System` で、macOS の優先言語が日本語なら日本語、それ以外なら英語で表示します。

手動で固定したい場合は、メニューバーの `Language` から次を選べます。

- `Use System Language`: OS の言語設定に従う
- `English`: 英語で表示する
- `Japanese`: 日本語で表示する

翻訳ファイルは `Sources/Mihako/Resources/en.lproj/Localizable.strings` と `Sources/Mihako/Resources/ja.lproj/Localizable.strings` で管理しています。現時点ではアプリ本体に同梱して管理し、別パッケージには分けていません。

## 外観設定

Mihako はライトモードとダークモードに対応しています。メニューバーの `Appearance` から次を選べます。

- `Use System Appearance`: macOS の外観設定に従う
- `Light`: ライトモードで固定する
- `Dark`: ダークモードで固定する

macOS の Appearance が `Auto` の場合、Mihako 側を `Use System Appearance` にしておくと、macOS と同じく昼はライト、夜はダークに切り替わります。

## 外部からMihakoを開く

Mihako は外部からフォルダを開くための入口を用意しています。配布用 app を作ると、次のURLスキームとフォルダ文書タイプがInfo.plistに登録されます。

- URLスキーム: `mihako://`
- フォルダタイプ: `public.folder` / `public.directory`

例えばターミナルからDownloadsをMihakoで開く場合は次です。

```sh
open "mihako://open?path=$HOME/Downloads"
```

ローカルフォルダをMihakoアプリへ直接渡すこともできます。

```sh
open -a /Applications/Mihako.app "$HOME/Downloads"
```

SFTPやS3のURLを渡す場合は、`url=` にURLを指定します。

```sh
open "mihako://open?url=sftp://dm-backend-ec2/opt/"
open "mihako://open?url=s3://bucket-name/prefix/"
```

### Dock用Downloadsランチャー

FinderのDockスタックそのものを完全に置き換えることはmacOSの制約上できませんが、MihakoでDownloadsを開く小さなランチャーappを作ってDockに置くことはできます。

```sh
scripts/create-open-in-mihako-launcher.sh
open ".build/Mihako Downloads.app"
```

作られた `.build/Mihako Downloads.app` をDockへドラッグしておくと、DockからMihakoでDownloadsを開けます。別のフォルダ用に作る場合は、第一引数にフォルダパス、第二引数に出力先appを指定します。

```sh
scripts/create-open-in-mihako-launcher.sh "$HOME/Documents" ".build/Mihako Documents.app"
```

Dock上のMihakoアイコンを右クリックすると、次のメニューから新規ウィンドウを開けます。

- `New Window`: 通常の新規ウィンドウ
- `New Window (Desktop)`: Desktopを開く新規ウィンドウ
- `New Window (Downloads)`: Downloadsを開く新規ウィンドウ

メニューバーの `Launcher Folders...` から、Dockメニューに表示する任意のフォルダーショートカットを追加、削除、並び替えできます。

なお、macOSではFinderが特別扱いされるため、Dockの標準Downloadsスタック、Finderを明示的に呼ぶアプリ、保存/選択ダイアログなどはFinderのままです。Mihako側では、Launch ServicesやURLスキーム経由で渡ってくるフォルダを受け取れるようにしています。

## 接続機能

`Connect Server...` から外部の場所へ接続できます。

- `SMB`: NAS や Windows 共有などを macOS の標準マウント機能で接続します。
- `SFTP`: `~/.ssh/config` や SSH 鍵設定を使って接続します。
- `S3`: AWS CLI の credential/profile を使って接続します。
- `FTP`: 接続種別としては用意していますが、現時点では段階的実装中です。

接続した場所は `Locations` に保存されます。Mihako を再起動したときや `Reload Locations` を実行したときに再接続を試みます。接続できない場合も Locations には残り、失敗アイコン付きで表示されます。

## デバッグ実行

開発中にそのまま起動する場合は、リポジトリのルートで次を実行します。

```sh
swift run Mihako
```

ビルドだけ確認したい場合は次です。

```sh
swift build
```

リリース構成でビルドだけ確認したい場合は次です。

```sh
swift build -c release
```

## SFTP を使う

Connect Server で `SFTP` を選び、次のように入力します。

```text
sftp://test-server/opt/
```

`~/.ssh/config` に `Host test-server` のような設定があれば、Mihako もその設定を使います。SFTP 接続中のフォルダは Terminal / iTerm で開けます。

## S3 を使う

S3 は AWS CLI の設定を使います。まずターミナルで次が通ることを確認してください。

```sh
aws s3 ls s3://bucket-name/
```

Switch Role や複数 profile を使っている場合は、profile を指定して確認します。

```sh
aws s3 ls s3://bucket-name/ --profile share
```

Mihako の Connect Server で `S3` を選ぶと、AWS CLI の profile 一覧が表示されます。何も選ばなければ `--profile` なしで実行します。`share` などを選ぶと、Mihako の S3 操作も `aws --profile share ...` として実行します。

入力例:

```text
s3://example.com/
```

## よくあるトラブル

### S3 で AccessDenied になる

ターミナルで同じ profile を指定して確認してください。

```sh
aws sts get-caller-identity --profile your-aws-profile-name
aws s3 ls s3://bucket-name/ --profile your-aws-profile-name
```

これが失敗する場合は Mihako ではなく AWS 側の IAM / bucket policy の問題です。少なくとも一覧表示には `s3:ListBucket` が必要です。アップロード、ダウンロード、削除、リネームには `s3:GetObject`、`s3:PutObject`、`s3:DeleteObject` も必要です。

### Terminal / iTerm を開くと権限エラーになる

macOS の System Settings > Privacy & Security > Automation で、Mihako が Terminal または iTerm を制御する許可を有効にしてください。

### app を開けない

ローカルで作った未署名 app なので、macOS の Gatekeeper が止めることがあります。その場合は Finder で右クリックして Open を選ぶか、System Settings > Privacy & Security から許可してください。

## 開発メモ

- エントリーポイント: `Sources/Mihako/MihakoApp.swift`
- 画面: `Sources/Mihako/ContentView.swift`
- ファイル操作と状態管理: `Sources/Mihako/FileBrowserViewModel.swift`
- SFTP 処理: `Sources/Mihako/SFTPClient.swift`
- S3 処理: `Sources/Mihako/S3Client.swift`
- app bundle 作成: `scripts/package-app.sh`
