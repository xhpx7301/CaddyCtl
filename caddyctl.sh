#!/usr/bin/env bash

# CaddyCtl - an interactive manager for a package-installed Caddy.
# Run without arguments to open the menu. Keep the official `caddy` command
# for the Caddy CLI; this project installs the separate `caddyctl` command.

set -uo pipefail

readonly PROJECT_NAME="CaddyCtl"
readonly MANAGER_VERSION="2.1.0"
readonly REAL_CADDY="/usr/bin/caddy"
readonly CADDYFILE="/etc/caddy/Caddyfile"
readonly SITES_DIR="/etc/caddy/sites"
readonly BACKUP_DIR="/var/backups/caddyctl"
readonly MANAGER_DIR="/usr/local/lib/caddyctl"
readonly MANAGER_SCRIPT="${MANAGER_DIR}/caddyctl.sh"
readonly MANAGER_COMMAND="/usr/local/bin/caddyctl"
readonly LEGACY_MANAGER_COMMAND="/usr/local/bin/caddy"
readonly IMPORT_BEGIN="# BEGIN CADDYCTL SITES"
readonly IMPORT_END="# END CADDYCTL SITES"
readonly LEGACY_IMPORT_BEGIN="# BEGIN CADDY-MANAGER SITES"

if [[ -t 1 ]]; then
  readonly RED=$'\033[31m'
  readonly GREEN=$'\033[32m'
  readonly YELLOW=$'\033[33m'
  readonly BLUE=$'\033[34m'
  readonly BOLD=$'\033[1m'
  readonly RESET=$'\033[0m'
else
  readonly RED="" GREEN="" YELLOW="" BLUE="" BOLD="" RESET=""
fi

info() { printf '%s[信息]%s %s\n' "$BLUE" "$RESET" "$*"; }
success() { printf '%s[完成]%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%s[注意]%s %s\n' "$YELLOW" "$RESET" "$*"; }
error() { printf '%s[错误]%s %s\n' "$RED" "$RESET" "$*" >&2; }

pause_menu() {
  printf '\n'
  read -r -p "按 Enter 键返回主菜单..." _ || true
}

manager_source() {
  local source_path="${BASH_SOURCE[0]}"
  readlink -f "$source_path" 2>/dev/null || printf '%s\n' "$source_path"
}

show_command_usage() {
  printf '%s\n' "$PROJECT_NAME 是 Caddy 的管理菜单。"
  printf '%s\n' "用法：caddyctl [--install]"
  printf '%s\n' "  --install  安装 Caddy 和 caddyctl 管理入口，然后打开管理菜单"
  printf '%s\n' "官方 Caddy CLI 保持不变，例如：caddy version"
}

require_root() {
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    return
  fi

  if ! command -v sudo >/dev/null 2>&1; then
    error "此菜单需要 root 权限，并且系统没有安装 sudo。"
    exit 1
  fi

  exec sudo bash "$(manager_source)" "$@"
}

detect_package_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    printf 'apt\n'
  elif command -v dnf >/dev/null 2>&1; then
    printf 'dnf\n'
  else
    printf 'unsupported\n'
  fi
}

timestamp() {
  date '+%Y%m%d-%H%M%S'
}

backup_file() {
  local path="$1"
  local label="${2:-$(basename "$path")}"

  [[ -e "$path" ]] || return 0
  install -d -m 0750 "$BACKUP_DIR"
  cp -a -- "$path" "${BACKUP_DIR}/${label}.$(timestamp).bak"
}

is_legacy_manager_command() {
  [[ -f "$LEGACY_MANAGER_COMMAND" ]] \
    && grep -Fq 'MANAGER_SCRIPT="/usr/local/lib/caddy-manager/caddy-manager.sh"' "$LEGACY_MANAGER_COMMAND" 2>/dev/null
}

migrate_legacy_manager_command() {
  if ! is_legacy_manager_command; then
    return
  fi

  backup_file "$LEGACY_MANAGER_COMMAND" "legacy-caddy-command"
  rm -f -- "$LEGACY_MANAGER_COMMAND"
  success "已移除旧版 caddy 管理包装器，官方 caddy 命令已恢复。"
}

