#!/usr/bin/env bash
# 打包发布产物：多架构 paneld 二进制 + install-panel.sh + sha256
#
#   ./scripts/package-release.sh            # 版本号取 git describe
#   VERSION=3.0.0 ./scripts/package-release.sh
#
# 产物在 dist/ 下：
#   flyx-paneld-linux-amd64 / -arm64   给 install-panel.sh 下载用
#   flyx-native-<version>.tar.gz           整套（含 install-panel.sh、systemd 单元、文档）
#   SHA256SUMS
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
OUT="$ROOT/dist"
VERSION="${VERSION:-$(git describe --tags --always --dirty 2>/dev/null || echo dev)}"

echo "▶ 版本：$VERSION"
# 没有全局 pnpm 时退回 npx（CI 里用 npm i -g pnpm）
PNPM="pnpm"
command -v pnpm >/dev/null 2>&1 || PNPM="npx --yes pnpm@10"
# 本机 Node 版本不在 package.json 的 engines 里时也能构建（CI 用官方 Node 版本即可）
export npm_config_engine_strict="${npm_config_engine_strict:-false}"

echo "▶ 构建前端"
(cd "$ROOT/vite-frontend" && $PNPM install --frozen-lockfile >/dev/null && $PNPM run build >/dev/null)
rm -rf "$ROOT/go-backend/internal/webserver/dist"
mkdir -p "$ROOT/go-backend/internal/webserver/dist"
cp -R "$ROOT/vite-frontend/dist/." "$ROOT/go-backend/internal/webserver/dist/"
touch "$ROOT/go-backend/internal/webserver/dist/.gitkeep"

mkdir -p "$OUT"

# 节点 agent 的下载来源（面板生成的安装命令会用这个仓库）
GITHUB_REPO="${GITHUB_REPO:-kunkundun/flyx-native}"

for arch in amd64 arm64; do
	echo "▶ 编译 linux/$arch 面板"
	(
		cd "$ROOT/go-backend"
		CGO_ENABLED=0 GOOS=linux GOARCH="$arch" \
			go build -trimpath \
			-ldflags="-s -w -X main.version=$VERSION -X go-backend/internal/http/handler.githubRepo=$GITHUB_REPO" \
			-o "$OUT/flyx-paneld-linux-$arch" ./cmd/paneld
	)

	echo "▶ 编译 linux/$arch 节点 agent"
	(
		cd "$ROOT/go-gost"
		CGO_ENABLED=0 GOOS=linux GOARCH="$arch" \
			go build -trimpath -ldflags="-s -w -X main.version=$VERSION" \
			-o "$OUT/gost-$arch" .
	)
done

echo "▶ 附带安装脚本（节点安装命令 + 面板一键安装都会从这里下载）"
cp -f "$ROOT/install.sh" "$OUT/install.sh"
cp -f "$ROOT/install-panel.sh" "$OUT/install-panel.sh"

echo "▶ 打包整套"
tar czf "$OUT/flyx-native-$VERSION.tar.gz" \
	-C "$ROOT" install-panel.sh README.md docs/native-deploy.md deploy/native

echo "▶ 校验和"
(
	cd "$OUT"
	sha256sum flyx-paneld-linux-* flyx-native-"$VERSION".tar.gz >SHA256SUMS
	cat SHA256SUMS
)

echo
echo "✅ 完成：$OUT"
ls -lh "$OUT" | tail -6
echo
echo "发布：gh release create $VERSION dist/* --title \"$VERSION\" --notes \"FLYX 面板原生部署版\""
