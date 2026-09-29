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

1. 接続先への認証済みSSH接続を1本だけ開きます。パスワードや鍵のパスフレーズを求められる場合は、ここで入力します。
2. `codexfws`はFinder/VS Code用rclone NFSビューを作ります（正常なものが既にあれば再利用）。`claudefws`は`--view`が無ければ何もマウントしません。
3. どちらのエージェントも空のローカル制御ディレクトリで起動し、リモートプロジェクトを正本として扱います。
4. Claudeなら`fws-HOST-PROJECT-N`、Codexなら`cx-HOST-PROJECT-N`形式の未使用のセッション名を決めます。
5. `~/.afws/sessions/`へセッションを登録し、他のセッションから担当範囲が見えるようにします。
6. プロジェクト操作はすべて`afws-run`経由で、リモートのプロジェクトディレクトリから始まります。

Codexには4つのローカルライフサイクルフックも付けます。Codexに求められたら内容を確認して信頼してください。最初のターン後にスレッドID・状態・短い作業ラベルを記録し、別セッションから宛先にできるようにします。

どちらのエージェントもMacで動きます。読み取り・編集・Git・実行を含む全プロジェクト操作がSSH接続先で動きます。ビューが切れても作業は継続できます。ビューはデータ経路ではないからです。エージェント自身の作業ディレクトリは空の制御ディレクトリで、これがファイルツールを、古かったり欠けていたりするローカルコピーから遠ざけます。

対話セッションのターミナルタイトルは`[セッション名] プロジェクト名 | agent-for-work-station`になります。たとえば`AFWS_SESSION_NAME=ngof-1`なら`[ngof-1] ngof | agent-for-work-station`です。端末側でタイトルを管理したい場合は、起動時に`AFWS_NO_TERMINAL_TITLE=1`を設定します。バックグラウンドセッションはタイトルを変更しません。

追加のセッションは、同じマウントポイントの正常なビューを共有します。既存のSSHFSマウントも再利用するため、起動のたびに再マウントしたり、rcloneへの移行だけを理由に既存セッションを終了したりする必要はありません。マウントがない場合はrcloneで新しいビューを作ります。すでに何かがマウントされているパスへの新規マウントは拒否します。同じパスに重ねると下の層を置き換えるのではなく隠すことになり、後から上の層を外しても次の層が出てくるだけだからです。

## セッションを別の端末から操作する

対話型の`claudefws`セッションでは、Claudeの入力欄に`/remote-control`（または`/rc`）を入力します。今の会話をClaudeのWeb版やモバイルアプリから操作できます。もう一度入力すると状態を確認し、切断できます。

`codexfws`セッションでは、Codexにリモート操作のオン・オフを頼むか、次を実行します。

```zsh
afws-remote on       # このMacの共有Codex app-serverで有効化（自分のシェルで実行）
afws-remote status   # 接続状態を確認
afws-remote pair     # 端末を追加する短期ペアリングコードを表示（自分のシェルで実行）
afws-remote off      # リモート操作だけ無効化し、ローカルの会話は継続
```

Codex側の設定はこのMacの他のCodexセッションにも効き、セッション終了後も残ります。`pair`は信頼する端末を追加するときだけ使ってください。Codexから実行する場合、ワークスペース外へのアクセス承認を求められることがあります。開いているCodex CLIの会話は端末側でロックされる場合があり、Remote Controlの有効化だけではその会話を引き継げません。現在の`codexfws`には安全なセッション引き継ぎ機能がありません。

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

セッションが終了すると、launcherはそのセッションが最後の利用者だったものを解放します。レジストリの記録、他に使っているセッションがなければ起動したビュー、他に必要とするセッションがなければ`afws-lab`が起動したJupyterLab、そのホスト上に他のセッションがなければ共有SSH接続です。他のセッションがまだ使っているビューは残します。`~/afws-mounts`の外にあるマウント、つまりlauncherが作成していないものも解放しません。

対話型セッションでは、独立したwatchdogも起動します。`claudefws`または`codexfws`のlauncherが`kill -9`やクラッシュで終了した場合、watchdogは生き残ったエージェントプロセスの終了を待ち、通常終了時と同じ「最後の利用者か」の確認と後片付けを行います。他の登録済みセッションが使っているワークスペースはアンマウントしません。

バックグラウンドClaudeセッションにはlauncherのwatchdogがないため、起動したビューを残します。またwatchdog自体も停止した場合や、macOSがアンマウントを拒否した場合には残ることがあります。その場合は明示的に解放します。

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

セッション終了後もビューを残したい場合（続けて別のセッションを起動するときなど）は、その起動時に`AFWS_KEEP_MOUNT=1`を指定します。

## プロジェクトを読む：JupyterLab

ビューはファイル名を眺めるためのもので、中身を読むためのものが`afws-lab`です。ワークステーション上の専用`tmux`セッションでJupyterLabを動かし、ローカルのポートへ転送します。

```zsh
afws-lab                    # 起動する。動いていれば修復して再利用する
afws-lab --force            # 状態を判定できなかった層も作り直す
afws-lab status             # 層ごとの健全性と、壊れている層への次の一手
afws-lab open               # ブラウザで開く
afws-lab list               # すべてのlabと、それぞれの利用セッション
afws-lab stop
afws-lab stop --orphaned    # 生存セッションが使っていないlabを停止する
afws-lab -n                 # 変更内容だけ表示し、何も変えない
```

サーバがワークステーション上で動くため、プロジェクトをワークステーション上のまま読みます。symlinkは解決され、画像やPDFは描画され、ノートブックはリモートのカーネルで動き、Markdownは画像込みで整形されます。マウントが遅い・古い・無いことは一切関係しません。

