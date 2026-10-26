# CaddyCtl

`CaddyCtl` 是运行在 Linux 宿主机上的交互式 Caddy 管理工具。它提供 Caddy 的
安装、升级、站点反向代理、配置校验、日志查看和后端连通性诊断能力。

它不会替代官方 `caddy` CLI：日常管理使用 `caddyctl`，需要调用 Caddy 原生命令时
仍使用 `caddy`。

## 快速开始

在支持的 Linux 服务器 SSH 终端中执行：

```bash
curl -fsSL https://raw.githubusercontent.com/xhpx7301/CaddyCtl/main/install.sh | bash
```

安装器会安装并打开 `caddyctl` 管理菜单。随后依次选择“安装或更新 Caddy”和
“新增反向代理”即可开始配置站点。

## 特性

| 能力 | 说明 |
| --- | --- |
| Caddy 生命周期管理 | 安装、升级、卸载软件包，并管理 systemd 服务。 |
| 站点反向代理 | 创建、修改、查看和删除由 CaddyCtl 管理的站点配置。 |
| Docker 连接向导 | 为宿主机上的 Caddy 生成 Docker 后端访问方案，并检查端口映射。 |
| 诊断与维护 | 校验并重载配置、查看服务日志、检查端口监听和后端连通性。 |
| 配置保护 | 变更前确认；部分配置变更会创建备份，失败时尝试恢复。 |

## 支持环境

| 项目 | 要求 |
| --- | --- |
| 操作系统 | 使用 systemd 的 Debian/Ubuntu，或使用 dnf 的 Fedora/RHEL。 |
| 权限 | root，或具有 `sudo` 权限的交互式终端。 |
| 网络 | 域名 DNS 记录指向服务器；公网放行 TCP 80、443。 |
| 可选组件 | Docker 用于容器后端检测和连接向导。 |

## 安装

推荐在可交互的 SSH 终端中执行一键安装：

```bash
curl -fsSL https://raw.githubusercontent.com/xhpx7301/CaddyCtl/main/install.sh | bash
```

安装器只安装 `caddyctl` 管理入口并打开菜单，不会在未确认的情况下立即安装 Caddy。
若希望先查看脚本内容或在本地修改后运行，可使用 Git 克隆：

```bash
git clone https://github.com/xhpx7301/CaddyCtl.git
cd CaddyCtl
chmod +x install.sh
./install.sh
```

在 Debian/Ubuntu 上，CaddyCtl 默认使用 Caddy 官方 apt 软件源。若该源暂时不可用
（例如 Cloudsmith 返回 `402 Payment Required`），脚本会自动切换到 Caddy GitHub
Release，下载对应架构的 `.deb` 包并校验 SHA-512 后安装。后续更新也使用同样的回退流程。

安装完成后，使用以下命令重新打开菜单：

```bash
caddyctl
```

若维护私有镜像或自托管源，可通过 `CADDYCTL_SOURCE_URL` 指定管理脚本下载地址：

```bash
export CADDYCTL_SOURCE_URL="https://example.com/path/caddyctl.sh"
./install.sh
```

## 命令选项

| 命令或选项 | 作用 |
| --- | --- |
| `caddyctl` | 以交互式菜单运行管理工具。 |
| `pl` | 直接打开本机服务端口监听助手，不必进入主菜单。 |
| `caddyctl listen` | `pl` 的等价快捷写法。 |
| `caddyctl --install` | 直接安装 Caddy，然后打开管理菜单。 |
| `caddyctl --install-manager` | 安装 `caddyctl` 和 `pl` 命令入口，然后打开管理菜单。主要供安装器调用。 |
| `caddyctl --help` / `caddyctl -h` | 显示简要命令帮助。 |
| `caddy version` | 调用官方 Caddy CLI 查看版本；CaddyCtl 不会覆盖该命令。 |
| `caddy validate --config /etc/caddy/Caddyfile` | 使用官方 Caddy CLI 校验主配置。 |

