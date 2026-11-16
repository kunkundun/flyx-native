#!/bin/sh
# shellcheck shell=bash

# Alpine 默认不带 Bash。先用系统自带的 /bin/sh 安装/切换到 Bash，
# 后续主体继续使用 Bash 语法，避免要求用户手动准备运行环境。
if [ -z "${BASH_VERSION:-}" ]; then
  if command -v bash >/dev/null 2>&1; then
    exec bash "$0" "$@"
  fi

  if [ -f /etc/alpine-release ] && command -v apk >/dev/null 2>&1; then
    if [ "$(id -u)" -eq 0 ]; then
      apk add --no-cache bash
    elif command -v sudo >/dev/null 2>&1; then
      sudo apk add --no-cache bash
    elif command -v doas >/dev/null 2>&1; then
      doas apk add --no-cache bash
    else
      echo "❌ Alpine 安装需要 root 权限，或已配置 sudo/doas。" >&2
      exit 1
    fi

    exec bash "$0" "$@"
  fi

  echo "❌ 此安装脚本需要 Bash。" >&2
  exit 1
fi

# GitHub repo used for release downloads（可用 REPO=owner/repo 覆盖）
REPO="${REPO:-kunkundun/flyx-native}"

# 固定版本号（Release 构建时自动填充，留空则获取最新版）
PINNED_VERSION=""

# 获取系统架构
get_architecture() {
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)
            echo "amd64"
            ;;
        aarch64|arm64)
            echo "arm64"
            ;;
        *)
            echo "amd64"  # 默认使用 amd64
            ;;
    esac
}

# 安装目录
INSTALL_DIR="/etc/flyx-agent"
AGENT_NAME="flyx-agent"
AGENT_SYSTEMD_SERVICE_FILE="/etc/systemd/system/flyx-agent.service"
AGENT_OPENRC_SERVICE_FILE="/etc/init.d/flyx-agent"

# flux-panel, FLVX and FLYX before 3.4.0 all install to /etc/flux_agent.
# Only a FLYX agent of this panel (same addr in config.json) is kept in place,
# so it upgrades and rolls back from its old path; any other agent there
# belongs to another panel and is left alone.
legacy_agent_matches_panel() {
  local config="$1/config.json" addr
  [[ -n "$SERVER_ADDR" && -f "$config" ]] || return 1
  addr=$(grep -o '"addr"[[:space:]]*:[[:space:]]*"[^"]*"' "$config" | head -n 1 | sed 's/.*"\([^"]*\)"$/\1/')
  [[ -n "$addr" && "$addr" == "$(json_escape "$SERVER_ADDR")" ]]
}

# The menu has no panel address to compare, so let the user decide.
confirm_legacy_agent() {
  local etc_root="${AGENT_ETC_ROOT:-/etc}" confirm
  [[ ! -e "$INSTALL_DIR/config.json" && ! -e "$INSTALL_DIR/$AGENT_NAME" ]] || return 0
  [[ -e "$etc_root/flux_agent/config.json" || -e "$etc_root/flux_agent/flux_agent" ]] || return 0
  echo "⚠️ 未找到 $INSTALL_DIR，但发现 $etc_root/flux_agent。"
  echo "   它可能是 3.4.0 之前的 FLYX agent，也可能属于 flux-panel / FLVX 等其他面板。"
  read -p "确认 $etc_root/flux_agent 是本面板的 FLYX agent 吗？(y/N): " confirm
  [[ "$confirm" == "y" || "$confirm" == "Y" ]] || return 0
  AGENT_NAME="flux_agent"
  INSTALL_DIR="$etc_root/flux_agent"
  AGENT_SYSTEMD_SERVICE_FILE="$etc_root/systemd/system/$AGENT_NAME.service"
  AGENT_OPENRC_SERVICE_FILE="$etc_root/init.d/$AGENT_NAME"
}

