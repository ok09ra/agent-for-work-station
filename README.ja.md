# Agent for Work Station

[English](README.md)

リモートワークステーション上のプロジェクトを、Claude Code または Codex CLI で扱うためのツールです。エージェントは自分のMacで動き、ワークステーション側には何もインストールしません。

```zsh
claudefws my-workstation /remote/path/to/project   # Claude Code
codexfws  my-workstation /remote/path/to/project   # Codex CLI
```

どちらのエージェントもリモート側を正本とし、プロジェクトの読み取り・編集・Git・実行をすべて`afws-run`経由で行います。プロジェクトのsymlink、パーミッション、巨大なディレクトリがワークステーション上のまま扱われます。`claudefws`は既定で何もマウントせず、Finder/VS Code用のrclone NFSビューが要るときだけ`--view`を付けます（`codexfws`は従来どおり毎回ビューを作ります）。これは起動時に決め切る必要のない選択です。`afws-view`が実行中のセッションの中からビューをマウント・確認・解放するので、`--view`無しで始めたセッションを取り直す必要はありません。図・ノートブック・整形されたMarkdownを読みたいときは`afws-lab`がワークステーション上でJupyterLabを動かします。ビューもLabもデータ経路ではないので、壊れてもセッションは止まりません。ホストごとに認証済みのSSH接続を1本だけ開いて再利用し、それが死んだ場合は次に必要とした側が張り直します。

クライアントはmacOSのみ。実際のホスト名、アドレス、ユーザー名、パスはこのリポジトリに保存しません。

## 誰のためのものか

**ワークステーションを他の人と共有していて、扱いに気を配るデータがある人。** 他のアカウントもログインしており、そこにコーディングエージェントを入れるのは他人にも影響する決定です。Macで動かせば、共有マシンに自分のものは何も残りません。認証情報も、何か月もかけて積み上がる許可ルールも、終了したセッションが残す常駐プロセスも。共有マシンで半年ネイティブに使ったエージェントは、誰も見直さない許可リストを抱え、それがそのマシンの以降の全セッションに効きます。

**そのマシンの管理者ではない人。** インストールの許可がない、方針で禁止されている、エージェントがサインインするための外向き通信がない。このツールがワークステーションに要求するのは`sshd`とシェルだけです。

**読むものはローカル、計算はリモートという人。** 論文・ノート・手元の試し計算はMac、プロジェクトとGPUはワークステーション。1つのセッションで両方がただのパスになるので、論文を読むこととそこから出る計算を回すことが、2つのセッションと途中のコピーではなく1つの会話で済みます。

**複数のワークステーションを扱う人。** エージェントの設定1つ、セッション履歴1つ、そして`afws-peers`が全ホストの全セッションを表示します。マシンごとに導入と許可ファイルを持ち、それぞれが互いから離れていく状態になりません。

**1台のマシンに複数セッションを立てる人。** 認証済み接続を1つ共有し、JupyterLabを立てればそれも1つを共有します。`afws-lock`が2つのセッションを同じGPUから遠ざけ、Claudeセッション同士は互いが見つけたことを尋ね合えます（再調査が不要）。

副次的に得られるもの。コマンドごとではなくホストごとに1回のパスワード入力、書くときは手元のエディタと道具、そして最後のセッションが抜けた時点で自分を解放する接続。

## Installation

**1. `rclone`。** Finder/VS Codeビュー用です。`codexfws`は毎回、`claudefws`は`--view`のときに作ります。どちらのエージェントもプロジェクトに届くのにマウントを必要とはしません。macFUSEとSSHFSは、既存のSSHFSマウントを`afws-remount`で修復する場合にだけ必要です。

```zsh
rclone version
```

**2. エージェントを少なくとも1つ。** 片方でも両方でも。

```zsh
curl -fsSL https://claude.ai/install.sh | bash        # Claude Code
claude auth login

curl -fsSL https://chatgpt.com/codex/install.sh | sh  # Codex CLI
codex login
```

**3. このリポジトリ。** 置き場所は任意です。

```zsh
git clone https://github.com/ok09ra/agent-for-work-station.git ~/src/agent-for-work-station
cd ~/src/agent-for-work-station
```

**4. コマンドを `PATH` に乗せる。** どちらでも動きます。各コマンドは共有ライブラリを自分からの相対位置で見つけます。