## 主菜单

| 选项 | 作用 |
| --- | --- |
| `1` 更新 CaddyCtl 管理菜单 | 下载并替换管理脚本，不改动 Caddy、站点配置或证书。成功后自动重新打开新版本。 |
| `2` 本机服务端口监听助手 | 检查本机 TCP 服务、Docker 容器和 systemd 服务的监听方式，并提供受限的调整向导。 |
| `3` 网关设置 | 查看运行中的 NPM 容器网络、网关和同网络容器；查看 Docker 系统默认 `bridge` 网络，并将容器服务加入 Docker 网络或从网络移除。 |
| `4` 查看运行状态 | 显示 Caddy 安装状态、服务状态、开机启动和站点数量；可查看 systemd 原始详情。 |
| `5` 安装或更新 Caddy | 未安装时安装官方稳定版；已安装时更新软件包并重启服务。 |
| `6` 新增反向代理 | 手动填写后端，或进入 Docker 容器连接向导。 |
| `7` 修改现有反向代理 | 先按编号选择站点；后端地址、端口和协议直接回车可保留原配置。 |
| `8` 查看当前反向代理配置 | 列出并查看当前受管理站点配置。 |
| `9` 删除反向代理 | 按编号选择站点，确认提示直接回车即可删除。 |
| `10` 校验并重载 Caddy | 先校验配置，校验通过后重载 Caddy。 |
| `11` 查看 Caddy 端口监听与 Docker 映射 | 显示 Caddy 监听端口，以及 Docker 公开的端口映射。 |
| `12` 检测 Caddy 后端服务监听与连通性 | 自动或手动检查后端服务的监听状态和 HTTP/HTTPS 连通性。 |
| `13` 查看 Caddy 服务日志 | 查看 systemd 中的 Caddy 服务日志。 |
| `14` 卸载 Caddy 或 CaddyCtl | 进入卸载子菜单。选项 `1`、`2` 保留配置；选项 `3` 会删除全部配置和证书。 |
| `15` 443 端口复用 | 打开二级管理菜单，初始化面板入口，查看、添加、修改或删除多个 Reality SNI 映射，修改面板后端、校验应用或关闭复用。 |
| `0` 退出 | 退出管理菜单。 |

网关设置会让你选择运行中的 Nginx Proxy Manager 容器，展示其各 Docker 网络的网关、容器 IP 和网络成员，并单独标出 Docker 系统默认 `bridge`（通常网关为 `172.17.0.1`）；也可从子菜单直接查看本机 TCP 监听表。Compose 默认网络与系统默认 `bridge` 是不同网络。新增或移除服务时，先选择 Docker 共享网络，再选择相应容器；网络列表显示网关和成员数，且会过滤 `host`、`none` 网络。连接或断开网络前会要求确认，移除 NPM 时会提醒其将无法通过该网络访问同网络服务。网络连接即时作用于当前容器；Compose 重建后如需保留，应在对应 Compose 配置中声明。

## 子菜单选项

### 卸载

| 选项 | 作用 |
| --- | --- |
| `1` 卸载 Caddy | 删除 Caddy 软件包，保留 CaddyCtl、配置、证书和数据目录。 |
| `2` 卸载 CaddyCtl | 删除管理入口和脚本，保留 Caddy、配置和证书。 |
| `3` 完全卸载 | 删除 Caddy、CaddyCtl、`/etc/caddy` 配置、`/var/lib/caddy` 证书和数据，以及 CaddyCtl 备份。此操作不可恢复。 |
| `0` 返回 | 返回主菜单。 |

### 新增反向代理

| 选项 | 作用 |
| --- | --- |
| `1` 手动填写服务地址和端口 | 为本机、局域网或已知地址的后端创建反向代理。 |
| `2` Docker 容器连接向导 | 读取容器和端口映射，检查连通性并生成后端配置建议。 |
| `0` 返回 | 返回主菜单。 |