resolve_agent_installation() {
  local etc_root="${AGENT_ETC_ROOT:-/etc}"
  local current="$etc_root/flyx-agent" legacy="$etc_root/flux_agent"
  AGENT_NAME="flyx-agent"
  INSTALL_DIR="$current"
  if [[ ! -e "$current/config.json" && ! -e "$current/flyx-agent" ]] && legacy_agent_matches_panel "$legacy"; then
    AGENT_NAME="flux_agent"
    INSTALL_DIR="$legacy"
  fi
  AGENT_SYSTEMD_SERVICE_FILE="$etc_root/systemd/system/$AGENT_NAME.service"
  AGENT_OPENRC_SERVICE_FILE="$etc_root/init.d/$AGENT_NAME"
}
SERVICE_MANAGER="${SERVICE_MANAGER:-}"

# 镜像加速配置（可由面板传入或交互式询问）
#
# PROXY_ENABLED:
#   auto   （默认/面板下发）：直连与各镜像并行测速，选最快的一个
#   true   ：兼容旧值，等同 auto（优先用 PROXY_URL，再回退直连/其它镜像）
#   false  ：只直连
PROXY_ENABLED="${PROXY_ENABLED:-}"
PROXY_URL="${PROXY_URL:-}"
# 候选镜像（可用 PROXY_CANDIDATES="a b c" 覆盖）
PROXY_CANDIDATES="${PROXY_CANDIDATES:-https://gh-proxy.com https://ghfast.top https://githubproxy.cc}"
# 探测用的分片大小与超时
PROBE_BYTES="${PROBE_BYTES:-262144}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-6}"

