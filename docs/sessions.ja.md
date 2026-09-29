# 複数セッション

[English](sessions.md) · [README](../README.ja.md)

1台のワークステーションでは、長時間の学習ジョブ、再現中のバグ、レビュー中のリファクタリングなど、複数の作業が同時に進むのが普通です。同じMac上のClaudeとCodexは`afws-peers`で互いの作業を確認でき、どちらからどちらへも直接メッセージをqueueできます。

このページでは、ランチャーが追加する連携の仕組みと使い方を説明します。

## 2方向の連携

| 知りたいこと | 手段 |
| --- | --- |
| 他に誰がいて、何を担当しているか | `afws-peers`（シェルコマンド） |
| 独立したセッションと話したい | Claude/Codexとも`afws-message` |
| 1つのClaude Agent Team内で連携したい | nativeの`ListAgents`と`SendMessage` |
| このGPUは自分が使い終わるまで触らせたくない | `afws-lock`（シェルコマンド） |

`afws-peers`は、このMac上の全AFWSセッションと、その名前がどのSSH接続先のどのリモートディレクトリを担当しているかを返します。nativeの`ListAgents`は現在のClaude Agent Team内のteammate一覧であり、独立したClaudeセッション全体のregistryではありません。

## 2つ目のセッションを起動する

別のターミナルで、同じ接続先・ディレクトリ、あるいは別のものを指定してlauncherを再度実行します。

```zsh
claudefws SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY
```

起動ごとに`fws-HOST-PROJECT-N`形式の未使用の名前が割り当てられます。1つ目が`fws-HOST-PROJECT-1`、2つ目が`fws-HOST-PROJECT-2`という具合です。launcherは選んだ名前を表示し、セッション自身にもその名前を伝えます。これにより、返信先の名前を相手へ伝えられます。

番号よりも役割を表す名前が適切な場合は、次のように指定します。

```zsh
AFWS_SESSION_NAME=gpu-trainer claudefws SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY
AFWS_SESSION_NAME=bug-1204 claudefws SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY
```

同じ接続先・同じディレクトリの2つのセッションは、1つのSSHFSマウントを共有します。2つ目の起動は、マウントし直さずに1つ目が作成したマウントを再利用します。

## 各セッションのワークスペースの場所

Mac側のセッション自身の作業ディレクトリは、`~/.afws/workspaces/HOST/REMOTE/PATH`にある空のcontrol workspaceです。プロジェクトはそこにありません。`afws-run`経由で届くので、2つのセッションのファイルツールがローカルで衝突することはありません。共有されるのはリモートディレクトリそのもので、それこそが`afws-lock`とこの文書のpeerメッセージが扱う対象です。

Finder/VS Codeビューをマウントする場合、そのマウントポイントは接続名とリモートの絶対パスから決まります。

```
~/afws-mounts/HOST/REMOTE/PATH
```

そのため2つのセッションは自動的に分離されます。接続先が違えば別のツリーになり、同じ接続先でも別のディレクトリなら別のマウントポイントになります。知っておく価値があるのは次の3ケースです。

| 2つ目のセッションが指定したディレクトリ | 動作 |
| --- | --- |
| すでにマウント済みのディレクトリの**サブディレクトリ** | 既存のマウントを再利用し、ビューをその中に向けます。2つ目のマウントもSSH接続も作りません。 |
| **兄弟**ディレクトリ | 別のマウントを作ります。SSH接続はそのホストへの共有接続を使います。 |
| すでにマウント済みのディレクトリの**親** | 拒否します。そこへマウントすると既存のマウントが隠れ、相手セッションのビューが新しいマウント経由で解決され始めるためです。深い側のディレクトリで起動するか、先にアンマウントしてください。 |
| すでに何かがマウントされている**そのパス自体** | 拒否します。同じパスへの2つ目は置き換えではなく積み重なりです。見えるのは最新の層だけで、それを解放してもパスが空くのではなく下の層が出てきます。 |