install_manager_command() {
  local source_path
  source_path="$(manager_source)"

  install -d -m 0755 "$MANAGER_DIR"
  if [[ "$source_path" != "$MANAGER_SCRIPT" ]]; then
    install -m 0755 "$source_path" "$MANAGER_SCRIPT"
  else
    chmod 0755 "$MANAGER_SCRIPT"
  fi

  if [[ -e "$MANAGER_COMMAND" ]] \
      && ! grep -Fq '# CaddyCtl command wrapper' "$MANAGER_COMMAND" 2>/dev/null; then
    warn "$MANAGER_COMMAND 已存在，将先备份再安装管理入口。"
    backup_file "$MANAGER_COMMAND" "caddyctl-command"
  fi
  rm -f -- "$MANAGER_COMMAND"
  migrate_legacy_manager_command

  cat >"$MANAGER_COMMAND" <<'WRAPPER'
#!/usr/bin/env bash
set -uo pipefail

# CaddyCtl command wrapper
readonly MANAGER_SCRIPT="/usr/local/lib/caddyctl/caddyctl.sh"

if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--install" ) ]]; then
  printf 'caddyctl 仅支持无参数或 --install。官方 CLI 请使用 caddy。\n' >&2
  exit 2
fi

if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
  exec "$MANAGER_SCRIPT" "$@"
fi

if ! command -v sudo >/dev/null 2>&1; then
  printf '打开管理菜单需要 root 权限，但系统未安装 sudo。\n' >&2
  exit 1
fi

exec sudo "$MANAGER_SCRIPT" "$@"
WRAPPER
  chmod 0755 "$MANAGER_COMMAND"
}

