# Shodana

**The Developer Workspace for macOS**

> Manage local files, Git repositories, cloud storage, and remote servers from one application.

Shodana は、macOS 向けの開発者ワークスペースです。

Finder の雰囲気を保ちながら、Windows Explorer のような分かりやすいパス操作を取り入れ、さらに Git、SFTP、SMB、Amazon S3、Google Drive、OneDrive、SharePoint、Terminal、iTerm、IDE 連携まで一つの画面で扱えることを目指しています。

単なる Finder 代替ではなく、開発者やインフラエンジニアが毎日使うローカル、Git、クラウド、リモート、IDE を横断する作業環境として育てているアプリです。

```text
One application.
All your development resources.
Local. Git. Cloud. Remote. IDE.
```

## このプロジェクトについて

Shodana は Swift / SwiftUI / AppKit で作っている macOS アプリです。Swift Package Manager でそのままビルドできます。Xcode プロジェクトではなく `Package.swift` を中心にした構成なので、ターミナルから `swift run` や `swift build` で扱えます。

## なぜ Shodana なのか

Finder は macOS に深く統合されていて優れていますが、開発者が日常的に使う Git、SFTP、S3、IDE、Terminal との往復は別々のアプリやコマンドに分散しがちです。

Shodana は、次のような作業を一つのワークスペースにまとめます。

- ローカルファイルとクラウド同期フォルダを同じ操作感で扱う
- NAS、SFTP、S3 などのリモートリソースを `Locations` から開く
- Git リポジトリでブランチ、Pull、Push、Add、Commit、Merge を実行する
- 現在のフォルダや選択フォルダを Terminal、iTerm、VSCode、JetBrains IDE で開く
- パスバー、パンくず、詳細表示、検索、右クリックメニューで業務ファイル管理を読みやすくする
- 日本語/英語、ライト/ダークを OS 設定または手動設定で切り替える

## 現在の主な機能

### Local Files

- Finder に近い見た目と、Explorer ライクな分かりやすいファイル操作
- アドレスバーへ直接パスを入力して移動
- 複数ディレクトリをタブで切り替え
- デュアルペインで2つのフォルダを並べて表示
- 通常のフォルダ表示と検索結果表示の切り替え
- 検索対象パスを指定した検索、Spotlight (`mdfind`) 利用、検索中断
- AI Search: 許可したスコープ内の候補ファイルだけをAIに開示して、ファイル検索や内容相談
- パンくずリストで上位階層へ移動
- 戻る、進む、上の階層へ移動
- 一覧表示、アイコン表示、カラム表示、ギャラリー表示の切り替え
- 種類、変更日、サイズによるグループ表示
- 業務ファイル向けの詳細表示、列余白、ストライプ表示
- ファイル/フォルダの新規作成、名前変更、複製、削除
- 右クリックメニューから情報を見る
- Command+C / Command+X / Command+V によるコピー、切り取り、貼り付け
- 右クリックメニューからコピー、切り取り、貼り付け、パスコピー、Finder 表示
- `.app` などのパッケージを右クリックして内容を表示
- 右クリックメニューから ZIP / TAR / TAR.GZ / TAR.BZ2 / TAR.XZ 形式で圧縮、同じ形式を解凍
- 複数ファイルのドラッグ&ドロップ

### Git

- 現在開いているフォルダが Git リポジトリの場合に自動検出
- ステータスバーにブランチ名を表示
- 未プッシュ、リモート側の進行状態を矢印で表示
- ファイル一覧に独立した `Git` 列を表示
- `M Modified`、`A Added`、`D Deleted`、`? Untracked`、`- Ignored` などの状態を色付きで表示
- ステータスバーの Git メニューから Pull、Push、ブランチ切り替え、Merge
- 右クリックメニューから選択項目の Git Add、Git Commit
- Commit Message 入力ダイアログ
- 選択項目またはリポジトリ全体の Git Diff 表示
- 選択項目またはリポジトリ全体の Git History 表示
- URL を入力して Git Repository を Clone
- Pull、Push、Commit、Merge などの実行結果を読みやすい結果画面で表示