*clone を指す* — コピーを作らず、`git pull` だけで更新されます。

```zsh
echo 'export PATH="$HOME/src/agent-for-work-station/bin:$PATH"' >> ~/.zprofile
exec zsh -l
```

*またはコピーを入れる* — `~/.local/bin` へ、ライブラリはその隣の `~/.local/lib` へ。

```zsh
./scripts/install.sh
exec zsh -l
```

installer は `~/.local/bin` がログインシェルの `PATH` に無ければ追加し、何も削除しません（旧 `claudefws`／`codexfws` の導入物は一覧表示するだけ）。コピーを入れた場合は `git pull` のあとに再インストールが必要です。clone を指す方式では不要です。

**5. SSHの接続名。** `~/.ssh/config`に定義します。実値はこのリポジトリに書きません（[設定例](examples/ssh-config.example)は架空の値です）。

```
Host my-workstation
  HostName host.example.invalid
  User remote-user
  AddKeysToAgent yes
  UseKeychain yes
  ServerAliveInterval 30
  ServerAliveCountMax 6
```

パスワードをファイルに置かず、SSH鍵とmacOSのキーチェーンを使ってください。先に`ssh my-workstation`で接続名を確認します。

**6. 確認。**

```zsh
afws-doctor                  # 前提条件
afws-doctor my-workstation   # SSH設定もあわせて
```

すべての行が`[OK]`なら準備完了です。入れていないエージェントは失敗ではなく注記です。

## How to Use

**セッションを起動**します。指定するのはプロジェクトディレクトリで、リモートのホームではありません。ホームだと`~/.ssh`、保存された資格情報、他のすべてのプロジェクトが、セッションの操作が届く範囲に入ります。

```zsh
claudefws my-workstation /remote/path/to/project
```

引数を省略すると両方を対話的に尋ねるので、シェル履歴に残りません。パスワードやパスフレーズを聞かれるのは、ここでの1回だけです。

**別の端末から操作する。** `claudefws`の対話画面では`/remote-control`（または`/rc`）で今の会話をリモート操作できます。もう一度入力すると状態確認と切断ができます。`codexfws`では、Codexにオン・オフを頼むか、セッション内で次を実行します。

```zsh
afws-remote on       # このMacの共有Codex app-serverで有効化（自分のシェルで実行）
afws-remote status   # 接続状態を確認
afws-remote pair     # 信頼する端末のペアリングコードを表示（自分のシェルで実行）
afws-remote off      # リモート操作だけ無効化
```

Codex側のオン・オフはこのMacの他のCodexセッションにも効き、セッション終了後も残ります。開いているCLI会話は端末側でロックされる場合があり、有効化だけではその会話を引き継げません。詳しくは[使い方](docs/usage.ja.md)を参照してください。

**ワークステーションで実行する。** セッション内では接続名とディレクトリが環境変数に入るので、`afws-run`はコマンドをそのまま取ります。

```zsh
afws-run nvidia-smi
afws-run python train.py
afws-run sh -c 'nvidia-smi | wc -l'           # シェル構文にはリモートシェルが必要
printf 'set -eu\npytest -q\n' | afws-run     # スクリプトまるごと
```

プロジェクトへの経路も同じです。読み取り・検索・編集・ファイル操作・Gitはすべて`afws-run`を通り、リモートのプロジェクトディレクトリで始まります。エージェントはワークステーション上のツリーをそのまま見るので、遅延したりsymlinkを落としたり死んだりするファイルシステム層を挟みません。Mac側のセッションの作業ディレクトリは空のcontrol workspaceで、これがエージェントのファイルツールを古いローカルコピーから遠ざける仕組みです。ローカル資料も使う場合は、起動時に許可してから転送できます。

```zsh
codexfws --allow-local-files ~/Documents/input my-workstation /remote/project
afws-push ~/Documents/input data   # /remote/project/data/input へ直接転送
codexfws --resume my-workstation /remote/project  # 過去のCodexセッションを再開
```

許可していないローカルパスと、リモートプロジェクト外への転送は拒否されます。

これは**自分で打つとき**に効きます。Claude Codeの`!`はMacで動くので、`!nvidia-smi`はここで失敗し、`!python train.py`は黙って間違ったインタプリタで動きます。`claudefws`のセッションはローカル実行に`[local]`の印を付けて可視化し、違いは`afws-run`を前に置くかどうかだけです。