同じホスト・同じリモートディレクトリのセッションで1つを共有し（ビューと同じ共有規則です）、最後の1つが終了した時点で解放されます。`start`は修復経路でもあります。`tmux`セッション、サーバプロセス、転送ポート、HTTPエンドポイントを順に確認し、実際に壊れている層だけを作り直します。そのため接続が切れても再起動ではなく再接続で済み、開いているノートブックは状態を保ちます。

共有マシンでは2点が効きます。ポートは固定しません。JupyterLabが空きポートを選び、`afws-lab`がそれを読み戻すので、他の人と衝突しません。そしてtokenをコマンドラインに載せません。多くのシステムで`ps`は他ユーザから読めるためで、サーバ自身のランタイムファイルから読み取ります。

`afws-lab`はワークステーション側のJupyterLabを`python3 -m jupyterlab`として呼びます。ディストリビューションの`jupyter`コマンドはJupyterLabを含まない旧notebookパッケージであることが多いため、コマンド名ではなくモジュールの有無を確認しています。

## マウント無しで構造化されたファイルツールを使う：MCPサーバ

`lib/afws-fs-mcp.py`はMac側で動くstdio MCPサーバで、セッションの共有SSH接続を通してリモートプロジェクトに届きます。`read_file`、`write_file`、`edit_file`、`list_directory`、`glob`、`grep`、`stat`を提供します。プロジェクトがシェル出力としてしか届かない状況で失われる、構造化された操作を取り戻すためのものです。

`AFWS_SSH_HOST`、`AFWS_REMOTE_DIR`、任意で`AFWS_CONTROL_PATH`と`AFWS_CONTROL_PERSIST`を読みます。いずれもセッションが既にexport済みです。launcherには組み込まれていないので、Claude Codeへ明示的に指定します。

```zsh
claude --mcp-config '{"mcpServers":{"afws-fs":{"command":"python3",
  "args":["'"$HOME"'/.local/lib/afws-fs-mcp.py"]}}}'
```

すべてのパスは`AFWS_REMOTE_DIR`内に閉じ込められます。検査はローカルの文字列判定ではなく、パス解決後にリモート側で行います。ローカルでいくら文字列を調べても分からない形で、symlinkを通ってプロジェクトの外へ出られるためです。`stat`だけはリンクを追跡せず、リンクであることと向き先を報告します。`bin/python3`がプロジェクト外を指す`venv`を、そういうものとして見られるようにするためです。

## 変更せずに内容だけ確認する

dry-runモードでは、マウント、レジストリへの書き込み、エージェントの起動をいずれも行わず、予定される操作だけを表示します。

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
| `AFWS_NO_AGENT_TEAMS` | この起動ではClaude Codeの実験的Agent Teamsを有効にしません |
| `AFWS_SESSION_NAME` | 自動生成の代わりに使うセッション名 |
| `AFWS_REMOTE_LOCK_DIR` | リモート側のロック置き場（既定: `~/.afws-locks`） |
| `AFWS_NO_CONTROL_MASTER` | 値を設定すると、接続ごとに個別に認証します |
| `AFWS_KEEP_MOUNT` | 値を設定すると、セッション終了時にFinder/VS Codeビューを残します |
| `AFWS_VISIBILITY_MOUNT` | 値を設定すると、既定でFinder/VS Codeビューをマウントします（`claudefws`のみ。`--no-view`が優先） |
| `AFWS_NO_SHELL_MARKER` | 値を設定すると、ローカル実行への印付けを止めます |
| `AFWS_ADD_DIR` | セッションが追加で読めるローカルディレクトリ。`:`区切り（`claudefws`のみ） |
| `AFWS_REMOTE_ASSUME_YES` | `afws-remote on`と`pair`の端末確認を省きます。自分のスクリプト用であり、agentセッションが確認を回避するためのものではありません |
| `AFWS_CODEX_AUTO_REVIEW` | 値を設定すると、Codexの承認要求をセッション内で判断させず、Codex自身の審査agentに回します（`codexfws`のみ） |
| `AFWS_KEEP_CONTROL_MASTER` | 値を設定すると、最後のセッション終了後も共有接続を開いたままにします |
| `AFWS_CONTROL_PERSIST` | 共有SSH接続が無通信で維持される秒数（既定: 600、`AFWS_KEEP_CONTROL_MASTER`指定時は28800） |
| `AFWS_PROBE_TIMEOUT_SECONDS` | 既存マウントが最初の読み取りに応答するまで待つ秒数（既定: 20） |
| `AFWS_LOCK_TTL` | ロックをstaleと表示するまでの秒数（既定: 7200） |

セッション内では、launcherが`AFWS_SSH_HOST`、`AFWS_REMOTE_DIR`、`AFWS_LOCAL_WORKSPACE`もexportします。これにより`afws-run`と`afws-lock`を接続名なしで使えます。

permission modeをそのセッションだけ変更する場合は、起動時に指定します。指定できるのはClaude Codeが受け付ける値、すなわち`acceptEdits`、`auto`、`bypassPermissions`、`manual`、`dontAsk`、`plan`です。認識できない値は、マウントを行う前に拒否します。

`claudefws`は既定でClaude Code Agent Teamsと、プロジェクト単位で共有するnative task listを有効にします。実験的機能をポリシーや互換性の都合で無効のままにする場合は`AFWS_NO_AGENT_TEAMS=1`を指定します。その場合もAFWSの組織台帳、peer配送、lifecycle hookは動作します。

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