### Remote

- SMB による NAS や Windows 共有のマウント
- SFTP 接続、ブラウズ、アップロード、ダウンロード
- `~/.ssh/config` の Host 名を使った SFTP 接続
- SFTP 上のフォルダを Terminal / iTerm で開く
- Amazon S3 接続、ブラウズ、アップロード、ダウンロード
- AWS CLI の profile 一覧から S3 接続 profile を選択
- 接続先を `Locations` に保存
- 起動時や `Reload Locations` で再接続
- 接続できない場所も失敗アイコン付きで `Locations` に保持

### Cloud Storage

- Google Drive、OneDrive、SharePoint の同期フォルダを `Locations` に表示
- マウント済みボリューム、外部ドライブ、NAS を `Locations` に表示
- `Locations` の表示名指定、並び替え
- クラウド同期フォルダではファイル一覧に独立した `Cloud` 列を表示
- `Synced`、`Cloud Only`、`Syncing`、`Error`、`Pinned`、`Unknown` を色付きで表示
- OneDrive、SharePoint、Google Drive、iCloud Drive などは取得できるメタデータからベストエフォートで状態判定

### Development Tools

- 現在のフォルダを Terminal / iTerm で開く
- 選択フォルダを WebStorm、PyCharm、VSCode などの外部アプリで開く
- 外部ツールボタンの追加、変更、削除、並び替え
- 外部ツールボタンに起動先アプリのアイコン、または任意の SF Symbol を表示

### Productivity

- サイドバーの Favorites へフォルダをドラッグ&ドロップで追加
- Favorites の削除
- 最後に操作したウィンドウのタブを次回起動時に復元
- Dock メニューから新規ウィンドウ、Desktop、Downloads、任意フォルダを開く
- `shodana://` URL スキームから Shodana を開く
- Folder Compare: ローカル、マウント済みSMB/クラウド、SFTP、S3のフォルダ比較
- Folder Sync: Mirror、Update、Two-Way、Backup モード
- Dry Run、同期前プレビュー、大量削除確認、CSVログ出力
- `.gitignore` とよくある除外パターンを考慮した比較
- ローカルファイルは SHA-256 による内容比較に対応
- 日本語/英語の表示切り替え
- システム、ライト、ダークの外観切り替え

## Roadmap

Shodana は開発中のアプリです。以前の Priority 1 として挙げていたタブ、デュアルペイン、Git Status、Git Diff、Git History、Branch 切り替え、Clone Repository は、現在は初期実装済みです。

以下は、実装済み機能をさらに磨き込むための強化候補です。

### Priority 1

- タブ状態保持強化: タブごとの履歴、検索状態、ウィンドウごとの復元
- デュアルペイン強化: 左右ペイン間のコピー、移動、比較、同期操作をより直接的に実行
- Git Status 強化: ステージ済み/未ステージの区別、サブモジュール、競合の詳細表示
- Git Diff Viewer 強化: 色付き差分、ファイル単位の差分ナビゲーション、ステージ/アンステージ操作
- Git History 強化: コミット詳細、変更ファイル、ブランチグラフ、ファイル単位履歴
- Clone Repository 強化: clone 後の自動オープン、履歴、よく使うホスト補完
- Cloud Status 強化: OneDrive、SharePoint、Google Drive、iCloud Drive のプロバイダ別メタデータ対応精度向上
- Folder Compare / Sync 強化: 競合解決UI、キャッシュ、詳細進捗、バックグラウンドジョブ化
- AI Search 強化: 複数プロバイダーのプリセット、SFTP/S3の直接コンテキスト化、送信前レビューUI

### Priority 2

- Folder Compare 強化: テキストDiff Viewer、画像の左右プレビュー、差分キャッシュによる高速化
- Folder Sync 強化: Undo、同期履歴、スケジューラ
- Copy Queue: コピー、移動、アップロード、ダウンロードのジョブ管理
- Background Upload: 大量ファイル転送の詳細進捗、残り時間表示
- Advanced Search: ファイル内容、正規表現、Git Ignore 対応検索
- Workspace: Backend、Frontend、Terraform、Docker などの関連フォルダを一括管理
- Session Restore: 前回終了時のウィンドウ、タブ、接続先を復元
- Bookmark Sync: 複数 Mac 間で Favorites や Locations を同期