共有されたビューは、最後に抜けたセッションが解放します。同じマウントを他のセッションがまだ使っている状態で終了したセッションは、それを残し、そのことを表示します。`afws-lab`が起動したJupyterLabも同じ規則です。同じホスト・同じリモートディレクトリのセッションで1つを共有し、最後に抜けたセッションが停止します。各対話型launcherは独立したwatchdogも起動し、launcherが強制終了・クラッシュした場合も同じ「最後の利用者か」の確認と後片付けを行います。ClaudeまたはCodexのプロセスが生き残っていれば、その終了まで待ってから解放します。バックグラウンドセッションはビューをそのまま残し、`afws-umount --orphaned`で解放できます。labについては`afws-lab stop --orphaned`が同じことをします。

一方でロックは、ディレクトリ単位ではなく**ホスト単位**です。ロックディレクトリはリモートユーザーのホーム配下にあります。これは意図的な設計です。GPUは、各セッションがどのプロジェクトディレクトリで作業していようと、そのワークステーション上の全セッションで共有される資源だからです。同時に、`build`のような一般的な名前は同一ホスト上の無関係なプロジェクト間で衝突します。動作ではなく資源に名前を付けてください（`build-projectX`など）。

## 他のセッションを確認する

```zsh
afws-peers
```

```
SESSION        AGENT   KIND         STATUS  SSH HOST             REMOTE DIRECTORY  ACTIVITY
gpu-trainer    claude  interactive  busy    example-workstation  /remote/project   -
cx-training    codex   interactive  idle    example-workstation  /remote/project   8B学習
nightly-watch  claude  background   idle    example-workstation  /remote/project   -
```

`AGENT`はどちらのランチャーが起動したセッションかを示します。Claudeの`STATUS`はClaude Code自身から取得し、`waiting`も含みます。Codexの`busy`/`idle`はローカルフックから取得します。`ACTIVITY`にはCodexの短い作業ラベルを表示します。終了したセッションは、次のコマンド実行時に一覧から取り除かれます。

複数のワークステーションやプロジェクトが関係する場合は、一覧を絞り込みます。

```zsh
afws-peers --host SSH_CONFIG_HOST   # 特定のワークステーションだけ
afws-peers --same                   # まったく同じリモートディレクトリのセッションだけ
afws-peers --json                   # 機械可読
```

## 他のセッションと話す

独立セッション同士は`afws-message`を使います。`afws-peers`上の名前を解決し、Claudeなら永続inbox、Codexならhookで取得したthread IDへqueueします。Codexは最初のターンが始まってから宛先になります。現在のClaude Agent Team内だけはnativeの`ListAgents`と`SendMessage`も使えます（[エージェントごとにできること](agents.ja.md)）。

セッション内では自然な言葉で依頼してください。

> `afws-peers`を確認して、`gpu-trainer`に8Bの学習が終わったか、最終lossがいくらだったかを聞いてください。

送信側は作業ラベルなどを確認して`afws-message --to 名前 --message 本文`でqueueします。空いているCodexは新しいターンを始め、作業中なら現在のターンの終了後に処理します。ClaudeはSessionStart・UserPromptSubmit・Stopのhookで永続inboxを取り込み、Stop時ならその文脈で会話を継続できます。queue投入は受領確認や回答完了ではありません。送信側は投入したことを報告し、回答は受信側のセッションで後から確認できます。

peerからのメッセージは連絡であり、受信側のユーザーからの依頼を置き換えません。Codexでは`afws-message`のターンをStopフックが識別し、返信後に未完了の作業へ戻るよう一度だけ促します。完了済みの作業は繰り返しません。Claudeには返信後、同じターンで元の作業を続けるよう指示します。実際の割り込み、新たなユーザー依頼、ユーザー入力が必要な状態まで自動再開するものではありません。

名前は不要です。「8B学習に取り組んでいるエージェントに、データセットの準備ができたと伝えて」で構いません。作業ラベル・ホスト・ディレクトリから一意に特定できなければ確認します。`afws-peers`を読むのは必要な時だけで、フックは他セッションの情報をモデルの文脈へ流し込みません。Codexの`afws-status set '8B学習'`で安定した作業ラベルを設定でき、未設定なら直近のユーザープロンプトの最初の行を表示します。ラベルはこのMac上の本人だけが読めるファイルに保存されます。秘密情報はラベルに含めないでください。

ターミナルから直接送る場合は`afws-message --to 名前 --message 本文`、同じプロジェクトの他のCodex全員へは`afws-message --all --same --message 本文`を使います。`--same`なしの`--all`はこのMac上のすべての稼働中Codexが対象です。一斉送信は明示的に依頼された場合だけ行います。

