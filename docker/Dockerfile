FROM debian:forky-20261104-slim AS claude-sandbox

# iptables/ipset/dnsmasq: entrypoint.shが構築する外部通信の許可リスト方式のための一式
# curl: Claude Codeのネイティブインストーラ取得用
# jq: Claude CodeのJSON（フックの入力、トランスクリプト、設定ファイル等）を扱う用
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        iptables \
        ipset \
        dnsmasq \
        ca-certificates \
        curl \
        jq \
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
# 許可リストの構築後に実行するコマンド。docker run <image> <コマンド>で差し替えられる
CMD ["sleep", "infinity"]
