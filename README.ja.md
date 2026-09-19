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

## Installation

macOS専用です。ワークステーション側には何もインストールしません。

**1. macFUSE と SSHFS。** [macFUSE公式サイト](https://macfuse.github.io/)から最新の安定版を、次に[macFUSE公式SSHFSページ](https://github.com/macfuse/macfuse/wiki/File-Systems-%E2%80%90-SSHFS)からmacOS用SSHFSパッケージを導入します。macOSがシステム設定での許可を求めた場合は公式の案内に従い、再起動を求められたら再起動します。

```zsh
command -v sshfs && sshfs --version
```

**2. エージェントを少なくとも1つ。** 使うものだけ、あるいは両方。

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

コマンド8本を`~/.local/bin`へ、共有ライブラリを`~/.local/lib`へコピーし、そのディレクトリがログインシェルの`PATH`に無ければ追加します。何も削除しません。旧`claudefws`／`codexfws`の導入物が残っている場合は、残骸として一覧表示するだけです。

**4. SSHの接続名。** ローカルの`~/.ssh/config`に定義します。[架空の設定例](examples/ssh-config.example)を雛形にしてください。実値はこのリポジトリに書きません。

```
Host my-workstation
  HostName host.example.invalid
  User remote-user
  AddKeysToAgent yes
  UseKeychain yes
  ServerAliveInterval 30
  ServerAliveCountMax 6
```

パスワードをファイルに置かず、SSH鍵とmacOSのキーチェーンを使ってください。先に接続名だけ確認します。

```zsh
ssh my-workstation
```

**5. 確認。**

```zsh
afws-doctor                  # 前提条件
afws-doctor my-workstation   # SSH設定もあわせて
```

すべての行が`[OK]`になれば準備完了です。`afws-doctor`はどちらのランチャーが使えるかも報告するので、入れていないエージェントは失敗ではなく注記として扱われます。

## How to Use

**セッションを起動**します。指定するのはホームではなくプロジェクトディレクトリです（ホームに見える場合はランチャーが警告します）。

```zsh
claudefws my-workstation /remote/path/to/project   # Claude Code
codexfws  my-workstation /remote/path/to/project   # Codex CLI
```

引数を省略すると2つの値を対話的に尋ねるので、シェル履歴に残りません。パスワードや鍵のパスフレーズを聞かれるのは、ここでの1回だけです。

**ローカルの資料を持ち込む** — 論文、ノート、手元の試し計算。普通はセッションに入ってから言えば済みます。

> `~/Documents/papers`のノートを読んで、ここのパイプラインが実際にやっていることと比べて。

事前の宣言は要りません。リモートのプロジェクトもローカルのディレクトリも**Mac上のただのパス**であり、シェルコマンドはワークスペースに限定されず、Claude Codeはファイルツール用に`/add-dir`をセッション中に受け付けます。両側の間で何かを移すのは単なる`cp`です。

`AFWS_ADD_DIR`は、それが毎回になって面倒なとき、あるいはエージェントがローカルのディレクトリに**書き込む**必要があるときのためのものです。

```zsh
AFWS_ADD_DIR=~/Documents/papers:~/Documents/notes \
  claudefws my-workstation /remote/path/to/project
```

`codexfws`では、ワークスペース外へ書き込む唯一の手段になります。Codexのサンドボックスはセッション開始時に決まるためです。

**ワークステーションで何かを実行する。** セッション内では接続名とディレクトリが環境変数から入ります。

```zsh
afws-run -- nvidia-smi
afws-run -- python train.py
afws-run -- sh -c 'ls *.log | wc -l'     # シェル構文にはリモートシェルが必要
printf 'set -eu\npytest -q\n' | afws-run   # スクリプトまるごと
```

Claude Codeの`!`はワークステーションではなく**Macで**実行されます。`claudefws`のセッションはそれに`[mac]`の印を付けて可視化します。ワークステーションで動かすつもりだったなら`afws-run --`を前に付けてください。

**他に誰が作業しているかを見る。** GPUや共有ビルドディレクトリは順番に使います。

```zsh
afws-peers                  # 全セッション（両エージェント）とホスト・ディレクトリ
afws-lock acquire gpu0      # 確保する。取れなければ保持者を表示
afws-lock release gpu0
```

**セッションを終了**すると、他に使っているセッションがなければマウントと共有SSH接続が解放されます。バックグラウンドセッションや強制終了されたセッションはマウントを残します。

```zsh
afws-umount --list          # マウントと接続、それぞれの利用者数
afws-umount --orphaned      # 誰も使っていないものを解放
```

**何もせずに確認する。** マウントも接続もエージェント起動も行いません。

```zsh
claudefws --dry-run my-workstation /remote/path/to/project
afws-run my-workstation --cwd /remote/path --dry-run -- nvidia-smi
```

残りは[使い方](docs/usage.ja.md)に、環境変数の一覧も含めてあります。

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

## 向いている使い方

**エージェントを入れたくないワークステーション。** 共有マシン、機密データを持つマシン、自分が管理者でないマシン。エージェントの認証情報・許可ルール・履歴はMac側に留まり、ワークステーションには何も蓄積しません。半年かけて育つ許可リストも、終了したセッションが残した常駐プロセスも発生しません。

**ローカルの資料とリモートの計算を1つのセッションで。** 論文とノートはMac、プロジェクトとGPUはワークステーション。`AFWS_ADD_DIR`でローカルのディレクトリを同じセッションに入れられるので、論文を読むこととそこから出てくる計算を回すことが、2つのセッションと手作業のコピーではなく1つの会話で済みます。

**複数のワークステーションを1か所から。** Mac 1台、設定1つ、履歴1つ。`afws-peers`が全ホストの全セッションを一覧します。

**1台のワークステーションに複数セッション。** マウントと認証済み接続を1つずつ共有し、GPUや共有ビルドディレクトリは`afws-lock`で直列化され、Claudeセッション同士は互いに見つけたことを尋ね合えます。

**そもそもインストールできないマシン。** 許可がない、エージェントがサインインするための外向き通信がない、方針で禁止されている。

**手元の道具で書く。** エディタ、Python環境、IDE連携はローカルのまま。リモート環境を必要とする部分だけを送ります。

## 向いていない使い方

**ファイル操作が主な作業。** SSHFSは操作ごとにネットワークを往復するため、大きな`grep`、フルビルド、大きなツリーでの`git status`はマシン上で直接動かすより遅くなります。そういうものは`afws-run`経由で送るか、エージェントをネイティブに動かしてください。

**自分専用で自分が管理しているマシン。** そこにエージェントを入れるほうが単純で速く、共有マシンから遠ざけるべき状態もありません。

**モデルに渡してはいけないデータ。** マウントは何も変えません。エージェントが読んだファイルは、エージェントがどこで動いていてもモデルに渡ります。答えはマウントしないことです。

**ワークステーション上でエージェントにできることを制限したい場合。** `afws-run`はSSHユーザーとしての無制限なリモートシェルなので、マウントが限定するのは利便性であって権限ではありません。その境界はワークステーション側の`authorized_keys`に、エージェント専用鍵と強制コマンドとして置くものです。このリポジトリはその設定を行いません。何が成立し何が成立しないかは[セキュリティ](docs/security.ja.md)に書いてあります。

**macOS以外のクライアント。**

## リスクのある操作

エージェントはワークステーション上であなたのSSHユーザーとして動くので、ここに挙げたどれもあなたのアカウントを超える権限を与えるものではありません。変わるのは、**アカウントのどれだけが、どれだけの時間、どれだけ容易に、間違いの届く範囲に入るか**です。

| 操作 | なぜ問題か | 代わりに |
| --- | --- | --- |
| ホームディレクトリをマウントする | `~/.ssh`、保存された資格情報、他のすべてのプロジェクトがワークスペースの中に入る。そこの`.claude/settings.json`はこのセッションのプロジェクト設定になる | プロジェクトディレクトリをマウントする。ホームに見える場合はランチャーが警告する |
| `afws-run`にスクリプトを流す、`afws-run -- sh -c …` | SSHユーザーとしての無制限なリモートシェル。`--cwd`は開始位置でありサンドボックスではない | 承認前に内容を確認する。可能ならスクリプトより名前付きコマンド1つを選ぶ |
| 共有SSH接続を開いたまま放置する | 認証済みの経路で、同ユーザーの任意プロセスがパスワードなしで再利用できる。`SIGKILL`で終了したセッションは閉じられない | `AFWS_CONTROL_PERSIST`秒（既定600）で失効する。`afws-umount --orphaned`が未使用のものを閉じ、`afws-doctor`が検出する |
| `AFWS_PERMISSION_MODE=bypassPermissions` | セッション内のすべての書き込みがリモートへ届くため、ローカルだけで済む影響範囲が存在しない | 機密作業では`manual`か`plan`。既定は`auto` |
| コマンド末尾より前に`*`がある`allow`ルール | `*`は空白をまたぐため、その位置に差し込まれたオプションまで承認される。`;`やパイプを含むルールは複合コマンドごと承認する | 正確な値を書く、または`*`はサブコマンドより後だけに置く。複合コマンドは許可リストに入れない |
| `AFWS_ADD_DIR`に機密ディレクトリを指定する | そのディレクトリはセッションから読め（Codexでは書け）、読んだものはモデルにも渡る | 参照する特定のディレクトリだけを指定する。`~`、`~/.ssh`、`~/Library`は不可 |
| 外部に出せないデータを読ませる | マウントは何も変えない。エージェントが読んだファイルはモデルに渡る | マウントしない |
| `afws-lock steal` | 他者が保持しているロックを奪う。2つのジョブが1つのGPUに乗る原因 | 先に保持者へ確認する。長時間ジョブでロックが数時間保持されるのは正常 |
| `afws-umount --force` | 他のセッションが書き込んでいるかもしれないマウントに`diskutil unmount force`をかける | 先に`afws-umount --list`で確認し、保持者が本当に居ない場合だけ強制する |
| 権限の大きいリモートアカウントで接続する | パスワードなしsudo、コンテナランタイムのグループ、group-writableな共有データは、間違いが壊せる範囲を広げる。`id`と共有パスの権限を確認する | 必要最小限の権限のアカウントを使う |
| ワークステーション側にもエージェントを入れる | 許可ルールとバージョンが2系統に分かれ、誰も見ない側が育つ | 接続がある状態で`afws-doctor HOST`が検出する |
| `claude mcp serve`でClaude Desktopと橋を架ける | Desktopの会話からMac上の任意のシェル実行を渡すことになり、このツールの範囲限定・可視化・後片付けはいずれも効かない | 代わりに`AFWS_ADD_DIR`でローカルディレクトリをセッションに入れる |
| 実値をこのリポジトリにコミットする | 接続名、アドレス、ユーザー名、リモートパスは秘密ではないが、ここに置くものではない | `./scripts/prepublish-check.sh`と`git diff --cached`の確認 |

この構成が守るもの・守らないもの、そして実際に成立する境界がワークステーション側の`authorized_keys`にあることは[セキュリティ](docs/security.ja.md)に書いてあります。

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