### 后端连通性检测

| 选项 | 作用 |
| --- | --- |
| `1` 自动检测全部已配置的反向代理 | 检查全部受管理站点的后端。`401` 或 `403` 表示服务可达但需要认证或无访问权限。 |
| `2` 手动检测未配置的服务地址 | 输入地址和端口，单独检查尚未添加为反向代理的服务。 |
| `0` 返回 | 返回主菜单。 |

### 本机服务监听助手

此助手会识别 Docker、systemd 和部分已知服务类型。不会猜测或修改未知应用的启动命令；
对于通用 systemd 服务，只能在管理员确认配置文件与旧监听地址后进行受控替换。

| 场景 | 选项 | 作用 |
| --- | --- | --- |
| 手工运行的 Kopia | `1` 接管为 systemd 服务 | 保留当前启动参数，创建由 CaddyCtl 管理的 systemd 服务。 |
| Kopia | `1` 仅服务器本机 | 监听 `127.0.0.1`，供宿主机上的 Caddy、Nginx 等反向代理访问。 |
| Kopia | `2` Docker NPM 网关模式 | 为 Docker 中的 Nginx Proxy Manager 识别并验证宿主机网关访问路径。 |
| Kopia | `3` 允许服务器公网 IP | 监听 `0.0.0.0`；必须自行用防火墙限制访问。 |
| 通用 systemd 服务 | `1` 查看服务详情 | 显示服务和 systemd 定义。 |
| 通用 systemd 服务 | `2` 修改监听地址 | 替换配置中唯一可识别的监听地址，重启并验证；失败时自动恢复。 |
| 通用 systemd 服务 | `3` 恢复上一次修改 | 恢复最近一次由 CaddyCtl 创建的监听配置备份。 |
| 任一子菜单 | `0` 返回 | 不进行变更并返回上一级。 |

### Docker 容器访问与端口映射

| 选项 | 作用 |
| --- | --- |
| `1` 推荐：配置 NPM 与应用共享网络 | 建立或连接共享 Docker 网络，NPM 使用 `Compose 服务名:容器内部端口`；不修改当前 `ports`，确认直连正常后可自行移除不再需要的端口映射。 |
| `2` 兼容：经宿主机中转 | 自动检测 NPM 所在 Docker bridge 网关，并将映射改为 `网关地址:宿主机端口:容器端口`；兼容 NPMCtl 创建的 `npmctl_default` 等自定义 bridge 网络，不再依赖固定的 `172.17.0.1`；确认后备份、校验并重建 Compose 服务。 |
| `3` 宿主机 Caddy | 将映射改为 `127.0.0.1:宿主机端口:容器端口`，仅供宿主机上的 Caddy、Nginx 等本机反向代理使用。 |
| `4` 公网访问 | 将映射改为 `0.0.0.0:宿主机端口:容器端口`，允许任意来源访问，须自行配置防火墙。 |
| `0` 返回 | 不进行变更并返回上一级。 |

> Docker 不能为已创建的容器原地增加端口映射。对于已识别的单文件 Compose 项目，
> 向导可在确认后备份、修改、校验并重建服务；无法安全识别的 Compose 配置只会给出手工片段。若端口映射使用 `${VARIABLE}`，CaddyCtl 不会猜测变量来源，而会提示使用应用自身工具或修改对应 env 文件。对由 KopiaCtl 管理的 `kopia-web-ui`，选项 `3` 和 `4` 会在确认后调用 KopiaCtl 的发布范围命令，由 KopiaCtl 负责配置、重建与共享网络恢复。

## 443 端口复用（3x-ui HTTP 面板 + VLESS Reality）

