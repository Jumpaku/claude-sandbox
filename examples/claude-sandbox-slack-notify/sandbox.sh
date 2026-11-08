#!/bin/sh

# sh examples/claude-sandbox-slack-notify/sandbox.sh
# 同じディレクトリのDockerfile（claude-sandboxにslack-notifyを組み込んだもの）をビルドして起動する。

set -eux

# リポジトリルートで実行されることを前提とする
# claudeの作業対象としてマウントするフォルダ
WORKSPACE_DIR="${PWD}"
# このスクリプトと、Dockerfile・設定ファイル（.env.sandbox、.claude.json、.claude/）を置くディレクトリ
EXAMPLES_DIR="${PWD}/examples/claude-sandbox-slack-notify"

IMAGE_NAME=local-claude-sandbox-slack-notify:latest
CONTAINER_NAME=local-sandbox-slack-notify

# CLAUDE_CODE_OAUTH_TOKEN（任意）、SLACK_BOT_TOKEN・SLACK_CHANNEL・SLACK_MEMBER、
# ALLOWED_ENDPOINTS（slack.com:443を含める）などの環境変数を記載する
ENV_FILE="${EXAMPLES_DIR}/.env.sandbox"
# ~/.claude, ~/.claude.jsonの実体を置くディレクトリ
AGENTS_DIR="${EXAMPLES_DIR}/agents"
# ~/.slack-notify（スレッドtsの記録先と、アップロードする.mdの置き場）の実体を置くディレクトリ
SLACK_NOTIFY_DIR="${EXAMPLES_DIR}/agents/.slack-notify"

# plugins/をビルドコンテキスト"plugins"として渡し、Dockerfileからローカルのプラグインを取り込む
docker build --build-context plugins="${PWD}/plugins" -t "${IMAGE_NAME}" "${EXAMPLES_DIR}"

# マウント元が無いとdockerがディレクトリとして作成してしまうため、事前に用意する
mkdir -p "${AGENTS_DIR}/.claude" "${SLACK_NOTIFY_DIR}/data"
if [ ! -f "${AGENTS_DIR}/.claude.json" ]; then
    cp "${EXAMPLES_DIR}/.claude.json" "${AGENTS_DIR}/.claude.json"
fi

# 前回のコンテナが残っていれば削除する
docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true

# entrypoint.shはrootでiptables/ipsetを設定した後sleep infinityで待機するため、-uを付けずバックグラウンドで起動する
docker run -d --rm \
    --name "${CONTAINER_NAME}" \
    --cap-drop ALL \
    --cap-add NET_ADMIN \
    --cap-add NET_RAW \
    --cap-add SETUID \
    --cap-add SETGID \
    --env-file "${ENV_FILE}" \
    -v "${WORKSPACE_DIR}:/home/claude_user/workspace:rw" \
    -v "${AGENTS_DIR}/.claude.json:/home/claude_user/.claude.json:rw" \
    -v "${AGENTS_DIR}/.claude:/home/claude_user/.claude:rw" \
    -v "${EXAMPLES_DIR}/.claude/settings.json:/home/claude_user/.claude/settings.json:ro" \
    -v "${EXAMPLES_DIR}/.claude/CLAUDE.md:/home/claude_user/.claude/CLAUDE.md:ro" \
    -v "${SLACK_NOTIFY_DIR}:/home/claude_user/.slack-notify:rw" \
    "${IMAGE_NAME}"

# イメージの/opt/claude-plugins/slack-notifyに組み込んだプラグインを読み込ませる
docker exec -it -u claude_user "${CONTAINER_NAME}" claude --dangerously-skip-permissions \
    --plugin-dir /opt/claude-plugins/slack-notify
