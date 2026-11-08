#!/bin/sh

# Claude CodeのStop/StopFailure/Notification/PermissionRequestフックから呼ばれ、直前のUserPromptSubmit(user_prompt_submit_timestamp.shが記録)から60秒以上経過していればSlackへ通知する。
# 許可待ちはNotification(notification_type=permission_prompt)とPermissionRequestの両方で呼ばれるため、本文の詳しいPermissionRequest側だけで通知する。
# 初回はスレッド親となるメッセージを先に送ってそのtsを~/.slack-notify/thread_tsに記録し、通知は常にそのスレッドへぶら下げる。
# さらに~/.slack-notify/data直下の.mdを毎回全件、通知と同じスレッドへファイルとしてアップロードする。

set -u

# 未設定なら通知先が無いので何もしない（ローカル開発でSlack連携を使わない場合のデフォルト）
if [ -z "${SLACK_BOT_TOKEN:-}" ] || [ -z "${SLACK_CHANNEL:-}" ]; then
  exit 0
fi

# 入力JSONの解析とSlackへのpayload組み立てに必須
if ! command -v jq > /dev/null 2>&1; then
  echo "slack_notify.sh: jq not found" >&2
  exit 0
fi

notify_dir="/tmp/claude-notify"
# Notificationフックが最初のUserPromptSubmitより先に走る場合に備えて自分でも作っておく
mkdir -p "$notify_dir"

input="$(cat)"

session_id="$(printf '%s' "$input" | jq -r '.session_id // "unknown"')"

# フックの種類（Stop / Notification 等）。全フックの入力に共通してhook_event_nameが含まれる
hook_event_name="$(printf '%s' "$input" | jq -r '.hook_event_name // "unknown"')"

# 許可待ちのNotificationはPermissionRequestと重複するので通知しない
if [ "$hook_event_name" = "Notification" ] \
  && [ "$(printf '%s' "$input" | jq -r '.notification_type // empty')" = "permission_prompt" ]; then
  exit 0
fi

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

# セッションタイトルをトランスクリプト(JSONL)から取り出す。
# /renameで付けた名前(type=custom-title)を優先し、無ければ自動生成のタイトル(type=ai-title)の最新を使う。
# 1ターン目の直後などタイトルがまだ記録されていないときは「(タイトル未設定)」にする
transcript_path="$(printf '%s' "$input" | jq -r '.transcript_path // empty')"
session_title=""
if [ -f "$transcript_path" ]; then
  session_title="$(grep '"type":"custom-title"' "$transcript_path" | tail -n 1 | jq -r '.customTitle // empty' 2>/dev/null)"
  if [ -z "$session_title" ]; then
    session_title="$(grep '"type":"ai-title"' "$transcript_path" | tail -n 1 | jq -r '.aiTitle // empty' 2>/dev/null)"
  fi
fi
session_title="${session_title:-(タイトル未設定)}"


# スレッド準備
# スレッドtsの記録先と、.mdのアップロード元。コンテナ内の~/.slack-notify配下に固定し、
# ホストからマウントしてカスタマイズできるようにする（thread_tsはファイル、dataはフォルダ）
notify_home="/home/claude_user/.slack-notify"
data_dir="${notify_home}/data"
thread_file="${notify_home}/thread_ts"
thread_ts=""
if [ -f "$thread_file" ]; then
  thread_ts="$(cat "$thread_file")"
fi
if [ -z "$thread_ts" ]; then
  root_text="${session_title}
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
  # 失敗時(ok:false等でtsが無い)は記録せず、次回また親メッセージの作成を試みる
  if [ -n "$thread_ts" ]; then
    mkdir -p "$notify_home"
    printf '%s' "$thread_ts" > "$thread_file"
  fi
fi

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
  PermissionRequest)
    # 許可を求めているツールと、その内容（Bashならコマンド、それ以外は入力JSON）。長い入力は500文字で切る
    last_message="$(printf '%s' "$input" | jq -r '
      "許可待ち: \(.tool_name // "unknown")\n"
      + ((.tool_input.command // (.tool_input | tojson? // "")) | tostring | .[0:500])')"
    ;;
esac

text="${session_title}
Claude(${hook_event_name})
${last_message}

*session*: ${session_id}"

# ~/.slack-notify/data配下の.mdを毎回全件スレッドへアップロードする。

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
for md_path in "$data_dir"/*.md; do
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
