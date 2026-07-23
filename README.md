# Caddy 中文管理脚本

该脚本用于在 Linux 宿主机上安装和管理 Caddy，并将请求反向代理到 Docker
容器映射到宿主机的端口。

## Kopia 端口映射

当 Caddy 安装在宿主机、Kopia 运行在 Docker 中时，不需要让 Caddy 加入
Docker 网络。建议只向宿主机回环地址发布 Kopia 端口：

```yaml
services:
  kopia:
    ports:
      - "127.0.0.1:41515:51515"
```

其中 `41515` 是宿主机端口，`51515` 是示例中的 Kopia 容器内部端口，请以
实际容器配置为准。随后在管理脚本中填写：

- 域名：`kopiaalihk.6990699.xyz`
- IP：`127.0.0.1`
- 端口：`41515`
- 协议：`http`

菜单中的“添加或更新反向代理配置”提供两种模式：

1. 手动输入上游 IP、端口和协议。
2. Docker 容器连接向导，自动列出容器、检查内部端口的现有宿主机映射并生成配置。

如果容器尚未发布端口，向导会输出需要加入 Compose 的回环地址映射。Docker
不能给已经创建的容器原地增加端口映射，因此脚本不会自动重建或删除容器。

## 使用

将脚本上传到 Linux 服务器后执行：

```bash
chmod +x caddy-manager.sh
sudo ./caddy-manager.sh
```

选择“安装 Caddy / 安装管理命令”。安装完成后：

```bash
caddy
```

无参数调用会打开中文菜单；带参数调用仍然执行官方 Caddy CLI：

```bash
caddy version
caddy validate --config /etc/caddy/Caddyfile
```

脚本将站点配置保存在 `/etc/caddy/sites/*.caddy`，备份保存在
`/var/backups/caddy-manager`。卸载 Caddy 时会保留配置和证书数据。

当前脚本支持使用 systemd 的 Debian/Ubuntu 和 Fedora/RHEL（dnf）系统。

## 外部要求

- DNS A/AAAA 记录必须指向服务器。
- 服务器安全组及防火墙需要放行 TCP 80 和 443。
- Cloudflare SSL/TLS 模式建议设置为 `Full (strict)`。
- 不要再把 Kopia 的管理端口直接暴露给公网。
