# 使い方

[English](usage.md) · [README](../README.ja.md)

## 基本起動

もっとも安全で短い起動方法は、引数なしの対話モードです。

```zsh
claudefws
```

毎回の入力が不要なら、SSH configの接続名とリモートプロジェクトの絶対ディレクトリを引数にします。

```zsh
claudefws SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY
```

`codexfws`もまったく同じ2つの引数を取ります。エージェントの追加引数はその後ろへ続けられます。

```zsh
claudefws SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY --model MODEL_NAME
```

## 起動時の動作

1. 指定した接続先とリモートディレクトリに対応する既存のSSHFSマウントを探します。
2. 見つかれば再利用し、なければユーザーのホームディレクトリ配下へ新しくマウントします。
3. 接続先への認証済みSSH接続を1本だけ開きます。パスワードや鍵のパスフレーズを求められる場合は、ここで入力します。
4. `fws-HOST-PROJECT-N`形式の未使用のセッション名を決めます。
5. `~/.afws/sessions/`へセッションを登録し、他のセッションから担当範囲が見えるようにします。
6. マウントポイントを作業ディレクトリとして、リモート作業用の指示を与えてエージェントを起動します。`claudefws`はセッション名と`--permission-mode auto`を、`codexfws`は`--sandbox workspace-write`と`--ask-for-approval on-request`を渡します。

エージェントはローカルで動き、マウントしたワークスペース上でファイルを確認・編集します。Python、テスト、ビルド、GPU確認などリモート環境に依存する処理は、SSH接続先で実行します。

## リモートコマンドを手動で実行する

通常の引数形式は次のとおりです。

```zsh
afws-run SSH_CONFIG_HOST --cwd REMOTE_ABSOLUTE_DIRECTORY -- nvidia-smi
```

`claudefws`から起動したセッション内では、接続名とリモートディレクトリが環境変数に入っているため、どちらも省略できます。

```zsh
afws-run -- nvidia-smi
```

標準入力からスクリプトを渡すこともできます。

```zsh
printf '%s\n' 'pwd' 'git status --short' |
  afws-run SSH_CONFIG_HOST --cwd REMOTE_ABSOLUTE_DIRECTORY
```

標準入力モードは、指定したリモートディレクトリで`bash -s`としてスクリプトを実行します。したがって、設定されたSSHユーザーの権限で任意のBashコードを実行できます。`--cwd`は開始ディレクトリの指定であり、リモート側のサンドボックスではないため、スクリプトはそのユーザーがアクセスできる他のパスへも到達できます。別のシェルを明示的に使う場合は、コマンドとして渡します。

```zsh
afws-run SSH_CONFIG_HOST --cwd REMOTE_ABSOLUTE_DIRECTORY -- \
  zsh -lc 'print -r -- $ZSH_VERSION'
```

改行を含む引数はzsh形式でクォートされるため、リモートのログインシェルがbashまたはzshでなければ解釈されません。引数に改行が入る場合は、標準入力にスクリプトを流す形式を使ってください。

標準出力と標準エラーは現在のターミナルへ返るため、利用者とClaudeの双方が結果を確認できます。

## 自分でリモートコマンドを打つ

Claude Codeの`!`は、そのセッション自身のシェル、つまりMac側で実行されます。ワークスペースはSSHFSマウントなので、**パスはリモート、実行はローカル**という非対称になります。

```zsh
!ls                  # リモートのファイルが、Macのlsで一覧される。これは問題ない
!nvidia-smi          # Macで実行。GPUがないので単に失敗する
!python train.py     # Macで実行。リモートのファイルを、間違ったインタプリタと
                     # 間違った環境で処理する。しかも失敗してくれない
```

危険なのは3行目です。`nvcc`や`conda`はMacに無いことが多く明確に失敗しますが、`python`、`git`、`make`、`gcc`は存在するため、静かに誤った処理を行います。

