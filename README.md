# claude-sandbox

Claude Codeを隔離して実行するためのDockerイメージ。外部通信を許可リスト方式で制限したコンテナの中で、Claude Codeを動かせる。

- イメージ: `jumpaku/claude-sandbox`（Docker Hub。`linux/amd64`・`linux/arm64`）
- タグ: `latest` / `x.y.z`形式のバージョン（例: `1.0.0`）
- 含まれるもの: Claude Code、`curl`。一般ユーザー`claude_user`（uid 1000）で実行する

## 使い方

コンテナはroot権限で起動し、外部通信の許可リストを構築した後、起動したまま待機する。Claude Codeは`docker exec`で`claude_user`として起動する。

```sh
docker run -d --rm \
    --name claude-sandbox \
    --cap-drop ALL \
    --cap-add NET_ADMIN \
    --cap-add NET_RAW \
    --cap-add SETUID \
    --cap-add SETGID \
    -e CLAUDE_CODE_OAUTH_TOKEN \
    -v "${PWD}:/home/claude_user/workspace:rw" \
    jumpaku/claude-sandbox:latest

docker exec -it -u claude_user claude-sandbox claude
```

- 許可リストの構築に`iptables`/`ipset`を使うため、`NET_ADMIN`と`NET_RAW`が必要。
- `CLAUDE_CODE_OAUTH_TOKEN`は任意。ホスト側で未設定なら、`-e CLAUDE_CODE_OAUTH_TOKEN`は何も渡さない。
- `ALLOWED_ENDPOINTS`などの環境変数と、マウントによるカスタマイズは以降の節を参照。

## 環境変数

コンテナの環境変数として渡す。

| 変数 | 必須 | 内容 |
| --- | --- | --- |
| `CLAUDE_CODE_OAUTH_TOKEN` | 任意 | Claude Codeの認証トークン。未設定でもコンテナは起動する |
| `ALLOWED_ENDPOINTS` | 任意 | 常に許可される接続先に加えて、接続を許可する`ホスト名:ポート`（空白区切り。ポートは省略できない。サブドメインを含む。例: `postgres:5432 redis:6379`）。形式が不正（`:ポート`が無い、ホスト名に英数字・ハイフン・ドット以外を含む、ホスト名の先頭が英数字でない、ホスト名が28文字を超える、ポートが1〜65535の数字でない）ならコンテナがエラー終了する |
| `ALLOWED_DOCKER_DNS` | 任意 | Docker組み込みDNSで名前解決するホスト名（空白区切り。例: `postgres redis`）。compose内のコンテナなど、`1.1.1.1`・`8.8.8.8`では解決できない名前に指定する。名前解決だけで、接続の許可は`ALLOWED_ENDPOINTS`で別に指定する。解決できるよう、コンテナを対象のネットワークに接続しておく必要がある。英数字・ハイフン・ドット以外を含む、または先頭が英数字でないホスト名があるとコンテナがエラー終了する |

## 外部通信の制限

許可リスト方式で、以下のみ接続できる。上記以外への送信は拒否される。

- 許可した接続先へのTCP接続
  - 常に許可（443）: `api.anthropic.com` / `claude.ai`
  - 追加で許可: 環境変数`ALLOWED_ENDPOINTS`で指定した`ホスト名:ポート`（既定は指定なし）
- DNS: `1.1.1.1` / `8.8.8.8`
  - 環境変数`ALLOWED_DOCKER_DNS`で指定したホスト名だけは、Docker組み込みDNS（`127.0.0.11`）で名前解決する（接続の許可は`ALLOWED_ENDPOINTS`で別に指定する）

許可リストは、コンテナ内の`dnsmasq`が名前解決したIPを`ipset`へ追加し、`iptables`がそのIP宛ての指定ポートだけを許可する仕組みで実現している。

## マウントによるカスタマイズ

コンテナ内の以下のパスへマウントして、挙動をカスタマイズできる（`~`は`claude_user`のホーム`/home/claude_user`）。いずれも任意で、マウントしなければイメージ内の既定のままになり、コンテナを削除するとデータも消える。

| コンテナ内のパス | 種別 | 用途 | モード |
| --- | --- | --- | --- |
| `~/workspace` | ディレクトリ | claudeの作業対象（コンテナの`WORKDIR`）。ここへプロジェクトをマウントする | rw |
| `~/.claude` | ディレクトリ | セッションデータ（会話のトランスクリプト、履歴、ファイル編集のバックアップ、プラグインなど）の永続化 | rw |
| `~/.claude.json` | ファイル | Claude Codeのグローバル状態の永続化 | rw |
| `~/.claude/settings.json` | ファイル | ユーザー設定（権限、フック、テーマなど）の差し替え | ro推奨 |
| `~/.claude/CLAUDE.md` | ファイル | 全プロジェクト共通の指示の差し替え | ro推奨 |

- 設定系の2ファイルをroでマウントすると、コンテナ内のclaudeが自身の設定や指示を書き換えられなくなる。
- `~/.claude`と、その配下の`settings.json`・`CLAUDE.md`は両方マウントできる。配下のファイルが優先される。
- `~/.claude`はイメージ内で`claude_user`所有のディレクトリとして用意済み。マウント元のホスト側ディレクトリは、`claude_user`（uid 1000）が書き込める必要がある。
- `~/.claude.json`はファイルとしてマウントするため、ホスト側に事前にファイルを用意する。マウント元が無いとdockerがディレクトリとして作成してしまう。初期値には、このリポジトリの`examples/.claude.json`（オンボーディングと、`~/workspace`の信頼ダイアログをスキップする設定）を使える。

