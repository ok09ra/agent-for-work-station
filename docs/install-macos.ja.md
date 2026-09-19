# macOSセットアップ

[English](install-macos.md) · [README](../README.ja.md)

このドキュメントは、ほぼ初期状態のMacから`claudefws`が動く状態までの手順です。実際の接続情報と資格情報は、このリポジトリではなくMacのSSH configとキーチェーンで管理します。

## 1. 前提の確認

- macOS 12以降
- IntelまたはApple silicon搭載のMac
- SSH接続先へのアクセス権
- リモート側で対象プロジェクトを読み書き・実行できる権限

このセットアップでは、リモート側のソフトウェアやシェル設定を変更しません。

## 2. macFUSEのインストール

1. [macFUSE公式サイト](https://macfuse.github.io/)を開きます。
2. 最新の安定版installerをダウンロードして実行します。
3. macOSがシステム設定での許可を求めた場合は、公式の案内に従って許可します。
4. 再起動を求められた場合は再起動します。

macFUSEはmacOSのセキュリティ機構に関わるため、この部分はリポジトリ側で自動化していません。

## 3. SSHFSのインストール

1. [macFUSEプロジェクトのSSHFSページ](https://github.com/macfuse/macfuse/wiki/File-Systems-%E2%80%90-SSHFS)を開きます。
2. macOS用の最新パッケージをダウンロードして実行します。
3. ターミナルを開き直して確認します。

   ```zsh
   command -v sshfs
   sshfs --version
   ```

このプロジェクトでは、特定のサードパーティ製パッケージマネージャーを前提とせず、macFUSEプロジェクトが案内する署名済みパッケージを使います。

## 4. エージェントを少なくとも1つインストール

両方とも個別に任意です。使うものだけ、あるいは両方を導入してください。どちらのランチャーが使えるかは`afws-doctor`が報告します。

Claude Codeは[公式ドキュメント](https://docs.claude.com/en/docs/claude-code/overview)のinstallerを使います。

```zsh
curl -fsSL https://claude.ai/install.sh | bash
exec zsh -l
claude --version
claude auth login
```

Codex CLIは[公式ドキュメント](https://developers.openai.com/codex/cli)のinstallerを使います。

```zsh
curl -fsSL https://chatgpt.com/codex/install.sh | sh
exec zsh -l
codex --version
```

どちらのinstallerもユーザー領域へ導入するため、管理者権限は不要です。サインインは各エージェントで一度だけ行えば、ランチャーから起動する各セッションがそれを再利用します。

## 5. SSHの設定

次の情報を、承認された安全な経路でリモートシステムの管理者から受け取ります。

- SSH接続先
- リモートのユーザー名
- 許可されたSSH鍵
- 対象プロジェクトの絶対ディレクトリ

パスワードや秘密鍵をこのリポジトリへ複製しないでください。SSH鍵がない場合は、所属組織の方針に従って作成・登録します。認証にはmacOSのキーチェーンまたはSSH agentを使います。

ローカルのSSH configに接続名を定義します。[設定例](../examples/ssh-config.example)は架空の値だけを含みます。`HostName`と`User`の実値は、ローカルのファイルにのみ記述します。

設定ファイルと権限を準備します。

```zsh
mkdir -p ~/.ssh
chmod 700 ~/.ssh
touch ~/.ssh/config
chmod 600 ~/.ssh/config
```

接続を確認します。

```zsh
ssh example-workstation
```

`example-workstation`は、SSH configで定義した接続名に置き換えます。初回接続時は、ホスト鍵のfingerprintを管理者から提供された値と照合します。

セッションは数時間、バックグラウンドセッションはさらに長くワークステーションへ接続したままになるため、SSH configで接続を維持しておきます。

```
  ServerAliveInterval 30
  ServerAliveCountMax 6
```

## 6. コマンドのインストール

リポジトリを任意の場所へcloneします。アーカイブを展開したものでも構いません。

```zsh
git clone https://github.com/ok09ra/agent-for-work-station.git ~/src/agent-for-work-station
cd ~/src/agent-for-work-station
```

各コマンドは共有ライブラリを自分からの相対位置で探すため、cloneの`bin`を`PATH`に入れるだけで足ります。その場合は`git pull`だけで更新されます。

```zsh
echo 'export PATH="$HOME/src/agent-for-work-station/bin:$PATH"' >> ~/.zprofile
exec zsh -l
```

固定の場所へコピーを置きたい場合はinstallerを使います。

```zsh
./scripts/install.sh
exec zsh -l
```

installerが行うのは次の操作だけです。

1. 2つのランチャーと共通コマンドをユーザー領域のコマンドディレクトリへ、`lib/afws-common.zsh`をその隣の`../lib`へコピーします。各コマンドはそこからライブラリを探します。
2. 必要な場合にのみ、そのディレクトリをzshログインシェルの`PATH`へ追加します。
3. 新しく開いたターミナルからコマンドを見つけられるようにします。

既存のSSH config、各エージェントの設定、リモート環境はいずれも変更しません。また何も削除しません。置き換え対象である旧`claudefws`／`codexfws`の導入物が残っている場合は、削除候補として一覧表示するだけです。

## 7. 診断の実行

```zsh
afws-doctor
```

接続を開かずにSSH configの接続名だけを確認する場合は、引数に渡します。

```zsh
afws-doctor example-workstation
```

診断では`claude agents --json`が動作することも確認します。`afws-peers`がセッションの状態を取得するのにこの一覧を使うためです。失敗する場合は`claude auth login`を実行してから再試行します。

すべての診断が`[OK]`になれば準備完了です。

## 8. セッションの起動

シェル履歴に実値を残したくない場合は、引数なしで起動します。

```zsh
claudefws
```

表示に従って、SSHの接続名と許可されたリモートプロジェクトの絶対ディレクトリを入力します。SSHFSがマウントを完了すると、そのマウントポイントを作業ディレクトリとしてエージェントが起動します。`codexfws`も同じ引数を取ります。

`claudefws`では、新しいマウントポイントでの初回起動時に、Claude Codeがそのフォルダを信頼するか確認します。マウントポイントごとに一度だけ許可します。

## 9. 終了とアンマウント

エージェントを終了すると、そのマウント内で作業している他のセッション（どちらのエージェントであっても）がない限り、マウントは解放されます。そのホスト上にセッションが残っていなければ、共有SSH接続も同時に閉じられます。終了したセッションのレジストリ記録も削除され、古い記録は`afws-peers`や`claudefws`の実行時に整理されます。

セッション実行中は、launcherは要求した接続先とパスを含む既存のSSHFSマウントを再利用します。自身の記録ではなくシステムの`mount`一覧を参照しているためです。

バックグラウンドセッション、および終了ではなく強制終了されたセッションは、マウントを残します。明示的に解放してください。

```zsh
afws-umount --list
afws-umount --orphaned
```

`--list`は各claudefwsマウントと、それを使っている生存セッション数を表示します。`--orphaned`は誰も使っていないものを解放します。通常の`umount`が拒否される場合は`--force`を付けます。Finderでボリュームを取り出す方法も使えます。

ターミナルから手動でアンマウントする場合は、まず`mount`で確認し、確認済みのマウントポイントだけを`umount`へ渡します。広い範囲や未確認のパスに対しては実行しないでください。
