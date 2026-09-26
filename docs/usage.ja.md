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

`codexfws`も同じ2つの引数を取ります。Codexからローカル資料を使う場合だけ、許可するディレクトリを起動前に指定します。

```zsh
claudefws SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY --model MODEL_NAME
codexfws --allow-local-files /LOCAL/DATA SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY
codexfws --resume SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY
```

## 起動時の動作

1. ClaudeではSSHFS作業ツリー、CodexではFinder/VS Code用rclone NFSビューを探します。
2. Codex自身は空のローカル制御ディレクトリで起動し、リモートプロジェクトを正本として扱います。
3. 接続先への認証済みSSH接続を1本だけ開きます。パスワードや鍵のパスフレーズを求められる場合は、ここで入力します。
4. Claudeなら`fws-HOST-PROJECT-N`、Codexなら`cx-HOST-PROJECT-N`形式の未使用のセッション名を決めます。
5. `~/.afws/sessions/`へセッションを登録し、他のセッションから担当範囲が見えるようにします。
6. `claudefws`はマウント内、`codexfws`は制御ディレクトリ内で起動します。Codexのプロジェクト操作はすべて`afws-run`経由です。

Codexには4つのローカルライフサイクルフックも付けます。Codexに求められたら内容を確認して信頼してください。最初のターン後にスレッドID・状態・短い作業ラベルを記録し、別セッションから宛先にできるようにします。

どちらのエージェントもMacで動きます。Codexでは読み取り・編集・Git・実行を含む全プロジェクト操作がSSH接続先で動きます。表示用ビューが切れてもCodexの作業は継続できます。

## リモートコマンドを手動で実行する

通常の引数形式は次のとおりです。

```zsh
afws-run SSH_CONFIG_HOST --cwd REMOTE_ABSOLUTE_DIRECTORY -- nvidia-smi
```

どちらのランチャーから起動したセッション内でも、接続名とリモートディレクトリは環境変数に入っているので、**渡したものすべてがリモートコマンド**になります。

```zsh
afws-run nvidia-smi
afws-run python train.py
```

これはClaude Codeの`!`の後に打つのに十分短く、それが狙いです。`!nvidia-smi`はMacで動きますが、`!afws-run nvidia-smi`はワークステーションに届きます。先頭の`--`も引き続き使えますし、接続名を明示すればセッション内からでもそのホストを指定できます。

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
!echo works        → [local] works
!python train.py   → [local] /Library/Frameworks/Python.framework/.../python3
!nvidia-smi        → [local] zsh:1: command not found: nvidia-smi
                     [local] not found on this Mac. for HOST, use: afws-run -- <command>
