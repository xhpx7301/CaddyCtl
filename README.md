# CaddyCtl

`CaddyCtl` 是面向 Linux 宿主机的 Caddy 管理菜单。它安装、更新、配置和诊断
Caddy，并可将 HTTPS 请求反向代理到 Docker 容器中的服务。

## 命令边界

`CaddyCtl` 不替代官方 Caddy CLI：

```bash
caddyctl                         # 打开管理菜单
caddy version                    # 官方 Caddy CLI
caddy validate --config /etc/caddy/Caddyfile
```

## 安装

将 `caddyctl.sh` 上传到服务器后执行：

```bash
chmod +x caddyctl.sh
sudo ./caddyctl.sh
```

在菜单中选择“安装 Caddy / 安装管理命令”。安装完成后，使用 `caddyctl` 打开
菜单。脚本支持使用 systemd 的 Debian/Ubuntu 和 Fedora/RHEL（dnf）系统。

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

## 旧版迁移

旧版脚本会把管理菜单安装为 `caddy`，这会遮蔽官方 CLI。运行新版
`caddyctl.sh` 后选择“安装 Caddy / 安装管理命令”，脚本会：

- 安装新的 `caddyctl` 管理入口；
- 备份并移除可确认属于旧版的 `/usr/local/bin/caddy` 包装器；
- 保留 `/etc/caddy`、证书数据和已有站点配置。

如果 `caddy` 是其他手工创建的程序，脚本不会删除它。

## 文件位置

- 站点配置：`/etc/caddy/sites/*.caddy`
- 配置和迁移备份：`/var/backups/caddyctl`
- CaddyCtl 本体：`/usr/local/lib/caddyctl/caddyctl.sh`
- 菜单入口：`/usr/local/bin/caddyctl`

## 部署要求

- DNS A/AAAA 记录指向服务器。
- 服务器安全组及防火墙放行 TCP 80 和 443。
- Cloudflare SSL/TLS 模式使用 `Full (strict)`。
- 管理界面与内部服务端口仅发布到 `127.0.0.1`，不直接暴露公网。
