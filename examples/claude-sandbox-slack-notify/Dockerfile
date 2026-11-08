# claude-sandboxをベースに、slack-notifyプラグインを組み込んだイメージの例
# リポジトリルートで実行する。plugins/をビルドコンテキスト"plugins"として渡す（このリポジトリのローカルのplugins/を使う）
# docker build --build-context plugins=plugins -t my-claude-sandbox examples/claude-sandbox-slack-notify

# ENTRYPOINT・CMD・WORKDIRはclaude-sandboxのものを引き継ぐ
FROM jumpaku/claude-sandbox:latest

# claude起動時に--plugin-dir /opt/claude-plugins/slack-notifyで読み込ませる
# --chownを付けないのでroot所有になり、コンテナ内のclaudeからは書き換えられない
COPY --from=plugins /slack-notify /opt/claude-plugins/slack-notify

# ~/.slack-notify配下（data/やthread_ts）だけをマウントしても書き込めるよう、claude_user所有で先に作っておく
USER claude_user
RUN mkdir -p /home/claude_user/.slack-notify/data
# entrypoint.shがrootで許可リストを構築するため、rootに戻す
USER root