initialize_caddyfile() {
  install -d -m 0755 /etc/caddy "$SITES_DIR"

  if [[ ! -f "$CADDYFILE" ]]; then
    cat >"$CADDYFILE" <<EOF
$IMPORT_BEGIN
import $SITES_DIR/*.caddy
$IMPORT_END
EOF
    return
  fi

  if grep -Fq "$IMPORT_BEGIN" "$CADDYFILE" \
      || grep -Fq "$LEGACY_IMPORT_BEGIN" "$CADDYFILE"; then
    return
  fi

  backup_file "$CADDYFILE" "Caddyfile"

  # Replace the package's welcome site, but preserve any real user config.
  if grep -Fq 'root * /usr/share/caddy' "$CADDYFILE" \
      && grep -Fq 'file_server' "$CADDYFILE"; then
    cat >"$CADDYFILE" <<EOF
$IMPORT_BEGIN
import $SITES_DIR/*.caddy
$IMPORT_END
EOF
  else
    cat >>"$CADDYFILE" <<EOF

$IMPORT_BEGIN
import $SITES_DIR/*.caddy
$IMPORT_END
EOF
  fi
}

install_caddy_apt() {
  apt-get update || return 1
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates curl debian-keyring debian-archive-keyring \
    apt-transport-https gnupg || return 1

  install -d -m 0755 /usr/share/keyrings
  if ! curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
      | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg; then
    return 1
  fi
  chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg

  if ! curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
      -o /etc/apt/sources.list.d/caddy-stable.list; then
    return 1
  fi
  chmod o+r /etc/apt/sources.list.d/caddy-stable.list

  apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y caddy
}

install_caddy_dnf() {
  dnf install -y 'dnf-command(copr)' || return 1
  dnf copr enable -y @caddy/caddy || return 1
  dnf install -y caddy
}

install_caddy() {
  local package_manager

  if ! command -v systemctl >/dev/null 2>&1; then
    error "当前脚本面向使用 systemd 的 Linux 发行版，未检测到 systemctl。"
    return 1
  fi

  if [[ -x "$REAL_CADDY" ]]; then
    warn "Caddy 已安装：$($REAL_CADDY version 2>/dev/null || printf '版本未知')"
  else
    package_manager="$(detect_package_manager)"
    info "正在使用 ${package_manager} 安装 Caddy 官方稳定版..."

    case "$package_manager" in
      apt) install_caddy_apt || { error "通过 apt 安装失败。"; return 1; } ;;
      dnf) install_caddy_dnf || { error "通过 dnf 安装失败。"; return 1; } ;;
      *)
        error "暂不支持此发行版。支持使用 systemd 的 Debian/Ubuntu 和 Fedora/RHEL(dnf)。"
        return 1
        ;;
    esac
  fi

  if [[ ! -x "$REAL_CADDY" ]]; then
    error "安装结束但未找到 $REAL_CADDY。"
    return 1
  fi

  initialize_caddyfile
  install_manager_command

  if ! "$REAL_CADDY" validate --config "$CADDYFILE" --adapter caddyfile; then
    error "现有 Caddyfile 校验失败，未启动服务。请先修正配置。"
    return 1
  fi

  systemctl enable caddy >/dev/null 2>&1 || true
  if systemctl restart caddy; then
    success "Caddy 已安装并启动。以后输入 caddyctl 即可打开管理菜单。"
    info "官方 CLI 保持不变，例如：caddy version、caddy validate --config $CADDYFILE"
  else
    error "Caddy 已安装，但服务启动失败。请通过菜单查看日志。"
    return 1
  fi
}

update_caddy() {
  local package_manager

  if [[ ! -x "$REAL_CADDY" ]]; then
    warn "Caddy 尚未安装。"
    return 1
  fi

  backup_file "$CADDYFILE" "Caddyfile-before-update"
  package_manager="$(detect_package_manager)"
  info "更新前版本：$($REAL_CADDY version 2>/dev/null || printf '未知')"

  case "$package_manager" in
    apt)
      apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade caddy
      ;;
    dnf)
      dnf upgrade -y caddy
      ;;
    *)
      error "无法识别包管理器。"
      return 1
      ;;
  esac

  if [[ $? -ne 0 ]]; then
    error "Caddy 更新失败。"
    return 1
  fi

  install_manager_command
  systemctl restart caddy || {
    error "更新完成，但服务重启失败。请查看日志。"
    return 1
  }
  success "当前版本：$($REAL_CADDY version 2>/dev/null || printf '未知')"
}

uninstall_caddy() {
  local answer package_manager

  if [[ ! -x "$REAL_CADDY" ]]; then
    warn "Caddy 当前未安装。管理菜单仍保留，可用于重新安装。"
    return 0
  fi

  warn "卸载将停止反向代理，但默认保留 /etc/caddy 和 /var/lib/caddy。"
  read -r -p "输入 uninstall 确认卸载：" answer
  [[ "$answer" == "uninstall" ]] || { info "已取消。"; return 0; }

  backup_file "$CADDYFILE" "Caddyfile-before-uninstall"
  systemctl disable --now caddy >/dev/null 2>&1 || true
  package_manager="$(detect_package_manager)"

  case "$package_manager" in
    apt) DEBIAN_FRONTEND=noninteractive apt-get remove -y caddy ;;
    dnf) dnf remove -y caddy ;;
    *) error "无法识别包管理器，未卸载软件包。"; return 1 ;;
  esac

  if [[ $? -ne 0 ]]; then
    error "软件包卸载失败。"
    return 1
  fi

  success "Caddy 已卸载，配置、证书数据和管理菜单均已保留。"
  info "需要重新安装时，输入 caddyctl 并选择“安装”。"
}

is_valid_domain() {
  local domain="$1"
  [[ ${#domain} -le 253 ]] || return 1
  [[ "$domain" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

is_valid_upstream_host() {
  local host="$1"
  [[ -n "$host" && "$host" =~ ^[A-Za-z0-9._:-]+$ ]]
}

is_valid_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 ))
}

site_path_for_domain() {
  local domain="$1"
  printf '%s/%s.caddy\n' "$SITES_DIR" "${domain,,}"
}

format_upstream_host() {
  local host="$1"
  host="${host#[}"
  host="${host%]}"
  if [[ "$host" == *:* ]]; then
    printf '[%s]\n' "$host"
  else
    printf '%s\n' "$host"
  fi
}

reload_validated_config() {
  if ! "$REAL_CADDY" validate --config "$CADDYFILE" --adapter caddyfile; then
    return 1
  fi

  if systemctl is-active --quiet caddy; then
    systemctl reload caddy
  else
    systemctl start caddy
  fi
}

test_upstream_connection() {
  local upstream_host="$1"
  local upstream_port="$2"
  local upstream_scheme="$3"
  local formatted_host

  command -v curl >/dev/null 2>&1 || return 0
  formatted_host="$(format_upstream_host "$upstream_host")"
  if curl -ksS --connect-timeout 3 --max-time 5 -o /dev/null \
      "$upstream_scheme://$formatted_host:$upstream_port/"; then
    success "宿主机可以访问上游服务。"
    return 0
  fi

  warn "宿主机无法连接 $upstream_scheme://$formatted_host:$upstream_port，配置后会出现 502。"
  if [[ "$upstream_host" == "127.0.0.1" || "$upstream_host" == "::1" ]]; then
    info "127.0.0.1 仅能访问发布到回环接口或所有接口的端口；若 Docker 端口绑定到服务器具体 IP，请填写该 IP。"
  fi
  return 1
}

save_proxy_config() {
  local domain="$1"
  local upstream_host="$2"
  local upstream_port="$3"
  local upstream_scheme="$4"
  local formatted_host
  local target temp_file rollback_file="" had_existing="false"

  if ! is_valid_domain "$domain"; then
    error "域名格式不正确。"
    return 1
  fi
  if ! is_valid_upstream_host "$upstream_host"; then
    error "上游 IP/主机名格式不正确。"
    return 1
  fi
  if ! is_valid_port "$upstream_port"; then
    error "端口必须是 1-65535 之间的整数。"
    return 1
  fi
  if [[ "$upstream_scheme" != "http" && "$upstream_scheme" != "https" ]]; then
    error "上游协议只能是 http 或 https。"
    return 1
  fi

  initialize_caddyfile
  target="$(site_path_for_domain "$domain")"
  temp_file="$(mktemp "${SITES_DIR}/.${domain}.XXXXXX")" || return 1
  formatted_host="$(format_upstream_host "$upstream_host")"

cat >"$temp_file" <<EOF
# 由 CaddyCtl 管理。再次通过菜单修改此站点时，该文件将被更新。
$domain {
	reverse_proxy $upstream_scheme://$formatted_host:$upstream_port
}
EOF

  "$REAL_CADDY" fmt --overwrite "$temp_file" >/dev/null 2>&1 || true

  if [[ -f "$target" ]]; then
    had_existing="true"
    rollback_file="$(mktemp)"
    cp -a -- "$target" "$rollback_file"
    backup_file "$target" "${domain}.caddy"
  fi

  install -m 0644 "$temp_file" "$target"
  rm -f -- "$temp_file"

  if ! reload_validated_config; then
    error "配置校验或重载失败，正在回滚。"
    if [[ "$had_existing" == "true" ]]; then
      install -m 0644 "$rollback_file" "$target"
    else
      rm -f -- "$target"
    fi
    rm -f -- "$rollback_file"
    reload_validated_config >/dev/null 2>&1 || true
    return 1
  fi

  rm -f -- "$rollback_file"
  success "已配置：https://$domain -> $upstream_scheme://$formatted_host:$upstream_port"
  info "若上游是 Docker 容器，建议端口映射为 127.0.0.1:${upstream_port}:容器内部端口。"
}

configure_manual_proxy() {
  local domain upstream_host upstream_port upstream_scheme

  printf '\n%s手动添加或更新反向代理%s\n' "$BOLD" "$RESET"
  read -r -p "1. 域名（例如 app.example.com）：" domain
  domain="${domain,,}"
  if ! is_valid_domain "$domain"; then
    error "域名格式不正确；如使用中文域名，请先转换为 Punycode。"
    return 1
  fi

  read -r -p "2. 上游地址（Docker 通常填 127.0.0.1；其他服务填实际监听地址）：" upstream_host
  upstream_host="${upstream_host#[}"
  upstream_host="${upstream_host%]}"
  if ! is_valid_upstream_host "$upstream_host"; then
    error "上游 IP/主机名格式不正确。"
    return 1
  fi

  read -r -p "3. 上游端口（例如 8080）：" upstream_port
  if ! is_valid_port "$upstream_port"; then
    error "端口必须是 1-65535 之间的整数。"
    return 1
  fi

  read -r -p "4. 上游协议 [http/https，默认 http]：" upstream_scheme
  upstream_scheme="${upstream_scheme:-http}"
  if [[ "$upstream_scheme" != "http" && "$upstream_scheme" != "https" ]]; then
    error "上游协议只能是 http 或 https。"
    return 1
  fi

  test_upstream_connection "$upstream_host" "$upstream_port" "$upstream_scheme" || true
  save_proxy_config "$domain" "$upstream_host" "$upstream_port" "$upstream_scheme"
}

show_compose_mapping_help() {
  local container_port="$1"
  local host_port="$2"

  printf '\n请在应用的 compose.yaml 中加入：\n\n'
  printf 'services:\n'
  printf '  app:\n'
  printf '    ports:\n'
  printf '      - "127.0.0.1:%s:%s"\n' "$host_port" "$container_port"
  printf '\n然后在 compose.yaml 所在目录执行：\n\n'
  printf '  docker compose up -d\n\n'
  warn "Docker 不能给已创建的容器原地增加端口映射，必须通过 Compose 重建容器。"
  info "此操作通常不会删除挂载卷，但执行前应确认应用数据目录已经正确持久化。"
}

select_docker_binding() {
  local container_name="$1"
  local container_port="$2"
  local bindings binding host_part host_port

  bindings="$(docker port "$container_name" "${container_port}/tcp" 2>/dev/null || true)"
  [[ -n "$bindings" ]] || return 1

  # Prefer an IPv4 loopback/all-interface binding. Docker often reports both
  # 0.0.0.0 and [::] for the same published port.
  binding="$(printf '%s\n' "$bindings" \
    | sed -n '/^127\.0\.0\.1:[0-9][0-9]*$/p;/^0\.0\.0\.0:[0-9][0-9]*$/p' \
    | head -n 1)"
  if [[ -z "$binding" ]]; then
    binding="$(printf '%s\n' "$bindings" | sed -n '/^[0-9.][0-9.]*:[0-9][0-9]*$/p' | head -n 1)"
  fi
  [[ -n "$binding" ]] || return 1

  host_part="${binding%:*}"
  host_port="${binding##*:}"
  [[ "$host_part" == "0.0.0.0" ]] && host_part="127.0.0.1"
  printf '%s %s\n' "$host_part" "$host_port"
}

configure_docker_proxy() {
  local container_name container_port host_port domain upstream_scheme binding
  local upstream_host published_display exposed_ports

  if ! command -v docker >/dev/null 2>&1; then
    error "未检测到 Docker 命令。"
    return 1
  fi
  if ! docker info >/dev/null 2>&1; then
    error "无法连接 Docker 服务。当前菜单已使用 root 运行，请确认 Docker 正在运行。"
    return 1
  fi

  printf '\n%sDocker 容器代理向导%s\n' "$BOLD" "$RESET"
  printf '\n运行中的容器：\n'
  docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Ports}}'
  printf '\n'
  read -r -p "1. 输入容器名称：" container_name
  if ! docker inspect "$container_name" >/dev/null 2>&1; then
    error "未找到容器：$container_name"
    return 1
  fi
  if [[ "$(docker inspect --format '{{.State.Running}}' "$container_name" 2>/dev/null)" != "true" ]]; then
    error "容器当前没有运行：$container_name"
    return 1
  fi

  exposed_ports="$(docker inspect --format '{{range $port, $_ := .Config.ExposedPorts}}{{println $port}}{{end}}' "$container_name" 2>/dev/null || true)"
  if [[ -n "$exposed_ports" ]]; then
    printf '镜像声明的容器端口：\n%s\n' "$exposed_ports"
  else
    warn "镜像没有声明 EXPOSE 端口，请根据服务启动参数填写实际监听端口。"
  fi

  read -r -p "2. 容器内部 TCP 端口（例如 8080）：" container_port
  if ! is_valid_port "$container_port"; then
    error "容器端口必须是 1-65535 之间的整数。"
    return 1
  fi

  published_display="$(docker port "$container_name" "${container_port}/tcp" 2>/dev/null || true)"
  if [[ -z "$published_display" ]]; then
    warn "该容器没有发布 ${container_port}/tcp 到宿主机。"
    read -r -p "希望使用的宿主机端口 [默认 8080]：" host_port
    host_port="${host_port:-8080}"
    if ! is_valid_port "$host_port"; then
      error "宿主机端口必须是 1-65535 之间的整数。"
      return 1
    fi
    show_compose_mapping_help "$container_port" "$host_port"
    return 1
  fi

  printf '检测到端口映射：\n%s\n' "$published_display"
  binding="$(select_docker_binding "$container_name" "$container_port" || true)"
  if [[ -z "$binding" ]]; then
    error "只检测到 IPv6 或无法识别的映射。建议增加 127.0.0.1 的 IPv4 映射。"
    read -r -p "希望使用的宿主机端口 [默认 8080]：" host_port
    host_port="${host_port:-8080}"
    is_valid_port "$host_port" && show_compose_mapping_help "$container_port" "$host_port"
    return 1
  fi

  upstream_host="${binding%% *}"
  host_port="${binding##* }"
  if printf '%s\n' "$published_display" | grep -Eq '^0\.0\.0\.0:|^\[::\]:'; then
    warn "当前端口发布到所有网络接口，应用管理界面可能仍可被公网直接访问。"
    info "建议将 Compose 映射改成 127.0.0.1:${host_port}:${container_port}。"
  fi

  read -r -p "3. 域名（例如 app.example.com）：" domain
  domain="${domain,,}"
  if ! is_valid_domain "$domain"; then
    error "域名格式不正确；如使用中文域名，请先转换为 Punycode。"
    return 1
  fi

  read -r -p "4. 上游协议 [http/https，默认 http]：" upstream_scheme
  upstream_scheme="${upstream_scheme:-http}"
  if [[ "$upstream_scheme" != "http" && "$upstream_scheme" != "https" ]]; then
    error "上游协议只能是 http 或 https。"
    return 1
  fi

  test_upstream_connection "$upstream_host" "$host_port" "$upstream_scheme" || true

  save_proxy_config "$domain" "$upstream_host" "$host_port" "$upstream_scheme"
}

configure_proxy() {
  local mode

  if [[ ! -x "$REAL_CADDY" ]]; then
    error "请先安装 Caddy。"
    return 1
  fi

  printf '\n%s请选择上游服务类型%s\n' "$BOLD" "$RESET"
  printf '  1. 手动填写服务地址和端口\n'
  printf '  2. Docker 容器连接向导（仅适用于 Docker 容器）\n'
  printf '  0. 返回\n'
  read -r -p "请选择 [0-2]：" mode

  case "$mode" in
    1) configure_manual_proxy ;;
    2) configure_docker_proxy ;;
    0) return 0 ;;
    *) error "无效选项：$mode"; return 1 ;;
  esac
}

read_proxy_settings() {
  local target="$1"
  local upstream address upstream_scheme upstream_host upstream_port

  upstream="$(awk '$1 == "reverse_proxy" { print $2; exit }' "$target")"
  [[ "$upstream" =~ ^https?:// ]] || return 1
  upstream_scheme="${upstream%%://*}"
  address="${upstream#*://}"

  if [[ "$address" =~ ^\[([[:xdigit:]:]+)\]:([0-9]+)$ ]]; then
    upstream_host="${BASH_REMATCH[1]}"
    upstream_port="${BASH_REMATCH[2]}"
  elif [[ "$address" =~ ^([^:/]+):([0-9]+)$ ]]; then
    upstream_host="${BASH_REMATCH[1]}"
    upstream_port="${BASH_REMATCH[2]}"
  else
    return 1
  fi

  is_valid_upstream_host "$upstream_host" && is_valid_port "$upstream_port" || return 1
  printf '%s\t%s\t%s\n' "$upstream_scheme" "$upstream_host" "$upstream_port"
}

show_site_choices() {
  local site domain settings upstream_scheme upstream_host upstream_port

  for site in "$SITES_DIR"/*.caddy; do
    domain="${site##*/}"
    domain="${domain%.caddy}"
    settings="$(read_proxy_settings "$site" || true)"
    if [[ -n "$settings" ]]; then
      IFS=$'\t' read -r upstream_scheme upstream_host upstream_port <<< "$settings"
      printf '  - %s  ->  %s://%s:%s\n' \
        "$domain" "$upstream_scheme" "$(format_upstream_host "$upstream_host")" "$upstream_port"
    else
      printf '  - %s  ->  自定义 Caddy 配置\n' "$domain"
    fi
  done
}

