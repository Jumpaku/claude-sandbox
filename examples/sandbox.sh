#!/bin/sh

# sh examples/sandbox.sh

set -eux

# リポジトリルートで実行されることを前提とする
# claudeの作業対象としてマウントするフォルダ
WORKSPACE_DIR="${PWD}"
# このスクリプトと、その設定ファイル（.env.sandbox、.claude.json、.claude/）を置くディレクトリ
EXAMPLES_DIR="${PWD}/examples"

IMAGE_NAME=jumpaku/claude-sandbox:latest
CONTAINER_NAME=local-sandbox

# CLAUDE_CODE_OAUTH_TOKEN（任意）などの環境変数を記載する
ENV_FILE="${EXAMPLES_DIR}/.env.sandbox"
# ~/.claude, ~/.claude.jsonの実体を置くディレクトリ
AGENTS_DIR="${EXAMPLES_DIR}/agents"

# マウント元が無いとdockerがディレクトリとして作成してしまうため、事前に用意する
mkdir -p "${AGENTS_DIR}/.claude"
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
    -e ALLOWED_ENDPOINTS \
    -e ALLOWED_DOCKER_DNS \
    -v "${WORKSPACE_DIR}:/home/claude_user/workspace:rw" \
    -v "${AGENTS_DIR}/.claude.json:/home/claude_user/.claude.json:rw" \
    -v "${AGENTS_DIR}/.claude:/home/claude_user/.claude:rw" \
    -v "${EXAMPLES_DIR}/.claude/settings.json:/home/claude_user/.claude/settings.json:ro" \
    -v "${EXAMPLES_DIR}/.claude/settings.local.json:/home/claude_user/workspace/.claude/settings.local.json:ro" \
    -v "${EXAMPLES_DIR}/.claude/CLAUDE.md:/home/claude_user/.claude/CLAUDE.md:ro" \
    "${IMAGE_NAME}"

docker exec -it -u claude_user "${CONTAINER_NAME}" claude --dangerously-skip-permissions
