#!/bin/sh

# sh dockerhub.sh <タグ>
# 事前にdocker loginしておくこと
# 複数platformのbuildには、docker-containerドライバのbuildx builderまたはcontainerd image storeが必要
# （例: docker buildx create --use）

set -eux

# リポジトリルートで実行されることを前提とする
DOCKER_DIR="${PWD}/docker"

# imageのタグ。第1引数で指定する（必須。例: v1.0.0）。
IMAGE_TAG="${1:?第1引数にタグを指定してください（例: sh dockerhub.sh v1.0.0）}"
# build対象のplatform（カンマ区切り）
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"

# 全てのstageを同じリポジトリへpushし、stageの違いはタグで表す
REPO=jumpaku/claude-sandbox

# 複数platformのimageはローカルに読み込めないため、buildとpushを--pushで同時に行う

# claude-sandbox: ベース（フック用スクリプトなし）
docker buildx build \
    --platform "${PLATFORMS}" \
    --target claude-sandbox \
    -t "${REPO}:${IMAGE_TAG}" \
    -t "${REPO}:latest" \
    --push \
    "${DOCKER_DIR}"

# claude-sandbox-slack: ベース + Slack通知スクリプト（sandbox.shが使う、Dockerfileの最終stage）
docker buildx build \
    --platform "${PLATFORMS}" \
    --target claude-sandbox-slack \
    -t "${REPO}:${IMAGE_TAG}-slack" \
    -t "${REPO}:slack" \
    --push \
    "${DOCKER_DIR}"
