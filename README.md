# FLYX · 原生部署版（flyx-native）

把 FLYX 转发面板做成**一个静态二进制**：面板界面、管理 API、公开状态页、节点通道全部由同一个进程提供，
**不需要 Docker、不需要 nginx、不需要容器编排**。

```
paneld（systemd）
├─ 面板端口 :6366   /（内嵌前端）+ /api/v1/ + /system-info(type=0) + /status（公开状态页）
└─ 节点端口 :6365   /system-info(type=1) + /flow/*      ← 面板页面与 API 在这里一律 404
└─ SQLite  /var/lib/flyx/gost.db（业务数据 + 面板自己的设置）
```

## 特性

FLYX 自己的能力：

- **多内核节点**：Xray、sing-box、Snell v4 / v5 按服务器安装；VLESS Reality、Hysteria2（端口跳跃）、TUIC、AnyTLS、NaïveProxy、ShadowTLS 等模板一键创建
- **证书**：自签 / 服务器证书文件 / sing-box 自动申请（ACME，HTTP、Cloudflare、阿里云 DNS 验证）
- **对接中转**：端口转发、隧道转发，或「前置 → IX → 落地」多跳线路；入站白名单、真实客户端 IP
- **导入节点**：粘贴分享链接、Clash / sing-box / Surge 配置或订阅地址
- **订阅**：节点组挑选/过滤/改名、多订阅组合、按客户端自适应返回 Clash/Mihomo、sing-box、Surge、base64，可带独立凭据分享
- **流量转发**：TCP / UDP 端口转发与隧道转发，realm、nftables 引擎，按规则统计上下行
- **公开状态页**：`/status` 无需登录，显示在线率、负载、流量（不暴露 IP / 用户 / 协议）

本版本额外做的改造（相对官方 Docker 部署）：

- **单进程**：一个二进制，约 40~70MB 内存，无 Docker / 无 nginx
- **前端内嵌**：`go:embed` 把面板前端编进二进制，升级/迁移只搬一个文件
- **面板路径运行期可改**：`/` 或任意子路径，保存即生效，**不用重新构建前端**
- **同端口 HTTPS**：面板端口自己就能上 HTTPS，不额外占用 443；HTTP 访问 301 到同端口；证书热加载
- **端口 / 路径 / 证书都在设置页里改**：保存后约 3 秒重绑监听，新配置绑定失败自动回退
- **节点通道独立端口**：只放行 `/system-info`、`/flow/*`，不暴露面板页面与管理 API

## 一键安装

### 方式 A：一键脚本

```bash
curl -fsSL https://raw.githubusercontent.com/kunkundun/flyx-native/main/install-panel.sh | sudo bash
```

自定义端口 / 路径：

```bash
curl -fsSL https://raw.githubusercontent.com/kunkundun/flyx-native/main/install-panel.sh \
  | sudo bash -s -- --port 8443 --path /my-panel
```