!afws-run nvidia-smi → [remote] NVIDIA-SMI ...
```

`[local]`はこのMacで実行されたこと、`[remote]`はワークステーションで実行されたことを示します。`afws-run`を含むコマンドは`afws-run`自身のラベルに任せるため、答えは2つではなく1つになります。

この最後の点はトレードオフです。`python prep.py && afws-run train`ではローカル側が無印になります。一方、この仕組みが本来防ぎたい失敗 — ワークステーションに一切言及せず、静かにここで実行されるコマンド — は常に`[local]`が付きます。

印は標準エラーへ出るため、コマンドの出力に混ざりません。また何も禁止しません。ワークステーションで実行すべきコマンドも、ここで実行されたうえで、そう表示されるだけです。「not found on this Mac」の行はMacにそのコマンドが存在しない場合にのみ出ます。印が不要な場合は、起動時に`AFWS_NO_SHELL_MARKER=1`を指定します。語そのものは`AFWS_MARKER`と`AFWS_REMOTE_MARKER`で変えられます。

ワークステーション側で実行する短い形式が`afws-run`です。

```zsh
!afws-run -- nvidia-smi
!afws-run -- python train.py
!afws-run -- sh -c 'nvidia-smi | wc -l'
```

すべての引数がリモートコマンドの一部として扱われるため、`--`は不要です。シェルのメタ文字はリモートで解釈されず、そのまま渡されます。上の例でパイプを`sh -c`で包んでいるのはそのためです。`!`の後に書いた`|`はローカルシェルが解釈するため、`!afws-run -- nvidia-smi | wc -l`は`nvidia-smi`をワークステーションで、`wc`をMacで実行します。

リモートディレクトリとローカルのマウント済みワークスペースは、同じプロジェクトツリーへの2つのパスです。そのためプロジェクトの読み取り・検索・編集・ファイル管理・Git操作には、マウント上で通常のローカルツールを使います。利用者が明示的に求めない限り、別のclone・checkout・Git worktreeを作らないようセッションへ指示します。

マウント済みセッション内の`afws-run`もこの分担を補強し、典型的な探索・ファイル操作・Gitの直接実行を拒否します。shellで包んだ複数行コマンド、標準入力のshellスクリプト、`env`等の一般的なラッパーも検査し、明白な探索・Git・ファイル変更を拒否します。裸のリモートshellも拒否します。診断は1行だけなので、ローカル実行へ直す際に消費するコンテキストを抑えられます。これは作業手順上のガードであり、セキュリティサンドボックスではありません。任意のプログラムは引き続きファイルを読み書きでき、静的検査ですべてのshell表現を理解できるわけでもありません。利用者がリモート側のファイル操作を明示的に求めた場合だけ、次のように解除します。

```zsh
afws-run --allow-remote-files COMMAND ARG...
```

これは利用者が自分で打つ場合にも適用されます。ClaudeとCodexには同じ指示が渡り、`afws-run`をワークステーションの環境が必要なプログラムだけに使います。

## ローカルの資料とリモートの計算を1つのセッションで

Codexでは明示的に許可し、必要ならプロジェクトへ直接ストリーム転送します。

```zsh
codexfws --allow-local-files ~/Documents/input SSH_CONFIG_HOST /remote/project
afws-push ~/Documents/input data
```

この例は`/remote/project/data/input`へ転送します。中間コピーは作らず、許可範囲外のローカルパスと`..`や絶対パスによるリモートプロジェクト外への転送を拒否します。

プロジェクトはリモートにありますが、**作業の材料**はローカルにあることが多いはずです。論文、ノート、手元の試し計算。多くの場合、事前の準備は要りません。両側ともMac上のただのパスであり、シェルコマンドはワークスペースに限定されず、ファイルツールもワークスペース外の絶対パスを受け付けるため、会話の中でパスを言えば足ります。

`AFWS_ADD_DIR`は名前ほどのことはしません。`codexfws`では、ローカルディレクトリが書き込み可能になる唯一の手段です。Codexは書き込みをワークスペースに限定し、それを起動時に決めるためです。`claudefws`ではワークスペース外の読み取り・作成・編集は既に通るので、そのディレクトリのスキルやコマンドを読み込むかどうかにだけ効きます。`:`区切りで指定します。

```zsh
AFWS_ADD_DIR=~/Documents/papers:~/Documents/notes \
  claudefws SSH_CONFIG_HOST /remote/project