如果 3x-ui 面板本身只提供 HTTP，而同一台服务器还要让 VLESS Reality 使用公网 TCP 443，
可以在主菜单选择 `15`，再选择初始化。向导会优先从 Caddy 官方下载 API 下载当前 Linux 架构的预编译 Caddy，并验证其中包含
`github.com/mholt/caddy-l4`；只有预编译文件不可用时才会回退到本机 Go 构建。随后生成按 SNI
分流的 Layer4 listener wrapper。后续可在二级菜单中查看、添加、修改或删除 Reality 映射，或者修改面板域名及 HTTP 后端；每个 SNI 对应一个后端地址和端口。面板域名的 TLS 会在 Caddy 中终止，再以普通 HTTP 访问 3x-ui，例如：

预编译下载只需少量空间。源码构建备用流程会清理旧版本可能遗留的 Go 模块、编译缓存和 `/tmp/go-build*` 临时目录，并自动选择可用空间最大的本地目录；Go 的模块缓存、编译缓存和临时编译目录都会放在该目录，不依赖 `/tmp` 必须有大容量。源码构建时请至少在构建目录所在文件系统预留约 1.5 GiB 可用空间。普通 Caddy 安装不需要 Go，只有初始化 443 端口复用时才执行这一步。

如需固定插件版本或使用镜像，可设置 `CADDYCTL_L4_PLUGIN_VERSION` 和 `CADDYCTL_L4_PREBUILT_URL`；下载地址需要兼容 Caddy 下载 API 的 `os`、`arch` 和 `p` 查询参数。

```text
面板域名:443 -> caddy-l4（Caddy 终止 TLS） -> http://127.0.0.1:20534
reality-a.example:443 -> caddy-l4（保持原始 TLS） -> 127.0.0.1:15443
reality-b.example:443 -> caddy-l4（保持原始 TLS） -> 127.0.0.1:25443
```

其中 `20534` 和 `15443` 只是示例，分别替换为实际的 3x-ui HTTP 面板端口和 Xray Reality
入站端口。面板域名和所有 Reality `serverName` 必须不同，Reality 的 SNI 之间也不能重复；相同 SNI 无法区分多个后端。Xray 入站建议只监听 `127.0.0.1`。
启用前请确保公网 TCP 443 未被其他服务占用。Caddy 自定义构建后，后续 Caddy 更新也应通过
CaddyCtl 执行，并检查 `caddyctl` 日志。证书申请可继续使用 80 端口 HTTP-01，或改用 DNS-01；
如果使用 TLS-ALPN-01，需要额外配置 Layer4 放行 ACME 流量。

## Docker 后端建议

当 Caddy 运行在宿主机、应用运行在 Docker 中时，优先仅发布应用到宿主机回环地址：

```yaml
services:
  app:
    ports:
      - "127.0.0.1:8080:8080"
```

然后在 CaddyCtl 中选择“新增反向代理”并进入 Docker 容器连接向导。若使用 Docker 中的
Nginx Proxy Manager，请优先使用共享网络，而不是把应用端口开放到公网。

## 文件位置

| 内容 | 默认位置 |
| --- | --- |
| 主配置 | `/etc/caddy/Caddyfile` |
| 站点配置 | `/etc/caddy/sites/*.caddy` |
| CaddyCtl 配置备份 | `/var/backups/caddyctl` |
| CaddyCtl 主脚本 | `/usr/local/lib/caddyctl/caddyctl.sh` |
| `caddyctl` 命令入口 | `/usr/local/bin/caddyctl` |

## 部署建议

| 项目 | 建议 |
| --- | --- |
| TLS | DNS 记录指向服务器；若使用 Cloudflare，选择 `Full (strict)`。 |
| 防火墙 | 只开放对外提供服务所需的端口，通常为 TCP 80 和 443。 |
| 管理界面 | 数据库、面板和内部服务优先绑定 `127.0.0.1` 或私有 Docker 网络。 |
| 变更前 | 先查看当前配置；对生产服务在维护窗口执行涉及重启或容器重建的操作。 |