ensure_alpine_runtime_dependencies() {
  [[ -f /etc/alpine-release ]] || return 0

  local missing_packages=()
  local privileged_command=""

  command -v curl >/dev/null 2>&1 || missing_packages+=(curl)
  [[ -f /etc/ssl/certs/ca-certificates.crt ]] || missing_packages+=(ca-certificates)

  if [[ ${#missing_packages[@]} -eq 0 ]]; then
    return 0
  fi

  if [[ $EUID -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
      privileged_command="sudo"
    elif command -v doas >/dev/null 2>&1; then
      privileged_command="doas"
    else
      echo "❌ Alpine 安装需要 root 权限，或已配置 sudo/doas 来安装依赖: ${missing_packages[*]}。" >&2
      return 1
    fi
  fi

  echo "📦 Alpine 缺少运行依赖，正在安装: ${missing_packages[*]}"
  if [[ -n "$privileged_command" ]]; then
    "$privileged_command" apk add --no-cache "${missing_packages[@]}"
  else
    apk add --no-cache "${missing_packages[@]}"
  fi
}

# 把一个加速地址规范成 "https://host" 形式（无尾斜杠）
normalize_proxy_prefix() {
  local proxy="$1"
  [[ -z "$proxy" ]] && return 0
  if [[ "$proxy" != https://* && "$proxy" != http://* ]]; then
    proxy="https://$proxy"
  fi
  echo "${proxy%/}"
}

# 测速：返回整数 KB/s，失败返回 0
probe_speed() {
  local url="$1" out code speed
  out=$(curl -sL -m "$PROBE_TIMEOUT" -r "0-$((PROBE_BYTES - 1))" -o /dev/null \
    -w '%{http_code} %{speed_download}' "$url" 2>/dev/null || true)
  set -- $out
  code="${1:-000}"
  speed="${2:-0}"
  case "$code" in
    200 | 206) awk -v s="$speed" 'BEGIN { printf "%d", s / 1024 }' ;;
    *) echo 0 ;;
  esac
}

# 把探测结果写入安装目录与 systemd journal（装完后仍可追溯）
record_route() {
  local chosen="$1" speed="$2" table="$3"
  local line route_file
  # 目录不可写（例如 CI 里没有 /etc 权限）时回退到 /tmp
  route_file="${INSTALL_DIR:-/tmp}/install-route.txt"
  if ! mkdir -p "$(dirname "$route_file")" 2>/dev/null || [ ! -w "$(dirname "$route_file")" ]; then
    route_file="/tmp/flyx-agent-install-route.txt"
  fi
  line="route: chosen=${chosen:-direct} speed=${speed}KB/s"
  mkdir -p "$(dirname "$route_file")" 2>/dev/null || true
  {
    echo "# FLYX agent 安装时的下载线路探测结果"
    echo "time=$(date -Is 2>/dev/null || date)"
    echo "repo=${REPO}"
    echo "version=${RESOLVED_VERSION:-${VERSION:-latest}}"
    echo "chosen=${chosen:-direct}"
    echo "speed_kbps=${speed}"
    echo "candidates:"
    printf '%s\n' "$table"
  } >"$route_file" 2>/dev/null || true
  if command -v systemd-cat >/dev/null 2>&1; then
    printf '%s\n%s\n' "$line" "$table" | systemd-cat -t flyx-install -p info 2>/dev/null || true
  elif command -v logger >/dev/null 2>&1; then
    logger -t flyx-install "$line" 2>/dev/null || true
  fi
  echo "📝 线路选择已记录：${route_file}（journalctl -t flyx-install 也可查）" >&2
}

# 选出最快的下载前缀："" 表示直连，其它为 "https://mirror"
# 首次调用时并行探测一次，结果缓存到 RESOLVED_URL_PREFIX
RESOLVED_URL_PREFIX=""
RESOLVED_URL_PREFIX_DONE=""

resolve_url_prefix() {
  if [[ -n "$RESOLVED_URL_PREFIX_DONE" ]]; then
    echo "$RESOLVED_URL_PREFIX"
    return
  fi

  local mode="$PROXY_ENABLED"
  [[ -z "$mode" ]] && mode="auto"
  [[ "$mode" == "true" ]] && mode="auto"

  local preference
  preference=$(normalize_proxy_prefix "$PROXY_URL")
  if [[ "$mode" == "proxy" ]]; then
    RESOLVED_URL_PREFIX="$preference"
    RESOLVED_URL_PREFIX_DONE="1"
    record_route "${preference:-direct}" "skipped" "  （未探测：PROXY_ENABLED=proxy）"
    echo "$RESOLVED_URL_PREFIX"
    return
  fi

  if [[ "$mode" == "false" || "$mode" == "direct" ]]; then
    RESOLVED_URL_PREFIX=""
    RESOLVED_URL_PREFIX_DONE="1"
    record_route "direct" "skipped" "  （未探测：PROXY_ENABLED=${mode}）"
    echo ""
    return
  fi

  local arch
  arch=$(get_architecture)
  local target="https://github.com/${REPO}/releases/latest/download/gost-${arch}"

  # 候选：直连 + 面板配置的代理 + 内置候选
  local -a prefixes=() speeds=()
  prefixes+=("")
  [[ -n "$preference" ]] && prefixes+=("$preference")
  local candidate
  for candidate in $PROXY_CANDIDATES; do
    candidate=$(normalize_proxy_prefix "$candidate")
    [[ -n "$candidate" ]] && prefixes+=("$candidate")
  done

  # 去重
  local -a uniq=()
  local seen=" "
  for candidate in "${prefixes[@]}"; do
    if [[ "$seen" != *" $candidate "* ]]; then
      uniq+=("$candidate")
      seen="$seen$candidate "
    fi
  done
  prefixes=("${uniq[@]}")

  if [[ ${#prefixes[@]} -eq 1 ]]; then
    RESOLVED_URL_PREFIX="${prefixes[0]}"
    RESOLVED_URL_PREFIX_DONE="1"
    record_route "${prefixes[0]}" "skipped" "  （未探测：只有一个候选）"
    echo "$RESOLVED_URL_PREFIX"
    return
  fi


  echo "🔍 正在探测最快的下载线路（直连 + ${#prefixes[@]} 个候选，最多 ${PROBE_TIMEOUT}s）..." >&2
  local tmpdir
  tmpdir=$(mktemp -d)
  local i=0
  for candidate in "${prefixes[@]}"; do
    (
      local url="$target"
      [[ -n "$candidate" ]] && url="${candidate}/${target}"
      probe_speed "$url" >"$tmpdir/$i" 2>/dev/null
    ) &
    i=$((i + 1))
  done
  wait

  local best_prefix="" best_speed=0 idx=0
  local probe_table=""
  for candidate in "${prefixes[@]}"; do
    local spd label
    spd=$(cat "$tmpdir/$idx" 2>/dev/null || echo 0)
    [[ -z "$spd" ]] && spd=0
    label="${candidate:-直连}"
    echo "   $label: ${spd} KB/s" >&2
    probe_table="${probe_table}  ${label} = ${spd} KB/s
"
    if [[ "$spd" -gt "$best_speed" ]]; then
      best_speed="$spd"
      best_prefix="$candidate"
    fi
    idx=$((idx + 1))
  done
  rm -rf "$tmpdir"

  if [[ "$best_speed" -le 0 ]]; then
    # 全部探测失败：按保守顺序回退（仍优先代理，因为多数失败场景在受限网络）
    best_prefix="${preference:-${prefixes[1]:-}}"
    echo "⚠️  所有线路探测均失败，回退：${best_prefix:-直连}" >&2
    record_route "$best_prefix" "0(fallback)" "$probe_table"
  else
    echo "✅ 选用：${best_prefix:-直连}（${best_speed} KB/s）" >&2
  fi

  record_route "$best_prefix" "$best_speed" "$probe_table"

  RESOLVED_URL_PREFIX="$best_prefix"
  RESOLVED_URL_PREFIX_DONE="1"
  echo "$RESOLVED_URL_PREFIX"
}

# 拼接下载地址（自动选择最快线路）
maybe_proxy_url() {
  local url="$1"
  local prefix
  prefix=$(resolve_url_prefix)
  if [[ -z "$prefix" ]]; then
    echo "$url"
  else
    echo "${prefix}/${url}"
  fi
}

ask_proxy_config() {
  if [[ -n "$PROXY_ENABLED" ]]; then
    return
  fi

  if [[ -n "$PROXY_URL" ]]; then
    PROXY_ENABLED="true"
    return
  fi

  echo ""
  echo "==============================================="
  echo "           GitHub 下载线路"
  echo "==============================================="
  if ! read -r -p "自动选择最快线路（直连/镜像测速对比）? (Y/n): " proxy_choice; then
    proxy_choice=""
  fi
  case "$proxy_choice" in
    n|N)
      if ! read -r -p "只直连 GitHub? (Y/n): " direct_choice; then
        direct_choice=""
      fi
      case "$direct_choice" in
        n|N)
          if ! read -r -p "加速地址: " input_url; then
            input_url=""
          fi
          PROXY_ENABLED="true"
          PROXY_URL="${input_url}"
          ;;
        *)
          PROXY_ENABLED="false"
          echo "已选择只直连 GitHub"
          ;;
      esac
      ;;
    *)
      PROXY_ENABLED="auto"
      if ! read -r -p "额外候选加速地址（可留空，默认 gh-proxy.com 等）: " input_url; then
        input_url=""
      fi
      [[ -n "$input_url" ]] && PROXY_URL="$input_url"
      echo "已开启自动选择（直连 + 镜像测速）"
      ;;
  esac
  echo "==============================================="
}

resolve_latest_release_tag() {
  local effective_url tag api_tag latest_url api_url

  latest_url="https://github.com/${REPO}/releases/latest"
  api_url="https://api.github.com/repos/${REPO}/releases/latest"

  effective_url=$(curl -fsSL -o /dev/null -w '%{url_effective}' -L "$(maybe_proxy_url "$latest_url")" 2>/dev/null || true)
  tag="${effective_url##*/}"
  if [[ -n "$tag" && "$tag" != "latest" ]]; then
    echo "$tag"
    return 0
  fi

  api_tag=$(curl -fsSL "$(maybe_proxy_url "$api_url")" 2>/dev/null | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' || true)
  if [[ -n "$api_tag" ]]; then
    echo "$api_tag"
    return 0
  fi

  return 1
}

resolve_version() {
  if [[ -n "${VERSION:-}" ]]; then
    echo "$VERSION"
    return 0
  fi
  if [[ -n "${FLYX_VERSION:-}" ]]; then
    echo "$FLYX_VERSION"
    return 0
  fi
  if [[ -n "${FLUX_VERSION:-}" ]]; then
    echo "$FLUX_VERSION"
    return 0
  fi
  if [[ -n "${PINNED_VERSION:-}" ]]; then
    echo "$PINNED_VERSION"
    return 0
  fi

  if resolve_latest_release_tag; then
    return 0
  fi

  echo "❌ 无法获取最新版本号。你可以手动指定版本，例如：VERSION=<版本号> ./install.sh" >&2
  return 1
}

# 构建下载地址
build_download_url() {
    local ARCH=$(get_architecture)
    echo "https://github.com/${REPO}/releases/download/${RESOLVED_VERSION}/gost-${ARCH}"
}

ensure_download_url_initialized() {
  ensure_alpine_runtime_dependencies || return 1

  if [[ -n "${DOWNLOAD_URL:-}" ]]; then
    return 0
  fi

  RESOLVED_VERSION=$(resolve_version) || return 1
  DOWNLOAD_URL=$(maybe_proxy_url "$(build_download_url)")
}



# 显示菜单
show_menu() {
  echo "==============================================="
  echo "              管理脚本"
  echo "==============================================="
  echo "请选择操作："
  echo "1. 安装"
  echo "2. 更新"  
  echo "3. 卸载"
  echo "4. 退出"
  echo "==============================================="
}

# 删除脚本自身
delete_self() {
  echo ""
  echo "🗑️ 操作已完成，正在清理脚本文件..."
  SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
  sleep 1
  rm -f "$SCRIPT_PATH" && echo "✅ 脚本文件已删除" || echo "❌ 删除脚本文件失败"
}

# 检查并安装 tcpkill
check_and_install_tcpkill() {
  # 检查 tcpkill 是否已安装
  if command -v tcpkill &> /dev/null; then
    return 0
  fi
  
  # 检测操作系统类型
  OS_TYPE=$(uname -s)
  
  # 检查是否需要 sudo
  if [[ $EUID -ne 0 ]]; then
    SUDO_CMD="sudo"
  else
    SUDO_CMD=""
  fi
  
  if [[ "$OS_TYPE" == "Darwin" ]]; then
    if command -v brew &> /dev/null; then
      brew install dsniff &> /dev/null
    fi
    return 0
  fi
  
  # 检测 Linux 发行版并安装对应的包
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO=$ID
  elif [ -f /etc/redhat-release ]; then
    DISTRO="rhel"
  elif [ -f /etc/debian_version ]; then
    DISTRO="debian"
  else
    return 0
  fi
  
  case $DISTRO in
    ubuntu|debian)
      $SUDO_CMD apt update &> /dev/null
      $SUDO_CMD apt install -y dsniff &> /dev/null
      ;;
    centos|rhel|fedora)
      if command -v dnf &> /dev/null; then
        $SUDO_CMD dnf install -y dsniff &> /dev/null
      elif command -v yum &> /dev/null; then
        $SUDO_CMD yum install -y dsniff &> /dev/null
      fi
      ;;
    alpine)
      $SUDO_CMD apk add --no-cache dsniff &> /dev/null
      ;;
    arch|manjaro)
      $SUDO_CMD pacman -S --noconfirm dsniff &> /dev/null
      ;;
    opensuse*|sles)
      $SUDO_CMD zypper install -y dsniff &> /dev/null
      ;;
    gentoo)
      $SUDO_CMD emerge --ask=n net-analyzer/dsniff &> /dev/null
      ;;
    void)
      $SUDO_CMD xbps-install -Sy dsniff &> /dev/null
      ;;
  esac
  
  return 0
}