これは見落としやすいので、`claudefws`のセッションはローカルで実行したコマンドに必ず印を付けます。`codexfws`のセッションでは付きません。Codex CLIに印を付ける先のシェルラッパーがないためです。[エージェントごとにできること](agents.ja.md)を参照してください。

```
!echo works        → [mac] works
!python train.py   → [mac] /Library/Frameworks/Python.framework/.../python3
!nvidia-smi        → [mac] zsh:1: command not found: nvidia-smi
                     [mac] not found on this Mac. for HOST, use: afws-run -- <command>
```

`[mac]`は標準エラーへ出るため、コマンドの出力に混ざりません。また何も禁止しません。ワークステーションで実行すべきコマンドも、ここで実行されたうえで、そう表示されるだけです。2行目はMacにそのコマンドが存在しない場合にのみ出ます。印が不要な場合は、起動時に`AFWS_NO_SHELL_MARKER=1`を指定します。

ワークステーション側で実行する短い形式が`afws-run`です。

```zsh
!afws-run -- nvidia-smi
!afws-run -- python train.py
!afws-run -- sh -c 'ls *.log | wc -l'
```

すべての引数がリモートコマンドの一部として扱われるため、`--`は不要です。シェルのメタ文字はリモートで解釈されず、そのまま渡されます。上の例でパイプを`sh -c`で包んでいるのはそのためです。`!`の後に書いた`|`はローカルシェルが解釈するため、`!afws-run -- ls | wc -l`は`ls`をワークステーションで、`wc`をMacで実行します。

これはあなたが打つ場合の話です。Claude自身には、リモート環境に依存する処理は`afws-run`経由で実行するよう指示してあります。

## 複数セッションで作業する

このMac上のセッションと、それぞれの担当を一覧します。

```zsh
afws-peers
afws-peers --host SSH_CONFIG_HOST
afws-peers --same
```

リモートの排他資源は、使う前に確保し、終わったら解放します。

```zsh
afws-lock acquire gpu0
afws-lock status
afws-lock release gpu0
```

バックグラウンドで動き続け、他セッションからメッセージを受け取れるセッションを起動します。

```zsh
claudefws --bg SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY "学習ジョブを監視し、失敗があれば報告してください"
```

セッション間でメッセージを送る方法を含む全体像は[複数セッション](sessions.ja.md)にまとめています。

## セッションの終了

セッションが終了すると、launcherはそのセッションが最後の利用者だったものを解放します。レジストリの記録、そのマウント内で作業している他のセッションがなければSSHFSマウント、そのホスト上に他のセッションがなければ共有SSH接続です。他のセッションがまだ使っているマウントは残します。`~/afws-mounts`の外にあるマウント、つまりclaudefwsが作成していないものも解放しません。

自動では扱えないケースが2つあります。バックグラウンドセッションには後片付けを行うlauncherプロセスが残りません。また強制終了されたセッション（`kill -9`、クラッシュ、蓋を閉じた場合など）は後片付けを実行できません。どちらの場合も、明示的に解放します。

```zsh
afws-umount --list                                  # マウントと利用中のセッション数
afws-umount --orphaned                              # 未使用のものを解放
afws-umount SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY
afws-umount --orphaned --force                      # 通常のumountが拒否される場合
```

セッション終了後もマウントを残したい場合（続けて別のセッションを起動するときなど）は、その起動時に`AFWS_KEEP_MOUNT=1`を指定します。

## 変更せずに内容だけ確認する

dry-runモードでは、SSHFSのマウント、レジストリへの書き込み、エージェントの起動をいずれも行わず、予定される操作だけを表示します。

```zsh
claudefws --dry-run SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY
```

リモート実行とロックも同じ方式に対応します。

```zsh
afws-run SSH_CONFIG_HOST --cwd REMOTE_ABSOLUTE_DIRECTORY --dry-run -- nvidia-smi
afws-lock acquire gpu0 --host SSH_CONFIG_HOST --dry-run
```

