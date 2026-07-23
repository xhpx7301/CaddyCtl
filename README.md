# CaddyCtl

`CaddyCtl` 是面向 Linux 宿主机的 Caddy 管理菜单。它安装、更新、配置和诊断
Caddy，并可将 HTTPS 请求反向代理到 Docker 容器中的服务。

## 命令边界

`CaddyCtl` 不替代官方 Caddy CLI：

```bash
caddyctl                         # 打开管理菜单
caddyctl --install               # 直接安装 Caddy 与管理入口
caddy version                    # 官方 Caddy CLI
caddy validate --config /etc/caddy/Caddyfile
```

## 一键安装

在 Linux 服务器执行：

```bash
curl -fsSL https://raw.githubusercontent.com/xhpx7301/CaddyCtl/main/install.sh | bash
```

安装脚本会下载 `caddyctl.sh` 并执行安装。完成后使用：

```bash
caddyctl
```

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
  -> 5. 添加反向代理（手动 / Docker 向导）
  -> 2. Docker 容器连接向导
```

向导会列出容器、读取现有端口映射、检查连接并创建站点配置。若容器尚未发布
端口，它会输出应加入 Compose 的回环地址映射。Docker 不能给已创建的容器原地
增加端口映射，因此脚本不会自动重建或删除容器。

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