### Priority 3

- SSH Console: SSH ターミナルを内蔵
- Docker Browser: Container、Volume、Log の閲覧
- Kubernetes Browser: Namespace、Pod、Log の閲覧
- AWS Browser: EC2、S3、CloudWatch の横断表示
- AI Assist: Git Commit Message 生成、Shell Command 生成、Rename 提案

## 将来的な製品構成案

Community 版と Pro 版を分ける場合は、次のような整理が考えられます。

### Community

- ローカルファイル管理
- Git 基本操作
- Terminal / iTerm 起動
- IDE 連携
- Favorites / Locations

### Pro

- Folder Compare
- Folder Sync
- Background Transfer
- SFTP / S3 同期
- SharePoint / Google Drive 連携強化
- Workspace
- Session Restore
- SSH Console
- 高速検索
- AI 支援

## 必要なもの

- macOS 14 以降
- Xcode または Xcode Command Line Tools
- Swift Package Manager
- S3 を使う場合は AWS CLI

## インストール方法

### 1. リポジトリを取得する

GitHub から clone します。

```sh
git clone git@github.com:MasakiFUJISAWA/shodana.git
cd shodana
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
.build/release/Shodana.app
```

起動確認:

```sh
open .build/release/Shodana.app
```

Applications フォルダへ入れる場合:

```sh
cp -R .build/release/Shodana.app /Applications/
```

これで Launchpad や Finder の Applications から `Shodana` を起動できます。

### 4. 更新するとき

リポジトリを更新して、もう一度 app を作り直します。

```sh
git pull
scripts/package-app.sh
cp -R .build/release/Shodana.app /Applications/
```

## 基本的な使い方

画面は大きく左のサイドバーと右のファイル一覧に分かれています。

左のサイドバーには `Favorites` と `Locations` が表示されます。よく使うフォルダは `Favorites` にドラッグ&ドロップで追加できます。追加した項目は右クリックメニューから削除できます。`Locations` には Mac 本体、外部ドライブ、クラウドストレージ、NAS、SFTP、S3 などの接続先が表示されます。

右側の上部にはアドレスバーがあります。ここへ `/Users/yourname/Documents` のようなローカルパス、`sftp://...`、`s3://...` のようなリモートパスを入力して移動できます。

アドレスバー行の左端には、通常のフォルダ表示と検索結果表示を切り替えるボタンがあります。検索結果表示に切り替えると、アドレスバー行には検索対象パス、検索欄、検索ボタンが表示され、パンくずリストは隠れます。ローカルフォルダでは検索対象パス配下を Spotlight (`mdfind`) で検索し、Spotlight が使えない場合は再帰検索に戻ります。SFTP/S3 では検索対象パスの直下一覧から名前で絞り込みます。

検索結果表示の中には `Keyword Search` と `AI Search` の切り替えがあります。`AI Search` では、あらかじめ許可した `AI Scope` の範囲にあるファイルだけを候補として抽出し、OpenAI互換の Chat Completions API に送って内容相談できます。APIキーは macOS Keychain に保存され、`.env`、秘密鍵、`node_modules`、`.git` などはデフォルトで除外されます。

AI Search を使う流れは次の通りです。

1. 検索結果表示に切り替える
2. `AI Search` を選ぶ
3. アドレス欄に相談対象のパスを表示する
4. フォルダ追加ボタン、または `AI Search Settings...` から、そのパスを `AI Scope` に追加する
5. `AI Search Settings...` で Endpoint、Model、API Key を設定する
6. 質問欄に「この処理の入口はどこ？」などを入力してAIに質問する

現在の初期実装では、ローカルフォルダ、マウント済みNAS、Google Drive / OneDrive / SharePoint / iCloud Drive などの同期済みフォルダを対象にできます。SFTP/S3の内容を直接AIコンテキスト化する機能は今後の強化対象です。