これが有効なのは、一方のセッションだけが持っている情報を他方が知りたい場合です。どのcheckpointが最新か、なぜそのテストを無効化したのか、1時間前の失敗がどのような内容だったか、データセットの変換が終わったか、といった情報です。

## チャットからチームを管理する

Claude/Codexセッションでは、「タスクAはagent1〜3、タスクBはagent4〜9。各組の先頭をリーダーにして」のように自然な言葉で組織を指定できます。エージェントは`afws-peers`で実在するセッション名を解決し、プロジェクト単位のローカル台帳を`afws-org`で更新します。指定がなければ、各チームの先頭がリーダー、他は再委譲しないworkerとなり、workerはリーダーへ、リーダーはcoordinatorへ報告します。番号や説明から宛先を一意に決められない場合だけ確認します。

「組織図を見せて」「タスクBだけ」「誰が何をしている？」と尋ねると、登録した指揮系統、担当状態、現在のセッション生存状態を重ねて表示します。登録上の所属は、セッションが終了しても残るため、`offline`と表示されます。コマンドから同じ情報を見る場合は次を使います。

```zsh
afws-org show
afws-org show --team task-b
afws-org show --json
afws-org validate
```

`afws-peers`は観測された稼働セッション、`afws-org`は宣言された組織と担当の正本です。組織変更は、直接のユーザー依頼を受けたセッションが行います。通常のpeerメッセージだけでは組織を変更しません。

ユーザーが「開始して」「分配して」と言った場合、coordinatorは先に割当を台帳へ記録し、対象の各Claude/Codexへ個別に構造化した組織割当を送ります。一斉送信は使いません。受信側は、送信者が台帳上のcoordinatorまたは自分のleadであること、自分の担当とtaskが一致することを照合してからACKし、`acknowledged`、`running`、`completed`へ状態を更新します。workerの再委譲は禁止です。破壊的、高コスト、権限追加、担当範囲外の操作は、組織割当であっても受信側のユーザー確認が必要です。

### 永続配送と障害復旧

組織台帳は`~/.afws/organizations`に置くプロジェクト単位のSQLiteです。WAL、完全同期、revisionを照合する状態遷移、監査イベント、transactional outboxを使います。セッション名は表示名にすぎず、認可と担当所有者の判定にはランダムなinstance IDと、ローカル登録簿にはハッシュだけを保存するsession tokenを使います。同名セッションを作り直しても旧権限は暗黙に引き継がず、旧instanceをretireし、その実行中タスクを`orphaned`にします。

通常の割当loopは`assigned` → `delivered` → `acknowledged` → `running` → `completed`、`failed`、`waiting`、`blocked`のいずれかです。outboxの配送は`afws-org dispatch`、一度だけ使えるclaim tokenの受領は`claim ASSIGNMENT TOKEN`、作業中の生存通知は`heartbeat`、クラッシュ後の整合は`reconcile`で行います。`reconcile`はACK期限切れを`ack_timeout`、消えたinstanceの作業を`orphaned`にし、放置された配送leaseも回収します。再送、引継ぎ、取消は`retry`、`reassign`、`cancel`で明示し、実行中タスクの取消要求もoutboxで個別配送します。

### 自己解決loop

Claudeへ直接1つの目的を任せる場合は、`/goal 検証可能な終了条件`を入力します。これはsession-scopedなStop hookとして動き、条件達成、割り込み、または安全上限まで複数turnを継続します。終了条件は「頑張る」ではなく「`report.json`が存在し、`./scripts/verify.sh`が成功する」のように成果物と確認方法で書きます。時刻や外部状態を待つ場合はshellでbusy pollingせず、`/loop`またはscheduled wakeupを使います。

AFWSの永続割当は同じlifecycle境界を自動利用します。割当が`acknowledged`または`running`の間、ClaudeのStop hookが次に必要な行動を注入します。`completed`、`failed`、`waiting`、`blocked`を記録すると止まり、後二者には具体的な再開条件が必要です。Claude Code自身にもStop hookの連続継続上限があるため、これは永続的な監督であって無限loopではありません。