json_escape() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf '%s' "$value"
}

write_agent_config() {
  local path="$1"
  printf '{\n  "addr": "%s",\n  "secret": "%s"\n}\n' \
    "$(json_escape "$SERVER_ADDR")" \
    "$(json_escape "$SECRET")" > "$path"
}

ensure_service_manager() {
  if [[ -n "$SERVICE_MANAGER" ]]; then
    case "$SERVICE_MANAGER" in
      systemd|openrc)
        return 0
        ;;
      *)
        echo "❌ 不支持的服务管理器: $SERVICE_MANAGER" >&2
        return 1
        ;;
    esac
  fi

  # Alpine uses OpenRC even if a systemctl compatibility command happens to be installed.
  if [[ -f /etc/alpine-release ]]; then
    if command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then
      SERVICE_MANAGER="openrc"
      return 0
    fi
  elif command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    SERVICE_MANAGER="systemd"
    return 0
  elif command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then
    SERVICE_MANAGER="openrc"
    return 0
  fi

  echo "❌ 未检测到受支持的服务管理器（systemd 或 OpenRC）。" >&2
  return 1
}

agent_service_exists() {
  ensure_service_manager || return 1

  case "$SERVICE_MANAGER" in
    systemd)
      [[ -f "$AGENT_SYSTEMD_SERVICE_FILE" ]] || \
        systemctl list-units --full -all 2>/dev/null | grep -Fq "$AGENT_NAME.service"
      ;;
    openrc)
      [[ -f "$AGENT_OPENRC_SERVICE_FILE" ]]
      ;;
  esac
}