```
!nvidia-smi           → [local] command not found
!afws-run nvidia-smi  → ワークステーションのGPU
```

セッション外では接続名とディレクトリを指定します。
`afws-run my-workstation --cwd /remote/path -- nvidia-smi`

**プロジェクトを読む — 図、ノートブック、整形されたMarkdown。** `afws-lab`はワークステーション上の専用`tmux`セッションでJupyterLabを起動し、このMacへ転送します。

```zsh
afws-lab            # 起動する。既に動いていれば修復して再利用する
afws-lab status     # どの層が健全か、そうでない層をどうすべきか
afws-lab open       # ブラウザで開く
afws-lab stop
```

サーバがワークステーション上で動くので、本物のツリーを読みます。symlinkは解決され、画像やPDFは描画され、マウントが遅かろうと無かろうと関係ありません。同じホスト・同じディレクトリのセッションで1つを共有し、最後の1つが終了した時点で解放されます。`afws-lab`は修復コマンドでもあります。各層を確認し、実際に壊れている層だけを作り直すので、接続が切れても再起動ではなく再接続で済みます。

**Finder や VS Code でツリーを眺める。** `codexfws`は毎回rclone NFSビューを作り、`claudefws`は`--view`で同じものを付けます。`rclone`が表現できないネイティブのsymlinkは省かれるため、作業用ではなく閲覧用です。

```zsh
claudefws --view my-workstation /remote/path/to/project
claudefws --no-view my-workstation /remote/path/to/project   # 既定と同じ
afws-view           # --view無しで始めたセッションの中から、今マウントする
afws-view status    # 場所、応答の有無、他に使っているセッション数
afws-view stop      # 解放する
afws-remount        # そのビューが応答しなくなったら修復する
```

ビューは起動時に確定する約束ではありません。`afws-view`が必要とするのはSSHホスト、リモートディレクトリ、`rclone`だけで、実行中のセッションはすべて持っています。作ったビューはセッションレジストリに記録されるので、共有も自動解放も起動時に作ったものと同じに扱われます。セッションの途中で「ローカルのアプリで開きたい」と言われたエージェントは、起動し直しを求めるのではなくこれを実行します。図・ノートブック・整形されたMarkdownを*表示*するだけならマウントは一切要りません。`afws-lab`がプロジェクトを起点にワークステーション上でJupyterLabを動かします。

**マウント無しでClaudeに構造化されたファイルツールを渡す。** `lib/afws-fs-mcp.py`はMac側で動くMCPサーバで、セッションの共有SSH接続を通してプロジェクトに届きます。`read_file`、`write_file`、`edit_file`、`list_directory`、`glob`、`grep`、`stat`を提供します。すべてのパスはリモートプロジェクト内に閉じ込められ、その検査は解決後にリモート側で行うので、symlinkで外へ出ることもできません。自動では組み込まれないので、使いたいときにClaude Codeへ指定します。

```zsh
claude --mcp-config '{"mcpServers":{"afws-fs":{"command":"python3",
  "args":["'"$HOME"'/.local/lib/afws-fs-mcp.py"]}}}'
```

`AFWS_SSH_HOST`、`AFWS_REMOTE_DIR`、`AFWS_CONTROL_PATH`を読みます。セッションが既にexport済みなので、追加の設定は要りません。

**ローカルの資料を使う** — 論文、ノート、手元の試し計算。パスを言えば済みます。

> `~/Documents/papers/method.md`を読んで、ここのパイプラインが実際にやっていることと比べて。

事前の宣言は要りません。両側ともMac上のただのパスなので、間で何かを移すのは単なる`cp`です。ファイルツールもワークスペース外の絶対パスを、内側と同じように読み・作成・編集できます。

**他に誰が作業しているかを見る。** GPUや共有ビルドディレクトリは順番に使います。

```zsh
afws-peers                  # 全セッション（両エージェント）とホスト・ディレクトリ
afws-lock acquire gpu0      # 確保する。取れなければ保持者を表示
afws-lock release gpu0
```

**他のセッションに尋ねる。** 起動ごとに名前が付き、`afws-peers`で作業内容も見えます。作業内容で相手を指定して、自然な言葉で頼めます。

> 8B学習に取り組んでいるエージェントに、データセットの準備ができたと伝えて。