ファイル一覧の上には操作ボタンがあります。

- 表示形式の切り替え: 一覧、アイコン、カラム、ギャラリー
- グループ表示: なし、種類、変更日、サイズ
- Git Clone、Git Add、Git Commit、Git Pull、Git Push、Git Merge
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

Shodana は日本語と英語に対応しています。初期状態は `System` で、macOS の優先言語が日本語なら日本語、それ以外なら英語で表示します。

手動で固定したい場合は、メニューバーの `Language` から次を選べます。

- `Use System Language`: OS の言語設定に従う
- `English`: 英語で表示する
- `Japanese`: 日本語で表示する

翻訳ファイルは `Sources/Shodana/Resources/en.lproj/Localizable.strings` と `Sources/Shodana/Resources/ja.lproj/Localizable.strings` で管理しています。現時点ではアプリ本体に同梱して管理し、別パッケージには分けていません。

## 外観設定

Shodana はライトモードとダークモードに対応しています。メニューバーの `Appearance` から次を選べます。

- `Use System Appearance`: macOS の外観設定に従う
- `Light`: ライトモードで固定する
- `Dark`: ダークモードで固定する

macOS の Appearance が `Auto` の場合、Shodana 側を `Use System Appearance` にしておくと、macOS と同じく昼はライト、夜はダークに切り替わります。

## 外部からShodanaを開く

Shodana は外部からフォルダを開くための入口を用意しています。配布用 app を作ると、次のURLスキームとフォルダ文書タイプがInfo.plistに登録されます。

- URLスキーム: `shodana://`
- フォルダタイプ: `public.folder` / `public.directory`

旧 `mihako://` スキームも互換用に受け付けます。

例えばターミナルからDownloadsをShodanaで開く場合は次です。

```sh
open "shodana://open?path=$HOME/Downloads"
```

ローカルフォルダをShodanaアプリへ直接渡すこともできます。

```sh
open -a /Applications/Shodana.app "$HOME/Downloads"
```

SFTPやS3のURLを渡す場合は、`url=` にURLを指定します。

```sh
open "shodana://open?url=sftp://dm-backend-ec2/opt/"
open "shodana://open?url=s3://bucket-name/prefix/"
```

### Dock用Downloadsランチャー

FinderのDockスタックそのものを完全に置き換えることはmacOSの制約上できませんが、ShodanaでDownloadsを開く小さなランチャーappを作ってDockに置くことはできます。

```sh
scripts/create-open-in-shodana-launcher.sh
open ".build/Shodana Downloads.app"
```

作られた `.build/Shodana Downloads.app` をDockへドラッグしておくと、DockからShodanaでDownloadsを開けます。別のフォルダ用に作る場合は、第一引数にフォルダパス、第二引数に出力先appを指定します。

```sh
scripts/create-open-in-shodana-launcher.sh "$HOME/Documents" ".build/Shodana Documents.app"
```

Dock上のShodanaアイコンを右クリックすると、次のメニューから新規ウィンドウを開けます。

- `New Window`: 通常の新規ウィンドウ
- `New Window (Desktop)`: Desktopを開く新規ウィンドウ
- `New Window (Downloads)`: Downloadsを開く新規ウィンドウ

メニューバーの `Launcher Folders...` から、Dockメニューに表示する任意のフォルダーショートカットを追加、削除、並び替えできます。

なお、macOSではFinderが特別扱いされるため、Dockの標準Downloadsスタック、Finderを明示的に呼ぶアプリ、保存/選択ダイアログなどはFinderのままです。Shodana側では、Launch ServicesやURLスキーム経由で渡ってくるフォルダを受け取れるようにしています。

## 接続機能

`Connect Server...` から外部の場所へ接続できます。

- `SMB`: NAS や Windows 共有などを macOS の標準マウント機能で接続します。
- `SFTP`: `~/.ssh/config` や SSH 鍵設定を使って接続します。
- `S3`: AWS CLI の credential/profile を使って接続します。
- `FTP`: 接続種別としては用意していますが、現時点では段階的実装中です。

