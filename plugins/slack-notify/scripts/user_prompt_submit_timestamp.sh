#!/bin/sh

# Claude CodeのUserPromptSubmitフックから呼ばれ、プロンプト送信時刻をセッションごとに記録する。
# slack_notify.shがStop/Notification時にこの時刻との経過時間を見て、通知するかどうかを判定する。

set -u

input="$(cat)"
session_id="$(printf '%s' "$input" | jq -r '.session_id // "unknown"')"

mkdir -p /tmp/claude-notify 2>/dev/null
date +%s > "/tmp/claude-notify/${session_id}.last_prompt_ts" 2>/dev/null

exit 0
