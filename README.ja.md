# Claude for Work Station

[English](README.md)

`claude-for-work-station`（Claude for Work Station）は、macOS上のClaude CodeからSSH接続先のプロジェクトを扱うための小さなラッパーです。

- ファイルの読み書きは、SSHFSでマウントしたローカルワークスペース上で行います。
- Python、テスト、ビルド、GPUジョブなどは、`claudefws-run`を通してSSH接続先で実行します。
- 各セッションには名前が付き、レジストリへ登録されます。同じMac上の複数のClaudeセッションは互いを一覧でき、名前を指定して会話でき、リモートの排他資源を順番に使えます。
- 接続先のIPアドレス、ユーザー名、パスワード、実際のディレクトリは、このリポジトリには保存しません。
- 対象となるクライアントOSはmacOSのみです。

リポジトリ名は`claude-for-work-station`、インストールされるコマンド名には短い`claudefws`を使用します。

## 最短の導入手順

何も入っていないMacでは、次の順番で準備します。

1. [macFUSE公式サイト](https://macfuse.github.io/)から最新の安定版をインストールします。
2. [macFUSE公式SSHFSページ](https://github.com/macfuse/macfuse/wiki/File-Systems-%E2%80%90-SSHFS)からmacOS用SSHFSパッケージをインストールします。
3. [Claude Code公式ドキュメント](https://docs.claude.com/en/docs/claude-code/overview)に従ってClaude Codeをインストールします。

   ```zsh
   curl -fsSL https://claude.ai/install.sh | bash
   claude auth login
   ```

4. このリポジトリのルートでinstallerを実行します。

   ```zsh
   ./scripts/install.sh
   exec zsh -l
   claudefws-doctor
   ```

5. SSHの接続名をローカルの`~/.ssh/config`に設定します。実値はリポジトリ内へ書かず、[架空のSSH設定例](examples/ssh-config.example)を参考にローカルだけで管理してください。
6. 起動します。引数を省略すると、接続名とリモートディレクトリを対話形式で入力できます。

   ```zsh
   claudefws
   ```

引数で直接指定する場合は次の形式です。

```zsh
claudefws SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY
```

SSH側はパスワードをファイルへ保存せず、SSH鍵とmacOSのキーチェーンを利用してください。

## インストールされるコマンド

| コマンド | 役割 |
| --- | --- |
| `claudefws` | リモートプロジェクトをマウントし、名前付きのClaude Codeセッションを起動します。 |
| `claudefws-run` | 1つのコマンド、または標準入力から渡したスクリプトをリモートで実行します。 |
| `claudefws-peers` | このMac上のセッションと、それぞれが担当するホスト・ディレクトリを一覧します。 |
| `claudefws-lock` | リモートの排他資源を確保し、複数セッションの衝突を防ぎます。 |
| `claudefws-umount` | バックグラウンドセッションや強制終了が残したマウントを解放します。 |
| `ws-run` | `claudefws-run --`の短縮形。Claude Codeの`!`の後に打つためのものです。 |
| `claudefws-doctor` | 前提条件が揃っているかを確認します。 |

## 1台のワークステーションに複数セッション

起動ごとに別の名前のセッションが作られるため、2つ目のターミナルで起動すれば、1つ目と競合するコピーではなく、同じワークステーション上の2つ目のセッションになります。

```zsh
claudefws SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY   # fws-HOST-PROJECT-1
claudefws SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY   # fws-HOST-PROJECT-2
claudefws --bg SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY "学習ジョブを監視してください"
```

セッション内のClaudeは`claudefws-peers`で他セッションを一覧し、名前を指定してメッセージを送り、`claudefws-lock`でGPUや共有ビルドディレクトリへのアクセスを直列化できます。詳細は[複数セッション](docs/sessions.ja.md)を参照してください。

## ドキュメント

| 内容 | 日本語 | English |
| --- | --- | --- |
| macOSへの導入 | [macOSセットアップ](docs/install-macos.ja.md) | [Install on macOS](docs/install-macos.md) |
| 使用方法 | [使い方](docs/usage.ja.md) | [Usage](docs/usage.md) |
| 複数セッション | [複数セッション](docs/sessions.ja.md) | [Multiple sessions](docs/sessions.md) |
| セキュリティ | [セキュリティ](docs/security.ja.md) | [Security](docs/security.md) |
| 問題解決 | [トラブルシューティング](docs/troubleshooting.ja.md) | [Troubleshooting](docs/troubleshooting.md) |

## 開発者向けチェック

```zsh
./scripts/test.sh
./scripts/prepublish-check.sh
```

`test.sh`は使い捨てのレジストリ上だけで動作し、SSH接続、マウント、Claudeセッションの起動をいずれも行いません。

`prepublish-check.sh`は、秘密鍵らしき内容、代表的なトークン形式、IPアドレス、個人ホームディレクトリの絶対パス、設定済みパスワードらしき内容が混入していないか検査します。push前には、必ずstage済みの差分も確認してください。

## リポジトリの操作範囲

このリポジトリに含まれるinstaller、doctor、testは、Git remoteの追加、commit、push、release作成を行いません。リポジトリの公開操作は、内容確認後に明示的に行います。