接続した場所は `Locations` に保存されます。Shodana を再起動したときや `Reload Locations` を実行したときに再接続を試みます。接続できない場合も Locations には残り、失敗アイコン付きで表示されます。

## Folder Compare / Sync を使う

上部のタブバー付近にある `Compare / Sync` ボタンから、2つのフォルダを比較・同期できます。デュアルペイン表示中は、左ペインと右ペインの現在位置が初期値として入ります。

比較では、存在差異、サイズ差異、更新日時差異、内容差異を一覧表示します。ローカルファイル同士は SHA-256 を使った内容比較に対応しています。SFTP や S3 などリモート側は、まずサイズと更新日時を中心に比較します。

比較結果画面は上下分割になっており、上側に比較結果、下側に同期プレビューとログを表示します。境界線をドラッグして表示領域を調整できます。

比較結果一覧の `Sync` チェックが入っている項目だけが同期プレビューや同期実行の対象になります。`Select All` と `Clear All` で同期対象をまとめて切り替えられます。

比較結果のファイル行をダブルクリックすると詳細比較を開けます。テキストファイルの場合は左右の編集ペインで内容を直接編集でき、中央の `<<` / `>>` で差分ブロックを左右へ反映できます。上部の `左を保存`、`右を保存`、`両方保存` で保存します。Swift、JavaScript / TypeScript、Java、C#、C / C++、SQL、JSON、YAML、Markdown などは簡易シンタックスハイライトで表示します。

同期モードは次の通りです。

- `Mirror`: 左を正として右を一致させます。右だけにある項目は削除対象になります。
- `Update`: 左から右へ追加・更新します。削除は行いません。
- `Two-Way`: 左右の新しい方を採用します。判断できないものは競合として実行を止めます。
- `Backup`: 右側の `backup/yyyy-MM-dd-HHmmss/` 配下へ世代コピーします。

`Dry Run` がオンの場合、実際にはコピーや削除をせず、実行予定だけを確認できます。同期後は `~/Library/Logs/Shodana/` に CSV ログを保存します。

## デバッグ実行

開発中にそのまま起動する場合は、リポジトリのルートで次を実行します。

```sh
swift run Shodana
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

`~/.ssh/config` に `Host test-server` のような設定があれば、Shodana もその設定を使います。SFTP 接続中のフォルダは Terminal / iTerm で開けます。

## S3 を使う

S3 は AWS CLI の設定を使います。まずターミナルで次が通ることを確認してください。

```sh
aws s3 ls s3://bucket-name/
```

Switch Role や複数 profile を使っている場合は、profile を指定して確認します。

```sh
aws s3 ls s3://bucket-name/ --profile share
```

Shodana の Connect Server で `S3` を選ぶと、AWS CLI の profile 一覧が表示されます。何も選ばなければ `--profile` なしで実行します。`share` などを選ぶと、Shodana の S3 操作も `aws --profile share ...` として実行します。

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

これが失敗する場合は Shodana ではなく AWS 側の IAM / bucket policy の問題です。少なくとも一覧表示には `s3:ListBucket` が必要です。アップロード、ダウンロード、削除、リネームには `s3:GetObject`、`s3:PutObject`、`s3:DeleteObject` も必要です。

### Terminal / iTerm を開くと権限エラーになる

macOS の System Settings > Privacy & Security > Automation で、Shodana が Terminal または iTerm を制御する許可を有効にしてください。

### app を開けない

ローカルで作った未署名 app なので、macOS の Gatekeeper が止めることがあります。その場合は Finder で右クリックして Open を選ぶか、System Settings > Privacy & Security から許可してください。

## 開発メモ

- エントリーポイント: `Sources/Shodana/ShodanaApp.swift`
- 画面: `Sources/Shodana/ContentView.swift`
- ファイル操作と状態管理: `Sources/Shodana/FileBrowserViewModel.swift`
- SFTP 処理: `Sources/Shodana/SFTPClient.swift`
- S3 処理: `Sources/Shodana/S3Client.swift`
- app bundle 作成: `scripts/package-app.sh`
