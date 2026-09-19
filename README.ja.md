# Agent for Work Station

[English](README.md)

`agent-for-work-station`は、リモートワークステーション上のプロジェクトをコーディングエージェントで扱うためのmacOS用の小さなラッパーです。1回のインストールで2つのエージェントに対応します。

```zsh
claudefws SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY   # Claude Code
codexfws  SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY   # Codex CLI
```

- エージェントはMac上で動きます。リモートなのはプロジェクトだけで、SSHFSでマウントし、環境依存のコマンドだけをワークステーションへ送ります。ワークステーション側に何もインストールする必要がないため、共有マシンの場合に効いてきます。
- ホストごとに認証済みのSSH接続を1本だけ開き、マウントとすべてのリモートコマンドで再利用します。パスワードを要求するホストでも、聞かれるのは1回です。
- 同じMac上のセッションは登録され、互いを認識し、GPUや共有ビルドディレクトリを衝突せずに順番に使えます。
- マウントと接続は、それを使う最後のセッションが終了した時点で解放されます。
- 実際のIPアドレス、ユーザー名、パスワード、プロジェクトパスはこのリポジトリに保存しません。対象クライアントOSはmacOSのみです。

## 最短の導入手順

何も入っていないMacでは、次の順番で準備します。

1. [macFUSE公式サイト](https://macfuse.github.io/)から最新の安定版をインストールします。
2. [macFUSE公式SSHFSページ](https://github.com/macfuse/macfuse/wiki/File-Systems-%E2%80%90-SSHFS)からmacOS用SSHFSパッケージをインストールします。
3. エージェントを少なくとも1つ導入します。両方とも個別に任意で、どちらのランチャーが使えるかは`afws-doctor`が報告します。

   ```zsh
   curl -fsSL https://claude.ai/install.sh | bash      # Claude Code
   claude auth login
   curl -fsSL https://chatgpt.com/codex/install.sh | sh  # Codex CLI
   ```

4. このリポジトリのルートでinstallerを実行します。

   ```zsh
   ./scripts/install.sh
   exec zsh -l
   afws-doctor
   ```

5. SSHの接続名をローカルの`~/.ssh/config`に設定します。実値はリポジトリ内へ書かず、[架空のSSH設定例](examples/ssh-config.example)を参考にローカルだけで管理してください。
6. セッションを起動します。引数を省略すると、どちらのランチャーも接続名とリモートプロジェクトのディレクトリを対話的に尋ねます。

   ```zsh
   claudefws
   ```

SSH側はパスワードをファイルへ保存せず、SSH鍵とmacOSのキーチェーンを利用してください。

## インストールされるコマンド

| コマンド | 役割 |
| --- | --- |
| `claudefws` | リモートプロジェクトをマウントし、Claude Codeセッションを起動します。 |
| `codexfws` | 同じことをCodex CLIで行います。 |
| `afws-run` | 1つのコマンド、または標準入力のスクリプトをリモートで実行します。 |
| `afws-peers` | このMac上のセッションと、それぞれの担当ホスト・ディレクトリを一覧します。 |
| `afws-lock` | リモートの排他資源を確保し、複数セッションの衝突を防ぎます。 |
| `afws-umount` | バックグラウンドセッションや強制終了が残したマウントを解放します。 |
| `afws-doctor` | 前提条件が揃っているかを確認します。 |
| `afws-shell` | ローカル実行に`[mac]`の印を付けます。`claudefws`が使うもので、手で実行しません。 |

配管コマンドは共通です。`afws-run`はエージェントごとに分かれておらず1つだけで、`afws-peers`は両方のセッションを一覧します。共通ロジックは`lib/afws-common.zsh`にあり、コマンドの隣（`../lib`）へインストールされます。

## 1台のワークステーションに2つのエージェント

どちらのランチャーも同じ方法でワークステーションへ到達するため、同じホスト・同じディレクトリのClaudeセッションとCodexセッションは**マウントとSSH接続を1つずつ共有**し、並んで表示されます。

```zsh
afws-peers
```

```
SESSION                    AGENT   KIND         STATUS   SSH HOST            REMOTE DIRECTORY
fws-workstation-project-1  claude  interactive  busy     workstation         /remote/project
cx-workstation-project-1   codex   interactive  -        workstation         /remote/project
```

違いはエージェント自身が公開している機能です。Claudeセッションは名前指定でメッセージを受け取れて状態も報告しますが、Codexセッションはどちらもできません。Codex CLIに起動時のセッション名指定と機械可読なセッション一覧がないためです。差の全体と理由は[エージェントごとにできること](docs/agents.ja.md)にまとめています。

## ドキュメント

| 内容 | 日本語 | English |
| --- | --- | --- |
| エージェントごとの違い | [エージェント](docs/agents.ja.md) | [Agents](docs/agents.md) |
| macOSへの導入 | [macOSセットアップ](docs/install-macos.ja.md) | [Install on macOS](docs/install-macos.md) |
| 使用方法 | [使い方](docs/usage.ja.md) | [Usage](docs/usage.md) |
| 複数セッション | [複数セッション](docs/sessions.ja.md) | [Multiple sessions](docs/sessions.md) |
| セキュリティ | [セキュリティ](docs/security.ja.md) | [Security](docs/security.md) |
| 問題解決 | [トラブルシューティング](docs/troubleshooting.ja.md) | [Troubleshooting](docs/troubleshooting.md) |

## 旧 claudefws / codexfws からの移行

このリポジトリは2つの旧リポジトリを置き換えるもので、名前が変わっています。互換エイリアスは用意していません。

| 旧 | 新 |
| --- | --- |
| `claudefws-run`、`codexfws-run` | `afws-run` |
| `claudefws-peers`、`claudefws-lock`、`claudefws-umount` | `afws-peers`、`afws-lock`、`afws-umount` |
| `claudefws-doctor`、`codexfws-doctor` | `afws-doctor` |
| `ws-run` | 廃止。`afws-run -- COMMAND`を使います |
| `CLAUDEFWS_*`、`CODEXFWS_*` | `AFWS_*` |
| `~/claudefws-mounts`、`~/codexfws-mounts` | `~/afws-mounts` |
| `~/.claudefws`、`~/.codexfws` | `~/.afws` |

次の順序で移行してください。installerは何も削除せず、残っているものを一覧表示するだけです。

1. 稼働中のセッションを終了します（マウントと接続が解放されます）。
2. 残りを解放します。`claudefws-umount --orphaned`を実行し、`mount | grep macfuse`で`~/codexfws-mounts`配下に残っているものを確認して`umount`します。
3. 旧コマンドを`~/.local/bin`から削除し、旧状態ディレクトリ`~/.claudefws`と`~/.codexfws`も削除します。
4. `./scripts/install.sh`を実行します。

## 開発者向けチェック

```zsh
./scripts/test.sh
./scripts/prepublish-check.sh
```

`test.sh`は使い捨てのレジストリと、マウントテーブルの代わりのテキストファイルの上だけで動作し、SSH接続、マウント、エージェントの起動をいずれも行いません。

`prepublish-check.sh`は、秘密鍵らしき内容、代表的なトークン形式、IPアドレス、個人ホームディレクトリの絶対パス、設定済みパスワードらしき内容、統合前の旧名称の残留を検査します。

## リポジトリの操作範囲

このリポジトリに含まれるinstaller、doctor、testは、Git remoteの追加、commit、push、release作成を行いません。リポジトリの公開操作は、内容確認後に明示的に行います。