脚本自动判断架构（amd64/arm64）并从 [Releases](https://github.com/kunkundun/flyx-native/releases)
下载对应的二进制；重复执行即原地升级（保留 `.prev` 可回滚）。

### 方式 B：先构建，再一键装（离线 / 想自己编译时）

```bash
git clone <本仓库> flyx-native && cd flyx-native
cd go-backend && ./scripts/build-panel.sh      # 自动：构建前端 → embed → 编译
# 产物：go-backend/bin/paneld

scp go-backend/bin/paneld root@服务器:/root/flyx-paneld
scp install-panel.sh      root@服务器:/root/
ssh root@服务器 'sudo bash /root/install-panel.sh /root/flyx-paneld'
```

### 方式 C：从 Release 安装

```bash
sudo FLVX_BINARY_URL=https://github.com/kunkundun/flyx-native/releases/download/<版本>/flyx-paneld-linux-amd64 \
  bash install-panel.sh
```

## 下载线路（自动探测）

安装脚本默认 `PROXY_ENABLED=auto`：**并行探测「直连 + 各加速镜像」，选最快的那条**下载。
因为线路快慢与所在网络强相关（实测同一时刻：国内机房走镜像 300KB/s、直连 40KB/s；
而另一台机器直连 100KB/s、镜像只有 44KB/s），固定用代理反而可能更慢。

```
🔍 正在探测最快的下载线路（直连 + 4 个候选，最多 6s）...
   直连: 100 KB/s
   https://gh-proxy.com: 44 KB/s
   https://ghfast.top: 0 KB/s
   https://githubproxy.cc: 53 KB/s
✅ 选用：直连（100 KB/s）
```

可用环境变量调整：

| 变量 | 说明 |
|---|---|
| `PROXY_ENABLED` | `auto`（默认）/ `false` 只直连 / `true` 等同 auto |
| `PROXY_URL` | 额外候选镜像（面板「GitHub 加速」里的地址） |
| `PROXY_CANDIDATES` | 覆盖内置候选，空格分隔 |
| `PROBE_BYTES` / `PROBE_TIMEOUT` | 测速分片大小、单次超时（默认 256KB / 6s） |
| `PROXY_MODE=direct` | `install-panel.sh` 里关闭探测 |

面板「网站配置 → GitHub 加速」里的地址会作为候选之一一起参与测速，不再强制使用。

## 安装后三步

1. 浏览器打开面板，**改掉初始密码**（`admin_user` / `admin_user`，首次登录强制改）
2. 「网站配置 → 面板后端地址」填 `服务器IP:6365`（节点端口）
3. 「服务器 → 新增」→ 复制安装命令到目标机执行；之后即可在面板里装内核、建入站、生成订阅

## 面板设置（网站配置页）

| 设置项 | 说明 |
|---|---|
| 面板端口 | UI + API + 状态页的监听端口，默认 6366 |
| 节点连接端口 | agent 专用，默认 6365；只提供 `/system-info`、`/flow/*` |
| 面板路径 | `/` 或任意子路径，运行期可改 |
| 隐藏根路径 | 路径非 `/` 时：开 = `/` 返回 404；关 = `/` 302 跳到面板路径 |
| 启用 HTTPS | 面板端口本身改用 HTTPS（不占 443）；HTTP 访问 301 到 https 同端口 |
| 证书 / 私钥路径 | 服务器绝对路径，建议放 `/etc/flyx/certs/`；文件更新自动热加载 |

保存后约 3 秒生效：地址变了会提示并自动跳转；危险变更（隐藏根路径、开关 HTTPS）会二次确认；
新配置绑定失败（端口被占用、证书不可用）会自动回退，不会把面板锁在门外。

## 常用命令

```bash
systemctl status flyx-paneld
journalctl -u flyx-paneld -f
systemctl restart flyx-paneld
kill -HUP $(systemctl show -p MainPID --value flyx-paneld)   # 按数据库设置重绑监听
sudo bash install-panel.sh /root/flyx-paneld-new             # 升级（保留 .prev）
sudo cp /usr/local/bin/flyx-paneld.prev /usr/local/bin/flyx-paneld && sudo systemctl restart flyx-paneld   # 回滚
sudo bash install-panel.sh --uninstall                       # 卸载（保留数据库）
```

## 目录布局

```
/usr/local/bin/flyx-paneld        二进制（内嵌前端）
/usr/local/bin/flyx-paneld.prev   上一版本，回滚用
/etc/flyx/paneld.env              JWT_SECRET、数据库路径、首次安装的默认端口
/etc/flyx/certs/                  证书目录
/var/lib/flyx/gost.db             SQLite 数据库
/var/lib/flyx/themes/             状态页主题（可在面板里安装）
/etc/systemd/system/flyx-paneld.service
```

备份：`/var/lib/flyx/`（数据库 + 主题目录）。

## 从源码构建 / 打发布包

```bash
cd go-backend && ./scripts/build-panel.sh        # 本机架构
VERSION=1.0.0 ./scripts/package-release.sh       # linux/amd64 + linux/arm64 + 整包 + SHA256SUMS
```

环境要求：**Go 1.25+**、**Node 22+**（pnpm 10）。后端构建用 `CGO_ENABLED=0`，产物是静态二进制。

## 端口与网络

| 端口 | 用途 | 建议暴露范围 |
|---|---|---|
| 6366（面板端口） | 面板 UI + 管理 API + 公开状态页 | 内网 / VPN；公网访问请上 HTTPS + 反代 + 认证 |
| 6365（节点端口） | agent 通道 | 只对节点所在网络开放；公网接入请在其前面做 TLS（agent 会自动用 `wss`） |

节点端口只接受 `/system-info`、`/flow/test`、`/flow/config`、`/flow/upload`、`/flow/upload/v2`，其它一律 404。

## 与官方 Docker 版 FLYX 的差异

| | Docker 版 | 本版本 |
|---|---|---|
| 运行方式 | docker + 2~3 个容器 | 1 个进程 |
| 内存 | 200MB+ | 40~70MB |
| 前端 | 独立 nginx 容器 | `go:embed` 进二进制 |
| 面板「一键升级」 | 面板内点击 | `install-panel.sh <新二进制>`（保留回滚） |
| 端口/路径/TLS | 改 compose + 重建容器 | 设置页保存，3 秒生效 |

## 说明：仓库里的 Docker 相关文件

`docker-compose-v4.yml`、`docker-compose-v6.yml`、`panel_install.sh`、`go-backend/Dockerfile` 是上游
Docker 部署方式的产物，**本 fork 没有跟随改造**（端口布局改成了面板 / 节点双监听，面板默认 6366）。
它们保留只为对照参考，请勿与原生部署混用；本仓库只维护原生部署。

`install.sh` 是**节点 agent** 安装器，仍按上游方式从 Release 下载 `gost-{arch}`，可以正常使用。

## 许可

基于 FLYX（GPL-3.0）改造，本仓库同样以 **GPL-3.0** 发布（见 `LICENSE`）。
新增的原生部署与 web 层改造代码同样遵循 GPL-3.0；第三方代码来源见 `NOTICE`。

## 免责声明

本项目仅供个人学习与研究使用，仅限合法合规用途，请遵守所在国家或地区法律法规。