セッションが相手を調べ、質問を送り、送信結果を報告します。効くのは、片方だけが持っている情報を他方が欲しいときです。どのcheckpointが最新か、なぜそのテストを無効化したのか、1時間前の失敗がどういう内容だったか、データセットの変換が終わったか。受け取った側は実際に実行・観測したことから答えます。またこの経路で届いた依頼は権限を持ちません。破壊的なことは利用者に確認するよう指示されています。

メッセージ機能自体に追加の確認はないため、セッションは頼まれなくてもpeerへ送れます（Codexのローカルサンドボックスから補助コマンドを呼ぶ際は承認を求められる場合があります）。指示で3つの場合に絞っています。あなたが依頼した、必要なロックが保持されていて保持者に尋ねたい、共有状態への操作でpeerに影響が及ぶ。送るのはファイルの中身ではなく質問か観測結果で、送ったことは事後に報告するよう指示しています。

役割を表す名前を付けられます。

```zsh
AFWS_SESSION_NAME=gpu-trainer claudefws my-workstation /remote/path/to/project
AFWS_SESSION_NAME=bug-1204    claudefws my-workstation /remote/path/to/project
```

Codexは最初のターンが始まった後、ローカルフックと`codex queue`を介して宛先になります。Claude宛ては所有者だけが読めるローカルqueueへ保存され、次のlifecycle hookで会話へ渡されます。別のMac上のセッション同士には届きません。全体像は[複数セッション](docs/sessions.ja.md)にあります。

**セッション終了後。** 他に必要としているセッションがなければ、起動したビューと接続は解放されます。対話型のClaude・Codexセッションには独立したwatchdogが付くため、launcherが強制終了・クラッシュした場合も同じ後片付けを行います。バックグラウンドClaudeセッションは、起動したビューを残します。

```zsh
afws-umount --list          # マウントと接続、それぞれの利用者数
afws-umount --orphaned      # 誰も使っていないものを解放
```

**何もせず確認する。** 接続もエージェント起動も行いません。

```zsh
claudefws --dry-run my-workstation /remote/path/to/project
afws-run my-workstation --cwd /remote/path --dry-run -- nvidia-smi
```

残りは[使い方](docs/usage.ja.md)に、環境変数の一覧も含めてあります。

**入力一式だけを子に処理させる。** `afws-isolate`は指定したMarkdown説明書、スクリプト、元データ、設定ファイルを隔離された一時Codex実行へ渡し、生成物と申し送りを新しい結果ディレクトリに返します。メインセッションは元データと説明に照らして結果を評価し、判定と根拠を保存します。既定はDocker Desktop VM内実行です。ホスト実行は`--backend host`を明示した時だけ使います。使用する方式で初回ログインが必要です。詳細は[隔離ジョブ](docs/isolated-jobs.ja.md)を参照してください。

```zsh
afws-isolate docker build
afws-isolate docker doctor
afws-isolate docker login
afws-isolate run --guide /path/to/job/instructions.md --input /path/to/job --result /path/to/docker-result
afws-isolate auth login
afws-isolate run --backend host --guide /path/to/job/instructions.md --input /path/to/job --result /path/to/host-result
```

## コマンド

| コマンド | 役割 |
| --- | --- |
| `claudefws` | リモートプロジェクト上でClaude Codeセッションを起動する（経路は`afws-run`） |
| `codexfws` | 同じことをCodex CLIで行う |
| `afws-lab` | ワークステーションでJupyterLabを動かし、ここへ転送してプロジェクトを読む |
| `afws-run` | コマンド、または標準入力のスクリプトをワークステーションで実行する |
| `afws-isolate` | 指定した入力だけで一時Codexジョブを実行し、生成物と申し送りを返す |
| `afws-peers` | このMac上の全セッションと、それぞれの担当ホスト・ディレクトリ |
| `afws-org` | プロジェクトのチーム、指揮系統、担当状態を管理・表示する |
| `afws-message` | 稼働中のClaudeまたはCodexへメッセージをキュー投入（一斉送信はCodexのみ） |
| `afws-status` | このCodexセッションの短い作業ラベルを設定 |
| `afws-lock` | リモートの排他資源を確保し、複数セッションの衝突を防ぐ |
| `afws-view` | プロジェクトのFinder/VS Codeビューを、いつでもマウント・確認・解放する |
| `afws-remount` | 切断されたFinder/VS Codeビュー、または旧来のSSHFSマウントを同じ場所へ張り直す |
| `afws-umount` | 残されたマウントや接続を解放する |
| `afws-doctor` | 前提条件を確認する |
| `afws-shell` | ローカル実行に`[local]`の印を付ける。`claudefws`が使うもので、手で実行しない |