edit_proxy_config() {
  local domain target settings upstream_scheme upstream_host upstream_port
  local updated_host updated_port updated_scheme

  if [[ ! -x "$REAL_CADDY" ]]; then
    error "请先安装 Caddy。"
    return 1
  fi
  if ! compgen -G "${SITES_DIR}/*.caddy" >/dev/null 2>&1; then
    warn "暂无可修改的站点配置。"
    return 0
  fi

  printf '\n可修改的站点（域名 -> 当前上游）：\n'
  show_site_choices
  read -r -p "输入需要修改的完整域名：" domain
  domain="${domain,,}"
  if ! is_valid_domain "$domain"; then
    error "域名格式不正确。"
    return 1
  fi

  target="$(site_path_for_domain "$domain")"
  if [[ ! -f "$target" ]]; then
    error "未找到该域名的独立配置：$target"
    return 1
  fi
  settings="$(read_proxy_settings "$target")" || {
    error "无法识别该站点的上游地址；仅支持本工具生成的 reverse_proxy http(s)://主机:端口 配置。"
    return 1
  }
  IFS=$'\t' read -r upstream_scheme upstream_host upstream_port <<< "$settings"

  printf '\n当前上游：%s://%s:%s\n' "$upstream_scheme" "$(format_upstream_host "$upstream_host")" "$upstream_port"
  read -r -p "1. 上游 IP/主机名 [$upstream_host]：" updated_host
  updated_host="${updated_host:-$upstream_host}"
  updated_host="${updated_host#[}"
  updated_host="${updated_host%]}"
  if ! is_valid_upstream_host "$updated_host"; then
    error "上游 IP/主机名格式不正确。"
    return 1
  fi

  read -r -p "2. 上游端口 [$upstream_port]：" updated_port
  updated_port="${updated_port:-$upstream_port}"
  if ! is_valid_port "$updated_port"; then
    error "端口必须是 1-65535 之间的整数。"
    return 1
  fi

  read -r -p "3. 上游协议 [http/https，当前 $upstream_scheme]：" updated_scheme
  updated_scheme="${updated_scheme:-$upstream_scheme}"
  if [[ "$updated_scheme" != "http" && "$updated_scheme" != "https" ]]; then
    error "上游协议只能是 http 或 https。"
    return 1
  fi

  test_upstream_connection "$updated_host" "$updated_port" "$updated_scheme" || true
  save_proxy_config "$domain" "$updated_host" "$updated_port" "$updated_scheme"
}