```

launcherは`also:`として一覧表示し、Claude Codeへ`--add-dir`で渡します。マウントより前に検証するため、打ち間違いでマウントを作ってしまうことはありません。セッションには「これはローカルの参考資料であり、読むのはこちら、書くのはリモートのプロジェクト」と指示されます。

`codexfws`では、ワークスペース外へ書き込む唯一の手段になります。Codexのサンドボックスはセッション中ではなく開始時に決まるためです。

どちらのランチャーも同じ変数を受け取り、同じ表示をします。エージェントへ渡す形は異なりますが、それはランチャー側の事情です。

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

対話型セッションでは、独立したwatchdogも起動します。`claudefws`または`codexfws`のlauncherが`kill -9`やクラッシュで終了した場合、watchdogは生き残ったエージェントプロセスの終了を待ち、通常終了時と同じ「最後の利用者か」の確認と後片付けを行います。他の登録済みセッションが使っているワークスペースはアンマウントしません。

バックグラウンドClaudeセッションにはlauncherのwatchdogがないため、マウントを残します。またwatchdog自体も停止した場合や、macOSがアンマウントを拒否した場合には残ることがあります。その場合は明示的に解放します。

```zsh
afws-umount --list                                  # マウントと利用中のセッション数
afws-umount --orphaned                              # 未使用のものを解放
afws-umount SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY
afws-umount --orphaned --force                      # 通常のumountが拒否される場合
```

実行中のセッションでマウントが切断された場合、プロジェクトのファイル操作をリモートshellへ移さず、同じ場所で修復します。

```zsh
afws-remount                                        # 現在のセッションのマウント
afws-remount SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY
```

`codexfws`と`claudefws`は起動時にも同じ検査を行い、読み取りエラーによって切断が確定した既存マウントを、エージェント起動前に自動で張り直します。正常なマウントに対しては、`--force`を明示しない限り何もしません。切断が確認できたマウントは、セッションがより広いマウントのサブディレクトリを使っている場合も、元のマウント元とマウントポイントを保って張り直します。交換時は、長時間動作した共有SSH接続の故障を引き継がないよう、独立した新しい接続を使います。鍵認証が使えず、正常だと確認済みの共有接続が必要な場合だけ`--reuse-connection`を指定します。マウントを手動で外した後など、交換対象を自動検出できない場合は`--fresh-connection`を指定できます。応答タイムアウトは、単に低速で冷えたマウントかもしれないため、自動交換しません。それを交換する場合は利用者の承認と`afws-remount --force`が必要です。簡易な読み取りは成功しても内容が明らかに誤っている場合も、同じ明示オプションで修復できます。複数の生存セッションが共有していても、読み取りエラーが確定したマウントは全セッションのために自動修復します。応答中またはタイムアウトだけのマウントを交換する場合は、全セッションの中断を利用者が明示的に承認した`--force-shared`が必要です。通常の`umount`が固まった場合も期限を設け、対象のSSHFSだけを停止して強制解除へ進みます。修復後も実行中のエージェントが古い作業ディレクトリを保持して`ENXIO`を返す場合は、そのエージェントを終了して起動し直します。

セッション終了後もマウントを残したい場合（続けて別のセッションを起動するときなど）は、その起動時に`AFWS_KEEP_MOUNT=1`を指定します。

## 変更せずに内容だけ確認する

dry-runモードでは、SSHFSのマウント、レジストリへの書き込み、エージェントの起動をいずれも行わず、予定される操作だけを表示します。

```zsh
claudefws --dry-run SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY
afws-remount --dry-run SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY
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
| `AFWS_ADD_DIR` | セッションが追加で読めるローカルディレクトリ。`:`区切り（`claudefws`のみ） |
| `AFWS_KEEP_CONTROL_MASTER` | 値を設定すると、最後のセッション終了後も共有接続を開いたままにします |
| `AFWS_CONTROL_PERSIST` | 共有SSH接続が無通信で維持される秒数（既定: 600、`AFWS_KEEP_CONTROL_MASTER`指定時は28800） |
| `AFWS_PROBE_TIMEOUT_SECONDS` | 既存マウントが最初の読み取りに応答するまで待つ秒数（既定: 20） |
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

接続は、そのホストを使う最後のセッションが終了した時点で閉じられます。したがって次回の起動では再度認証します。パスワード認証のホストでは、これは起動ごとに1回のパスワード入力を意味し、さらにセッション外で`afws-run`を使うとコマンドごとに1回聞かれます。`AFWS_KEEP_CONTROL_MASTER=1`を設定すると接続を開いたままにし、寿命を決めるのは`AFWS_CONTROL_PERSIST`だけになります。何を引き換えにするかは[security.ja.md](security.ja.md)を参照してください。

共有接続が無い場合でも`afws-run`と`afws-lock`は動作し、自前で接続を開きます。鍵認証のホストではこれは単に成功します。成功しえない場合 — 再利用できる接続が無く、かつパスワード入力に使える端末も無い、つまりセッション内部の状況 — では、sshに`BatchMode`を渡して即座に失敗させ、askpassヘルパーを探し回らせません。その失敗時に、共有接続を開き直す方法を表示します。成功したフォールバックについては何も出力しません。

毎回個別に接続したい場合は`AFWS_NO_CONTROL_MASTER=1`を設定します。その場合、鍵認証が事実上必須になり、そもそも共有する意図のない接続について何も報告されません。

## 制限事項

- リモートファイルシステムのルートは選択できません。プロジェクトディレクトリを指定してください。
- `.`、`..`、連続した`/`を含むリモートパスは拒否します。
- SSH configの接続名に使えるのは、英数字、ピリオド、アンダースコア、ハイフンだけです。
- リモート側のパッケージ導入、シェル設定変更、システム変更は自動的には許可されません。
- SSHFSはネットワーク越しに動作するため、小さなファイルを大量に扱う処理はリモート実行のほうが速いことが多いです。
- セッションレジストリとセッション間メッセージは、1台のMac内に限られます。別のMac上のセッションとは、このツールでは相互に見えません。

## うまく動かないとき

まず[トラブルシューティング](troubleshooting.ja.md)を読み、`afws-doctor`を実行してください。