stop_agent_service() {
  ensure_service_manager || return 1

  case "$SERVICE_MANAGER" in
    systemd)
      systemctl stop "$AGENT_NAME" 2>/dev/null || true
      ;;
    openrc)
      rc-service "$AGENT_NAME" stop 2>/dev/null || true
      ;;
  esac
}

disable_agent_service() {
  ensure_service_manager || return 1

  case "$SERVICE_MANAGER" in
    systemd)
      systemctl disable "$AGENT_NAME" 2>/dev/null || true
      ;;
    openrc)
      rc-update del "$AGENT_NAME" default 2>/dev/null || true
      ;;
  esac
}

write_agent_service() {
  ensure_service_manager || return 1

  case "$SERVICE_MANAGER" in
    systemd)
      mkdir -p "$(dirname "$AGENT_SYSTEMD_SERVICE_FILE")"
      cat > "$AGENT_SYSTEMD_SERVICE_FILE" <<EOF
[Unit]
Description=FLYX Agent Proxy Service
After=network.target

[Service]
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/$AGENT_NAME
Environment=GODEBUG=disablethp=1
Restart=on-failure
StandardOutput=null
StandardError=null

[Install]
WantedBy=multi-user.target
EOF
      ;;
    openrc)
      mkdir -p "$(dirname "$AGENT_OPENRC_SERVICE_FILE")"
      cat > "$AGENT_OPENRC_SERVICE_FILE" <<EOF
