# Agent for Work Station

[English](README.md)

リモートワークステーション上のプロジェクトを、Claude Code または Codex CLI で扱うためのツールです。エージェントは自分のMacで動き、ワークステーション側には何もインストールしません。

```zsh
claudefws my-workstation /remote/path/to/project   # Claude Code
codexfws  my-workstation /remote/path/to/project   # Codex CLI
```

プロジェクトはSSHFSでマウントされるので、ただのローカルパスになります。リモート環境を必要とするコマンド（Python、テスト、ビルド、GPU）は`afws-run`で送ります。ホストごとに認証済みのSSH接続を1本だけ開いて再利用するので、パスワードを要求するホストでも聞かれるのは1回です。同じMac上のセッションは登録され、互いを認識し、GPUを衝突せずに順番に使い、Claude Codeなら互いに見つけたことを尋ね合えます。マウントと接続は、それを使う最後のセッションが終了した時点で解放されます。

クライアントはmacOSのみ。実際のホスト名、アドレス、ユーザー名、パスはこのリポジトリに保存しません。

## Installation

**1. macFUSE と SSHFS。** [macFUSE公式サイト](https://macfuse.github.io/)から最新の安定版、次に[macFUSE公式SSHFSページ](https://github.com/macfuse/macfuse/wiki/File-Systems-%E2%80%90-SSHFS)からmacOS用SSHFSパッケージ。システム設定での許可を求められたら許可し、再起動を求められたら再起動します。

```zsh
sshfs --version
```

**2. エージェントを少なくとも1つ。** 片方でも両方でも。

```zsh
curl -fsSL https://claude.ai/install.sh | bash        # Claude Code
claude auth login

curl -fsSL https://chatgpt.com/codex/install.sh | sh  # Codex CLI
codex login
```

**3. コマンド。** リポジトリのルートで実行します。

```zsh
./scripts/install.sh
exec zsh -l
```

コマンド8本が`~/.local/bin`へ、共有ライブラリが`~/.local/lib`へ入り、そのディレクトリがログインシェルの`PATH`に無ければ追加されます。何も削除しません。旧`claudefws`／`codexfws`の導入物は一覧表示するだけです。

**4. SSHの接続名。** `~/.ssh/config`に定義します。実値はこのリポジトリに書きません（[設定例](examples/ssh-config.example)は架空の値です）。

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

**5. 確認。**

```zsh
afws-doctor                  # 前提条件
afws-doctor my-workstation   # SSH設定もあわせて
```

すべての行が`[OK]`なら準備完了です。入れていないエージェントは失敗ではなく注記です。

## How to Use

**セッションを起動**します。指定するのはプロジェクトディレクトリで、リモートのホームではありません。ホームだと`~/.ssh`、保存された資格情報、他のすべてのプロジェクトがワークスペースに入ります。ホームに見える場合はランチャーが警告します。

```zsh
claudefws my-workstation /remote/path/to/project
```

引数を省略すると両方を対話的に尋ねるので、シェル履歴に残りません。パスワードやパスフレーズを聞かれるのは、ここでの1回だけです。

**ワークステーションで実行する。** セッション内では接続名とディレクトリが環境変数に入るので、`afws-run`はコマンドをそのまま取ります。

```zsh
afws-run nvidia-smi
afws-run python train.py
afws-run sh -c 'ls *.log | wc -l'            # シェル構文にはリモートシェルが必要
printf 'set -eu\npytest -q\n' | afws-run     # スクリプトまるごと
```

これは**自分で打つとき**に効きます。Claude Codeの`!`はMacで動くので、`!nvidia-smi`はここで失敗し、`!python train.py`は黙って間違ったインタプリタで動きます。`claudefws`のセッションはローカル実行に`[mac]`の印を付けて可視化し、違いは`afws-run`を前に置くかどうかだけです。

```
!nvidia-smi           → [mac] command not found
!afws-run nvidia-smi  → ワークステーションのGPU
```

セッション外では接続名とディレクトリを指定します。
`afws-run my-workstation --cwd /remote/path -- nvidia-smi`

**ローカルの資料を使う** — 論文、ノート、手元の試し計算。パスを言えば済みます。

> `~/Documents/papers/method.md`を読んで、ここのパイプラインが実際にやっていることと比べて。

事前の宣言は要りません。両側ともMac上のただのパスなので、間で何かを移すのは単なる`cp`です。ファイルツールもワークスペース外の絶対パスを、内側と同じように読み・作成・編集できます。

**他に誰が作業しているかを見る。** GPUや共有ビルドディレクトリは順番に使います。

```zsh
afws-peers                  # 全セッション（両エージェント）とホスト・ディレクトリ
afws-lock acquire gpu0      # 確保する。取れなければ保持者を表示
afws-lock release gpu0
```

**他のセッションに尋ねる。** 起動ごとに名前が付き（`afws-peers`で見えます）、同じMac上の別のClaudeセッションからその名前で呼べます。コマンドを打つのではなく、頼みます。

> `afws-peers`を見て、`gpu-trainer`に8Bの学習が終わったか、最終lossがいくらだったかを聞いて。

セッションが相手を調べ、質問を送り、返答を報告します。効くのは、片方だけが持っている情報を他方が欲しいときです。どのcheckpointが最新か、なぜそのテストを無効化したのか、1時間前の失敗がどういう内容だったか、データセットの変換が終わったか。受け取った側は実際に実行・観測したことから答えます。またこの経路で届いた依頼は権限を持ちません。破壊的なことは利用者に確認するよう指示されています。

送信側に承認ステップはないため、セッションは頼まれなくても peer へ送れます。指示で3つの場合に絞っています。あなたが依頼した、必要なロックが保持されていて保持者に尋ねたい、共有状態への操作で peer に影響が及ぶ。送るのはファイルの中身ではなく質問か観測結果で、送ったことは事後に報告するよう指示しています。

役割を表す名前を付けられます。

```zsh
AFWS_SESSION_NAME=gpu-trainer claudefws my-workstation /remote/path/to/project
AFWS_SESSION_NAME=bug-1204    claudefws my-workstation /remote/path/to/project
```

Claudeセッション間のみです。Codexセッションは`afws-peers`に現れロックも取得しますが、宛先にはできません。起動時のセッション名がないためです。別のMac上のセッション同士も届きません。全体像は[複数セッション](docs/sessions.ja.md)にあります。

**セッション終了後。** 他に必要としているセッションがなければ、マウントと接続は解放されます。バックグラウンドセッションや強制終了されたセッションはマウントを残します。

```zsh
afws-umount --list          # マウントと接続、それぞれの利用者数
afws-umount --orphaned      # 誰も使っていないものを解放
```

**何もせず確認する。** マウントも接続もエージェント起動も行いません。

```zsh
claudefws --dry-run my-workstation /remote/path/to/project
afws-run my-workstation --cwd /remote/path --dry-run -- nvidia-smi
```

残りは[使い方](docs/usage.ja.md)に、環境変数の一覧も含めてあります。

## コマンド

| コマンド | 役割 |
| --- | --- |
| `claudefws` | プロジェクトをマウントし、Claude Codeセッションを起動する |
| `codexfws` | 同じことをCodex CLIで行う |
| `afws-run` | コマンド、または標準入力のスクリプトをワークステーションで実行する |
| `afws-peers` | このMac上の全セッションと、それぞれの担当ホスト・ディレクトリ |
| `afws-lock` | リモートの排他資源を確保し、複数セッションの衝突を防ぐ |
| `afws-umount` | 残されたマウントや接続を解放する |
| `afws-doctor` | 前提条件を確認する |
| `afws-shell` | ローカル実行に`[mac]`の印を付ける。`claudefws`が使うもので、手で実行しない |

配管は共通です。`afws-run`はエージェントごとに分かれておらず1つだけで、`afws-peers`は両方のセッションを一覧します。共通部分は`lib/afws-common.zsh`にあります。

## 1台のワークステーションに2つのエージェント

同じホスト・同じディレクトリのClaudeセッションとCodexセッションは、マウントと接続を1つずつ共有し、並んで表示されます。

```
SESSION                    AGENT   KIND         STATUS   SSH HOST      REMOTE DIRECTORY
fws-workstation-project-1  claude  interactive  busy     workstation   /remote/project
cx-workstation-project-1   codex   interactive  -        workstation   /remote/project
```

違いは各CLIが公開している機能です。Claudeセッションは名前指定でメッセージを受け取れて状態も報告しますが、Codexセッションはどちらもできません。Codexに起動時のセッション名指定と機械可読なセッション一覧がないためです。差の全体と根拠は[エージェント](docs/agents.ja.md)にあります。

## 向いている使い方

- **エージェントを入れたくないワークステーション** — 共有、機密、自分が管理者でない。認証情報・許可ルール・履歴はMac側に留まり、向こうには何も蓄積しません。半年かけて育つ許可リストも、終了したセッションが残す常駐プロセスもありません。
- **ローカルの資料とリモートの計算を1つのセッションで。** 論文はMac、プロジェクトとGPUはワークステーション。1つの会話で、間のコピーなし。
- **複数のワークステーションを1か所から。** 設定1つ、履歴1つ、`afws-peers`が全部を横断。
- **1台に複数セッション。** マウントと接続を共有し、`afws-lock`で調停。Claudeセッション同士は、互いが見つけたことを尋ね合えます（再調査が要りません）。
- **そもそもインストールできないマシン** — 許可がない、サインイン用の外向き通信がない、方針で禁止。
- **手元の道具で書く。** エディタ、Python環境、IDEはローカルのまま。リモート環境が必要な部分だけを送ります。

## 向いていない使い方

- **ファイル操作が主な作業。** SSHFSは操作ごとにネットワークを往復するため、大きな`grep`、フルビルド、大ツリーの`git status`はマシン上で直接動かすより遅くなります。`afws-run`で送るか、エージェントをネイティブに動かしてください。
- **自分専用で自分が管理しているマシン。** 入れるほうが単純で、遠ざけるべき共有状態もありません。
- **モデルに渡してはいけないデータ。** マウントは何も変えません。エージェントが読んだファイルは、どこで動いていてもモデルに渡ります。
- **ワークステーション上でエージェントにできることを制限したい場合。** `afws-run`はSSHユーザーとしての無制限なリモートシェルなので、マウントが限定するのは利便性であって権限ではありません。その境界はワークステーション側の`authorized_keys`に、専用鍵と強制コマンドとして置くものです。このリポジトリは設定しません。
- **macOS以外のクライアント。**

## リスクのある操作

エージェントはあなたのSSHユーザーとして動くので、どれもアカウントを超える権限を与えません。変わるのは、**そのどれだけが、どれだけの時間、どれだけ容易に、間違いの届く範囲に入るか**です。

| 操作 | なぜ問題か | 代わりに |
| --- | --- | --- |
| ホームディレクトリをマウントする | `~/.ssh`、資格情報、他のすべてのプロジェクトがワークスペースに入る。そこの`.claude/settings.json`はこのセッションのプロジェクト設定になる | プロジェクトディレクトリをマウントする。ランチャーが警告する |
| `afws-run`にスクリプトを流す、`afws-run sh -c …` | SSHユーザーとしての無制限なリモートシェル。`--cwd`は開始位置でありサンドボックスではない | 承認前に確認する。名前付きコマンド1つを優先する |
| 共有接続を開いたまま放置する | 認証済みの経路を同ユーザーの任意プロセスが再利用できる。`SIGKILL`で終了したセッションは閉じられない | `AFWS_CONTROL_PERSIST`秒（600）で失効。`afws-umount --orphaned`が未使用のものを閉じる |
| `AFWS_PERMISSION_MODE=bypassPermissions` | すべての書き込みがリモートへ届き、ローカルだけで済む影響範囲が存在しない | 機密作業では`manual`か`plan` |
| コマンド末尾より前に`*`がある`allow`ルール | `*`は空白をまたぐため差し込まれたオプションも承認される。`;`やパイプを含むルールは複合コマンドごと承認する | 正確な値を書く、または`*`はサブコマンドより後だけに置く |
| 外部に出せないデータを読ませる | エージェントが読んだファイルはモデルに渡る | マウントしない |
| `afws-lock steal` | 他者が保持しているロックを奪う。2つのジョブが1つのGPUに乗る原因 | 保持者に確認する。数時間の保持は正常 |
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