配管は共通です。`afws-run`はエージェントごとに分かれておらず1つだけで、`afws-peers`は両方のセッションを一覧します。共通部分は`lib/afws-common.zsh`にあります。

## 1台のワークステーションに2つのエージェント

同じホスト・同じディレクトリのClaudeセッションとCodexセッションは、接続を1つ、JupyterLabを立てていればそれも1つ共有し、並んで表示されます。

```
SESSION                    AGENT   KIND         STATUS   SSH HOST      REMOTE DIRECTORY  ACTIVITY
fws-workstation-project-1  claude  interactive  busy     workstation   /remote/project
cx-workstation-project-1   codex   interactive  idle     workstation   /remote/project   8B学習
```

同じClaude Agent Team内では標準の`SendMessage`も使えます。独立したClaude/Codexセッションには`afws-message`を使い、Claudeは永続ローカルqueue、Codexはフックで取得したスレッドIDを経由します。差の全体は[エージェント](docs/agents.ja.md)にあります。

## このツールが不適な場合

- **細かいファイル操作の反復が主な作業。** `afws-run`は1回の呼び出しが1往復です。大きな`grep`、フルビルド、大ツリーの`git status`は1コマンドとしてリモートで走るので問題ありませんが、1行読み取りを延々繰り返すと往復がその回数だけ積み上がります。1つのリモートコマンドにまとめるか、エージェントをネイティブに動かしてください。
- **自分専用で自分が管理しているマシン。** 入れるほうが単純で、遠ざけるべき共有状態もありません。
- **モデルに渡してはいけないデータ。** マウントは何も変えません。エージェントが読んだファイルは、どこで動いていてもモデルに渡ります。
- **ワークステーション上でエージェントにできることを制限したい場合。** `afws-run`はSSHユーザーとしての無制限なリモートシェルなので、マウントが限定するのは利便性であって権限ではありません。その境界はワークステーション側の`authorized_keys`に、専用鍵と強制コマンドとして置くものです。このリポジトリは設定しません。
- **macOS以外のクライアント。**

## リスクのある操作

エージェントはあなたのSSHユーザーとして動くので、どれもアカウントを超える権限を与えません。変わるのは、**そのどれだけが、どれだけの時間、どれだけ容易に、間違いの届く範囲に入るか**です。

| 操作 | なぜ問題か | 代わりに |
| --- | --- | --- |
| ホームディレクトリでセッションを起動する | `~/.ssh`、資格情報、他のすべてのプロジェクトが、セッションの操作が届く範囲に入る。`--view`を付けるとそこの`.claude/settings.json`がこのセッションのプロジェクト設定になる | ホームではなくプロジェクトディレクトリを指定する |
| `afws-run`にスクリプトを流す、`afws-run sh -c …` | SSHユーザーとしての無制限なリモートシェル。`--cwd`は開始位置でありサンドボックスではない | 承認前に確認する。名前付きコマンド1つを優先する |
| 共有接続を開いたまま放置する | 認証済みの経路を同ユーザーの任意プロセスが再利用できる。launcherとwatchdogが両方とも接続を閉じる前に停止する可能性がある | `AFWS_CONTROL_PERSIST`秒（600）で失効。`afws-umount --orphaned`が未使用のものを閉じる |
| `AFWS_PERMISSION_MODE=bypassPermissions` | すべての書き込みがリモートへ届き、ローカルだけで済む影響範囲が存在しない | 機密作業では`manual`か`plan` |
| コマンド末尾より前に`*`がある`allow`ルール | `*`は空白をまたぐため差し込まれたオプションも承認される。`;`やパイプを含むルールは複合コマンドごと承認する | 正確な値を書く、または`*`はサブコマンドより後だけに置く |
| 外部に出せないデータを読ませる | エージェントが読んだファイルはモデルに渡る | マウントしない |
| `afws-lock steal` | 他者が保持しているロックを奪う。2つのジョブが1つのGPUに乗る原因 | 保持者に確認する。数時間の保持は正常 |
| `afws-remount --force` | タイムアウトは低速な正常マウントかもしれず、交換すると利用中のセッションを中断する | 先にprobe時間を延ばす。生存セッションが複数なら明示的な`--force-shared`も必要 |
| `afws-lab --force` | 状態を判定できなかった層は正常かもしれず、作り直すとJupyterLabが再起動して実行中のカーネルが落ちる | 先に`afws-lab status`で、実際に到達できない層を確認する |
| `afws-umount --force` | 他のセッションが書き込み中かもしれないマウントを強制的に外す | 先に`afws-umount --list`で確認する |
| 権限の大きいアカウントで接続する | パスワードなしsudo、コンテナランタイムのグループ、group-writableな共有データは、壊せる範囲を広げる | 最小権限のアカウントを使う。`id`を確認する |
| ワークステーション側にもエージェントを入れる | 許可ルールとバージョンが2系統に分かれ、誰も読まない側が育つ | `afws-doctor HOST`が検出する |
| `claude mcp serve`でClaude Desktopと橋を架ける | Desktopの会話からMac上の任意のシェル実行を渡すことになり、このツールの範囲限定も後片付けも効かない | セッション内でローカルパスを言うだけにする |
| セッションが自発的に peer へメッセージを送る | 承認ステップがない。相手は割り込まれ、書いた内容が相手の文脈に入り、相手の予算を消費する | 指示で3つの場合に限定（依頼された、保持中のロックの保持者に尋ねる、共有状態への操作を予告する）。送ったことを利用者に報告させる |
| 実値をこのリポジトリにコミットする | 接続名やリモートパスは秘密ではないが、ここに置くものではない | `./scripts/prepublish-check.sh`と`git diff --cached`の確認 |