#!/sbin/openrc-run

name="$AGENT_NAME"
description="FLYX Agent Proxy Service"
command="$INSTALL_DIR/$AGENT_NAME"
directory="$INSTALL_DIR"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="/dev/null"
error_log="/dev/null"

depend() {
  need net
}
EOF
      chmod +x "$AGENT_OPENRC_SERVICE_FILE"
      ;;
  esac
}

enable_and_start_agent_service() {
  ensure_service_manager || return 1

  case "$SERVICE_MANAGER" in
    systemd)
      systemctl daemon-reload
      systemctl enable "$AGENT_NAME"
      systemctl start "$AGENT_NAME"
      ;;
    openrc)
      rc-update add "$AGENT_NAME" default
      rc-service "$AGENT_NAME" start
      ;;
  esac
}

start_agent_service() {
  ensure_service_manager || return 1

  case "$SERVICE_MANAGER" in
    systemd)
      systemctl start "$AGENT_NAME"
      ;;
    openrc)
      rc-service "$AGENT_NAME" start
      ;;
  esac
}

agent_service_is_active() {
  ensure_service_manager || return 1

  case "$SERVICE_MANAGER" in
    systemd)
      systemctl is-active --quiet "$AGENT_NAME"
      ;;
    openrc)
      rc-service "$AGENT_NAME" status >/dev/null 2>&1
      ;;
  esac
}

agent_service_status() {
  ensure_service_manager || return 1

  case "$SERVICE_MANAGER" in
    systemd)
      systemctl is-active "$AGENT_NAME" 2>/dev/null || true
      ;;
    openrc)
      rc-service "$AGENT_NAME" status 2>/dev/null || true
      ;;
  esac
}

