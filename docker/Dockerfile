FROM debian:forky-20260713-slim AS claude-sandbox

# iptables/ipset/dnsmasq: entrypoint.shが構築する外部通信の許可リスト方式のための一式
# curl: Claude Codeのネイティブインストーラ取得用（ビルド時のみ使用）、notify_slack.shのSlack通知送信にも使用
# jq: notify_slack.sh/user_prompt_submit_timestamp.shがフックの入力JSON・transcriptを解析するために使用
# git: notify_slack.shがカレントブランチ名の取得に使用
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        iptables \
        ipset \
        dnsmasq \
        ca-certificates \
        curl \
        jq \
        git \
    && rm -rf /var/lib/apt/lists/*

# claude用のユーザー作成
RUN useradd --create-home --uid 1000 --shell /bin/sh claude_user
USER claude_user
# ~/.claude配下を先にclaude_user所有で作っておく。
# 無いとsandbox.shがsettings.json等をmountすると、親ディレクトリがroot所有で作成されてしまう。
RUN mkdir -p /home/claude_user/.claude

# claudeのインストール
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/home/claude_user/.local/bin:${PATH}"

# 外部アクセスの制限
USER root
COPY dnsmasq.conf /etc/dnsmasq.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
WORKDIR /home/claude_user/workspace/
# entrypoint.shがrootでipset/iptablesを設定する必要があるため
ENTRYPOINT ["/entrypoint.sh"]

# claude-sandbox-slack: Slack通知用のスクリプトを追加するイメージ
FROM claude-sandbox AS claude-sandbox-slack

## Stop/NotificationフックからSlackへ通知するスクリプト
COPY notify_slack.sh /usr/local/bin/notify_slack.sh
RUN chmod +x /usr/local/bin/notify_slack.sh
## UserPromptSubmitフックから呼び出す、プロンプト送信時刻の記録スクリプト
COPY user_prompt_submit_timestamp.sh /usr/local/bin/user_prompt_submit_timestamp.sh
RUN chmod +x /usr/local/bin/user_prompt_submit_timestamp.sh
