#!/bin/sh

# sh sandbox.sh

set -eux

# リポジトリルートで実行されることを前提とする
DOCKER_DIR="${PWD}/docker"
# claudeの作業対象としてマウントするフォルダ
WORKSPACE_DIR="${PWD}"

IMAGE_NAME=local-sandbox
IMAGE_TAG=$(date +%s)
CONTAINER_NAME=local-sandbox

# CLAUDE_CODE_OAUTH_TOKEN（必須）、SLACK_BOT_TOKEN/SLACK_CHANNEL/SLACK_MEMBER（任意）を記載する
ENV_FILE="${PWD}/.env.sandbox"
# claudeの出力先(agents)と~/.claude, ~/.claude.jsonの実体を置くディレクトリ
AGENTS_DIR="${PWD}/agents"
# コンテナ内でagentsをマウントするパス（notify_slack.shへ環境変数SLACK_DIRとして渡す）
CONTAINER_AGENTS_DIR="/home/claude_user/workspace/agents"

# Slack通知のため、ALLOWED_ENDPOINTSに常にslack.com:443を加えてコンテナへ渡す。
# ホストの環境変数が無ければ.env.sandboxの値を使い、そこで指定された接続先も残す。
if [ -z "${ALLOWED_ENDPOINTS:-}" ] && [ -f "${ENV_FILE}" ]; then
    ALLOWED_ENDPOINTS=$(sed -n 's/^ALLOWED_ENDPOINTS=//p' "${ENV_FILE}" | tail -n 1)
fi
case " ${ALLOWED_ENDPOINTS:-} " in
    *" slack.com:443 "*) ;;
    *) ALLOWED_ENDPOINTS="slack.com:443${ALLOWED_ENDPOINTS:+ ${ALLOWED_ENDPOINTS}}" ;;
esac
export ALLOWED_ENDPOINTS

# マウント元が無いとdockerがディレクトリとして作成してしまうため、事前に用意する
mkdir -p "${AGENTS_DIR}/.claude"
if [ ! -f "${AGENTS_DIR}/.claude.json" ]; then
    cp "${DOCKER_DIR}/.claude.json" "${AGENTS_DIR}/.claude.json"
fi

docker build -t "${IMAGE_NAME}:${IMAGE_TAG}" -t "${IMAGE_NAME}:latest" "${DOCKER_DIR}"

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
    -e "SLACK_DIR=${CONTAINER_AGENTS_DIR}" \
    -e ALLOWED_ENDPOINTS \
    -e ALLOWED_DOCKER_DNS \
    -v "${WORKSPACE_DIR}:/home/claude_user/workspace:rw" \
    -v "${AGENTS_DIR}:${CONTAINER_AGENTS_DIR}:rw" \
    -v "${AGENTS_DIR}/.claude.json:/home/claude_user/.claude.json:rw" \
    -v "${AGENTS_DIR}/.claude:/home/claude_user/.claude:rw" \
    -v "${DOCKER_DIR}/.claude/settings.json:/home/claude_user/.claude/settings.json:ro" \
    -v "${DOCKER_DIR}/.claude/settings.local.json:/home/claude_user/workspace/.claude/settings.local.json:ro" \
    -v "${DOCKER_DIR}/.claude/CLAUDE.md:/home/claude_user/.claude/CLAUDE.md:ro" \
    "${IMAGE_NAME}:${IMAGE_TAG}"

docker exec -it -u claude_user "${CONTAINER_NAME}" claude --dangerously-skip-permissions