この構成が守るもの・守らないもの、そして成立する境界がワークステーション側にあることは[セキュリティ](docs/security.ja.md)にあります。

## ドキュメント

| 内容 | 日本語 | English |
| --- | --- | --- |
| エージェントごとの違い | [エージェント](docs/agents.ja.md) | [Agents](docs/agents.md) |
| macOSへの導入 | [macOSセットアップ](docs/install-macos.ja.md) | [Install on macOS](docs/install-macos.md) |
| 使用方法 | [使い方](docs/usage.ja.md) | [Usage](docs/usage.md) |
| 複数セッション | [複数セッション](docs/sessions.ja.md) | [Multiple sessions](docs/sessions.md) |
| セキュリティ | [セキュリティ](docs/security.ja.md) | [Security](docs/security.md) |
| 問題解決 | [トラブルシューティング](docs/troubleshooting.ja.md) | [Troubleshooting](docs/troubleshooting.md) |

## 旧 claudefws / codexfws から移る場合

このリポジトリは2つの旧リポジトリを置き換えます。名前が変わり、互換エイリアスはありません。`claudefws-run`と`codexfws-run`は`afws-run`、他の補助コマンドは`afws-*`、`ws-run`は廃止、`CLAUDEFWS_*`と`CODEXFWS_*`は`AFWS_*`、マウントと状態のディレクトリは`~/afws-mounts`と`~/.afws`になりました。

次の順序で移行します。installerは何も削除せず、残骸を一覧表示するだけです。

1. 稼働中のセッションを終了する（マウントと接続が解放されます）。
2. 残りを解放する。`claudefws-umount --orphaned`を実行し、`mount | grep macfuse`で`~/codexfws-mounts`配下に残っているものを`umount`する。
3. 旧コマンドを`~/.local/bin`から、`~/.claudefws`と`~/.codexfws`も削除する。
4. `./scripts/install.sh`を実行する。

## 開発

```zsh
./scripts/test.sh
./scripts/prepublish-check.sh
```

`test.sh`は使い捨てのレジストリと、マウントテーブルの代わりのテキストファイルの上で動きます。SSH接続、マウント、エージェント起動はいずれも行いません。`prepublish-check.sh`は秘密鍵、トークン形式、IPリテラル、ホームディレクトリのパス、パスワードらしき内容、統合前の旧名称の残留を検査します。

installer、doctor、testはGit remoteの追加、commit、push、release作成を行いません。

## ライセンス

[MIT](LICENSE)。利用・改変・再配布・商用利用のいずれも自由です。条件は著作権表示とライセンス本文を一緒に残すことだけです。

```
Copyright (c) 2026 Sota Okuda (ok09ra)
```
