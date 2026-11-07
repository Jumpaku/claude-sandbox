# claude-sandbox

Claude Codeを隔離して実行するためのコンテナ（イメージ）。`docker/`がビルドコンテキスト。

## ファイル

| ファイル | 内容 |
| --- | --- |
| `docker/Dockerfile` | debian slimベースのイメージ定義。`iptables`/`ipset`/`dnsmasq`/`curl`/`jq`/`git`とClaude Codeを導入し、一般ユーザー`claude_user`を作成する |
| `docker/entrypoint.sh` | コンテナのエントリポイント。必須の環境変数を確認し、`dnsmasq`と`iptables`/`ipset`で外部通信の許可リストを構築して待機する |
| `docker/dnsmasq.conf` | DNSプロキシの設定。許可した接続先（`ALLOWED_ENDPOINTS`から生成される設定）の解決済みIPを`ipset`へ追加し、`ALLOWED_DOCKER_DNS`のホストをDocker組み込みDNSで解決する |
| `docker/notify_slack.sh` | Stop/StopFailure/Notification/PermissionRequestフックから呼ばれ、Slackへ通知する |
| `docker/user_prompt_submit_timestamp.sh` | UserPromptSubmitフックから呼ばれ、プロンプト送信時刻を記録する |
| `docker/.claude/settings.json` | コンテナ内の`~/.claude/settings.json`としてreadonlyでマウントされる |
| `docker/.claude/settings.local.json` | コンテナ内の`~/workspace/.claude/settings.local.json`としてreadonlyでマウントされる |
| `docker/.claude.json` | コンテナ内の`~/.claude.json`の初期値 |
| `docker/.claude/CLAUDE.md` | コンテナ内の`~/.claude/CLAUDE.md`としてreadonlyでマウントされる |

## Docker Hubへのpush

`dockerhub.sh`が`docker/`をビルドし、`jumpaku/claude-sandbox`へpushする。Dockerfileのstageの違いはタグで表す。`<IMAGE_TAG>`は第1引数で指定する（必須。未指定ならエラー終了する）。

| stage | タグ |
| --- | --- |
| `claude-sandbox`（ベース） | `<IMAGE_TAG>` / `latest` |
| `claude-sandbox-slack`（Slack通知スクリプト入り） | `<IMAGE_TAG>-slack` / `slack` |

事前に`docker login`済みであること。`linux/amd64`と`linux/arm64`の両方を`docker buildx build --push`でbuildとpushする（`docker-container`ドライバのbuildx builderまたはcontainerd image storeが必要。例: `docker buildx create --use`）。

```sh
sh dockerhub.sh <タグ>
```

| 引数・変数 | 必須 | 内容 |
| --- | --- | --- |
| 第1引数 | 必須 | タグのバージョン部分（上表の`<IMAGE_TAG>`。例: `v1.0.0`） |
| `PLATFORMS` | 任意 | build対象のplatform（カンマ区切り）。既定は`linux/amd64,linux/arm64` |

## 外部通信の制限

許可リスト方式で、以下のみ接続できる。

- 許可した接続先へのTCP接続
  - 常に許可（443）: `api.anthropic.com` / `claude.ai`（`dnsmasq.conf`で指定）
  - 追加で許可: 環境変数`ALLOWED_ENDPOINTS`で指定した`ホスト名:ポート`（既定は指定なし）
- DNS: `1.1.1.1` / `8.8.8.8`（`dnsmasq`のプロキシ先）
  - 環境変数`ALLOWED_DOCKER_DNS`で指定したホスト名だけは、Docker組み込みDNS（`127.0.0.11`）で名前解決する（接続の許可は`ALLOWED_ENDPOINTS`で別に指定する）

`entrypoint.sh`が`ALLOWED_ENDPOINTS`・`ALLOWED_DOCKER_DNS`から`dnsmasq`の設定（`/etc/dnsmasq-allowed-domains.conf`）を生成し、ホストごとに`ipset`（`ep-<ホスト名>`）を作って、解決されたIPを追加する。そのipset宛ての指定ポートへの許可ルールも`entrypoint.sh`で定義する。
上記以外への送信は拒否される。

## 環境変数

コンテナの環境変数として渡す。

| 変数 | 必須 | 内容 |
| --- | --- | --- |
| `CLAUDE_CODE_OAUTH_TOKEN` | 必須 | Claude Codeの認証トークン。未設定なら`entrypoint.sh`がエラー終了する |
| `ALLOWED_ENDPOINTS` | 任意 | 常に許可される接続先に加えて、接続を許可する`ホスト名:ポート`（空白区切り。ポートは省略できない。サブドメインを含む。例: `postgres:5432 redis:6379`）。形式が不正（`:ポート`が無い、ホスト名に英数字・ハイフン・ドット以外を含む、ホスト名の先頭が英数字でない、ホスト名が28文字を超える、ポートが1〜65535の数字でない）なら`entrypoint.sh`がエラー終了する |
| `ALLOWED_DOCKER_DNS` | 任意 | Docker組み込みDNSで名前解決するホスト名（空白区切り。例: `postgres redis`）。compose内のコンテナなど、`1.1.1.1`・`8.8.8.8`では解決できない名前に指定する。名前解決だけで、接続の許可は`ALLOWED_ENDPOINTS`で別に指定する。解決できるよう、コンテナを対象のネットワークに接続しておく必要がある。英数字・ハイフン・ドット以外を含む、または先頭が英数字でないホスト名があると`entrypoint.sh`がエラー終了する |
| `SLACK_BOT_TOKEN` | 任意 | Slack通知用のBot Token。`SLACK_CHANNEL`と両方が設定されたときだけ通知する。`slack.com`は常に許可される接続先に含まれないため、通知するには`ALLOWED_ENDPOINTS`に`slack.com:443`が必要 |
| `SLACK_CHANNEL` | 任意 | Slack通知先のチャンネル |
| `SLACK_MEMBER` | 任意 | スレッド親メッセージでメンションするユーザー |
| `SLACK_DIR` | 任意 | スレッドtsの記録（`slack_thread_ts`）と、アップロードする`.md`を置くコンテナ内ディレクトリ。未設定なら、スレッドにせず単独メッセージとして通知する |

## Slack通知

`notify_slack.sh`は、直前のプロンプト送信（`user_prompt_submit_timestamp.sh`が記録）から60秒以上経過している場合のみ通知する。
`SLACK_DIR`が設定されている場合は、初回にスレッド親メッセージを投稿してtsを`${SLACK_DIR}/slack_thread_ts`に記録し、以降の通知を同じスレッドへ投稿する。
あわせて、`${SLACK_DIR}`直下の`.md`を毎回すべて、通知と同じスレッドへアップロードする。
