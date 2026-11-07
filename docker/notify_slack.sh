#!/bin/sh

# Claude CodeのStop/StopFailure/Notificationフックから呼ばれ、直前のUserPromptSubmit(user_prompt_submit_timestamp.shが記録)から60秒以上経過していればSlackへ通知する。
# 初回はスレッド親となるメッセージを先に送ってそのtsをagents/slack_thread_tsに記録し、通知は常にそのスレッドへぶら下げる。
# さらにagents直下の.mdを毎回全件、通知と同じスレッドへファイルとしてアップロードする。

set -u

# 未設定なら通知先が無いので何もしない（ローカル開発でSlack連携を使わない場合のデフォルト）
if [ -z "${SLACK_BOT_TOKEN:-}" ] || [ -z "${SLACK_CHANNEL:-}" ]; then
  exit 0
fi

notify_dir="/tmp/claude-notify"
# Notificationフックが最初のUserPromptSubmitより先に走る場合に備えて自分でも作っておく
mkdir -p "$notify_dir"

input="$(cat)"

session_id="$(printf '%s' "$input" | jq -r '.session_id // "unknown"')"

# 直前のUserPromptSubmitから60秒未満なら通知しない（短いやり取りでのSlack通知過多を防ぐ）
ts_file="${notify_dir}/${session_id}.last_prompt_ts"
if [ -f "$ts_file" ]; then
  last_user_epoch="$(cat "$ts_file")"
  now_epoch="$(date +%s)"
  elapsed=$((now_epoch - last_user_epoch))
  if [ "$elapsed" -lt 60 ]; then
    exit 0
  fi
fi

cwd="$(printf '%s' "$input" | jq -r '.cwd // empty')"
branch="(unknown)"
if [ -n "$cwd" ]; then
  branch="$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
fi


# スレッド準備
# agentsのコンテナ内パスはsandbox.shが環境変数SLACK_DIRで渡す（任意）。
# 未設定なら、スレッド親の作成・スレッドtsの記録・.mdのアップロードは行わず、通知だけを単独メッセージとして投稿する。
agents_dir="${SLACK_DIR:-}"
thread_file="${agents_dir}/slack_thread_ts"
thread_ts=""
if [ -n "$agents_dir" ] && [ -f "$thread_file" ]; then
  thread_ts="$(cat "$thread_file")"
fi
if [ -n "$agents_dir" ] && [ -z "$thread_ts" ]; then
  root_text="${branch}
Claude: 新規スレッド"

  # 通知先ユーザーが設定されていれば末尾にメンションを付ける。
  if [ -n "${SLACK_MEMBER:-}" ]; then
    root_text="${root_text}
<@${SLACK_MEMBER}>"
  fi

  root_payload="$(jq -n \
    --arg channel "$SLACK_CHANNEL" \
    --arg text "$root_text" \
    '{channel: $channel, text: $text}')"

  root_response="$(
    curl -fsS -X POST \
      -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
      -H 'Content-Type: application/json; charset=utf-8' \
      -d "$root_payload" \
      https://slack.com/api/chat.postMessage
  )"

  thread_ts="$(printf '%s' "$root_response" | jq -r '.ts // empty')"
  printf '%s' "$thread_ts" > "$thread_file"
fi

# フックの種類（Stop / Notification 等）。全フックの入力に共通してhook_event_nameが含まれる
hook_event_name="$(printf '%s' "$input" | jq -r '.hook_event_name // "unknown"')"
# 通知本文の取得元はフック種別で異なる
last_message=""
case "$hook_event_name" in
  Notification)
    last_message="$(printf '%s' "$input" | jq -r '.message // empty')"
    ;;
  Stop)
    last_message="$(printf '%s' "$input" | jq -r '.last_assistant_message // empty')"
    ;;
  StopFailure)
    # APIエラーでターンが終了した場合。エラー種別(rate_limit等)と詳細を本文にする
    last_message="$(printf '%s' "$input" | jq -r '[.error, .error_details, .last_assistant_message] | map(select(. != null and . != "")) | join("\n")')"
    ;;
esac

# ブランチ名は英数字とハイフン以外（"/"や"."等）を'-'へ置換してディレクトリ名にする（例: feature/foo → feature-foo）
branch_dir="$(printf '%s' "$branch" | tr -c 'A-Za-z0-9-' '-')"

text="${branch}
Claude(${hook_event_name})
${last_message}

*session*: ${session_id}"

# agents配下の.mdを毎回全件スレッドへアップロードする。

# 1ファイル分のアップロードURL発行と本体POSTを行い、成功したら紐付け用のJSONを1行で出力する
upload_md() {
  file_path="$1"
  file_name="$(basename "$file_path")"
  file_size="$(stat -c %s "$file_path" 2>/dev/null || echo 0)"
  # 空ファイルはgetUploadURLExternalがエラーになる
  if [ "$file_size" -le 0 ]; then
    return 0
  fi

  url_response="$(curl -fsS -X POST \
    -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
    --data-urlencode "filename=${file_name}" \
    --data-urlencode "length=${file_size}" \
    https://slack.com/api/files.getUploadURLExternal)" || return 0

  upload_url="$(printf '%s' "$url_response" | jq -r '.upload_url // empty')"
  file_id="$(printf '%s' "$url_response" | jq -r '.file_id // empty')"

  # 発行されたURL（files.slack.com）へ本体をPOSTする。ここはBot Token不要
  curl -fsS -X POST -F "file=@${file_path}" "$upload_url" > /dev/null || return 0

  jq -nc --arg id "$file_id" --arg title "$file_name" '{id: $id, title: $title}'
}

# アップロードできたファイルの紐付け用JSONを1行1件で貯めていく
file_entries=""
for md_path in ${agents_dir:+"$agents_dir"/*.md}; do
  # マッチが無い場合はグロブが展開されずそのまま渡ってくる
  [ -f "$md_path" ] || continue
  entry="$(upload_md "$md_path")"
  if [ -n "$entry" ]; then
    file_entries="${file_entries}${entry}
"
  fi
done


# $textは生の改行やlast_message由来の任意文字列（"、\等）を含むため、手動でのJSON組み立ては壊れる。jqでエスケープする
# スレッド親の作成に失敗してthread_tsが空のときは、キー自体を落として通知だけは単独メッセージとして投稿する

if [ -z "$file_entries" ]; then
  # ファイルが無いときは本文だけを投稿する
  payload="$(jq -n \
    --arg channel "$SLACK_CHANNEL" \
    --arg text "$text" \
    --arg thread_ts "$thread_ts" \
    '{channel: $channel, text: $text} + (if $thread_ts == "" then {} else {thread_ts: $thread_ts} end)')"

  curl -fsS -X POST \
    -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
    -H 'Content-Type: application/json; charset=utf-8' \
    -d "$payload" \
    https://slack.com/api/chat.postMessage > /dev/null
else
  # アップロード済みの分をまとめて1回のcompleteUploadExternalへ渡し、本文(initial_comment)と全ファイルを1メッセージにする
  payload="$(printf '%s' "$file_entries" | jq -s \
    --arg channel "$SLACK_CHANNEL" \
    --arg text "$text" \
    --arg thread_ts "$thread_ts" \
    '{channel_id: $channel, initial_comment: $text, files: .} + (if $thread_ts == "" then {} else {thread_ts: $thread_ts} end)')"

  curl -fsS -X POST \
    -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
    -H 'Content-Type: application/json; charset=utf-8' \
    -d "$payload" \
    https://slack.com/api/files.completeUploadExternal > /dev/null
fi

exit 0
