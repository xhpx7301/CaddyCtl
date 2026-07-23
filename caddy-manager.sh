#!/usr/bin/env bash

# Caddy Manager - a small interactive manager for a package-installed Caddy.
# Run without arguments to open the menu. Arguments are forwarded to the real
# Caddy binary after the manager command has been installed.

set -uo pipefail

readonly MANAGER_VERSION="1.1.0"
readonly REAL_CADDY="/usr/bin/caddy"
readonly CADDYFILE="/etc/caddy/Caddyfile"
readonly SITES_DIR="/etc/caddy/sites"
readonly BACKUP_DIR="/var/backups/caddy-manager"
readonly MANAGER_DIR="/usr/local/lib/caddy-manager"
readonly MANAGER_SCRIPT="${MANAGER_DIR}/caddy-manager.sh"
readonly MANAGER_COMMAND="/usr/local/bin/caddy"
readonly IMPORT_BEGIN="# BEGIN CADDY-MANAGER SITES"
readonly IMPORT_END="# END CADDY-MANAGER SITES"

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
  read -r -p "按 Enter 返回菜单..." _ || true
}

manager_source() {
  local source_path="${BASH_SOURCE[0]}"
  readlink -f "$source_path" 2>/dev/null || printf '%s\n' "$source_path"
}

