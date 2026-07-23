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

“卸载 Caddy 或 CaddyCtl”提供独立选项：卸载 Caddy 时保留配置、证书和管理菜单；
卸载 CaddyCtl 时保留 Caddy、配置和证书；完全卸载会移除两者，但仍保留配置、证书
和数据目录。

菜单中的“检测后端服务监听与连通性”会自动检查全部已配置站点。后端服务是 Caddy
转发请求的实际应用地址，例如 `127.0.0.1:41515`；手动检测仅用于尚未添加反代的
服务排障。对本机服务会显示监听地址；对 HTTP/HTTPS 服务会测试连通性。返回 `401`
或 `403` 表示服务已连通，只是需要认证或当前没有访问权限。

“本机服务端口监听助手”会列出全部本机 TCP 服务的监听地址和进程，并允许选择
端口查看详情。当前可自动修改由 systemd 启动的 Kopia：可设为仅本机
`127.0.0.1`，或设为 `0.0.0.0` 以允许服务器公网 IP 访问。修改前会确认，重启失败
会恢复原有启动配置。Docker 容器会显示容器和 Compose 信息，并生成回环或公网端口
映射方案；Docker 映射必须重建容器，因此脚本不会自动重建。其他原生服务仅显示
信息，不会被自动修改。选中端口后，助手会明确显示启动方式（Docker/Compose、
systemd 或未识别的手工命令、脚本、面板）及下一步操作建议。

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