`afws-lock --dry-run`は、SSHコマンドとリモート側で実行されるスクリプトの両方を表示します。接続する前に、影響の全体を確認できます。

## 環境変数

| 変数 | 効果 |
| --- | --- |
| `AFWS_MOUNT_BASE` | 新規マウントの親ディレクトリ（既定: `~/afws-mounts`） |
| `AFWS_STATE_DIR` | セッションレジストリの場所（既定: `~/.afws`） |
| `AFWS_PERMISSION_MODE` | Claude Codeのpermission mode。`claudefws`のみ（既定: `auto`） |
| `AFWS_SESSION_NAME` | 自動生成の代わりに使うセッション名 |
| `AFWS_REMOTE_LOCK_DIR` | リモート側のロック置き場（既定: `~/.afws-locks`） |
| `AFWS_NO_CONTROL_MASTER` | 値を設定すると、接続ごとに個別に認証します |
| `AFWS_KEEP_MOUNT` | 値を設定すると、セッション終了時にマウントを残します |
| `AFWS_NO_SHELL_MARKER` | 値を設定すると、ローカル実行への印付けを止めます |
| `AFWS_ALLOW_HOME_MOUNT` | 値を設定すると、ホームディレクトリの警告を抑止します |
| `AFWS_CONTROL_PERSIST` | 共有SSH接続が無通信で維持される秒数（既定: 600） |
| `AFWS_LOCK_TTL` | ロックをstaleと表示するまでの秒数（既定: 7200） |

セッション内では、launcherが`AFWS_SSH_HOST`、`AFWS_REMOTE_DIR`、`AFWS_LOCAL_WORKSPACE`もexportします。これにより`afws-run`と`afws-lock`を接続名なしで使えます。

permission modeをそのセッションだけ変更する場合は、起動時に指定します。指定できるのはClaude Codeが受け付ける値、すなわち`acceptEdits`、`auto`、`bypassPermissions`、`manual`、`dontAsk`、`plan`です。認識できない値は、マウントを行う前に拒否します。

```zsh
AFWS_PERMISSION_MODE=manual claudefws SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY
```

## SSH接続の共有

マウントと、すべての`afws-run`・`afws-lock`は、多重化された1本のSSH接続を通ります。制御ソケットは`~/.afws/control/HOST.sock`です。これには2つの意味があります。

パスワードや鍵のパスフレーズを要求するホストでも、聞かれるのは`claudefws`を起動したターミナルでの1回だけです。それ以降は入力を求められません。マウントはターミナルから切り離されており、セッション内のリモートコマンドには入力を求める相手がいないためです。

接続を再利用することで、リモートコマンドごとのTCPハンドシェイクと認証もなくなります。コマンドを多数実行するセッションでは体感できる差になります。

そのホストでの作業を終えたら、接続を閉じます。

```zsh
ssh -S ~/.afws/control/HOST.sock -O exit HOST
```

毎回個別に接続したい場合は`AFWS_NO_CONTROL_MASTER=1`を設定します。その場合、鍵認証が事実上必須になります。

## 制限事項

- リモートファイルシステムのルートは選択できません。プロジェクトディレクトリを指定してください。
- `.`、`..`、連続した`/`を含むリモートパスは拒否します。
- SSH configの接続名に使えるのは、英数字、ピリオド、アンダースコア、ハイフンだけです。
- リモート側のパッケージ導入、シェル設定変更、システム変更は自動的には許可されません。
- SSHFSはネットワーク越しに動作するため、小さなファイルを大量に扱う処理はリモート実行のほうが速いことが多いです。
- セッションレジストリとセッション間メッセージは、1台のMac内に限られます。別のMac上のセッションとは、このツールでは相互に見えません。

## うまく動かないとき

まず[トラブルシューティング](troubleshooting.ja.md)を読み、`afws-doctor`を実行してください。