forward_to_caddy() {
  if [[ $# -eq 0 ]]; then
    return 1
  fi

  if [[ ! -x "$REAL_CADDY" ]]; then
    error "尚未安装 Caddy，请先无参数运行 caddy-manager.sh 并选择安装。"
    exit 127
  fi

  exec "$REAL_CADDY" "$@"
}

require_root() {
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    return
  fi

  if ! command -v sudo >/dev/null 2>&1; then
    error "此菜单需要 root 权限，并且系统没有安装 sudo。"
    exit 1
  fi

  exec sudo bash "$(manager_source)"
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
      && ! grep -Fq 'MANAGER_SCRIPT="/usr/local/lib/caddy-manager/caddy-manager.sh"' "$MANAGER_COMMAND" 2>/dev/null; then
    warn "$MANAGER_COMMAND 已存在，将先备份再安装管理入口。"
    backup_file "$MANAGER_COMMAND" "caddy-command"
  fi
  rm -f -- "$MANAGER_COMMAND"

  cat >"$MANAGER_COMMAND" <<'WRAPPER'
#!/usr/bin/env bash
set -uo pipefail

readonly REAL_CADDY="/usr/bin/caddy"
readonly MANAGER_SCRIPT="/usr/local/lib/caddy-manager/caddy-manager.sh"

if [[ $# -eq 0 ]]; then
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    exec "$MANAGER_SCRIPT"
  fi
  if ! command -v sudo >/dev/null 2>&1; then
    printf '打开管理菜单需要 root 权限，但系统未安装 sudo。\n' >&2
    exit 1
  fi
  exec sudo "$MANAGER_SCRIPT"
fi

if [[ ! -x "$REAL_CADDY" ]]; then
  printf 'Caddy 尚未安装。请无参数运行 caddy 打开管理菜单。\n' >&2
  exit 127
fi

exec "$REAL_CADDY" "$@"
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

  if grep -Fq "$IMPORT_BEGIN" "$CADDYFILE"; then
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
    success "Caddy 已安装并启动。以后输入 caddy 即可打开此菜单。"
    info "官方 CLI 仍可使用，例如：caddy version、caddy validate --config $CADDYFILE"
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
  info "需要重新安装时，输入 caddy 并选择“安装”。"
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
# Managed by Caddy Manager. Local changes are preserved until this domain is edited again.
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
  read -r -p "1. 域名（例如 kopiaalihk.6990699.xyz）：" domain
  domain="${domain,,}"
  if ! is_valid_domain "$domain"; then
    error "域名格式不正确；如使用中文域名，请先转换为 Punycode。"
    return 1
  fi

  read -r -p "2. 上游 IP/主机名（宿主机代理 Docker 通常填 127.0.0.1）：" upstream_host
  upstream_host="${upstream_host#[}"
  upstream_host="${upstream_host%]}"
  if ! is_valid_upstream_host "$upstream_host"; then
    error "上游 IP/主机名格式不正确。"
    return 1
  fi

  read -r -p "3. 上游端口（例如 41515）：" upstream_port
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

  save_proxy_config "$domain" "$upstream_host" "$upstream_port" "$upstream_scheme"
}

show_compose_mapping_help() {
  local container_port="$1"
  local host_port="$2"

  printf '\n请在 Kopia 的 compose.yaml 中加入：\n\n'
  printf 'services:\n'
  printf '  kopia:\n'
  printf '    ports:\n'
  printf '      - "127.0.0.1:%s:%s"\n' "$host_port" "$container_port"
  printf '\n然后在 compose.yaml 所在目录执行：\n\n'
  printf '  docker compose up -d\n\n'
  warn "Docker 不能给已创建的容器原地增加端口映射，必须通过 Compose 重建容器。"
  info "此操作通常不会删除挂载卷，但执行前应确认 Kopia 数据目录已经正确持久化。"
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
  read -r -p "1. 输入 Kopia 容器名称：" container_name
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
    warn "镜像没有声明 EXPOSE 端口，请根据 Kopia 启动参数填写实际监听端口。"
  fi

  read -r -p "2. Kopia 容器内部 TCP 端口（常见为 51515）：" container_port
  if ! is_valid_port "$container_port"; then
    error "容器端口必须是 1-65535 之间的整数。"
    return 1
  fi

  published_display="$(docker port "$container_name" "${container_port}/tcp" 2>/dev/null || true)"
  if [[ -z "$published_display" ]]; then
    warn "该容器没有发布 ${container_port}/tcp 到宿主机。"
    read -r -p "希望使用的宿主机端口 [默认 41515]：" host_port
    host_port="${host_port:-41515}"
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
    read -r -p "希望使用的宿主机端口 [默认 41515]：" host_port
    host_port="${host_port:-41515}"
    is_valid_port "$host_port" && show_compose_mapping_help "$container_port" "$host_port"
    return 1
  fi

  upstream_host="${binding%% *}"
  host_port="${binding##* }"
  if printf '%s\n' "$published_display" | grep -Eq '^0\.0\.0\.0:|^\[::\]:'; then
    warn "当前端口发布到所有网络接口，Kopia 管理端口可能仍可被公网直接访问。"
    info "建议将 Compose 映射改成 127.0.0.1:${host_port}:${container_port}。"
  fi

  read -r -p "3. 域名（例如 kopiaalihk.6990699.xyz）：" domain
  domain="${domain,,}"
  if ! is_valid_domain "$domain"; then
    error "域名格式不正确；如使用中文域名，请先转换为 Punycode。"
    return 1
  fi

  read -r -p "4. Kopia 上游协议 [http/https，默认 http]：" upstream_scheme
  upstream_scheme="${upstream_scheme:-http}"
  if [[ "$upstream_scheme" != "http" && "$upstream_scheme" != "https" ]]; then
    error "上游协议只能是 http 或 https。"
    return 1
  fi

  if command -v curl >/dev/null 2>&1; then
    if curl -ksS --connect-timeout 3 --max-time 5 -o /dev/null \
        "$upstream_scheme://$upstream_host:$host_port/"; then
      success "宿主机可以访问 Kopia 映射端口。"
    else
      warn "端口映射存在，但暂时无法取得 HTTP 响应；配置后可能出现 502。"
    fi
  fi

  save_proxy_config "$domain" "$upstream_host" "$host_port" "$upstream_scheme"
}

configure_proxy() {
  local mode

  if [[ ! -x "$REAL_CADDY" ]]; then
    error "请先安装 Caddy。"
    return 1
  fi

  printf '\n%s选择上游类型%s\n' "$BOLD" "$RESET"
  printf '  1. 手动输入 IP/主机名和端口\n'
  printf '  2. Docker 容器连接向导\n'
  printf '  0. 返回\n'
  read -r -p "请选择 [0-2]：" mode

  case "$mode" in
    1) configure_manual_proxy ;;
    2) configure_docker_proxy ;;
    0) return 0 ;;
    *) error "无效选项：$mode"; return 1 ;;
  esac
}

