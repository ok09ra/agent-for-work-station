# 複数セッション

[English](sessions.md) · [README](../README.ja.md)

1台のワークステーションでは、長時間の学習ジョブ、再現中のバグ、レビュー中のリファクタリングなど、複数の作業が同時に進むのが普通です。同じMac上で動いているClaude Codeのセッションは互いを認識し、メッセージを交換できます。そのため、これらの作業を1つのセッションで切り替えるのではなく、協調する別々のセッションとして進められます。

このページでは、その仕組みに対して`claudefws`が何を追加するのか、どう使うのかを説明します。

## 2方向の連携

| 知りたいこと | 手段 |
| --- | --- |
| 他に誰がいて、何を担当しているか | `claudefws-peers`（シェルコマンド） |
| そのセッションと話したい | `ListAgents`と`SendMessage`（Claude Codeのツール） |
| このGPUは自分が使い終わるまで触らせたくない | `claudefws-lock`（シェルコマンド） |

`ListAgents`は、このMac上のClaudeセッションと、それぞれが応答する名前を返します。`claudefws-peers`は、その名前がどのSSH接続先のどのリモートディレクトリを担当しているかを返します。通常は両方が必要です。前者は宛先を指定するため、後者はどのセッションを宛先にすべきか判断するためです。

## 2つ目のセッションを起動する

別のターミナルで、同じ接続先・ディレクトリ、あるいは別のものを指定してlauncherを再度実行します。

```zsh
claudefws SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY
```

起動ごとに`fws-HOST-PROJECT-N`形式の未使用の名前が割り当てられます。1つ目が`fws-HOST-PROJECT-1`、2つ目が`fws-HOST-PROJECT-2`という具合です。launcherは選んだ名前を表示し、セッション自身にもその名前を伝えます。これにより、返信先の名前を相手へ伝えられます。

番号よりも役割を表す名前が適切な場合は、次のように指定します。

```zsh
CLAUDEFWS_SESSION_NAME=gpu-trainer claudefws SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY
CLAUDEFWS_SESSION_NAME=bug-1204 claudefws SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY
```

同じ接続先・同じディレクトリの2つのセッションは、1つのSSHFSマウントを共有します。2つ目の起動は、マウントし直さずに1つ目が作成したマウントを再利用します。

## 各セッションのワークスペースの場所

マウントポイントは、接続名とリモートの絶対パスから決まります。

```
~/claudefws-mounts/HOST/REMOTE/PATH
```

そのため2つのセッションは自動的に分離されます。接続先が違えば別のツリーになり、同じ接続先でも別のディレクトリなら別のマウントポイントになります。知っておく価値があるのは次の3ケースです。

| 2つ目のセッションが指定したディレクトリ | 動作 |
| --- | --- |
| すでにマウント済みのディレクトリの**サブディレクトリ** | 既存のマウントを再利用し、ワークスペースをその中に向けます。2つ目のSSHFSマウントもSSH接続も作りません。 |
| **兄弟**ディレクトリ | 別のマウントを作ります。SSH接続はそのホストへの共有接続を使います。 |
| すでにマウント済みのディレクトリの**親** | 拒否します。そこへマウントすると既存のマウントが隠れ、相手セッションのワークスペースが新しいマウント経由で解決され始めるためです。深い側のディレクトリで起動するか、先にアンマウントしてください。 |

共有されたマウントは、最後に抜けたセッションが解放します。同じマウント内で他のセッションがまだ作業している状態で終了したセッションは、マウントを残し、そのことを表示します。バックグラウンドセッションは後片付けを行うlauncherプロセスが残らないため、マウントをそのまま残します。それらは`claudefws-umount --orphaned`で解放できます。

一方でロックは、ディレクトリ単位ではなく**ホスト単位**です。ロックディレクトリはリモートユーザーのホーム配下にあります。これは意図的な設計です。GPUは、各セッションがどのプロジェクトディレクトリで作業していようと、そのワークステーション上の全セッションで共有される資源だからです。同時に、`build`のような一般的な名前は同一ホスト上の無関係なプロジェクト間で衝突します。動作ではなく資源に名前を付けてください（`build-projectX`など）。

## 他のセッションを確認する

```zsh
claudefws-peers
```

```
SESSION                      KIND         STATUS   SSH HOST           REMOTE DIRECTORY
gpu-trainer                  interactive  busy     example-workstation /remote/project
fws-example-workstation-project-2  interactive  idle  example-workstation /remote/project
nightly-watch                background   idle     example-workstation /remote/project
```

`STATUS`はClaude Code自身が報告する値です。`busy`、`idle`、`waiting`から、そのセッションが作業中なのか、空いているのか、利用者の応答を待っているのかが分かります。終了したセッションは、これらのコマンドを次に実行した時点で一覧から取り除かれます。

複数のワークステーションやプロジェクトが関係する場合は、一覧を絞り込みます。

```zsh
claudefws-peers --host SSH_CONFIG_HOST   # 特定のワークステーションだけ
claudefws-peers --same                   # まったく同じリモートディレクトリのセッションだけ
claudefws-peers --json                   # 機械可読
```