remove_agent_service() {
  ensure_service_manager || return 1

  case "$SERVICE_MANAGER" in
    systemd)
      rm -f "$AGENT_SYSTEMD_SERVICE_FILE"
      systemctl daemon-reload 2>/dev/null || true
      ;;
    openrc)
      rm -f "$AGENT_OPENRC_SERVICE_FILE"
      ;;
  esac
}

agent_service_status_hint() {
  ensure_service_manager || return 1

  case "$SERVICE_MANAGER" in
    systemd)
      echo "systemctl status $AGENT_NAME --no-pager"
      ;;
    openrc)
      echo "rc-service $AGENT_NAME status"
      ;;
  esac
}



# 获取用户输入的配置参数
get_config_params() {
  if [[ -z "$SERVER_ADDR" || -z "$SECRET" ]]; then
    echo "请输入配置参数："
    
    if [[ -z "$SERVER_ADDR" ]]; then
      read -p "服务器地址: " SERVER_ADDR
    fi
    
    if [[ -z "$SECRET" ]]; then
      read -p "密钥: " SECRET
    fi
    
    if [[ -z "$SERVER_ADDR" || -z "$SECRET" ]]; then
      echo "❌ 参数不完整，操作取消。"
      exit 1
    fi
  fi
}

# 解析命令行参数
while getopts "a:s:" opt; do
  case $opt in
    a) SERVER_ADDR="$OPTARG" ;;
    s) SECRET="$OPTARG" ;;
    *) echo "❌ 无效参数"; exit 1 ;;
  esac
done