show_config() {
  printf '\n%s主配置：%s%s\n' "$BOLD" "$CADDYFILE" "$RESET"
  if [[ -f "$CADDYFILE" ]]; then
    sed -n '1,$p' "$CADDYFILE"
  else
    warn "主配置不存在。"
  fi

  printf '\n%s站点配置：%s%s\n' "$BOLD" "$SITES_DIR" "$RESET"
  if compgen -G "${SITES_DIR}/*.caddy" >/dev/null 2>&1; then
    local site
    for site in "$SITES_DIR"/*.caddy; do
      printf '\n--- %s ---\n' "$site"
      sed -n '1,$p' "$site"
    done
  else
    warn "暂无站点配置。"
  fi
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

  printf '\n当前站点：\n'
  find "$SITES_DIR" -maxdepth 1 -type f -name '*.caddy' -printf '  - %f\n' 2>/dev/null \
    | sed 's/\.caddy$//'
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
  journalctl -u caddy -n 120 --no-pager
}

show_listeners() {
  printf '\n%s宿主机监听端口%s\n' "$BOLD" "$RESET"
  if command -v ss >/dev/null 2>&1; then
    ss -ltnp 2>/dev/null | sed -n '1p;/caddy/p;/docker-proxy/p;/:80 /p;/:443 /p;/:41515 /p'
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltnp 2>/dev/null | sed -n '1,2p;/caddy/p;/docker-proxy/p;/:80 /p;/:443 /p;/:41515 /p'
  else
    warn "未找到 ss 或 netstat。"
  fi

  printf '\n%sDocker 端口映射%s\n' "$BOLD" "$RESET"
  if command -v docker >/dev/null 2>&1; then
    docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || true
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

  printf '状态：%s%s%s | 服务：%s | 自启：%s | 站点：%s\n' \
    "$GREEN" "$installed" "$RESET" "$active" "$enabled" "$site_count"
  printf '版本：%s | 管理脚本：%s\n' "$version" "$MANAGER_VERSION"
}

draw_menu() {
  clear 2>/dev/null || true
  printf '%s============================================%s\n' "$BLUE" "$RESET"
  printf '%s          Caddy 中文管理菜单%s\n' "$BOLD" "$RESET"
  printf '%s============================================%s\n' "$BLUE" "$RESET"
  status_line
  printf '%s--------------------------------------------%s\n' "$BLUE" "$RESET"
  printf '  1. Caddy 当前状态\n'
  printf '  2. 安装 Caddy / 安装管理命令\n'
  printf '  3. 更新 Caddy\n'
  printf '  4. 卸载 Caddy（保留配置）\n'
  printf '  5. 添加反向代理（手动 / Docker 向导）\n'
  printf '  6. 查看当前配置\n'
  printf '  7. 删除反向代理配置\n'
  printf '  8. 校验配置并重载\n'
  printf '  9. 查看 Caddy 日志\n'
  printf ' 10. 检查监听端口和 Docker 映射\n'
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
    read -r -p "请选择 [0-10]：" choice || exit 0
    printf '\n'

    case "$choice" in
      1) show_status_detail; pause_menu ;;
      2) install_caddy; pause_menu ;;
      3) update_caddy; pause_menu ;;
      4) uninstall_caddy; pause_menu ;;
      5) configure_proxy; pause_menu ;;
      6) show_config; pause_menu ;;
      7) delete_proxy; pause_menu ;;
      8) validate_and_reload; pause_menu ;;
      9) show_logs; pause_menu ;;
      10) show_listeners; pause_menu ;;
      0) exit 0 ;;
      *) warn "无效选项：$choice"; pause_menu ;;
    esac
  done
}

forward_to_caddy "$@" || true
require_root
main_menu