## 他のセッションと話す

メッセージ送信はシェルコマンドではなく、Claudeが行います。セッション内で普通に依頼してください。

> `claudefws-peers`を確認して、`gpu-trainer`に8Bの学習が終わったか、最終lossがいくらだったかを聞いてください。

セッションは`ListAgents`で名前を確認し、`SendMessage`で質問を送り、返答を報告します。受け取った側は、そのメッセージで割り込まれ、実際に実行・観測した内容に基づいて回答し、自分の作業へ戻ります。

これが有効なのは、一方のセッションだけが持っている情報を他方が知りたい場合です。どのcheckpointが最新か、なぜそのテストを無効化したのか、1時間前の失敗がどのような内容だったか、データセットの変換が終わったか、といった情報です。

## 排他資源を順番に使う

1台のワークステーション上の2つのセッションは、いずれ同じGPU、同じビルドディレクトリ、同じデータセットを使いたくなります。`claudefws-lock`はそれを明示的に扱います。

```zsh
claudefws-lock acquire gpu0        # 確保する。取得できない場合は終了コード3で保持者を表示
claudefws-lock status              # この接続先のすべてのロック
claudefws-lock status gpu0         # 特定のロック
claudefws-lock release gpu0        # 解放できるのは保持者だけ
```

ロックは、リモート側の`~/.claudefws-locks`配下に原子的に作成されるディレクトリです。常駐プロセスを必要とせず、そのワークステーション上のすべてのセッションから見え、プロジェクトツリーの中には何も書き込みません。保持者はセッション名として記録されます。これは、メッセージの宛先に使える名前と同じものです。

```
held gpu0 holder=gpu-trainer since=2026-01-01T09:12:44Z age=318s ttl=7200s
```

すぐに失敗させず、ロックが空くまで待つこともできます。

```zsh
claudefws-lock acquire gpu0 --wait 600
```

TTLを超えたロックは`stale`と表示しますが、自動的に解放はしません。長時間ジョブでロックが数時間保持されるのは正常な状態だからです。保持中のロックを奪うのは、常に明示的な操作です。

```zsh
claudefws-lock steal gpu0
```

その前に保持者へ確認してください。そのためのメッセージ機能です。セッションには、利用者の指示がない限りロックを奪わないよう指示しています。

ロック名は自由に決められます。`gpu0`、`build`、`dataset-convert`、`migrations`などが適切です。ロックは同じ名前を使うセッション同士でしか機能しないため、その資源を取り合うすべてのセッションで同じ名前を使ってください。

## バックグラウンドセッション

何かを監視するだけのセッションに、ターミナルは必要ありません。

```zsh
claudefws --bg SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY \
  "claudefws-runで学習ジョブを監視してください。失敗を報告し、質問されたら進捗を要約してください。"
```

launcherは、Claude Codeがそのセッションに使う識別子を表示します。

```zsh
claude agents          # バックグラウンドと対話セッションの一覧
claude attach ID       # このターミナルで開く
claude logs ID         # 直近の出力を表示
claude stop ID         # 会話を保持したまま停止
claude rm ID           # 停止済みセッションを削除
```

バックグラウンドセッションも他と同様に`claudefws-peers`へ表示され、名前を指定してメッセージを送れます。これが要点です。対話セッションは、自分でログを読み直す代わりに、監視役へ何が起きたかを尋ねられます。

## 具体例

1台のワークステーションに対する3つのセッションです。

```zsh
CLAUDEFWS_SESSION_NAME=gpu-trainer claudefws workstation /remote/project
CLAUDEFWS_SESSION_NAME=bug-1204 claudefws workstation /remote/project
claudefws --bg workstation /remote/project "キューを監視し、失敗を報告してください。"
```

- `gpu-trainer`は`claudefws-lock acquire gpu0`でGPUを確保し、`claudefws-run`経由で学習を開始し、終わるまでロックを保持します。
- `bug-1204`はGPU上でクラッシュを再現したいものの、ロックが`gpu-trainer`に保持されていることを見つけ、`SendMessage`で残り時間を尋ねます。その間はCPUだけで進められる部分を進めるか、`claudefws-lock acquire gpu0 --wait 1800`で待ちます。
- バックグラウンドセッションは失敗したジョブを検知し、直近のエラー内容を他のどちらのセッションからも尋ねられます。

どのセッションも他のセッションの動きを推測する必要がなく、GPUを同時に使うことも起きません。

## 境界

- レジストリとセッション間メッセージは、1台のMac内に限られます。同じワークステーションを共有していても、別のMac上の2つのセッションはこのツールでは相互に見えません。それを実現する仕組みはClaude CodeのRemote Controlであり、`claudefws`の対象範囲外です。
- ロックが調整できるのは`claudefws-lock`を使うセッションの間だけです。ワークステーション上の他の人、他のツール、スケジューラーが同じ資源を使うことは防げません。
- セッションはリモートのファイルシステムを共有します。同じマウント越しに同じファイルを編集する2つのセッションは互いの変更を上書きします。そのためのメッセージ機能です。