書込scopeは正規化したプロジェクト相対パスです。生きている割当どうしの包含・重複は、同時操作でもtransaction内で拒否します。書込scopeは書いただけでは強制になりません。プロジェクトはワークステーション上にあり、
すべての書き込みは`afws-run`を通るため、この Mac 上のどの規則もscopeを保持できません。
代わりにターン終了前に結果を照合します。scope付き割当のセッションは、ワークステーションの
`git status`をscopeと突き合わせ、範囲外の変更があれば停止を拒否し、該当パスと
`afws-org wait`を示します。1回の停止につき1度だけブロックするので、後始末のために
ワークステーションへ到達できないセッションが閉じ込められることはありません。読み取りは
一切制限しません。見られないagentは推測で書きます。
割当に`--worktree`を付けると、衝突を報告するのではなく無くします。`afws-org start`で
台帳がプロジェクトの隣に`<project>.afws-worktrees/<assignment>`としてGit worktreeを作り、
`afws/<id>`ブランチ上で作業します。中ではなく隣なのは、プロジェクト配下のworktreeが
ビルド・検索・scope検査すべてに拾われてしまうためです。プロジェクトがGit work treeでない場合と、
未コミット変更がある場合は拒否します。worktreeはHEADから始まるので、その変更は中から見えません。
worktreeは新品のcheckoutなので、プロジェクトが未追跡で持っているもの（データ・仮想環境・
チェックポイント）は存在しません。`--share PATH`はそれをsymlinkで持ち込みます。共有は推測でなく
明示です。共有したパスはworktreeが隔離しない唯一のものであり、それは台帳に残って
`afws-org show`が表示すべきものだからです。
割当の実行中、台帳はcheckoutのパスをセッション記録の隣に公開し、`afws-run`とファイルツールが
それに従います。セッション側は意識しません。プロジェクトに見えるものを触ると、自分のcheckoutに
着地します。`--cwd`を明示した呼び出しはその意図を尊重し、隔離割当を持たないセッションは
どこにもリダイレクトされません。読めない・空・相対のポインタはプロジェクトを意味します。
これは全プロジェクト操作の前に走るので、パスを捏造してはならないためです。
scope検査もリダイレクトに従い、checkoutとscopeを突き合わせます。共有パスは検査から外します。
共有とは「そのパスは隔離の外だ」という宣言であり、symlink自体が未追跡の変更として現れてしまい、
そもそもデータディレクトリの共有は作業がそこへ書くからこそ意味があるからです。
終端状態はcheckoutを回収し、ブランチは残します。ブランチが成果物です。自動マージはしません。
閉じられずにorphanになった割当はcheckoutを保持し、`afws-org show`に表示されます。
`afws-org guard PATH...`はその検査単体です。読み取り専用でeventを記録せず、scope付き割当が
無ければ成功を返すため、書き込みのたびに呼んでも安全です。`check-write`は自己申告版として残ります。
`--done-when CONDITION`は完了の定義です。これを持つ割当は本人の申告だけでは閉じられず、
`afws-org complete`には結果に加えて`--evidence "実行したコマンド -> 実際の戻り"`が必要で、
無ければ拒否します。早すぎる完了宣言こそがこの項目の目的です。`afws-org set-done-when`で
既存の割当にも追加できます。
仕事は列挙できる単位ではなく、独立して理解できる単位で分割してください。同じ文脈を要する
2つのタスクは、触るファイルが違っても1つの割当です。`--lock NAME`を付けると、`running`へ入る前に`afws-lock`の取得を必須にできます。

組織全体を変更できるのはcoordinatorだけで、team leadは自teamのメンバーと割当を管理でき、workerは自分の割当だけをclaim・更新できます。coordinatorを同名で作り直しても権限は自動継承しません。旧instanceがretire済みであることを確認し、同じセッション名の代替セッションから`afws-org recover-coordinator`を実行します。schema移行は追記型で、移行前にmode 0600のbackupを作ります。監査は`afws-org events`、整合検査は`afws-org validate`で確認できます。

配送保証は意図的にat-least-onceです。受信後、送信成功の記録前にprocessが落ちると同じ通知が再送され得ます。claim tokenによりACKは冪等になりますが、タスクの副作用自体も再試行して安全な形にしてください。

## 排他資源を順番に使う

