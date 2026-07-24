# CaddyCtl

`CaddyCtl` 是面向 Linux 宿主机的 Caddy 管理菜单。它安装、更新、配置和诊断
Caddy，并可将 HTTPS 请求反向代理到 Docker 容器中的服务。

## 命令边界

`CaddyCtl` 不替代官方 Caddy CLI：

```bash
caddyctl                         # 打开管理菜单
caddyctl --install               # 直接安装 Caddy，然后打开管理菜单
caddy version                    # 官方 Caddy CLI
caddy validate --config /etc/caddy/Caddyfile
```

## 一键安装

在 Linux 服务器执行：

```bash
curl -fsSL https://raw.githubusercontent.com/xhpx7301/CaddyCtl/main/install.sh | bash
```

安装脚本会安装 `CaddyCtl` 管理入口并自动打开菜单，不会立即安装 Caddy。需要时
在菜单中选择“安装或更新 Caddy”。之后也可使用：

```bash
caddyctl
```

请在可交互的 SSH 终端中执行一键命令。安装脚本会将菜单输入连接到当前终端，避免
`curl | bash` 的下载管道导致菜单立即退出。

菜单中的“安装或更新 Caddy”会根据当前状态执行安装或软件包更新；“更新
CaddyCtl 管理菜单”只下载并更新管理脚本，不会修改 Caddy 配置、站点或证书。
更新和安装请求会绕过 GitHub Raw 的短期 CDN 缓存，刚推送的提交无需退出菜单或等待
缓存失效即可获取。菜单更新成功后会自动重新打开新版本，无需手动退出或再次选择更新。

“卸载 Caddy 或 CaddyCtl”提供独立选项：卸载 Caddy 时保留配置、证书和管理菜单；
卸载 CaddyCtl 时保留 Caddy、配置和证书；完全卸载会移除两者，但仍保留配置、证书
和数据目录。

菜单中的“检测后端服务监听与连通性”会自动检查全部已配置站点。后端服务是 Caddy
转发请求的实际应用地址，例如 `127.0.0.1:41515`；手动检测仅用于尚未添加反代的
服务排障。对本机服务会显示监听地址；对 HTTP/HTTPS 服务会测试连通性。返回 `401`
或 `403` 表示服务已连通，只是需要认证或当前没有访问权限。

“本机服务端口监听助手”会列出全部本机 TCP 服务的监听地址和进程，并允许选择
端口查看详情。当前可自动修改由 systemd 启动的 Kopia：可设为仅本机
`127.0.0.1`，可在检测到 Nginx Proxy Manager（NPM）容器时设为 NPM 所在 Docker 网络
的网关地址，也可设为 `0.0.0.0` 以允许服务器公网 IP 访问。NPM 模式会从容器侧验证
到 Kopia 的 TCP 连通性，并提示应填写的 NPM 上游地址。修改前会确认，重启失败会恢复
原有启动配置。Docker 容器会显示容器和 Compose 信息，并生成回环或公网端口
映射方案；Docker 映射必须重建容器，因此脚本不会自动重建。选中端口后，助手会
明确显示启动方式（Docker/Compose、systemd 或未识别的手工命令、脚本、面板）及
下一步操作建议。非 Kopia 的 systemd 服务可查看服务定义，并使用“通用 systemd
监听地址管理”替换指定应用配置文件中唯一的监听地址。它会备份原配置，重启服务后
确认目标地址实际处于监听；重启、服务状态或监听验证失败会自动恢复。成功后仍保留
一次手动回滚入口，适合业务验证后主动撤销。该功能不会猜测或改写未知应用的
`ExecStart`，需由管理员确认应用自己的配置文件与旧监听地址。