## エントリポイントの差し替え

イメージの`ENTRYPOINT`は`/entrypoint.sh`、`CMD`は`sleep infinity`。root権限で起動し、環境変数の形式を確認して外部通信の許可リストを構築した後、`CMD`のコマンドを`exec`で実行する。既定ではコンテナが起動したまま待機し、Claude Codeは`docker exec`で起動する。

### CMDの差し替え（制限は維持される）

`docker run <image> <コマンド>`でコマンドを渡すと、許可リストの構築後に、`sleep infinity`の代わりにそのコマンドが実行される。外部通信の制限は維持される。

```sh
docker run -d --rm ... jumpaku/claude-sandbox:latest <コマンド> <引数>
```

- 渡したコマンドは`claude_user`ではなく、root権限で実行される。`claude_user`で動かしたい場合は、コマンド側で権限を落とす（例: `su claude_user -s /bin/sh -c '<コマンド>'`）。
- コマンドが終了するとコンテナも終了する。待機し続けたい場合は、コマンドの方で常駐させる。

### ENTRYPOINTの差し替え（制限は外れる）

`docker run --entrypoint <パス>`で指定するか、自作のスクリプトを`/entrypoint.sh`へマウントする（実行権限が必要）と、`ENTRYPOINT`を差し替えられる。

- 差し替えると、許可リストの構築（`dnsmasq`・`iptables`・`ipset`の設定）と環境変数の形式確認は実行されない。外部通信の制限は効かなくなる。
- 通常は、制限が維持されるCMDの差し替えを使う。

## 起動スクリプトの例

このリポジトリの`examples/sandbox.sh`は、上記のマウントをすべて使う起動スクリプトの例。リポジトリルートで`sh examples/sandbox.sh`を実行すると、コンテナを起動して`claude --dangerously-skip-permissions`を開始する。

- `examples/.env.sandbox`に`CLAUDE_CODE_OAUTH_TOKEN`（任意）などの環境変数を記載する（`--env-file`で渡す）。
- マウントは次のとおり（ホスト側はリポジトリルートからの相対パス）。

| コンテナ内のパス | ホスト側 |
| --- | --- |
| `~/workspace` | `.` |
| `~/.claude` | `examples/agents/.claude/` |
| `~/.claude.json` | `examples/agents/.claude.json`（無ければ`examples/.claude.json`をコピーして作る） |
| `~/.claude/settings.json` | `examples/.claude/settings.json`（ro） |
| `~/.claude/CLAUDE.md` | `examples/.claude/CLAUDE.md`（ro） |

`examples/agents/`と`examples/.env.sandbox`は、`.gitignore`済み。

## 開発者向け

### ファイル

`docker/`がイメージのビルドコンテキスト。

| ファイル | 内容 |
| --- | --- |
| `docker/Dockerfile` | debian slimベースのイメージ定義。`iptables`/`ipset`/`dnsmasq`/`curl`とClaude Codeを導入し、一般ユーザー`claude_user`を作成する |
| `docker/.dockerignore` | ビルドコンテキストの除外設定。`Dockerfile`の`COPY`で使うファイルだけを含める許可リスト方式。`COPY`するファイルを増やしたら、ここにも追加する |
| `docker/entrypoint.sh` | コンテナのエントリポイント。環境変数の形式を確認し、`dnsmasq`と`iptables`/`ipset`で外部通信の許可リストを構築した後、`CMD`（既定は`sleep infinity`）を実行する |
| `docker/dnsmasq.conf` | DNSプロキシの設定。許可した接続先（`ALLOWED_ENDPOINTS`から生成される設定）の解決済みIPを`ipset`へ追加し、`ALLOWED_DOCKER_DNS`のホストをDocker組み込みDNSで解決する |
| `examples/sandbox.sh` | 起動スクリプトの例 |
| `examples/.claude/settings.json` | `examples/sandbox.sh`が`~/.claude/settings.json`としてroでマウントする設定 |
| `examples/.claude/CLAUDE.md` | `examples/sandbox.sh`が`~/.claude/CLAUDE.md`としてroでマウントする指示 |
| `examples/.claude.json` | `~/.claude.json`の初期値 |

### Docker Hubへのpush

`dockerhub.sh`が`docker/`をビルドし、`jumpaku/claude-sandbox`へpushする。`<IMAGE_TAG>`は第1引数で指定する（必須。未指定ならエラー終了する）。タグは`<IMAGE_TAG>`と`latest`。

事前に`docker login`済みであること。`linux/amd64`と`linux/arm64`の両方を`docker buildx build --push`でbuildとpushする（`docker-container`ドライバのbuildx builderまたはcontainerd image storeが必要。例: `docker buildx create --use`）。

```sh
sh dockerhub.sh <タグ>
```

| 引数・変数 | 必須 | 内容 |
| --- | --- | --- |
| 第1引数 | 必須 | タグのバージョン部分（`<IMAGE_TAG>`。`x.y.z`形式。例: `1.0.0`） |
| `PLATFORMS` | 任意 | build対象のplatform（カンマ区切り）。既定は`linux/amd64,linux/arm64` |