1台のワークステーション上の2つのセッションは、いずれ同じGPU、同じビルドディレクトリ、同じデータセットを使いたくなります。`afws-lock`はそれを明示的に扱います。

```zsh
afws-lock acquire gpu0        # 確保する。取得できない場合は終了コード3で保持者を表示
afws-lock status              # この接続先のすべてのロック
afws-lock status gpu0         # 特定のロック
afws-lock release gpu0        # 解放できるのは保持者だけ
```

ロックは、リモート側の`~/.afws-locks`配下に原子的に作成されるディレクトリです。常駐プロセスを必要とせず、そのワークステーション上のすべてのセッションから見え、プロジェクトツリーの中には何も書き込みません。保持者はセッション名として記録されます。これは、メッセージの宛先に使える名前と同じものです。

```
held gpu0 holder=gpu-trainer since=2026-01-01T09:12:44Z age=318s ttl=7200s
```

すぐに失敗させず、ロックが空くまで待つこともできます。

```zsh
afws-lock acquire gpu0 --wait 600
```

TTLを超えたロックは`stale`と表示しますが、自動的に解放はしません。長時間ジョブでロックが数時間保持されるのは正常な状態だからです。保持中のロックを奪うのは、常に明示的な操作です。

```zsh
afws-lock steal gpu0
```

その前に保持者へ確認してください。そのためのメッセージ機能です。セッションには、利用者の指示がない限りロックを奪わないよう指示しています。

ロック名は自由に決められます。`gpu0`、`build`、`dataset-convert`、`migrations`などが適切です。ロックは同じ名前を使うセッション同士でしか機能しないため、その資源を取り合うすべてのセッションで同じ名前を使ってください。

## バックグラウンドセッション

Claude Codeのみです。`codexfws`には相当する機能がありません。

何かを監視するだけのセッションに、ターミナルは必要ありません。

```zsh
claudefws --bg SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY \
  "afws-runで学習ジョブを監視してください。失敗を報告し、質問されたら進捗を要約してください。"
```

launcherは、Claude Codeがそのセッションに使う識別子を表示します。

```zsh
claude agents          # バックグラウンドと対話セッションの一覧
claude attach ID       # このターミナルで開く
claude logs ID         # 直近の出力を表示
claude stop ID         # 会話を保持したまま停止
claude rm ID           # 停止済みセッションを削除
```

バックグラウンドセッションも他と同様に`afws-peers`へ表示され、名前を指定してメッセージを送れます。これが要点です。対話セッションは、自分でログを読み直す代わりに、監視役へ何が起きたかを尋ねられます。

## 具体例

1台のワークステーションに対する3つのセッションです。

```zsh
AFWS_SESSION_NAME=gpu-trainer claudefws workstation /remote/project
AFWS_SESSION_NAME=bug-1204 claudefws workstation /remote/project
claudefws --bg workstation /remote/project "キューを監視し、失敗を報告してください。"
```

- `gpu-trainer`は`afws-lock acquire gpu0`でGPUを確保し、`afws-run`経由で学習を開始し、終わるまでロックを保持します。
- `bug-1204`はGPU上でクラッシュを再現したいものの、ロックが`gpu-trainer`に保持されていることを見つけ、`SendMessage`で残り時間を尋ねます。その間はCPUだけで進められる部分を進めるか、`afws-lock acquire gpu0 --wait 1800`で待ちます。
- バックグラウンドセッションは失敗したジョブを検知し、直近のエラー内容を他のどちらのセッションからも尋ねられます。

どのセッションも他のセッションの動きを推測する必要がなく、GPUを同時に使うことも起きません。

## 境界

- レジストリとセッション間メッセージは、1台のMac内に限られます。同じワークステーションを共有していても、別のMac上の2つのセッションはこのツールでは相互に見えません。それを実現する仕組みはClaude CodeのRemote Controlであり、`claudefws`の対象範囲外です。
- ロックが調整できるのは`afws-lock`を使うセッションの間だけです。ワークステーション上の他の人、他のツール、スケジューラーが同じ資源を使うことは防げません。
- セッションはリモートのファイルシステムを共有します。同じマウント越しに同じファイルを編集する2つのセッションは互いの変更を上書きします。そのためのメッセージ機能です。
