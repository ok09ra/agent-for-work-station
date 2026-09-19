# macOSセットアップ

[English](install-macos.md) · [README](../README.ja.md)

このドキュメントは、ほぼ初期状態のMacから`claudefws`が動く状態までの手順です。実際の接続情報と資格情報は、このリポジトリではなくMacのSSH configとキーチェーンで管理します。

## 1. 前提の確認

- macOS 12以降
- IntelまたはApple silicon搭載のMac
- SSH接続先へのアクセス権
- リモート側で対象プロジェクトを読み書き・実行できる権限

このセットアップでは、リモート側のソフトウェアやシェル設定を変更しません。

## 2. macFUSEのインストール

1. [macFUSE公式サイト](https://macfuse.github.io/)を開きます。
2. 最新の安定版installerをダウンロードして実行します。
3. macOSがシステム設定での許可を求めた場合は、公式の案内に従って許可します。
4. 再起動を求められた場合は再起動します。

macFUSEはmacOSのセキュリティ機構に関わるため、この部分はリポジトリ側で自動化していません。

## 3. SSHFSのインストール

1. [macFUSEプロジェクトのSSHFSページ](https://github.com/macfuse/macfuse/wiki/File-Systems-%E2%80%90-SSHFS)を開きます。
2. macOS用の最新パッケージをダウンロードして実行します。
3. ターミナルを開き直して確認します。

   ```zsh
   command -v sshfs
   sshfs --version
   ```

このプロジェクトでは、特定のサードパーティ製パッケージマネージャーを前提とせず、macFUSEプロジェクトが案内する署名済みパッケージを使います。

## 4. Claude Codeのインストール

[Claude Code公式ドキュメント](https://docs.claude.com/en/docs/claude-code/overview)のinstallerを使います。

```zsh
curl -fsSL https://claude.ai/install.sh | bash
exec zsh -l
claude --version
claude auth login
```

公式installerはユーザー領域へ導入するため、Claude Codeの実行に管理者権限は不要です。サインインは一度だけ行えば、`claudefws`から起動する各セッションがそれを再利用します。

## 5. SSHの設定

次の情報を、承認された安全な経路でリモートシステムの管理者から受け取ります。

- SSH接続先
- リモートのユーザー名
- 許可されたSSH鍵
- 対象プロジェクトの絶対ディレクトリ

パスワードや秘密鍵をこのリポジトリへ複製しないでください。SSH鍵がない場合は、所属組織の方針に従って作成・登録します。認証にはmacOSのキーチェーンまたはSSH agentを使います。

ローカルのSSH configに接続名を定義します。[設定例](../examples/ssh-config.example)は架空の値だけを含みます。`HostName`と`User`の実値は、ローカルのファイルにのみ記述します。

設定ファイルと権限を準備します。

```zsh
mkdir -p ~/.ssh
chmod 700 ~/.ssh
touch ~/.ssh/config
chmod 600 ~/.ssh/config
```

接続を確認します。

```zsh
ssh example-workstation
```

`example-workstation`は、SSH configで定義した接続名に置き換えます。初回接続時は、ホスト鍵のfingerprintを管理者から提供された値と照合します。

セッションは数時間、バックグラウンドセッションはさらに長くワークステーションへ接続したままになるため、SSH configで接続を維持しておきます。

```
  ServerAliveInterval 30
  ServerAliveCountMax 6
```

## 6. claudefwsのインストール

リポジトリを取得したら、そのルートでinstallerを実行します。Gitが使えない場合は、アーカイブを展開したものでも構いません。

```zsh
./scripts/install.sh
exec zsh -l
```

installerが行うのは次の操作だけです。

1. `claudefws`、`claudefws-run`、`claudefws-peers`、`claudefws-lock`、`claudefws-doctor`をユーザー領域のコマンドディレクトリへコピーします。
2. 必要な場合にのみ、そのディレクトリをzshログインシェルの`PATH`へ追加します。
3. 新しく開いたターミナルからコマンドを見つけられるようにします。

既存のSSH config、Claude Codeの設定、リモート環境はいずれも変更しません。

## 7. 診断の実行

```zsh
claudefws-doctor
```

接続を開かずにSSH configの接続名だけを確認する場合は、引数に渡します。

```zsh
claudefws-doctor example-workstation
```

診断では`claude agents --json`が動作することも確認します。`claudefws-peers`がセッションの状態を取得するのにこの一覧を使うためです。失敗する場合は`claude auth login`を実行してから再試行します。

すべての診断が`[OK]`になれば準備完了です。

## 8. Claude for Work Stationの起動

シェル履歴に実値を残したくない場合は、引数なしで起動します。

```zsh
claudefws
```

表示に従って、SSHの接続名と許可されたリモートプロジェクトの絶対ディレクトリを入力します。SSHFSがマウントを完了すると、そのマウントポイントを作業ディレクトリとしてClaude Codeが起動します。

新しいマウントポイントでの初回起動時は、Claude Codeがそのフォルダを信頼するか確認します。マウントポイントごとに一度だけ許可します。

## 9. 終了とアンマウント

Claude Codeを終了すると、そのマウント内で作業している他のセッションがない限り、マウントは解放されます。そのホスト上にセッションが残っていなければ、共有SSH接続も同時に閉じられます。終了したセッションのレジストリ記録も削除され、古い記録は`claudefws-peers`や`claudefws`の実行時に整理されます。

セッション実行中は、launcherは要求した接続先とパスを含む既存のSSHFSマウントを再利用します。自身の記録ではなくシステムの`mount`一覧を参照しているためです。

バックグラウンドセッション、および終了ではなく強制終了されたセッションは、マウントを残します。明示的に解放してください。

```zsh
claudefws-umount --list
claudefws-umount --orphaned
```

`--list`は各claudefwsマウントと、それを使っている生存セッション数を表示します。`--orphaned`は誰も使っていないものを解放します。通常の`umount`が拒否される場合は`--force`を付けます。Finderでボリュームを取り出す方法も使えます。

ターミナルから手動でアンマウントする場合は、まず`mount`で確認し、確認済みのマウントポイントだけを`umount`へ渡します。広い範囲や未確認のパスに対しては実行しないでください。