show_raw_config() {
  local site

  printf '\n%s原始主配置：%s%s\n' "$BOLD" "$CADDYFILE" "$RESET"
  if [[ -f "$CADDYFILE" ]]; then
    sed -n '1,$p' "$CADDYFILE"
  else
    warn "主配置文件不存在。"
  fi

  printf '\n%s原始站点配置：%s%s\n' "$BOLD" "$SITES_DIR" "$RESET"
  if compgen -G "${SITES_DIR}/*.caddy" >/dev/null 2>&1; then
    for site in "$SITES_DIR"/*.caddy; do
      printf '\n--- %s ---\n' "$site"
      sed -n '1,$p' "$site"
    done
  else
    warn "暂未找到站点配置文件。"
  fi
}

show_config() {
  local answer

  printf '\n%s当前反向代理配置%s\n' "$BOLD" "$RESET"
  if [[ -f "$CADDYFILE" ]] && grep -Fq "import $SITES_DIR/*.caddy" "$CADDYFILE"; then
    printf '  主配置：已加载站点目录 %s\n' "$SITES_DIR"
  else
    warn "主配置未检测到站点目录导入，请检查 $CADDYFILE。"
  fi

  if compgen -G "${SITES_DIR}/*.caddy" >/dev/null 2>&1; then
    printf '\n已配置站点（域名 -> 上游）：\n'
    show_site_choices
    printf '\n提示：使用“修改现有反向代理”更新上游，使用“删除反向代理”移除站点。\n'
  else
    warn "暂未配置反向代理站点。"
  fi

  read -r -p "是否查看原始 Caddy 配置？[y/N]：" answer
  [[ "$answer" =~ ^[Yy]$ ]] && show_raw_config
}

delete_proxy() {
  local domain target rollback_file answer

  if [[ ! -x "$REAL_CADDY" ]]; then
    error "Caddy 尚未安装。"
    return 1
  fi

  if ! compgen -G "${SITES_DIR}/*.caddy" >/dev/null 2>&1; then
    warn "暂无可删除的站点配置。"
    return 0
  fi

  printf '\n可删除的站点（域名 -> 当前上游）：\n'
  show_site_choices
  read -r -p "输入需要删除的完整域名：" domain
  domain="${domain,,}"

  if ! is_valid_domain "$domain"; then
    error "域名格式不正确。"
    return 1
  fi

  target="$(site_path_for_domain "$domain")"
  if [[ ! -f "$target" ]]; then
    error "未找到该域名的独立配置：$target"
    return 1
  fi

  read -r -p "确认删除 $domain 的代理配置？[y/N]：" answer
  [[ "$answer" =~ ^[Yy]$ ]] || { info "已取消。"; return 0; }

  rollback_file="$(mktemp)"
  cp -a -- "$target" "$rollback_file"
  backup_file "$target" "${domain}.caddy-before-delete"
  rm -f -- "$target"

  if ! reload_validated_config; then
    error "删除后的配置无法加载，正在恢复。"
    install -m 0644 "$rollback_file" "$target"
    rm -f -- "$rollback_file"
    reload_validated_config >/dev/null 2>&1 || true
    return 1
  fi

  rm -f -- "$rollback_file"
  success "$domain 的代理配置已删除。"
}

validate_and_reload() {
  if [[ ! -x "$REAL_CADDY" ]]; then
    error "Caddy 尚未安装。"
    return 1
  fi

  if reload_validated_config; then
    success "配置校验通过，Caddy 已重载。"
  else
    error "配置校验或服务重载失败。"
    return 1
  fi
}

show_logs() {
  if ! command -v journalctl >/dev/null 2>&1; then
    error "当前系统没有 journalctl。"
    return 1
  fi
  printf '\n%sCaddy 最近 120 条服务日志%s\n' "$BOLD" "$RESET"
  journalctl -u caddy -n 120 --no-pager
}

show_listeners() {
  printf '\n%s宿主机监听端口（Caddy、Docker、80、443）%s\n' "$BOLD" "$RESET"
  if command -v ss >/dev/null 2>&1; then
    ss -ltnp 2>/dev/null | sed -n '1p;/caddy/p;/docker-proxy/p;/:80 /p;/:443 /p'
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltnp 2>/dev/null | sed -n '1,2p;/caddy/p;/docker-proxy/p;/:80 /p;/:443 /p'
  else
    warn "未找到 ss 或 netstat。"
  fi

  printf '\n%sDocker 容器端口映射%s\n' "$BOLD" "$RESET"
  if command -v docker >/dev/null 2>&1; then
    printf '容器名称\t状态\t端口映射\n'
    docker ps --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || true
  else
    warn "未安装 Docker。"
  fi
}

service_value() {
  local action="$1"
  if ! command -v systemctl >/dev/null 2>&1; then
    printf '不可用'
    return
  fi
  systemctl "$action" caddy 2>/dev/null || true
}

status_line() {
  local installed="未安装" version="-" active="未运行" enabled="未启用" site_count="0"

  if [[ -x "$REAL_CADDY" ]]; then
    installed="已安装"
    version="$($REAL_CADDY version 2>/dev/null || printf '未知')"
  fi
  [[ "$(service_value is-active)" == "active" ]] && active="运行中"
  [[ "$(service_value is-enabled)" == "enabled" ]] && enabled="开机启动"
  if [[ -d "$SITES_DIR" ]]; then
    site_count="$(find "$SITES_DIR" -maxdepth 1 -type f -name '*.caddy' 2>/dev/null | wc -l | tr -d ' ')"
  fi

  printf '安装：%s%s%s | 服务：%s | 开机启动：%s | 站点数：%s\n' \
    "$GREEN" "$installed" "$RESET" "$active" "$enabled" "$site_count"
  printf 'Caddy 版本：%s | CaddyCtl 版本：%s\n' "$version" "$MANAGER_VERSION"
}

draw_menu() {
  clear 2>/dev/null || true
  printf '%s============================================%s\n' "$BLUE" "$RESET"
  printf '%s              CaddyCtl 管理菜单%s\n' "$BOLD" "$RESET"
  printf '%s============================================%s\n' "$BLUE" "$RESET"
  status_line
  printf '%s--------------------------------------------%s\n' "$BLUE" "$RESET"
  printf '  1. 查看运行状态\n'
  printf '  2. 安装或修复 Caddy\n'
  printf '  3. 更新 Caddy\n'
  printf '  4. 卸载 Caddy（保留配置和证书）\n'
  printf '  5. 新增反向代理\n'
  printf '  6. 修改现有反向代理\n'
  printf '  7. 查看当前反向代理配置\n'
  printf '  8. 删除反向代理\n'
  printf '  9. 校验并重载 Caddy\n'
  printf ' 10. 查看 Caddy 服务日志\n'
  printf ' 11. 查看端口监听与 Docker 映射\n'
  printf '  0. 退出\n'
  printf '%s============================================%s\n' "$BLUE" "$RESET"
}

show_status_detail() {
  status_line
  printf '\n'
  if command -v systemctl >/dev/null 2>&1; then
    systemctl status caddy --no-pager -l 2>/dev/null || true
  fi
}

main_menu() {
  local choice
  while true; do
    draw_menu
    read -r -p "请选择 [0-11]：" choice || exit 0
    printf '\n'

    case "$choice" in
      1) show_status_detail; pause_menu ;;
      2) install_caddy; pause_menu ;;
      3) update_caddy; pause_menu ;;
      4) uninstall_caddy; pause_menu ;;
      5) configure_proxy; pause_menu ;;
      6) edit_proxy_config; pause_menu ;;
      7) show_config; pause_menu ;;
      8) delete_proxy; pause_menu ;;
      9) validate_and_reload; pause_menu ;;
      10) show_logs; pause_menu ;;
      11) show_listeners; pause_menu ;;
      0) exit 0 ;;
      *) warn "无效选项：$choice"; pause_menu ;;
    esac
  done
}

if [[ $# -eq 1 && ( "$1" == "--help" || "$1" == "-h" ) ]]; then
  show_command_usage
  exit 0
fi

if [[ $# -eq 1 && "$1" == "--install" ]]; then
  require_root "$@"
  install_caddy || exit $?
  main_menu
  exit 0
fi

if [[ $# -ne 0 ]]; then
  show_command_usage
  exit 2
fi
require_root "$@"
main_menu
