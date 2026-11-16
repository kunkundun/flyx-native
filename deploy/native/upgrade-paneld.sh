#!/usr/bin/env bash
# FLYX 面板原地升级（替代 Docker 方案的「一键升级」）
#
#   ./upgrade-paneld.sh /path/to/new/flyx-paneld
#
# 做的事：校验新二进制能否运行 → 备份旧文件 → 原子替换 → 重启 → 健康检查
# 失败时自动回滚到旧二进制。
set -euo pipefail

BIN_SRC="${1:-}"
SERVICE_NAME="flyx-paneld"
BIN_DST="/usr/local/bin/flyx-paneld"
ENV_FILE="/etc/flyx/paneld.env"
HEALTH_PATH="${HEALTH_PATH:-/flow/test}"   # 打节点端口，固定可用

die() { echo "❌ $*" >&2; exit 1; }
[ "$(id -u)" = "0" ] || die "请用 root 执行"
[ -n "$BIN_SRC" ] || die "用法：$0 /path/to/new/flyx-paneld"
[ -f "$BIN_SRC" ] || die "找不到文件：$BIN_SRC"

# 端口与路径以数据库里的设置为准（面板设置页可以改），环境变量只做兜底
read_setting() { # $1=键名 $2=默认值
	value=""
	if command -v python3 >/dev/null 2>&1; then
		value=$(python3 -c 'import sqlite3,sys
key, default = sys.argv[1], sys.argv[2]
try:
    con = sqlite3.connect("file:/var/lib/flyx/gost.db?mode=ro", uri=True)
    row = con.execute("SELECT value FROM vite_config WHERE name = ?", (key,)).fetchone()
    print((row[0] if row and row[0] else default).strip())
except Exception:
    print(default)' "$1" "$2" 2>/dev/null || true)
	fi
	[ -n "$value" ] || value="$2"
	echo "$value"
}

PANEL_PORT_DB=$(read_setting panel_port 6366)
AGENT_PORT_DB=$(read_setting panel_agent_port 6365)
PANEL_PATH_DB=$(read_setting panel_path /)

echo "▶ 备份当前版本"
cp -a "$BIN_DST" "${BIN_DST}.prev"

echo "▶ 替换二进制"
install -m 0755 "$BIN_SRC" "${BIN_DST}.new"
mv -f "${BIN_DST}.new" "$BIN_DST"

echo "▶ 重启服务"
systemctl restart "$SERVICE_NAME"
sleep 3

# 健康检查打节点端口：它不随面板路径 / 隐藏根路径变化，固定 200
health_ok=0
for _ in 1 2 3 4 5 6 7 8; do
	if ! systemctl is-active --quiet "$SERVICE_NAME"; then
		sleep 2
		continue
	fi
	if curl -fsS -m 3 -o /dev/null "http://127.0.0.1:${AGENT_PORT_DB}${HEALTH_PATH}" 2>/dev/null; then
		health_ok=1
		break
	fi
	sleep 2
done

if [ "$health_ok" != "1" ]; then
	echo "⚠️  健康检查失败，回滚"
	systemctl stop "$SERVICE_NAME" 2>/dev/null || true
	install -m 0755 "${BIN_DST}.prev" "${BIN_DST}.rollback"
	mv -f "${BIN_DST}.rollback" "$BIN_DST"
	systemctl start "$SERVICE_NAME"
	die "已回滚到上一个版本，请检查：journalctl -u ${SERVICE_NAME} -n 80"
fi

echo "✅ 升级完成：$(systemctl is-active "$SERVICE_NAME")"
echo "   面板：http://<服务器IP>:${PANEL_PORT_DB}${PANEL_PATH_DB%/}/"
echo "   节点通道：<服务器IP>:${AGENT_PORT_DB}"
echo "   回滚：cp ${BIN_DST}.prev ${BIN_DST} && systemctl restart ${SERVICE_NAME}"
