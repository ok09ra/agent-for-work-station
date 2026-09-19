# トラブルシューティング

[English](troubleshooting.md) · [README](../README.ja.md)

まず診断を実行します。

```zsh
afws-doctor
```

## `command not found: claudefws` / `codexfws`

installer実行後に新しいターミナルを開くか、ログインシェルを読み込み直します。

```zsh
exec zsh -l
```

解消しない場合は`./scripts/install.sh`を再実行し、表示されたインストール先を確認してください。

## `command not found: sshfs`

[macFUSEのSSHFSページ](https://github.com/macfuse/macfuse/wiki/File-Systems-%E2%80%90-SSHFS)からmacOS用パッケージを導入し、ターミナルを開き直します。

## macOSがマウントを拒否する

macOSのシステム設定でmacFUSEが許可されているか確認します。画面構成はmacOSやMacの機種によって異なるため、公式の[macFUSE Getting Startedガイド](https://github.com/macfuse/macfuse/wiki/Getting-Started)に従ってください。再起動を求められた場合は再起動します。

## SSH接続に失敗する

Claude CodeやSSHFSを介さない通常のSSHで先に確認します。

```zsh
ssh SSH_CONFIG_HOST
```

接続名、ユーザー名、鍵、VPNの要否、踏み台ホストは、ローカルのSSH configと所属組織の接続手順で解決してください。パスワードや秘密鍵を課題、ログ、リポジトリへ貼り付けないでください。

## Claude Codeがフォルダを信頼するか確認してくる（claudefwsのみ）

新しいマウントポイントでの初回起動は、Claude Codeが見たことのないディレクトリを開くため、マウントポイントごとに一度確認します。許可してください。同じマウント上の以降のセッションでは再表示されません。

## `fuse: forking after mount is not supported`

macFUSEは、sshfsがマウント後に自分をバックグラウンドへ回すために行うforkを拒否します。sshfsを通常どおり実行すると、マウント自体は成功するものの、sshfsが前面に残り続けてターミナルが返ってきません。

`claudefws`は、sshfsを`-f`で実行し、シェル側で切り離すことでこれを回避しています。そのためターミナルを占有するプロセスは残りません。手動でsshfsを実行してこのメッセージが出た場合、多くはマウント自体は成功しています。失敗と判断する前に`mount`を確認し、次回は`-f`と末尾の`&`を使ってください。

## マウントが30秒以内に現れない

切り離されたsshfsプロセスは`~/.afws/logs/SESSION.sshfs.log`へ出力します。launcherは断念した時点でその末尾を表示します。そこに権限エラーが出ていれば共有SSH接続が使えていない状態、タイムアウトであれば接続を開いてからマウントするまでの間にホストへ到達できなくなった状態です。

## マウントが20秒以内に応答しない

これはタイムアウトであって、診断ではありません。既存のマウントを再利用する前に、launcherは一度だけ読み取りを行います。sshfsプロセスが死んでいるマウントは即座にエラーを返すため、何も返さないマウントはハングしているか、単に「冷えている」かのどちらかです。低速な回線では、最初の読み取りに時間がかかることがあります。

unmountする前に、どちらなのかを確認してください。

```zsh
pgrep -fl sshfs
```

該当するプロセスが残っていれば、マウントはおそらく正常で、遅いだけです。待ち時間を延ばして起動し直してください。

```zsh
AFWS_PROBE_TIMEOUT_SECONDS=60 claudefws SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY
```

該当するプロセスが無ければ、そのマウントは死んでいます。次項の手順でunmountしてください。

## マウントはあるが応答しない

こちらは読み取りがエラーを返した場合です。macFUSEではこれは、マウントの背後にあるsshfsプロセスが消えており、内部のすべてのパスが`ENXIO`で失敗することを意味します。

SSHFSはネットワーク中断後に再接続を試みますが、常に復旧できるとは限りません。Claude Codeを終了し、Finderで該当ボリュームを取り出してから、もう一度起動してください。プロセスを強制停止する前やアンマウントする前に、書き込み処理が進行中でないことを確認してください。

長時間のセッション中に発生する場合は、SSH configのkeepaliveを長めにします。

```
  ServerAliveInterval 30
  ServerAliveCountMax 6
```

## GPUが見えない

`nvidia-smi`はMacではなくSSH接続先で実行します。

```zsh
afws-run SSH_CONFIG_HOST --cwd REMOTE_ABSOLUTE_DIRECTORY -- nvidia-smi
```

出力は現在のターミナルへ返るため、利用者とClaudeの双方が確認できます。接続先にコマンドが存在しない場合や権限エラーになる場合は、リモートシステムの管理者へ問い合わせてください。

## スクリプトのシェルが想定と違う

`afws-run`へパイプしたスクリプトは、リモート側の`bash -s`で実行されます。別のシェル向けのコードは、そのシェルを明示的に指定してください。

```zsh
afws-run SSH_CONFIG_HOST --cwd REMOTE_ABSOLUTE_DIRECTORY -- \
  zsh -lc 'YOUR_ZSH_CODE'
```

## エージェントがテストをローカルで実行しようとする

そのセッションが`claudefws`または`codexfws`から起動されたか確認してください。素の`claude`や`codex`では、リモート実行の指示が渡りません。終了し、対象プロジェクトを指定してランチャーから起動し直してください。

## リモートコマンドが実行されずに止まる

リモートコマンドはすべて`~/.afws/control/HOST.sock`の共有SSH接続を通ります。その接続が失われていると、sshは自力で接続し直そうとし、誰も入力できないパスワードを待ち続けることがあります。状態を確認し、`claudefws`を起動し直して開き直してください。

```zsh
ssh -S ~/.afws/control/HOST.sock -O check HOST
```

## 共有接続を閉じたい、または詰まっている

```zsh
ssh -S ~/.afws/control/HOST.sock -O exit HOST
```

次回の`claudefws`起動で新しく開かれます。強制終了で残った古いソケットファイルは、次回起動時に自動的に削除されます。

## セッション終了後にマウントが残っている

バックグラウンドセッションには後片付けを行うlauncherプロセスが残りません。また終了ではなく強制終了されたセッションは後片付けを実行できません。残っているものを一覧して解放してください。

```zsh
afws-umount --list
afws-umount --orphaned
```

`--list`は各マウントを使っている生存セッション数を表示するため、`0`と表示されたマウントは安全に解放できます。ディレクトリ内に何かが残っていて`umount`が拒否される場合は`--force`を付けます。

## `afws-peers`に何も出ない、またはセッションが欠けている

レジストリに入るのは`claudefws`または`codexfws`から起動したセッションだけです。マウント済みワークスペース内であっても、素の`claude`や`codex`で起動したセッションは登録されません。

自分が起動したセッションが見えない場合は、まだ動作しているかを確認します。

```zsh
claude agents
```

終了したセッションはレジストリから自動的に取り除かれます。レジストリを変更せずに確認したい場合は`--no-prune`を付けます。

## `afws-peers`のSTATUSが`unknown`や`-`になる

Codexの行は常に`-`です。Codex CLIに機械可読なセッション一覧がないためです。Claudeの行のSTATUSは`claude agents --json`から取得しています。直接実行して原因を確認してください。多くの場合、Claude Codeへサインインしていないことが原因です。

```zsh
claude agents --json
claude auth login
```

接続先、リモートディレクトリ、種別はレジストリから取得しているため、引き続き正しく表示されます。

## すでに存在しないセッションがロックを保持している

保持者と経過時間を確認します。

```zsh
afws-lock status gpu0
```

TTLを超えたロックは`stale`と表示されます。`afws-peers`と`claude agents`で保持者が実際に存在しないことを確認してから、明示的に解放します。

```zsh
afws-lock steal gpu0
```

ロックは自動的には奪いません。長時間ジョブでロックが数時間保持されるのは正常な状態だからです。

## `--resume`で再開したセッションのパスが古い

Claude Codeは、会話の最初のリクエスト時にシステムプロンプトを記録し、再開時にもその記録を再利用します。そのため、再開したセッションは起動時のマウントポイントとセッション名をそのまま参照します。マウントポイントが変わっている場合は、古い会話を再開せず、`claudefws`から新しいセッションを起動してください。

## 2つのセッションが互いの編集を上書きした

どちらのセッションも、同じマウント越しに同じリモートファイルへ書き込んでおり、ファイルシステムはその調整を行いません。ディレクトリ単位で作業を分けるか、共有ファイルを編集する前に`SendMessage`でセッション間で合意してください。共有のビルドディレクトリや出力ディレクトリについては、`afws-lock`で同じ問題を防げます。[複数セッション](sessions.ja.md)を参照してください。
