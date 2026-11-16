# 原生部署（不使用 Docker）

FLYX 现在可以完全脱离 Docker 运行：**一个静态二进制**同时提供面板界面、管理 API、公开状态页与节点通道，
不需要 nginx，也不需要任何容器。

## 为什么可以

| 组件 | 原生实现 |
|---|---|
| 面板后端 + 前端 | `paneld` 单文件二进制，前端 `dist` 通过 `go:embed` 编进二进制 |
| 数据库 | SQLite 单文件（默认）或 PostgreSQL |
| 状态页主题 | `/var/lib/flyx/themes/`（面板里安装） |
| 节点 agent | 面板「服务器 → 新增」生成的安装命令（agent 以 systemd 常驻，与 Docker 方案一致） |
| 面板「一键升级」 | 由 `install-panel.sh <新二进制>` 取代（Docker 方案里唯一依赖 docker 的功能） |

## 运行形态

```
paneld（systemd: flyx-paneld）
├─ 面板端口 :6366   /（内嵌 SPA）+ /api/v1/ + /system-info(type=0) + /status（公开状态页）
└─ 节点端口 :6365   /system-info(type=1) + /flow/*        面板页面与 API 在这里都是 404
```

端口、路径、HTTPS 全部在**面板设置页**里改（存 SQLite 的 `vite_config`）：

| 设置项 | 键 | 说明 |
|---|---|---|
| 面板端口 | `panel_port` | UI + API + 状态页的监听端口 |
| 节点连接端口 | `panel_agent_port` | agent 专用；服务器安装命令里的地址要写 `服务器IP:这个端口` |
| 面板路径 | `panel_path` | `/`（根路径）或任意子路径；**运行期可改，无需重新构建前端** |
| 隐藏根路径 | `panel_hide_root` | 路径非 `/` 时，`/` 返回 404（开）或 302 跳到面板路径（关） |
| 启用 HTTPS | `panel_tls_enable` | 面板端口本身改用 HTTPS，不额外占用 443 |
| 证书 / 私钥路径 | `panel_cert_file` / `panel_key_file` | 服务器绝对路径；证书按 mtime 热加载 |

保存后约 **3 秒**自动重绑监听（前端会提示并自动跳转）。新配置绑定失败会自动回退旧配置；
证书文件不可用时按 HTTP 启动，不会把面板锁在门外。

## 安装 / 升级

**推荐直接用根目录的 `install-panel.sh`**：

```bash
# 方式一：本机构建后上传（离线友好）
cd go-backend && ./scripts/build-panel.sh
scp bin/paneld root@服务器:/root/flyx-paneld
scp install-panel.sh root@服务器:/root/
ssh root@服务器 'sudo bash /root/install-panel.sh /root/flyx-paneld'

# 方式二：一行（仓库公开且能访问 GitHub Release 时）
curl -fsSL https://raw.githubusercontent.com/kunkundun/flyx-native/main/install-panel.sh | sudo bash
```

重复执行即原地升级（保留 `.prev`，健康检查失败自动回滚）。

## 环境变量（/etc/flyx/paneld.env）

```ini
JWT_SECRET=<32 字节 hex>
DB_TYPE=sqlite
DB_PATH=/var/lib/flyx/gost.db
TZ=Asia/Shanghai

FLYX_VERSION=native            # 面板里「检查更新」显示的版本
STATUS_THEMES_DIR=/var/lib/flyx/themes
# GEOIP_COUNTRY_DB=off         # 不装地区库；留空则自动下载到数据库同目录（需要出网）

# 首次启动的默认值，之后以数据库里的 panel_* 为准
PANEL_PORT=6366
AGENT_PORT=6365
PANEL_PATH=/
PANEL_HIDE_ROOT=1
```

## 下载线路自动探测

`install.sh` / `install-panel.sh` 默认 `PROXY_ENABLED=auto`：并行探测「直连 + 面板配置的代理 +
内置候选（gh-proxy.com / ghfast.top / githubproxy.cc）」，按 256KB 分片测速选最快的一条；
全部失败时回退到配置的代理。国内机房直连通常只有 40KB/s，而外网机器直连可能比镜像更快，
所以不再固定走代理。

每次安装的线路选择会落盘，便于事后排查：

```bash
cat /etc/flyx-agent/install-route.txt      # 节点：chosen=direct|https://gh-proxy.com + 各候选速度
journalctl -t flyx-install -n 20           # 同样内容也写入 journal（安装结束后仍保留）
```

```bash
PROXY_ENABLED=false bash install.sh -a <面板IP>:6365 -s <secret>     # 强制直连
PROXY_CANDIDATES="https://gh-proxy.com" bash install.sh ...          # 只用一个候选
PROXY_MODE=direct bash install-panel.sh ./flyx-paneld                # 关掉探测
```

## 常用运维

```bash
systemctl status flyx-paneld
journalctl -u flyx-paneld -f
kill -HUP $(systemctl show -p MainPID --value flyx-paneld)   # 只按数据库配置重绑监听
sudo bash install-panel.sh /root/flyx-paneld-new             # 升级
sudo bash install-panel.sh --uninstall                       # 卸载（保留数据库）
```

## 加服务器（节点）

1. 「网站配置 → 面板后端地址」填 `服务器IP:节点端口`
2. 「服务器 → 新增」填 IP、SSH 信息与端口范围
3. 复制安装命令到目标机执行（agent 会以 `systemd` 常驻）
4. 之后在面板里装内核（Xray / sing-box / Snell）、建入站、生成订阅

## 与 Docker 方案的差异

| | Docker 方案 | 原生方案 |
|---|---|---|
| 活动部件 | docker + 2~3 个容器 | 1 个进程 |
| 内存占用 | 约 200MB+ | 约 40~70MB |
| 面板一键升级 | 面板内点击 | `install-panel.sh <新二进制>` |
| 面板端口/路径/TLS | 生成 nginx 配置并重建容器 | 设置页保存后 3 秒生效 |

## 已知限制

- 节点通道目前是明文 HTTP/WS；要用 `wss` 请在节点端口前面做 TLS 终结
- 面板自升级在原生方案下线，改由 `install-panel.sh` 完成
- 地区识别（节点国旗）依赖 GeoIP 库：留空会自动下载（需出网），内网可设 `GEOIP_COUNTRY_DB=off`
- 只支持 Linux（systemd）
