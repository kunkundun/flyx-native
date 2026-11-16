#!/usr/bin/env bash
# 构建内嵌前端的 paneld 二进制
#
#   ./scripts/build-panel.sh                 # 本机架构
#   GOOS=linux GOARCH=amd64 ./scripts/build-panel.sh
#
# 步骤：构建前端 → 拷贝 dist 到 internal/webserver/dist → go build
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
FRONTEND="$ROOT/../vite-frontend"
OUT="${OUT:-$ROOT/bin/paneld}"

PNPM="pnpm"
command -v pnpm >/dev/null 2>&1 || PNPM="npx --yes pnpm@10"
# 本机 Node 版本不在 package.json 的 engines 里时也能构建（CI 用官方 Node 版本即可）
export npm_config_engine_strict="${npm_config_engine_strict:-false}"

echo "▶ 构建前端"
(cd "$FRONTEND" && $PNPM install --frozen-lockfile >/dev/null && $PNPM run build >/dev/null)

echo "▶ 拷贝 dist 到 go-backend/internal/webserver/dist"
rm -rf "$ROOT/internal/webserver/dist"
mkdir -p "$ROOT/internal/webserver/dist"
cp -R "$FRONTEND/dist/." "$ROOT/internal/webserver/dist/"
touch "$ROOT/internal/webserver/dist/.gitkeep"

echo "▶ 编译 paneld"
mkdir -p "$(dirname "$OUT")"
CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o "$OUT" ./cmd/paneld

echo "✅ 完成：$OUT"
ls -lh "$OUT"