“Docker NPM 访问宿主机服务（网关模式）”用于 Kopia 等宿主机/systemd 服务；它不会让
Kopia 直接监听公网接口，但与 NPM 位于相同 Docker 网络的其他容器也能访问该网关地址
及端口。自动扫描显示和解析容器短 ID、名称与镜像；自动识别不到 NPM 时，菜单会列出
这些信息，可输入
实际 NPM 容器名称或 ID 读取网关；若 NPM 使用 Docker `host` 网络，则应选择本机
`127.0.0.1` 模式。修改 Kopia 后，菜单会等待目标地址实际进入监听；超时或服务异常会
自动恢复原启动配置。

对于 Docker 后端服务，端口监听助手会进入 Docker 映射菜单，而非通用 systemd 修改。
首选“Docker NPM 共享网络”：它检查 NPM 与应用是否共享用户自定义网络；没有时生成
持久化的 Compose 网络片段，并提示使用 `应用容器名:容器内部端口` 作为 NPM 上游。
该指引不自动连接网络或重建容器。也提供“经宿主机网关访问”的兼容方案，但它必须把
容器端口发布到 `0.0.0.0`，应以防火墙限制 Docker 网段，不如共享网络安全。

若 Kopia 通过 `kopia server start ... &` 手工放入后台运行，它不属于 systemd 服务，
即使 SSH 断开后由 PID 1 收养也是如此。端口监听助手可将这类直接运行的 Kopia 接管为
独立的 `caddyctl-kopia-端口.service`：它保留当前命令和 `KOPIA_CONFIG_PATH`，创建仅
root 可读的启动包装脚本，并设置开机自启；已有 systemd 服务不会被覆盖。

接管和之后修改监听地址时，CaddyCtl 还会保留 `HOME`、`XDG_CONFIG_HOME` 与所有
`KOPIA_*` 环境变量；未显式设置路径时，会使用原运行用户的默认
`~/.config/kopia/repository.config`。这避免 systemd 环境与原 SSH 环境不同而出现
“需要连接存储库”的界面。

只有父进程为 PID 1 的已脱离终端手工命令可自动接管。仍由脚本、面板或其他守护进程
托管的 Kopia 必须先在原管理器中停止并禁用，否则它可能重新拉起 Kopia 并与新服务
争用端口。

也可以克隆仓库后在本地运行：

```bash
chmod +x install.sh
./install.sh
```

脚本支持使用 systemd 的 Debian/Ubuntu 和 Fedora/RHEL（dnf）系统。

## Docker 反向代理

当 Caddy 安装在宿主机、应用运行在 Docker 中时，不需要将两者加入同一个
Docker 网络。建议只将应用端口发布到宿主机回环地址：

```yaml
services:
  app:
    ports:
      - "127.0.0.1:8080:8080"
```

随后运行：

```text
caddyctl
  -> 5. 新增反向代理
  -> 2. Docker 容器连接向导
```

向导会列出容器、读取现有端口映射、检查连接并创建站点配置。若容器尚未发布
端口，它会输出应加入 Compose 的回环地址映射。Docker 不能给已创建的容器原地
增加端口映射，因此脚本不会自动重建或删除容器。

若手动填写 `127.0.0.1` 后出现 502，表示 Caddy 无法通过宿主机回环接口连接
后端服务。确认 Docker 端口映射是 `127.0.0.1:宿主机端口:容器端口` 或
`0.0.0.0:宿主机端口:容器端口`；若它只绑定到服务器的特定 IP，则在菜单中选择
“修改当前反向代理配置”并填写该 IP。

## 文件位置

- 站点配置：`/etc/caddy/sites/*.caddy`
- 配置备份：`/var/backups/caddyctl`
- CaddyCtl 本体：`/usr/local/lib/caddyctl/caddyctl.sh`
- 菜单入口：`/usr/local/bin/caddyctl`

## 部署要求

- DNS A/AAAA 记录指向服务器。
- 服务器安全组及防火墙放行 TCP 80 和 443。
- Cloudflare SSL/TLS 模式使用 `Full (strict)`。
- 管理界面与内部服务端口仅发布到 `127.0.0.1`，不直接暴露公网。
