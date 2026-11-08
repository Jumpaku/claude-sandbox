# CLAUDE.md

Dockerコンテナ内で動作している。

- 作業フォルダは`~/workspace`（gitリポジトリ）。
- 使えるツールは`curl`・`jq`。
- 外部通信は、`api.anthropic.com` / `claude.ai`（443）と、環境変数`ALLOWED_ENDPOINTS`（`ホスト名:ポート`の空白区切り）に含まれる接続先へのTCP接続のみ可能。
- `~/.claude/CLAUDE.md`・`~/.claude/settings.json`はreadonlyで編集できない。
- `docker`コマンド・WebSearch・WebFetchは使えない。