# 安装功能
install_agent() {
  echo "🚀 开始安装 FLYX agent..."

  ask_proxy_config
  ensure_download_url_initialized || exit 1

  get_config_params

  # 检查并安装 tcpkill
  check_and_install_tcpkill
  ensure_service_manager || exit 1

  mkdir -p "$INSTALL_DIR"

  local tmp_binary="$INSTALL_DIR/$AGENT_NAME.new"

  # 下载 FLYX agent
  echo "⬇️ 下载 FLYX agent 中..."
  rm -f "$tmp_binary"
  curl -L "$DOWNLOAD_URL" -o "$tmp_binary"
  if [[ ! -f "$tmp_binary" || ! -s "$tmp_binary" ]]; then
    rm -f "$tmp_binary"
    echo "❌ 下载失败，请检查网络或下载链接。"
    exit 1
  fi
  echo "✅ 下载完成"

  # 新二进制已就绪，此时才停服务替换：下载慢时节点不会提前离线
  # 停止并禁用已有服务
  if agent_service_exists; then
    echo "🔍 检测到已存在的FLYX agent服务"
    stop_agent_service
    echo "🛑 停止服务"
    disable_agent_service
    echo "🚫 禁用自启"
  fi

  mv "$tmp_binary" "$INSTALL_DIR/$AGENT_NAME"
  chmod +x "$INSTALL_DIR/$AGENT_NAME"

  # 打印版本
  echo "🔎 FLYX agent 版本：$($INSTALL_DIR/$AGENT_NAME -V)"

  # 写入 config.json (安装时总是创建新的)
  CONFIG_FILE="$INSTALL_DIR/config.json"
  echo "📄 创建新配置: config.json"
  write_agent_config "$CONFIG_FILE"

  # 写入 gost.json
  GOST_CONFIG="$INSTALL_DIR/gost.json"
  if [[ -f "$GOST_CONFIG" ]]; then
    echo "⏭️ 跳过配置文件: gost.json (已存在)"
  else
    echo "📄 创建新配置: gost.json"
    cat > "$GOST_CONFIG" <<EOF
{}
EOF
  fi

  # 加强权限
  chmod 600 "$INSTALL_DIR"/*.json

  # 创建 systemd 或 OpenRC 服务
  write_agent_service

  # 启动服务
  enable_and_start_agent_service

  # 检查状态
  echo "🔄 检查服务状态..."
  if agent_service_is_active; then
    echo "✅ 安装完成，FLYX agent服务已启动并设置为开机启动。"
    echo "📁 配置目录: $INSTALL_DIR"
    echo "🔧 服务状态: $(agent_service_status)"
  else
    echo "❌ FLYX agent服务启动失败，请执行以下命令查看状态："
    agent_service_status_hint
  fi
}

# 更新功能
update_agent() {
  echo "🔄 开始更新 FLYX agent..."
  confirm_legacy_agent
  
  if [[ ! -d "$INSTALL_DIR" ]]; then
    echo "❌ FLYX agent 未安装，请先选择安装。"
    return 1
  fi

  ask_proxy_config
  ensure_download_url_initialized || return 1
  
  echo "📥 使用下载地址: $DOWNLOAD_URL"
  
  # 检查并安装 tcpkill
  check_and_install_tcpkill
  ensure_service_manager || return 1
  
  # 先下载新版本
  echo "⬇️ 下载最新版本..."
  rm -f "$INSTALL_DIR/$AGENT_NAME.new"
  curl -L "$DOWNLOAD_URL" -o "$INSTALL_DIR/$AGENT_NAME.new"
  if [[ ! -f "$INSTALL_DIR/$AGENT_NAME.new" || ! -s "$INSTALL_DIR/$AGENT_NAME.new" ]]; then
    echo "❌ 下载失败。"
    return 1
  fi

  # 停止服务
  if agent_service_exists; then
    echo "🛑 停止 FLYX agent 服务..."
    stop_agent_service
  fi

  # 替换文件
  mv "$INSTALL_DIR/$AGENT_NAME.new" "$INSTALL_DIR/$AGENT_NAME"
  chmod +x "$INSTALL_DIR/$AGENT_NAME"
  
  # 打印版本
  echo "🔎 新版本：$($INSTALL_DIR/$AGENT_NAME -V)"

  # 重启服务
  echo "🔄 重启服务..."
  start_agent_service
  
  echo "✅ 更新完成，服务已重新启动。"
}

# 卸载功能
uninstall_agent() {
  echo "🗑️ 开始卸载 FLYX agent..."
  ensure_service_manager || return 1
  confirm_legacy_agent
  if [[ ! -d "$INSTALL_DIR" ]]; then
    echo "❌ FLYX agent 未安装。"
    return 1
  fi

  read -p "确认卸载 FLYX agent 吗？此操作将删除所有相关文件 (y/N): " confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "❌ 取消卸载"
    return 0
  fi

  # 停止并禁用服务
  if agent_service_exists; then
    echo "🛑 停止并禁用服务..."
    stop_agent_service
    disable_agent_service
  fi

  # 删除服务文件
  if [[ -f "$AGENT_SYSTEMD_SERVICE_FILE" || -f "$AGENT_OPENRC_SERVICE_FILE" ]]; then
    remove_agent_service
    echo "🧹 删除服务文件"
  fi

  # 删除安装目录
  if [[ -d "$INSTALL_DIR" ]]; then
    rm -rf "$INSTALL_DIR"
    echo "🧹 删除安装目录: $INSTALL_DIR"
  fi

  echo "✅ 卸载完成"
}

# 主逻辑
main() {
  resolve_agent_installation || return 1
  # 如果提供了命令行参数，直接执行安装
  if [[ -n "$SERVER_ADDR" && -n "$SECRET" ]]; then
    install_agent
    delete_self
    exit 0
  fi

  # 显示交互式菜单
  while true; do
    show_menu
    read -p "请输入选项 (1-4): " choice
    
    case $choice in
      1)
        # The panel address decides whether an old flux_agent is ours.
        get_config_params
        resolve_agent_installation || exit 1
        install_agent
        delete_self
        exit 0
        ;;
      2)
        update_agent
        delete_self
        exit 0
        ;;
      3)
        uninstall_agent
        delete_self
        exit 0
        ;;
      4)
        echo "👋 退出脚本"
        delete_self
        exit 0
        ;;
      *)
        echo "❌ 无效选项，请输入 1-4"
        echo ""
        ;;
    esac
  done
}

# 执行主函数
main
