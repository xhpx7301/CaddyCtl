#!/usr/bin/env bash

# CaddyCtl - an interactive manager for a package-installed Caddy.
# Run without arguments to open the menu. Keep the official `caddy` command
# for the Caddy CLI; this project installs the separate `caddyctl` command.

set -uo pipefail

readonly PROJECT_NAME="CaddyCtl"
readonly MANAGER_VERSION="3.3.30"
readonly MANAGER_SOURCE_URL="${CADDYCTL_SOURCE_URL:-https://raw.githubusercontent.com/xhpx7301/CaddyCtl/main/caddyctl.sh}"
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

confirm_action() {
  local prompt="$1"
  local answer

  read -r -p "$prompt [y/N]：" answer || return 1
  [[ "$answer" =~ ^[Yy]$ ]]
}

manager_source() {
  local source_path="${BASH_SOURCE[0]}"
  readlink -f "$source_path" 2>/dev/null || printf '%s\n' "$source_path"
}

show_command_usage() {
  printf '%s\n' "$PROJECT_NAME 是 Caddy 的管理菜单。"
  printf '%s\n' "用法：caddyctl [--install]"
  printf '%s\n' "  --install  直接安装 Caddy 并打开管理菜单"
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

cache_busted_github_raw_url() {
  local source_url="$1"
  local separator

  case "$source_url" in
    https://raw.githubusercontent.com/*)
      [[ "$source_url" == *\?* ]] && separator="&" || separator="?"
      printf '%s%scaddyctl_cache_bust=%s-%s-%s\n' "$source_url" "$separator" "$(date +%s)" "$$" "$RANDOM"
      ;;
    *) printf '%s\n' "$source_url" ;;
  esac
}

download_manager_script() {
  local destination="$1"
  local source_url

  source_url="$(cache_busted_github_raw_url "$MANAGER_SOURCE_URL")"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --proto '=https' --tlsv1.2 \
      -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
      "$source_url" -o "$destination"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$destination" \
      --header='Cache-Control: no-cache' --header='Pragma: no-cache' \
      "$source_url"
  else
    error "需要 curl 或 wget 才能下载 CaddyCtl 更新。"
    return 1
  fi
}

manager_version_from_file() {
  local path="$1"
  sed -n 's/^readonly MANAGER_VERSION="\([^"]*\)"$/\1/p' "$path" | head -n 1
}

update_manager() {
  local temp_file current_version updated_version

  temp_file="$(mktemp)" || {
    error "无法创建更新临时文件。"
    return 1
  }
  current_version="$MANAGER_VERSION"
  info "正在下载 CaddyCtl 管理菜单更新..."
  if ! download_manager_script "$temp_file"; then
    rm -f -- "$temp_file"
    error "下载更新失败，当前版本保持不变。"
    return 1
  fi
  if ! grep -Fq 'readonly PROJECT_NAME="CaddyCtl"' "$temp_file" \
      || ! bash -n "$temp_file"; then
    rm -f -- "$temp_file"
    error "下载的脚本校验失败，当前版本保持不变。"
    return 1
  fi

  updated_version="$(manager_version_from_file "$temp_file")"
  if [[ -z "$updated_version" ]]; then
    rm -f -- "$temp_file"
    error "下载的脚本缺少版本信息，当前版本保持不变。"
    return 1
  fi
  if [[ -f "$MANAGER_SCRIPT" ]] && cmp -s "$temp_file" "$MANAGER_SCRIPT"; then
    rm -f -- "$temp_file"
    success "CaddyCtl 已是最新版本（$current_version）。"
    return 0
  fi

  backup_file "$MANAGER_SCRIPT" "caddyctl-before-update"
  install -d -m 0755 "$MANAGER_DIR"
  if ! install -m 0755 "$temp_file" "$MANAGER_SCRIPT"; then
    rm -f -- "$temp_file"
    error "写入 CaddyCtl 更新失败，当前版本保持不变。"
    return 1
  fi
  rm -f -- "$temp_file"
  success "CaddyCtl 已更新：$current_version -> $updated_version"
  info "正在重新打开新版本菜单。"
  exec "$MANAGER_SCRIPT"
  error "更新已写入，但无法自动重新打开菜单。请退出后重新执行 caddyctl。"
  return 1
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

install_or_update_caddy() {
  if [[ -x "$REAL_CADDY" ]]; then
    update_caddy
  else
    install_caddy
  fi
}

remove_caddy_package() {
  local package_manager

  if [[ ! -x "$REAL_CADDY" ]]; then
    warn "Caddy 当前未安装。"
    return 0
  fi

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

  return 0
}

uninstall_caddy() {
  if [[ ! -x "$REAL_CADDY" ]]; then
    warn "Caddy 当前未安装。管理菜单仍保留，可用于重新安装。"
    return 0
  fi

  warn "卸载将停止反向代理，但默认保留 /etc/caddy 和 /var/lib/caddy。"
  confirm_action "确认卸载 Caddy？" || { info "已取消。"; return 0; }

  remove_caddy_package || return 1
  success "Caddy 已卸载，配置、证书数据和管理菜单均已保留。"
  info "需要重新安装时，输入 caddyctl 并选择“安装或更新 Caddy”。"
}

remove_manager_files() {
  backup_file "$MANAGER_SCRIPT" "caddyctl-before-uninstall"
  backup_file "$MANAGER_COMMAND" "caddyctl-command-before-uninstall"
  rm -f -- "$MANAGER_COMMAND" "$MANAGER_SCRIPT"
  rmdir -- "$MANAGER_DIR" 2>/dev/null || true
}

uninstall_manager() {
  warn "这将删除 caddyctl 命令和管理脚本，但不会修改 Caddy、站点配置或证书。"
  confirm_action "确认卸载 CaddyCtl 管理菜单？" || { info "已取消。"; return 0; }

  remove_manager_files

  success "CaddyCtl 管理菜单已卸载。Caddy、配置和证书保持不变。"
}

uninstall_everything() {
  warn "这将卸载 Caddy 和 CaddyCtl 管理菜单，停止反向代理服务。"
  warn "站点配置、Caddyfile、证书和数据目录将被保留，不会删除。"
  confirm_action "确认完全卸载 Caddy 和 CaddyCtl？" || { info "已取消。"; return 0; }

  remove_caddy_package || return 1
  remove_manager_files
  success "Caddy 和 CaddyCtl 管理菜单已卸载。配置、证书和数据目录保持不变。"
}

uninstall_menu() {
  local choice

  printf '\n%s请选择卸载内容%s\n' "$BOLD" "$RESET"
  printf '  1. 卸载 Caddy（保留配置、证书和 CaddyCtl）\n'
  printf '  2. 卸载 CaddyCtl 管理菜单（保留 Caddy、配置和证书）\n'
  printf '  3. 完全卸载 Caddy 和 CaddyCtl（保留配置和证书）\n'
  printf '  0. 返回\n'
  read -r -p "请选择 [0-3]：" choice

  case "$choice" in
    1) uninstall_caddy ;;
    2) uninstall_manager ;;
    3) uninstall_everything ;;
    0) return 0 ;;
    *) error "无效选项：$choice"; return 1 ;;
  esac
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
  local formatted_host http_status

  command -v curl >/dev/null 2>&1 || return 0
  formatted_host="$(format_upstream_host "$upstream_host")"
  if http_status="$(curl -ksS --connect-timeout 3 --max-time 5 -o /dev/null \
      -w '%{http_code}' "$upstream_scheme://$formatted_host:$upstream_port/")"; then
    if [[ "$http_status" == "401" || "$http_status" == "403" ]]; then
      success "已连通后端服务（HTTP $http_status，需要认证或无访问权限）。"
    else
      success "已连通后端服务（HTTP $http_status）。"
    fi
    return 0
  fi

  warn "宿主机无法连接后端服务 $upstream_scheme://$formatted_host:$upstream_port，配置后会出现 502。"
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
    error "后端服务地址格式不正确。"
    return 1
  fi
  if ! is_valid_port "$upstream_port"; then
    error "端口必须是 1-65535 之间的整数。"
    return 1
  fi
  if [[ "$upstream_scheme" != "http" && "$upstream_scheme" != "https" ]]; then
    error "后端服务协议只能是 http 或 https。"
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
  success "已配置：https://$domain -> 后端服务 $upstream_scheme://$formatted_host:$upstream_port"
  info "若后端服务运行在 Docker 容器中，建议端口映射为 127.0.0.1:${upstream_port}:容器内部端口。"
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

  read -r -p "2. 后端服务地址（Docker 通常填 127.0.0.1；其他服务填实际监听地址）：" upstream_host
  upstream_host="${upstream_host#[}"
  upstream_host="${upstream_host%]}"
  if ! is_valid_upstream_host "$upstream_host"; then
    error "后端服务地址格式不正确。"
    return 1
  fi

  read -r -p "3. 后端服务端口（例如 8080）：" upstream_port
  if ! is_valid_port "$upstream_port"; then
    error "端口必须是 1-65535 之间的整数。"
    return 1
  fi

  read -r -p "4. 后端服务协议 [http/https，默认 http]：" upstream_scheme
  upstream_scheme="${upstream_scheme:-http}"
  if [[ "$upstream_scheme" != "http" && "$upstream_scheme" != "https" ]]; then
    error "后端服务协议只能是 http 或 https。"
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

  read -r -p "4. 后端服务协议 [http/https，默认 http]：" upstream_scheme
  upstream_scheme="${upstream_scheme:-http}"
  if [[ "$upstream_scheme" != "http" && "$upstream_scheme" != "https" ]]; then
    error "后端服务协议只能是 http 或 https。"
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

  printf '\n%s请选择后端服务类型%s\n' "$BOLD" "$RESET"
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

  printf '\n可修改的站点（域名 -> 当前后端服务）：\n'
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
    error "无法识别该站点的后端服务地址；仅支持本工具生成的 reverse_proxy http(s)://主机:端口 配置。"
    return 1
  }
  IFS=$'\t' read -r upstream_scheme upstream_host upstream_port <<< "$settings"

  printf '\n当前后端服务：%s://%s:%s\n' "$upstream_scheme" "$(format_upstream_host "$upstream_host")" "$upstream_port"
  read -r -p "1. 后端服务地址 [$upstream_host]：" updated_host
  updated_host="${updated_host:-$upstream_host}"
  updated_host="${updated_host#[}"
  updated_host="${updated_host%]}"
  if ! is_valid_upstream_host "$updated_host"; then
    error "后端服务地址格式不正确。"
    return 1
  fi

  read -r -p "2. 后端服务端口 [$upstream_port]：" updated_port
  updated_port="${updated_port:-$upstream_port}"
  if ! is_valid_port "$updated_port"; then
    error "端口必须是 1-65535 之间的整数。"
    return 1
  fi

  read -r -p "3. 后端服务协议 [http/https，当前 $upstream_scheme]：" updated_scheme
  updated_scheme="${updated_scheme:-$upstream_scheme}"
  if [[ "$updated_scheme" != "http" && "$updated_scheme" != "https" ]]; then
    error "后端服务协议只能是 http 或 https。"
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
    printf '\n已配置站点（域名 -> 后端服务）：\n'
    show_site_choices
    printf '\n提示：使用“修改现有反向代理”更新后端服务，使用“删除反向代理”移除站点。\n'
  else
    warn "暂未配置反向代理站点。"
  fi

  read -r -p "是否查看原始 Caddy 配置？[y/N]：" answer
  [[ "$answer" =~ ^[Yy]$ ]] && show_raw_config
}

is_local_upstream_host() {
  local host="$1"

  case "$host" in
    localhost|127.0.0.1|::1) return 0 ;;
  esac

  command -v ip >/dev/null 2>&1 || return 1
  ip -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$host"
}

local_tcp_listener_details() {
  local port="$1"

  if command -v ss >/dev/null 2>&1; then
    ss -ltnpH "sport = :$port" 2>/dev/null || true
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltnp 2>/dev/null | awk -v port=":$port" '$4 ~ (port "$")'
  fi
}

show_local_listener() {
  local port="$1"
  local listener

  printf '\n%s本机端口监听结果%s\n' "$BOLD" "$RESET"
  info "127.0.0.1 表示仅本机；* 或 0.0.0.0 表示所有 IPv4；具体 IP 表示仅该网卡。"
  if ! command -v ss >/dev/null 2>&1 && ! command -v netstat >/dev/null 2>&1; then
    warn "未找到 ss 或 netstat，无法查看本机监听状态。"
    return 0
  fi
  listener="$(local_tcp_listener_details "$port")"

  if [[ -n "$listener" ]]; then
    printf '%s\n' "$listener"
  else
    warn "未发现 TCP 端口 $port 处于监听状态。"
  fi
}

diagnose_upstream_target() {
  local label="$1"
  local upstream_scheme="$2"
  local upstream_host="$3"
  local upstream_port="$4"
  local listener

  printf '\n%s%s%s\n' "$BOLD" "$label" "$RESET"
  printf '后端服务地址：%s://%s:%s\n' \
    "$upstream_scheme" "$(format_upstream_host "$upstream_host")" "$upstream_port"
  if is_local_upstream_host "$upstream_host"; then
    show_local_listener "$upstream_port"
  else
    listener="$(local_tcp_listener_details "$upstream_port")"
    if [[ -n "$listener" ]]; then
      warn "$upstream_host 未出现在本机网卡地址中，可能是云服务器公网 IP 映射；已发现本机同端口监听。"
      printf '%s\n' "$listener"
    else
      info "$upstream_host 未出现在本机网卡地址中，可能是远程服务或云公网 IP 映射；将只检测连通性。"
    fi
  fi

  printf '\n%sHTTP/HTTPS 连通性%s\n' "$BOLD" "$RESET"
  test_upstream_connection "$upstream_host" "$upstream_port" "$upstream_scheme" || true
}

diagnose_configured_upstreams() {
  local site domain settings upstream_scheme upstream_host upstream_port

  if ! compgen -G "${SITES_DIR}/*.caddy" >/dev/null 2>&1; then
    warn "暂未配置反向代理站点。"
    return 0
  fi

  printf '\n正在自动检测全部已配置站点：\n'
  for site in "$SITES_DIR"/*.caddy; do
    domain="${site##*/}"
    domain="${domain%.caddy}"
    settings="$(read_proxy_settings "$site" || true)"
    if [[ -z "$settings" ]]; then
      warn "$domain 使用自定义 Caddy 配置，无法自动读取后端服务地址。"
      continue
    fi
    IFS=$'\t' read -r upstream_scheme upstream_host upstream_port <<< "$settings"
    diagnose_upstream_target "站点：$domain" "$upstream_scheme" "$upstream_host" "$upstream_port"
  done
}

diagnose_upstream() {
  local mode upstream_scheme upstream_host upstream_port

  printf '\n%s检测后端服务监听与连通性%s\n' "$BOLD" "$RESET"
  info "后端服务是 Caddy 转发请求的实际应用，例如 Kopia 的 127.0.0.1:41515。"
  printf '  1. 自动检测全部已配置的反向代理\n'
  printf '  2. 手动检测未配置的服务地址\n'
  printf '  0. 返回\n'
  read -r -p "请选择 [0-2]：" mode

  case "$mode" in
    1)
      diagnose_configured_upstreams
      return
      ;;
    2)
      read -r -p "后端服务地址（IP 或主机名）：" upstream_host
      upstream_host="${upstream_host#[}"
      upstream_host="${upstream_host%]}"
      if ! is_valid_upstream_host "$upstream_host"; then
        error "后端服务地址格式不正确。"
        return 1
      fi
      read -r -p "后端服务端口：" upstream_port
      if ! is_valid_port "$upstream_port"; then
        error "端口必须是 1-65535 之间的整数。"
        return 1
      fi
      read -r -p "后端服务协议 [http/https，默认 http]：" upstream_scheme
      upstream_scheme="${upstream_scheme:-http}"
      if [[ "$upstream_scheme" != "http" && "$upstream_scheme" != "https" ]]; then
        error "后端服务协议只能是 http 或 https。"
        return 1
      fi
      ;;
    0) return 0 ;;
    *) error "无效选项：$mode"; return 1 ;;
  esac

  diagnose_upstream_target "手动检测服务" "$upstream_scheme" "$upstream_host" "$upstream_port"
}

localize_ss_listener_header() {
  sed '1 {
    s/State/状态/
    s/Recv-Q/接收队列/
    s/Send-Q/发送队列/
    s/Local Address:Port/本地监听地址:端口/
    s/Peer Address:Port/远端限制/
    s/Process/进程/
  }'
}

localize_netstat_listener_header() {
  sed '1 {
    s/Active Internet connections (only servers)/TCP 监听端口（仅服务端）/
  }
  2 {
    s/Proto/协议/
    s/Recv-Q/接收队列/
    s/Send-Q/发送队列/
    s/Local Address/本地地址/
    s/Foreign Address/远端限制/
    s/State/状态/
    s/PID\/Program name/进程/
  }'
}

show_all_local_listeners() {
  printf '\n%s本机 TCP 服务监听地址%s\n' "$BOLD" "$RESET"
  info "127.0.0.1 表示仅本机；* 或 0.0.0.0 表示所有 IPv4；具体 IP 表示仅该网卡。"
  info "远端限制在 LISTEN 状态通常显示 0.0.0.0:* 或 [::]:*，表示可接受的连接范围，不是 Docker 容器地址。"
  info "docker-proxy 表示宿主机发布端口；容器内部监听位于独立网络空间，需在 Docker 映射详情中查看端口。"
  if command -v ss >/dev/null 2>&1; then
    ss -ltnp 2>/dev/null | localize_ss_listener_header
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltnp 2>/dev/null | localize_netstat_listener_header
  else
    warn "未找到 ss 或 netstat，无法查看本机监听状态。"
  fi
}

listener_pid_from_details() {
  sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | head -n 1
}

listener_process_from_details() {
  sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | head -n 1
}

is_valid_ipv4() {
  local address="$1" octet

  [[ "$address" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  IFS='.' read -r -a octet <<< "$address"
  (( ${#octet[@]} == 4 )) || return 1
  for address in "${octet[@]}"; do
    (( 10#$address <= 255 )) || return 1
  done
}

is_npm_container() {
  local image="${1,,}"
  local container_name="${2,,}"

  case "$image" in
    *nginx*proxy*manager*|jc21/*) return 0 ;;
  esac
  case "$container_name" in
    npm|npm-*|nginx-proxy-manager|nginx-proxy-manager-*) return 0 ;;
  esac
  return 1
}

find_npm_containers() {
  local container_id image container_name

  command -v docker >/dev/null 2>&1 || return 0
  docker info >/dev/null 2>&1 || return 0
  while IFS='|' read -r container_id image container_name; do
    is_npm_container "$image" "$container_name" || continue
    printf '%s\t%s\t%s\n' "$container_id" "$container_name" "$image"
  done < <(docker ps --format '{{.ID}}|{{.Image}}|{{.Names}}' 2>/dev/null)
}

docker_gateway_targets_for_container() {
  local container_reference="$1"
  local container_id container_name network gateway

  IFS='|' read -r container_id container_name < <(docker inspect --format '{{.Id}}|{{.Name}}' "$container_reference" 2>/dev/null)
  [[ -n "$container_id" && -n "$container_name" ]] || return 0
  container_name="${container_name#/}"
  while IFS='|' read -r network gateway; do
    is_valid_ipv4 "$gateway" || continue
    printf '%s\t%s\t%s\t%s\n' "$container_id" "$container_name" "$network" "$gateway"
  done < <(docker inspect --format '{{range $name, $network := .NetworkSettings.Networks}}{{$name}}|{{$network.Gateway}}{{println}}{{end}}' "$container_reference" 2>/dev/null)
}

show_running_docker_containers() {
  command -v docker >/dev/null 2>&1 || return 0
  docker info >/dev/null 2>&1 || return 0

  printf '\n运行中的 Docker 容器（短 ID | 名称 | 镜像）：\n'
  docker ps --format '{{.ID}} | {{.Names}} | {{.Image}}' 2>/dev/null
}

show_docker_container_internal_listeners() {
  local container_reference="$1"
  local container_name="$2"
  local exposed_ports

  printf '\n%sDocker 容器内部监听%s\n' "$BOLD" "$RESET"
  printf '容器：%s\n' "$container_name"
  printf '容器网络 IP（仅供诊断，NPM 共享网络优先使用服务名）：\n'
  docker inspect --format '{{range $name, $network := .NetworkSettings.Networks}}  {{$name}}: {{$network.IPAddress}}{{println}}{{end}}' "$container_reference" 2>/dev/null || true

  if docker exec "$container_reference" ss -ltnp >/dev/null 2>&1; then
    info "以下为容器网络空间中的实际 TCP 监听地址。"
    docker exec "$container_reference" ss -ltnp 2>/dev/null | localize_ss_listener_header
    return 0
  fi
  if docker exec "$container_reference" netstat -ltnp >/dev/null 2>&1; then
    info "以下为容器网络空间中的实际 TCP 监听地址。"
    docker exec "$container_reference" netstat -ltnp 2>/dev/null | localize_netstat_listener_header
    return 0
  fi

  warn "容器内未找到 ss 或 netstat，无法直接检测实际监听地址。"
  exposed_ports="$(docker inspect --format '{{range $port, $_ := .Config.ExposedPorts}}{{println $port}}{{end}}' "$container_reference" 2>/dev/null || true)"
  if [[ -n "$exposed_ports" ]]; then
    printf '镜像声明端口（不等同于实际监听）：\n%s\n' "$exposed_ports"
  else
    warn "镜像未声明 EXPOSE 端口，请根据应用启动参数或日志确认容器内部端口。"
  fi
}

show_all_docker_internal_listeners() {
  local container_id container_name count=0
  local network_ips listeners exposed_ports detection table

  command -v docker >/dev/null 2>&1 || {
    error "未检测到 Docker 命令。"
    return 1
  }
  docker info >/dev/null 2>&1 || {
    error "无法连接 Docker 服务。"
    return 1
  }
  printf '\n%s全部运行中 Docker 容器的内部监听%s\n' "$BOLD" "$RESET"
  table=$'容器名称\t网络 IP（仅诊断）\t内部 TCP 监听\t检测方式'
  while IFS='|' read -r container_id container_name; do
    [[ -n "$container_id" && -n "$container_name" ]] || continue
    ((count += 1))

    network_ips="$(docker inspect --format '{{range $name, $network := .NetworkSettings.Networks}}{{$name}}={{$network.IPAddress}}{{println}}{{end}}' "$container_id" 2>/dev/null | paste -sd ',' -)"
    [[ -n "$network_ips" ]] || network_ips="-"

    listeners=""
    detection=""
    if docker exec "$container_id" ss -ltnH >/dev/null 2>&1; then
      listeners="$(docker exec "$container_id" ss -ltnH 2>/dev/null | awk '{print $4}' | paste -sd ',' -)"
      detection="ss 实际检测"
    elif docker exec "$container_id" netstat -ltn >/dev/null 2>&1; then
      listeners="$(docker exec "$container_id" netstat -ltn 2>/dev/null | awk '$1 ~ /^tcp/ {print $4}' | paste -sd ',' -)"
      detection="netstat 实际检测"
    else
      exposed_ports="$(docker inspect --format '{{range $port, $_ := .Config.ExposedPorts}}{{println $port}}{{end}}' "$container_id" 2>/dev/null | paste -sd ',' -)"
      if [[ -n "$exposed_ports" ]]; then
        listeners="声明：${exposed_ports}"
        detection="无检测工具；仅镜像声明"
      else
        listeners="-"
        detection="无检测工具；未声明端口"
      fi
    fi
    [[ -n "$listeners" ]] || listeners="-"
    table+=$'\n'"${container_name}"$'\t'"${network_ips}"$'\t'"${listeners}"$'\t'"${detection}"
  done < <(docker ps --format '{{.ID}}|{{.Names}}' 2>/dev/null)
  if (( count == 0 )); then
    warn "未发现运行中的 Docker 容器。"
    return 0
  fi

  if command -v column >/dev/null 2>&1; then
    printf '%s\n' "$table" | column -t -s $'\t'
  else
    printf '%s\n' "$table"
  fi
  info "网络 IP 仅用于诊断；NPM 共享网络反代请填写 Docker Compose 服务名和容器内部端口。"
}

docker_network_mode_for_container() {
  docker inspect --format '{{.HostConfig.NetworkMode}}' "$1" 2>/dev/null || true
}

find_npm_gateway_targets() {
  local container_id image container_name

  command -v docker >/dev/null 2>&1 || return 0
  docker info >/dev/null 2>&1 || return 0

  while IFS='|' read -r container_id image container_name; do
    is_npm_container "$image" "$container_name" || continue
    docker_gateway_targets_for_container "$container_id"
  done < <(docker ps --format '{{.ID}}|{{.Image}}|{{.Names}}' 2>/dev/null)
}

verify_npm_gateway_connection() {
  local container_id="$1"
  local container_name="$2"
  local gateway="$3"
  local port="$4"
  local node_check

  node_check='const net = require("net");
const host = process.argv[1];
const port = Number(process.argv[2]);
const socket = net.createConnection({ host, port });
socket.setTimeout(5000);
socket.on("connect", () => { socket.end(); process.exit(0); });
socket.on("timeout", () => { socket.destroy(); process.exit(1); });
socket.on("error", () => process.exit(1));'

  printf '\n%sNPM 容器连通性验证%s\n' "$BOLD" "$RESET"
  if docker exec "$container_id" node -e "$node_check" "$gateway" "$port" >/dev/null 2>&1; then
    success "NPM 容器 ${container_name} 可连接 Kopia：${gateway}:${port}。"
    info "请在 Nginx Proxy Manager 中将“转发主机名/IP”设为 ${gateway}，端口设为 ${port}，协议使用 http。"
    return 0
  fi

  warn "NPM 容器 ${container_name} 无法连接 ${gateway}:${port}。请检查 Docker 网络、服务重启结果及主机防火墙。"
  return 1
}

systemd_unit_for_pid() {
  local pid="$1"

  [[ -r "/proc/$pid/cgroup" ]] || return 1
  awk -F/ '{for (i = NF; i > 0; i--) if ($i ~ /\.service$/) { print $i; exit }}' \
    "/proc/$pid/cgroup"
}

kopia_default_config_path_for_user() {
  local user="$1"
  local home_dir="$2"
  local xdg_config_home="$3"
  local config_root candidate

  if [[ -z "$home_dir" ]]; then
    home_dir="$(getent passwd "$user" 2>/dev/null | cut -d: -f6 || true)"
  fi
  [[ -n "$home_dir" ]] || return 0
  config_root="${xdg_config_home:-${home_dir}/.config}"
  candidate="${config_root}/kopia/repository.config"
  [[ -f "$candidate" ]] && printf '%s\n' "$candidate"
}

kopia_environment_exports() {
  local pid="$1"
  local environment_item name value
  local run_user home_dir="" xdg_config_home="" config_path=""
  local has_config_path="false"

  [[ -r "/proc/$pid/environ" ]] || return 0
  run_user="$(ps -o user= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
  while IFS= read -r -d '' environment_item; do
    name="${environment_item%%=*}"
    value="${environment_item#*=}"
    case "$name" in
      HOME) home_dir="$value" ;;
      XDG_CONFIG_HOME) xdg_config_home="$value" ;;
      KOPIA_CONFIG_PATH) has_config_path="true" ;;
    esac
    if [[ "$name" == "HOME" || "$name" == "XDG_CONFIG_HOME" || "$name" =~ ^KOPIA_[A-Za-z0-9_]+$ ]]; then
      printf 'export %s=%q\n' "$name" "$value"
    fi
  done < "/proc/$pid/environ"

  if [[ "$has_config_path" != "true" && -n "$run_user" ]]; then
    config_path="$(kopia_default_config_path_for_user "$run_user" "$home_dir" "$xdg_config_home")"
    [[ -n "$config_path" ]] && printf 'export KOPIA_CONFIG_PATH=%q\n' "$config_path"
  fi
}

apply_kopia_listener_address() {
  local pid="$1"
  local port="$2"
  local bind_host="$3"
  local unit wrapper_dir wrapper_path override_dir override_path
  local previous_wrapper="" previous_override="" had_wrapper="false" had_override="false"
  local temp_wrapper temp_override arg attempt listener_ready="false"
  local -a command filtered
  local i has_server="false" has_start="false"

  unit="$(systemd_unit_for_pid "$pid")"
  if [[ -z "$unit" || ! "$unit" =~ ^[A-Za-z0-9_.@-]+\.service$ ]]; then
    error "未找到 Kopia 对应的 systemd 服务，无法安全自动修改。"
    return 1
  fi
  case "$(systemctl show "$unit" --property=Type --value 2>/dev/null)" in
    simple|exec) ;;
    *)
      error "仅支持 Type=simple 或 Type=exec 的 systemd Kopia 服务，当前服务类型不支持自动修改。"
      return 1
      ;;
  esac
  if ! mapfile -d '' -t command < "/proc/$pid/cmdline" || [[ ${#command[@]} -eq 0 ]]; then
    error "无法读取当前 Kopia 启动命令。"
    return 1
  fi
  if [[ "$(basename "${command[0]}")" != "kopia" ]]; then
    error "当前进程不是直接由 kopia 命令启动，无法安全自动修改。"
    return 1
  fi
  for arg in "${command[@]}"; do
    [[ "$arg" == "server" ]] && has_server="true"
    [[ "$arg" == "start" ]] && has_start="true"
  done
  if [[ "$has_server" != "true" || "$has_start" != "true" ]]; then
    error "当前 Kopia 命令不是 server start 模式，无法安全自动修改。"
    return 1
  fi

  for ((i = 0; i < ${#command[@]}; i++)); do
    arg="${command[$i]}"
    if [[ "$arg" == "--address" ]]; then
      ((i++))
      continue
    fi
    [[ "$arg" == --address=* ]] && continue
    filtered+=("$arg")
  done
  filtered+=("--address=${bind_host}:${port}")

  wrapper_dir="${MANAGER_DIR}/service-wrappers"
  wrapper_path="${wrapper_dir}/${unit}.sh"
  override_dir="/etc/systemd/system/${unit}.d"
  override_path="${override_dir}/caddyctl-listener.conf"
  temp_wrapper="$(mktemp)" || return 1
  temp_override="$(mktemp)" || { rm -f -- "$temp_wrapper"; return 1; }
  {
    printf '#!/usr/bin/env bash\nset -euo pipefail\n'
    kopia_environment_exports "$pid"
    printf 'exec'
    for arg in "${filtered[@]}"; do
      printf ' %q' "$arg"
    done
    printf '\n'
  } >"$temp_wrapper"
  printf '[Service]\nExecStart=\nExecStart=%s\n' "$wrapper_path" >"$temp_override"

  if [[ -f "$wrapper_path" ]]; then
    had_wrapper="true"
    previous_wrapper="$(mktemp)"
    cp -a -- "$wrapper_path" "$previous_wrapper"
    backup_file "$wrapper_path" "${unit}-listener-wrapper"
  fi
  if [[ -f "$override_path" ]]; then
    had_override="true"
    previous_override="$(mktemp)"
    cp -a -- "$override_path" "$previous_override"
    backup_file "$override_path" "${unit}-listener-override"
  fi

  install -d -m 0700 "$wrapper_dir" "$override_dir"
  install -m 0700 "$temp_wrapper" "$wrapper_path"
  install -m 0600 "$temp_override" "$override_path"
  rm -f -- "$temp_wrapper" "$temp_override"
  systemctl daemon-reload
  if systemctl restart "$unit" && systemctl is-active --quiet "$unit"; then
    for ((attempt = 1; attempt <= 10; attempt++)); do
      if generic_listener_is_listening_on "$port" "$bind_host"; then
        listener_ready="true"
        break
      fi
      sleep 1
    done
  fi
  if [[ "$listener_ready" == "true" ]]; then
    rm -f -- "$previous_wrapper" "$previous_override"
    success "Kopia 监听地址已更新为 ${bind_host}:${port}。"
    if [[ "$bind_host" == "127.0.0.1" ]]; then
      info "请使用第 6 项检查对应站点，将后端服务地址同步改为 127.0.0.1。"
    fi
    show_local_listener "$port"
    return 0
  fi

  error "Kopia 重启或监听验证失败，正在恢复原有启动配置。"
  if [[ "$had_wrapper" == "true" ]]; then
    install -m 0700 "$previous_wrapper" "$wrapper_path"
  else
    rm -f -- "$wrapper_path"
  fi
  if [[ "$had_override" == "true" ]]; then
    install -m 0600 "$previous_override" "$override_path"
  else
    rm -f -- "$override_path"
  fi
  rm -f -- "$previous_wrapper" "$previous_override"
  systemctl daemon-reload
  systemctl restart "$unit" >/dev/null 2>&1 || true
  return 1
}

adopt_manual_kopia_service() {
  local pid="$1"
  local port="$2"
  local unit="caddyctl-kopia-${port}.service"
  local unit_path="/etc/systemd/system/${unit}"
  local wrapper_dir="${MANAGER_DIR}/service-wrappers"
  local wrapper_path="${wrapper_dir}/${unit}.sh"
  local run_user parent_pid
  local temp_wrapper temp_unit argument
  local -a command
  local i has_server="false" has_start="false"

  if [[ -e "$unit_path" ]] || systemctl cat "$unit" >/dev/null 2>&1; then
    error "systemd 服务 ${unit} 已存在，CaddyCtl 不会覆盖它。请先检查或删除该服务后重试。"
    return 1
  fi
  if ! mapfile -d '' -t command < "/proc/$pid/cmdline" || [[ ${#command[@]} -eq 0 ]]; then
    error "无法读取当前 Kopia 启动命令。"
    return 1
  fi
  if [[ "$(basename "${command[0]}")" != "kopia" ]]; then
    error "当前进程不是直接由 kopia 命令启动，无法安全接管。"
    return 1
  fi
  for argument in "${command[@]}"; do
    [[ "$argument" == "server" ]] && has_server="true"
    [[ "$argument" == "start" ]] && has_start="true"
  done
  if [[ "$has_server" != "true" || "$has_start" != "true" ]]; then
    error "当前 Kopia 命令不是 server start 模式，无法安全接管。"
    return 1
  fi
  run_user="$(ps -o user= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
  if [[ -z "$run_user" ]] || ! id "$run_user" >/dev/null 2>&1; then
    error "无法识别 Kopia 进程的运行用户，无法安全接管。"
    return 1
  fi
  parent_pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
  if [[ "$parent_pid" != "1" ]]; then
    error "Kopia 的父进程为 PID ${parent_pid:-未知}，可能仍受脚本或面板管理；请先在原管理器中停止它，再改用 systemd。"
    return 1
  fi
  temp_wrapper="$(mktemp)" || return 1
  temp_unit="$(mktemp)" || { rm -f -- "$temp_wrapper"; return 1; }
  {
    printf '#!/usr/bin/env bash\nset -euo pipefail\n'
    kopia_environment_exports "$pid"
    printf 'exec'
    for argument in "${command[@]}"; do
      printf ' %q' "$argument"
    done
    printf '\n'
  } >"$temp_wrapper"
  {
    printf '[Unit]\nDescription=CaddyCtl managed Kopia server on TCP %s\n' "$port"
    printf 'Wants=network-online.target\nAfter=network-online.target\n\n'
    printf '[Service]\nType=simple\n'
    [[ "$run_user" != "root" ]] && printf 'User=%s\n' "$run_user"
    printf 'ExecStart=%s\nRestart=on-failure\nRestartSec=5\n\n' "$wrapper_path"
    printf '[Install]\nWantedBy=multi-user.target\n'
  } >"$temp_unit"

  warn "将接管 PID ${pid} 的手工 Kopia 进程，保留当前启动参数并创建 ${unit}。"
  info "将保留 HOME、XDG_CONFIG_HOME 以及 KOPIA_* 环境变量，并优先沿用原存储库配置。"
  confirm_action "确认停止当前手工进程并启用 ${unit}？" || {
    rm -f -- "$temp_wrapper" "$temp_unit"
    info "已取消。"
    return 0
  }

  install -d -m 0700 "$wrapper_dir"
  install -m 0700 "$temp_wrapper" "$wrapper_path"
  install -m 0644 "$temp_unit" "$unit_path"
  rm -f -- "$temp_wrapper" "$temp_unit"
  systemctl daemon-reload
  if ! kill -TERM "$pid" 2>/dev/null; then
    error "无法停止当前手工 Kopia 进程，未启动新的 systemd 服务。"
    rm -f -- "$wrapper_path" "$unit_path"
    systemctl daemon-reload
    return 1
  fi
  for ((i = 0; i < 25; i++)); do
    [[ -d "/proc/$pid" ]] || break
    sleep 0.2
  done
  if [[ -d "/proc/$pid" ]]; then
    error "当前手工 Kopia 进程未在 5 秒内退出，未启动新的 systemd 服务。"
    rm -f -- "$wrapper_path" "$unit_path"
    systemctl daemon-reload
    return 1
  fi
  if systemctl start "$unit"; then
    systemctl enable "$unit" >/dev/null 2>&1 || warn "服务已启动，但未能设置开机自启：$unit"
    success "已接管为 systemd 服务：${unit}。"
    return 0
  fi

  error "systemd 服务启动失败，正在尝试恢复原手工启动方式。"
  systemctl stop "$unit" >/dev/null 2>&1 || true
  "$wrapper_path" >/dev/null 2>&1 &
  rm -f -- "$wrapper_path" "$unit_path"
  systemctl daemon-reload
  warn "已尝试按原命令恢复 Kopia。请使用 ss 或 caddyctl 菜单确认端口监听状态。"
  return 1
}

manage_kopia_listener() {
  local port="$1"
  local listener="$2"
  local pid unit mode bind_host process_info parent_pid
  local -a npm_targets
  local npm_target npm_container_id npm_container_name npm_network npm_gateway
  local manual_container npm_network_mode

  pid="$(printf '%s\n' "$listener" | listener_pid_from_details)"
  [[ "$pid" =~ ^[0-9]+$ ]] || { error "无法识别 Kopia 进程 PID。"; return 1; }
  unit="$(systemd_unit_for_pid "$pid")"
  printf '\n%sKopia 监听地址修改%s\n' "$BOLD" "$RESET"
  printf '当前监听：\n%s\n' "$listener"
  printf '关联 systemd 服务：%s\n' "${unit:-未识别}"
  if [[ -z "$unit" ]]; then
    process_info="$(ps -o pid=,ppid=,user=,comm= -p "$pid" 2>/dev/null || true)"
    parent_pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
    [[ -n "$process_info" ]] && info "进程信息（PID/父进程/用户/命令）：$process_info"
    if [[ "$parent_pid" != "1" ]]; then
      warn "Kopia 当前可能仍由脚本或面板管理，菜单不会直接接管以避免原管理器重新拉起进程。"
      info "请先在原脚本或面板中停止并禁用 Kopia，再以 systemd 方式启动。"
      return 1
    fi
    warn "Kopia 当前是已脱离终端的手工命令（由 PID 1 收养），不是 systemd 服务。"
    printf '  1. 接管为 CaddyCtl 管理的 systemd 服务（保留当前启动参数）\n'
    printf '  0. 返回\n'
    read -r -p "请选择 [0-1]：" mode
    case "$mode" in
      1)
        if adopt_manual_kopia_service "$pid" "$port"; then
          listener="$(local_tcp_listener_details "$port")"
          if [[ -n "$listener" ]] && [[ "$(printf '%s\n' "$listener" | listener_process_from_details)" == "kopia" ]]; then
            manage_kopia_listener "$port" "$listener"
          else
            warn "接管后的 Kopia 监听状态尚未识别，请稍后重新打开端口助手检查。"
          fi
        fi
        return
        ;;
      0) return 0 ;;
      *) error "无效选项：$mode"; return 1 ;;
    esac
  fi
  printf '  1. 仅服务器本机：127.0.0.1:%s（供宿主机上的 Caddy、Nginx 等反代访问）\n' "$port"
  printf '  2. Docker NPM 访问宿主机服务（网关模式，自动识别并验证）\n'
  printf '  3. 允许服务器公网 IP 访问：0.0.0.0:%s（需配合防火墙）\n' "$port"
  printf '  0. 返回\n'
  read -r -p "请选择 [0-3]：" mode

  case "$mode" in
    1) bind_host="127.0.0.1" ;;
    2)
      mapfile -t npm_targets < <(find_npm_gateway_targets)
      if (( ${#npm_targets[@]} == 0 )); then
        warn "未自动识别到带 IPv4 Docker 网络网关的 Nginx Proxy Manager 容器。"
        show_running_docker_containers
        read -r -p "输入 NPM 容器名称或 ID（直接回车返回）:" manual_container
        [[ -n "$manual_container" ]] || return 0
        mapfile -t npm_targets < <(docker_gateway_targets_for_container "$manual_container")
        if (( ${#npm_targets[@]} == 0 )); then
          npm_network_mode="$(docker_network_mode_for_container "$manual_container")"
          if [[ "$npm_network_mode" == "host" ]]; then
            warn "该容器使用 host 网络，NPM 可直接访问宿主机 127.0.0.1。请返回并选择“仅服务器本机”模式。"
          else
            error "容器 ${manual_container} 未找到 IPv4 Docker 网络网关。请确认名称正确且容器正在使用 bridge 网络。"
          fi
          return 1
        fi
      fi
      if (( ${#npm_targets[@]} == 1 )); then
        npm_target="${npm_targets[0]}"
      else
        printf '\n检测到多个 NPM Docker 网络：\n'
        local i selection
        for ((i = 0; i < ${#npm_targets[@]}; i++)); do
          IFS=$'\t' read -r npm_container_id npm_container_name npm_network npm_gateway <<< "${npm_targets[$i]}"
          printf '  %d. 容器 %s，网络 %s，网关 %s\n' "$((i + 1))" "$npm_container_name" "$npm_network" "$npm_gateway"
        done
        read -r -p "请选择 [1-${#npm_targets[@]}]：" selection
        if [[ ! "$selection" =~ ^[0-9]+$ ]] || (( selection < 1 || selection > ${#npm_targets[@]} )); then
          error "无效选项：$selection"
          return 1
        fi
        npm_target="${npm_targets[$((selection - 1))]}"
      fi
      IFS=$'\t' read -r npm_container_id npm_container_name npm_network npm_gateway <<< "$npm_target"
      if ! is_local_upstream_host "$npm_gateway"; then
        error "Docker 网关 ${npm_gateway} 未出现在本机网卡地址中，无法安全作为 Kopia 监听地址。"
        return 1
      fi
      bind_host="$npm_gateway"
      info "检测到 NPM 容器 ${npm_container_name}，网络 ${npm_network}，网关 ${npm_gateway}。"
      info "Kopia 将仅监听 Docker 网络网关；该模式不直接开放公网端口。"
      warn "同一 Docker 网络中的其他容器也可访问 ${npm_gateway}:${port}。"
      ;;
    3)
      bind_host="0.0.0.0"
      warn "此端口将接受所有 IPv4 网络接口的连接，请仅在防火墙允许可信来源。"
      ;;
    0) return 0 ;;
    *) error "无效选项：$mode"; return 1 ;;
  esac

  warn "将为 $unit 创建 CaddyCtl 管理的启动覆盖文件，并重启 Kopia 服务。"
  confirm_action "确认修改 Kopia 监听地址为 ${bind_host}:${port}？" || { info "已取消。"; return 0; }
  if apply_kopia_listener_address "$pid" "$port" "$bind_host"; then
    if [[ "$mode" == "2" ]]; then
      verify_npm_gateway_connection "$npm_container_id" "$npm_container_name" "$npm_gateway" "$port" || true
    fi
  fi
}

generic_systemd_rollback_paths() {
  local unit="$1"
  local port="$2"
  local rollback_dir="${MANAGER_DIR}/listener-rollbacks"

  printf '%s\t%s\n' \
    "${rollback_dir}/${unit}-${port}.rollback" \
    "${rollback_dir}/${unit}-${port}.before-change.bak"
}

generic_listener_is_listening_on() {
  local port="$1"
  local bind_host="$2"
  local listener

  listener="$(local_tcp_listener_details "$port")"
  [[ -n "$listener" ]] || return 1
  if [[ "$bind_host" == "0.0.0.0" ]]; then
    grep -Eq "(0\\.0\\.0\\.0|\\*):${port}([^0-9]|$)" <<< "$listener"
  else
    grep -Fq -- "${bind_host}:${port}" <<< "$listener"
  fi
}

show_generic_systemd_service_details() {
  local unit="$1"

  printf '\n%s%s 服务详情%s\n' "$BOLD" "$unit" "$RESET"
  systemctl show "$unit" \
    --property=Id,Description,ActiveState,SubState,Type,ExecStart,Environment,FragmentPath \
    --no-pager 2>/dev/null || true
  printf '\n%s服务定义与覆盖文件%s\n' "$BOLD" "$RESET"
  systemctl cat "$unit" --no-pager 2>/dev/null || true
}

prompt_generic_systemd_bind_host() {
  local port="$1"
  local mode manual_host manual_container npm_network_mode selection i
  local npm_target npm_container_id npm_container_name npm_network npm_gateway
  local -a npm_targets

  GENERIC_BIND_HOST=""
  GENERIC_NPM_CONTAINER_ID=""
  GENERIC_NPM_CONTAINER_NAME=""
  GENERIC_NPM_GATEWAY=""
  printf '  1. 仅服务器本机：127.0.0.1:%s\n' "$port"
  printf '  2. Docker NPM 访问宿主机服务（网关模式，自动识别并验证）\n'
  printf '  3. 允许服务器公网 IP 访问：0.0.0.0:%s\n' "$port"
  printf '  4. 指定服务器本机 IPv4 地址\n'
  printf '  0. 返回\n'
  read -r -p "请选择 [0-4]：" mode

  case "$mode" in
    1) GENERIC_BIND_HOST="127.0.0.1" ;;
    2)
      mapfile -t npm_targets < <(find_npm_gateway_targets)
      if (( ${#npm_targets[@]} == 0 )); then
        warn "未自动识别到带 IPv4 Docker 网络网关的 Nginx Proxy Manager 容器。"
        show_running_docker_containers
        read -r -p "输入 NPM 容器名称或 ID（直接回车返回）:" manual_container
        [[ -n "$manual_container" ]] || return 1
        mapfile -t npm_targets < <(docker_gateway_targets_for_container "$manual_container")
        if (( ${#npm_targets[@]} == 0 )); then
          npm_network_mode="$(docker_network_mode_for_container "$manual_container")"
          if [[ "$npm_network_mode" == "host" ]]; then
            warn "该容器使用 host 网络，请返回并选择“仅服务器本机”模式。"
          else
            error "容器 ${manual_container} 未找到 IPv4 Docker 网络网关。"
          fi
          return 1
        fi
      fi
      if (( ${#npm_targets[@]} == 1 )); then
        npm_target="${npm_targets[0]}"
      else
        printf '\n检测到多个 NPM Docker 网络：\n'
        for ((i = 0; i < ${#npm_targets[@]}; i++)); do
          IFS=$'\t' read -r npm_container_id npm_container_name npm_network npm_gateway <<< "${npm_targets[$i]}"
          printf '  %d. 容器 %s，网络 %s，网关 %s\n' "$((i + 1))" "$npm_container_name" "$npm_network" "$npm_gateway"
        done
        read -r -p "请选择 [1-${#npm_targets[@]}]：" selection
        if [[ ! "$selection" =~ ^[0-9]+$ ]] || (( selection < 1 || selection > ${#npm_targets[@]} )); then
          error "无效选项：$selection"
          return 1
        fi
        npm_target="${npm_targets[$((selection - 1))]}"
      fi
      IFS=$'\t' read -r npm_container_id npm_container_name npm_network npm_gateway <<< "$npm_target"
      if ! is_local_upstream_host "$npm_gateway"; then
        error "Docker 网关 ${npm_gateway} 未出现在本机网卡地址中，无法安全作为监听地址。"
        return 1
      fi
      GENERIC_BIND_HOST="$npm_gateway"
      GENERIC_NPM_CONTAINER_ID="$npm_container_id"
      GENERIC_NPM_CONTAINER_NAME="$npm_container_name"
      GENERIC_NPM_GATEWAY="$npm_gateway"
      info "检测到 NPM 容器 ${npm_container_name}，网络 ${npm_network}，网关 ${npm_gateway}。"
      ;;
    3)
      GENERIC_BIND_HOST="0.0.0.0"
      warn "此端口将接受所有 IPv4 网络接口的连接，请仅在防火墙允许可信来源。"
      ;;
    4)
      read -r -p "服务器本机 IPv4 地址：" manual_host
      if ! is_valid_ipv4 "$manual_host" || ! is_local_upstream_host "$manual_host"; then
        error "该地址不是服务器当前网卡上的 IPv4 地址。"
        return 1
      fi
      GENERIC_BIND_HOST="$manual_host"
      ;;
    0) return 1 ;;
    *) error "无效选项：$mode"; return 1 ;;
  esac
}

apply_generic_systemd_listener_address() {
  local unit="$1"
  local port="$2"
  local config_path="$3"
  local old_address="$4"
  local bind_host="$5"
  local new_address="${bind_host}:${port}"
  local rollback_manifest rollback_backup rollback_dir temp_file previous_file match_lines

  [[ "$unit" =~ ^[A-Za-z0-9_.@-]+\.service$ ]] || {
    error "systemd 服务名称不安全，已取消。"
    return 1
  }
  config_path="$(readlink -f -- "$config_path" 2>/dev/null || true)"
  if [[ -z "$config_path" || ! -f "$config_path" || ! -r "$config_path" || ! -w "$config_path" ]]; then
    error "配置文件必须是当前可读写的普通文件。"
    return 1
  fi
  if [[ -z "$old_address" || ! "$old_address" == *:* ]]; then
    error "旧监听地址必须包含地址和端口，例如 0.0.0.0:${port}。"
    return 1
  fi
  if ! grep -Fq -- "$old_address" "$config_path"; then
    error "配置文件中未找到精确的旧监听地址：${old_address}"
    return 1
  fi
  match_lines="$(grep -Foc -- "$old_address" "$config_path" || true)"
  if [[ "$match_lines" != "1" ]]; then
    error "旧监听地址出现在 ${match_lines} 行。请缩小为仅包含该服务监听地址的配置文件后重试。"
    return 1
  fi
  if [[ "$old_address" == "$new_address" ]]; then
    info "监听地址已是 ${new_address}，无需修改。"
    return 0
  fi

  IFS=$'\t' read -r rollback_manifest rollback_backup < <(generic_systemd_rollback_paths "$unit" "$port")
  rollback_dir="$(dirname "$rollback_manifest")"
  install -d -m 0700 "$rollback_dir"
  previous_file="$(mktemp "${rollback_dir}/.${unit}-${port}.previous.XXXXXX")" || return 1
  temp_file="$(mktemp "$(dirname "$config_path")/.caddyctl-listener.XXXXXX")" || {
    rm -f -- "$previous_file"
    return 1
  }
  cp -a -- "$config_path" "$previous_file"
  cp -a -- "$config_path" "$rollback_backup"
  chown --reference="$config_path" "$temp_file"
  chmod --reference="$config_path" "$temp_file"
  awk -v old="$old_address" -v new="$new_address" '
    {
      while ((position = index($0, old)) > 0) {
        $0 = substr($0, 1, position - 1) new substr($0, position + length(old))
      }
      print
    }
  ' "$config_path" >"$temp_file"
  mv -f -- "$temp_file" "$config_path"
  printf '%s\t%s\t%s\t%s\n' "$config_path" "$rollback_backup" "$unit" "$port" >"$rollback_manifest"
  backup_file "$previous_file" "${unit}-${port}-before-listener-change"

  if systemctl restart "$unit" && systemctl is-active --quiet "$unit" \
      && generic_listener_is_listening_on "$port" "$bind_host"; then
    rm -f -- "$previous_file"
    success "${unit} 监听地址已更新为 ${new_address}。"
    show_local_listener "$port"
    return 0
  fi

  error "服务重启或监听验证失败，正在自动恢复原配置。"
  cp -a -- "$previous_file" "$config_path"
  rm -f -- "$previous_file" "$rollback_manifest" "$rollback_backup"
  systemctl restart "$unit" >/dev/null 2>&1 || true
  return 1
}

rollback_generic_systemd_listener_address() {
  local unit="$1"
  local port="$2"
  local rollback_manifest rollback_backup config_path saved_unit saved_port current_copy

  IFS=$'\t' read -r rollback_manifest rollback_backup < <(generic_systemd_rollback_paths "$unit" "$port")
  if [[ ! -f "$rollback_manifest" ]]; then
    warn "未找到 ${unit} 端口 ${port} 的 CaddyCtl 手动回滚点。"
    return 0
  fi
  IFS=$'\t' read -r config_path rollback_backup saved_unit saved_port <"$rollback_manifest"
  if [[ "$saved_unit" != "$unit" || "$saved_port" != "$port" || ! -f "$rollback_backup" || ! -f "$config_path" ]]; then
    error "回滚记录不完整或已被手工修改，已取消。"
    return 1
  fi
  confirm_action "确认恢复 ${unit} 在修改前的监听配置？" || { info "已取消。"; return 0; }
  current_copy="$(mktemp "$(dirname "$rollback_manifest")/.${unit}-${port}.current.XXXXXX")" || return 1
  cp -a -- "$config_path" "$current_copy"
  cp -a -- "$rollback_backup" "$config_path"
  if systemctl restart "$unit" && systemctl is-active --quiet "$unit" \
      && [[ -n "$(local_tcp_listener_details "$port")" ]]; then
    rm -f -- "$current_copy" "$rollback_manifest" "$rollback_backup"
    success "已恢复 ${unit} 修改前的监听配置。"
    show_local_listener "$port"
    return 0
  fi

  error "手动回滚后服务未正常启动，正在恢复回滚前配置。"
  cp -a -- "$current_copy" "$config_path"
  rm -f -- "$current_copy"
  systemctl restart "$unit" >/dev/null 2>&1 || true
  return 1
}

manage_generic_systemd_listener() {
  local port="$1"
  local listener="$2"
  local unit="$3"
  local mode config_path old_address

  while true; do
    printf '\n%s通用 systemd 监听地址管理%s\n' "$BOLD" "$RESET"
    printf '服务：%s\n当前监听：\n%s\n' "$unit" "$listener"
    printf '此功能仅替换你明确指定的应用配置文件中的精确地址，不修改 systemd ExecStart。\n'
    printf '  1. 查看服务详情与 systemd 定义\n'
    printf '  2. 修改应用配置中的监听地址（自动回滚）\n'
    printf '  3. 恢复上一次由 CaddyCtl 修改的监听配置\n'
    printf '  0. 返回\n'
    read -r -p "请选择 [0-3]：" mode

    case "$mode" in
    1)
      show_generic_systemd_service_details "$unit"
      read -r -p "按 Enter 键返回通用 systemd 监听地址管理菜单..." _ || true
      ;;
    2)
      prompt_generic_systemd_bind_host "$port" || continue
      printf '\n请填写应用自身的配置文件和当前监听地址。\n'
      printf '旧地址必须与文件内容完全一致，例如 0.0.0.0:%s 或 127.0.0.1:%s。\n' "$port" "$port"
      read -r -p "应用配置文件绝对路径：" config_path
      read -r -p "配置中的旧监听地址：" old_address
      warn "将把 ${config_path} 中唯一的 ${old_address} 替换为 ${GENERIC_BIND_HOST}:${port}，并重启 ${unit}。"
      confirm_action "确认继续？" || { info "已取消。"; continue; }
      if apply_generic_systemd_listener_address "$unit" "$port" "$config_path" "$old_address" "$GENERIC_BIND_HOST"; then
        if [[ -n "$GENERIC_NPM_CONTAINER_ID" ]]; then
          verify_npm_gateway_connection "$GENERIC_NPM_CONTAINER_ID" "$GENERIC_NPM_CONTAINER_NAME" "$GENERIC_NPM_GATEWAY" "$port" || true
        fi
      fi
      ;;
    3) rollback_generic_systemd_listener_address "$unit" "$port" ;;
    0) return 0 ;;
    *) error "无效选项：$mode" ;;
    esac
  done
}

docker_mapping_for_host_port() {
  local host_port="$1"
  local container_id container_name mappings container_port host_ip mapped_port

  command -v docker >/dev/null 2>&1 || return 0
  docker info >/dev/null 2>&1 || return 0
  while IFS='|' read -r container_id container_name; do
    mappings="$(docker inspect --format '{{range $port, $bindings := .NetworkSettings.Ports}}{{range $bindings}}{{$port}}|{{.HostIp}}|{{.HostPort}}{{println}}{{end}}{{end}}' "$container_id" 2>/dev/null || true)"
    while IFS='|' read -r container_port host_ip mapped_port; do
      [[ "$mapped_port" == "$host_port" ]] || continue
      printf '%s\t%s\t%s\t%s\n' "$container_id" "$container_name" "$container_port" "$host_ip"
      return 0
    done <<< "$mappings"
  done < <(docker ps --format '{{.ID}}|{{.Names}}' 2>/dev/null)
}

docker_container_network_names() {
  docker inspect --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' "$1" 2>/dev/null
}

docker_container_has_network() {
  local container_reference="$1"
  local network_name="$2"
  local attached_network

  while IFS= read -r attached_network; do
    [[ "$attached_network" == "$network_name" ]] && return 0
  done < <(docker_container_network_names "$container_reference")
  return 1
}

connect_container_to_network() {
  local container_reference="$1"
  local container_name="$2"
  local network_name="$3"
  local network_alias="${4:-}"

  if docker_container_has_network "$container_reference" "$network_name"; then
    info "容器 ${container_name} 已加入网络 ${network_name}。"
    return 0
  fi

  if [[ -n "$network_alias" ]]; then
    if ! docker network connect --alias "$network_alias" "$network_name" "$container_reference"; then
      error "无法将容器 ${container_name} 加入网络 ${network_name}。"
      return 1
    fi
  elif ! docker network connect "$network_name" "$container_reference"; then
    error "无法将容器 ${container_name} 加入网络 ${network_name}。"
    return 1
  fi

  if ! docker_container_has_network "$container_reference" "$network_name"; then
    error "容器 ${container_name} 未出现在网络 ${network_name} 中。"
    return 1
  fi
  success "已将容器 ${container_name} 加入网络 ${network_name}。"
}

replace_compose_port_mapping() {
  local config_path="$1"
  local current_host_ip="$2"
  local host_port="$3"
  local internal_port="$4"
  local bind_host="$5"
  local temp_file line mapping_regex port_suffix line_suffix match_count=0

  [[ -r "$config_path" && -w "$config_path" ]] || {
    error "Compose 配置文件不可读或不可写：${config_path}"
    return 1
  }
  temp_file="$(mktemp "${config_path}.caddyctl.XXXXXX")" || return 1
  if [[ "$current_host_ip" == "0.0.0.0" ]]; then
    mapping_regex="^([[:space:]]*-[[:space:]]*[\"']?)(0\\.0\\.0\\.0:)?${host_port}:${internal_port}(/tcp)?([\"']?[[:space:]]*(#.*)?)$"
  else
    mapping_regex="^([[:space:]]*-[[:space:]]*[\"']?)${current_host_ip}:${host_port}:${internal_port}(/tcp)?([\"']?[[:space:]]*(#.*)?)$"
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ $mapping_regex ]]; then
      ((match_count += 1))
      if [[ "$current_host_ip" == "0.0.0.0" ]]; then
        port_suffix="${BASH_REMATCH[3]:-}"
        line_suffix="${BASH_REMATCH[4]:-}"
      else
        port_suffix="${BASH_REMATCH[2]:-}"
        line_suffix="${BASH_REMATCH[3]:-}"
      fi
      printf '%s%s:%s:%s%s%s\n' "${BASH_REMATCH[1]}" "$bind_host" "$host_port" "$internal_port" "$port_suffix" "$line_suffix" >>"$temp_file"
    else
      printf '%s\n' "$line" >>"$temp_file"
    fi
  done <"$config_path"

  if (( match_count != 1 )); then
    rm -f -- "$temp_file"
    warn "未能在 Compose 文件中唯一识别当前端口映射，未自动修改。"
    return 1
  fi
  chmod --reference="$config_path" "$temp_file" || {
    rm -f -- "$temp_file"
    return 1
  }
  mv -- "$temp_file" "$config_path"
}

wait_for_docker_port_mapping() {
  local host_port="$1"
  local expected_host="$2"
  local expected_container_port="$3"
  local mapping container_id container_name container_port mapped_host attempt

  for ((attempt = 1; attempt <= 10; attempt++)); do
    mapping="$(docker_mapping_for_host_port "$host_port" || true)"
    if [[ -n "$mapping" ]]; then
      IFS=$'\t' read -r container_id container_name container_port mapped_host <<< "$mapping"
      if [[ "$mapped_host" == "$expected_host" && "$container_port" == "$expected_container_port" ]]; then
        return 0
      fi
    fi
    sleep 1
  done
  return 1
}

apply_compose_port_mapping() {
  local config_path="$1"
  local workdir="$2"
  local service="$3"
  local current_host_ip="$4"
  local host_port="$5"
  local internal_port="$6"
  local bind_host="$7"
  local rollback_file

  rollback_file="$(mktemp "$(dirname "$config_path")/.caddyctl-port-rollback.XXXXXX")" || return 1
  cp -a -- "$config_path" "$rollback_file" || {
    rm -f -- "$rollback_file"
    return 1
  }
  backup_file "$config_path" "docker-${service}-port-mapping-before-change"

  if ! replace_compose_port_mapping "$config_path" "$current_host_ip" "$host_port" "$internal_port" "$bind_host"; then
    rm -f -- "$rollback_file"
    return 1
  fi
  if ! (cd "$workdir" && docker compose -f "$config_path" config -q); then
    error "Compose 配置校验失败，正在恢复原配置。"
    cp -a -- "$rollback_file" "$config_path"
    rm -f -- "$rollback_file"
    return 1
  fi
  if ! (cd "$workdir" && docker compose -f "$config_path" up -d "$service"); then
    error "重建 Docker 服务失败，正在恢复原配置和服务。"
    cp -a -- "$rollback_file" "$config_path"
    (cd "$workdir" && docker compose -f "$config_path" up -d "$service") || true
    rm -f -- "$rollback_file"
    return 1
  fi
  if ! wait_for_docker_port_mapping "$host_port" "$bind_host" "${internal_port}/tcp"; then
    error "未检测到目标端口映射，正在恢复原配置和服务。"
    cp -a -- "$rollback_file" "$config_path"
    (cd "$workdir" && docker compose -f "$config_path" up -d "$service") || true
    rm -f -- "$rollback_file"
    return 1
  fi

  rm -f -- "$rollback_file"
  success "已修改 Compose 端口映射并重建服务：${bind_host}:${host_port}:${internal_port}。"
}

docker_compose_service_or_name() {
  local container_reference="$1"
  local service container_name

  service="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "$container_reference" 2>/dev/null || true)"
  if [[ -n "$service" && "$service" != "<no value>" ]]; then
    printf '%s\n' "$service"
    return 0
  fi
  container_name="$(docker inspect --format '{{.Name}}' "$container_reference" 2>/dev/null || true)"
  printf '%s\n' "${container_name#/}"
}

show_npm_shared_network_guide() {
  local app_container_id="$1"
  local app_container_name="$2"
  local container_port="$3"
  local npm_target npm_container_id npm_container_name npm_image manual_container selection
  local app_network npm_network shared_network="" internal_port app_service npm_service upstream_name default_network create_network_answer connect_network_answer
  local -a npm_containers app_networks npm_networks

  printf '\n%sDocker 后端 + NPM 共享网络创建%s\n' "$BOLD" "$RESET"
  mapfile -t npm_containers < <(find_npm_containers)
  if (( ${#npm_containers[@]} == 0 )); then
    warn "未自动识别 Nginx Proxy Manager 容器。"
    show_running_docker_containers
    read -r -p "输入 NPM 容器名称或 ID（直接回车返回）:" manual_container
    [[ -n "$manual_container" ]] || return 0
    if [[ "$(docker inspect --format '{{.State.Running}}' "$manual_container" 2>/dev/null)" != "true" ]]; then
      error "容器未运行或不存在：$manual_container"
      return 1
    fi
    npm_container_id="$(docker inspect --format '{{.Id}}' "$manual_container" 2>/dev/null || true)"
    npm_container_name="$(docker inspect --format '{{.Name}}' "$manual_container" 2>/dev/null || true)"
    npm_container_name="${npm_container_name#/}"
  elif (( ${#npm_containers[@]} == 1 )); then
    npm_target="${npm_containers[0]}"
    IFS=$'\t' read -r npm_container_id npm_container_name npm_image <<< "$npm_target"
  else
    printf '检测到多个 NPM 容器：\n'
    local i
    for ((i = 0; i < ${#npm_containers[@]}; i++)); do
      IFS=$'\t' read -r npm_container_id npm_container_name npm_image <<< "${npm_containers[$i]}"
      printf '  %d. %s | %s\n' "$((i + 1))" "$npm_container_name" "$npm_image"
    done
    read -r -p "请选择 [1-${#npm_containers[@]}]：" selection
    if [[ ! "$selection" =~ ^[0-9]+$ ]] || (( selection < 1 || selection > ${#npm_containers[@]} )); then
      error "无效选项：$selection"
      return 1
    fi
    npm_target="${npm_containers[$((selection - 1))]}"
    IFS=$'\t' read -r npm_container_id npm_container_name npm_image <<< "$npm_target"
  fi

  mapfile -t app_networks < <(docker_container_network_names "$app_container_id")
  mapfile -t npm_networks < <(docker_container_network_names "$npm_container_id")
  for app_network in "${app_networks[@]}"; do
    for npm_network in "${npm_networks[@]}"; do
      if [[ "$app_network" == "$npm_network" ]]; then
        shared_network="$app_network"
        break 2
      fi
    done
  done

  internal_port="${container_port%/tcp}"
  app_service="$(docker_compose_service_or_name "$app_container_id")"
  npm_service="$(docker_compose_service_or_name "$npm_container_id")"
  upstream_name="${app_service:-$app_container_name}"
  if [[ -n "$shared_network" ]]; then
    success "应用容器 ${app_container_name} 与 NPM ${npm_container_name} 已共享网络：${shared_network}。"
    info "请在 NPM 中将上游设为 ${upstream_name}:${internal_port}，协议按应用实际情况选择。"
    warn "请确认该网络已在两个 Compose 文件中声明；手工连接会在容器重建后丢失。"
    return 0
  fi

  warn "应用容器 ${app_container_name} 与 NPM ${npm_container_name} 没有共享 Docker 网络。"
  # Network names are for operators to recognize; Compose service names remain for NPM DNS upstreams.
  default_network="${npm_container_name}-${app_container_name}"
  read -r -p "共享网络名称 [默认 ${default_network}，按容器名自动生成]：" shared_network
  shared_network="${shared_network:-$default_network}"
  if [[ ! "$shared_network" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
    error "Docker 网络名称格式不正确。"
    return 1
  fi
  if docker network inspect "$shared_network" >/dev/null 2>&1; then
    info "Docker 网络 ${shared_network} 已存在。"
  else
    read -r -p "立即创建 Docker 共享网络 ${shared_network}？[y/N]：" create_network_answer
    create_network_answer="${create_network_answer:-N}"
    case "$create_network_answer" in
      Y|y)
        if ! docker network create "$shared_network" >/dev/null; then
          error "创建 Docker 网络失败：${shared_network}"
          return 1
        fi
        success "已创建 Docker 共享网络：${shared_network}。"
        ;;
      N|n)
        info "未创建 Docker 网络。可稍后执行：docker network create ${shared_network}"
        ;;
      *)
        error "请输入 Y 或 n。"
        return 1
        ;;
    esac
  fi

  if ! docker network inspect "$shared_network" >/dev/null 2>&1; then
    warn "Docker 网络 ${shared_network} 尚未创建，未执行容器连接。"
  else
    read -r -p "立即将 NPM ${npm_container_name} 和应用 ${app_container_name} 加入 ${shared_network}？[y/N]：" connect_network_answer
    connect_network_answer="${connect_network_answer:-N}"
    case "$connect_network_answer" in
      Y|y)
        connect_container_to_network "$app_container_id" "$app_container_name" "$shared_network" "$upstream_name" || return 1
        connect_container_to_network "$npm_container_id" "$npm_container_name" "$shared_network" || return 1
        if docker_container_has_network "$app_container_id" "$shared_network" && docker_container_has_network "$npm_container_id" "$shared_network"; then
          success "已验证 NPM 与应用容器均已加入网络 ${shared_network}。"
        else
          error "共享网络成员验证失败。"
          return 1
        fi
        if docker exec "$npm_container_id" getent hosts "$upstream_name" >/dev/null 2>&1; then
          success "NPM 容器可解析上游名称：${upstream_name}。"
        else
          warn "未能在 NPM 容器中执行 getent 解析检查；请在 NPM 保存代理主机后验证连接。"
        fi
        success "现在可在 NPM 中将上游设为 ${upstream_name}:${internal_port}。"
        ;;
      N|n)
        info "未连接当前容器。完成 Compose 配置后执行 docker compose up -d，或重新进入此菜单连接。"
        ;;
      *)
        error "请输入 Y 或 n。"
        return 1
        ;;
    esac
  fi

  printf '\n在 NPM 和应用各自的 Compose 文件中加入同名外部网络：\n\n'
  printf 'services:\n  %s:\n    networks:\n      - %s\n\n' "${npm_service:-<NPM服务名>}" "$shared_network"
  printf 'services:\n  %s:\n    networks:\n      - %s\n\n' "${app_service:-<应用服务名>}" "$shared_network"
  printf 'networks:\n  %s:\n    external: true\n\n' "$shared_network"
  info "以上片段用于持久化：分别保存后在两个 Compose 项目目录执行 docker compose up -d。"
  info "手工连接成功时可立即使用 ${upstream_name}:${internal_port}；重建容器后必须依靠上述 Compose 配置恢复连接。"
  warn "确认 NPM 访问正常后，才移除应用现有 ports 映射；菜单不会自动修改 Compose 或重建容器。"
}

show_docker_mapping_plan() {
  local container_id="$1"
  local container_name="$2"
  local container_port="$3"
  local current_host_ip="$4"
  local host_port="$5"
  local mode bind_host internal_port project service workdir config_files auto_apply_answer

  internal_port="${container_port%/tcp}"
  project="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "$container_id" 2>/dev/null || true)"
  service="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "$container_id" 2>/dev/null || true)"
  workdir="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$container_id" 2>/dev/null || true)"
  config_files="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$container_id" 2>/dev/null || true)"

  printf '\n%sDocker 容器端口映射%s\n' "$BOLD" "$RESET"
  if [[ -n "$project" ]]; then
    printf '启动方式：Docker 容器（Compose 管理）\n'
  else
    printf '启动方式：Docker 容器\n'
  fi
  printf '容器：%s\n宿主机发布地址：%s:%s（docker-proxy）\n容器内部端口：%s（共享网络/NPM 直连使用）\n' \
    "$container_name" "${current_host_ip:-0.0.0.0}" "$host_port" "$container_port"
  printf '  1. [推荐] NPM 容器直连应用容器（共享网络，不开放端口）\n'
  printf '  2. [兼容] NPM 经宿主机中转：172.17.0.1:%s（需发布 0.0.0.0）\n' "$host_port"
  printf '  3. [宿主机 Caddy] 发布端口改为：127.0.0.1:%s:%s（不改容器内部端口；可与选项 1 共用）\n' "$host_port" "$internal_port"
  printf '  4. [公网] 任何来源可访问：0.0.0.0:%s:%s\n' "$host_port" "$internal_port"
  printf '  0. 返回\n'
  read -r -p "请选择 [0-4]：" mode

  case "$mode" in
    1)
      show_npm_shared_network_guide "$container_id" "$container_name" "$container_port"
      return
      ;;
    2)
      bind_host="0.0.0.0"
      warn "兼容方案会将端口发布到所有 IPv4 网卡。请限制防火墙来源，仅让 NPM 所在 Docker 网段访问。"
      info "重建容器后，在 NPM 中填写 Docker 网关地址:${host_port}；共享网络方案更安全且无需发布端口。"
      ;;
    3)
      bind_host="127.0.0.1"
      info "仅修改宿主机发布地址为 127.0.0.1:${host_port}；容器内部端口仍为 ${internal_port}。"
      info "此端口供宿主机上的 Caddy、Nginx 等反代；Docker 内的 NPM 不能经 127.0.0.1:${host_port} 访问。"
      info "若已选择选项 1 共享网络，NPM 仍可使用 ${service:-应用服务名}:${internal_port} 直连应用。"
      ;;
    4)
      bind_host="0.0.0.0"
      warn "此容器端口将接受所有 IPv4 网络接口的连接，请限制防火墙来源。"
      ;;
    0) return 0 ;;
    *) error "无效选项：$mode"; return 1 ;;
  esac

  printf '\n请将 Compose 中对应服务的 ports 映射改为：\n\n'
  printf 'services:\n  %s:\n    ports:\n      - "%s:%s:%s"\n' \
    "${service:-<服务名>}" "$bind_host" "$host_port" "$internal_port"
  printf '\n'
  if [[ -n "$project" ]]; then
    info "检测到 Compose 项目：$project"
    [[ -n "$workdir" ]] && info "项目目录：$workdir"
    [[ -n "$config_files" ]] && info "配置文件：$config_files"
    if [[ "$current_host_ip" == "$bind_host" ]]; then
      info "当前 Docker 端口映射已是目标地址，无需修改。"
    elif [[ -n "$service" && "$service" != "<no value>" && -n "$workdir" && -d "$workdir" && -n "$config_files" && "$config_files" != *,* && -f "$config_files" ]]; then
      read -r -p "自动备份、修改 Compose 并重建服务 ${service}？[y/N]：" auto_apply_answer
      auto_apply_answer="${auto_apply_answer:-N}"
      case "$auto_apply_answer" in
        Y|y)
          apply_compose_port_mapping "$config_files" "$workdir" "$service" "$current_host_ip" "$host_port" "$internal_port" "$bind_host" || return 1
          ;;
        N|n)
          info "未自动修改。保存上述 Compose 片段后，在项目目录执行 docker compose up -d。"
          ;;
        *) error "请输入 Y 或 n。"; return 1 ;;
      esac
    else
      warn "未能安全识别单个可修改的 Compose 文件，未自动重建容器。"
      info "保存上述 Compose 片段后，在项目目录执行 docker compose up -d。"
    fi
  else
    warn "未检测到 Compose 标签。Docker 无法原地修改端口映射，需要使用新的 -p 参数重建该容器。"
  fi
  info "自动重建仅在已识别的单文件 Compose 与唯一端口映射时执行；其他情形保留手工操作。"
}

show_native_listener_launch_info() {
  local listener="$1"
  local pid unit ppid user process parent_process

  pid="$(printf '%s\n' "$listener" | listener_pid_from_details)"
  [[ "$pid" =~ ^[0-9]+$ ]] || {
    warn "无法从监听信息中识别进程 PID。"
    return 0
  }
  unit="$(systemd_unit_for_pid "$pid")"
  if [[ -n "$unit" ]]; then
    printf '启动方式：systemd 服务（%s）\n' "$unit"
    info "下一步：Kopia 可自动修改；其他原生服务可使用通用 systemd 配置替换与回滚功能。"
    return 0
  fi

  ppid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
  user="$(ps -o user= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
  process="$(ps -o comm= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
  parent_process="$(ps -o comm= -p "$ppid" 2>/dev/null | tr -d ' ' || true)"
  if [[ "$ppid" == "1" ]]; then
    printf '启动方式：已脱离终端的手工命令（由 systemd / PID 1 收养，但不是 systemd 服务）\n'
    printf '进程：%s | PID：%s | 用户：%s\n' "${process:-未知}" "$pid" "${user:-未知}"
    info "下一步：可在 Kopia 菜单中选择接管为 CaddyCtl 管理的 systemd 服务。"
    return 0
  fi
  printf '启动方式：手工命令、脚本或面板（未识别为 systemd 服务）\n'
  printf '进程：%s | PID：%s | 用户：%s | 父进程：%s（PID %s）\n' \
    "${process:-未知}" "$pid" "${user:-未知}" "${parent_process:-未知}" "${ppid:-未知}"
  info "下一步：请在上述父进程对应的面板、脚本或启动命令中修改监听地址；菜单不会直接接管该进程。"
}

local_service_listener_assistant() {
  local port listener process docker_mapping container_id container_name container_port host_ip

  printf '\n%s本机服务端口监听助手%s\n' "$BOLD" "$RESET"
  info "先列出本机服务，再输入需要查看或修改的端口。可将手工启动的 Kopia 接管为 systemd 服务。"
  show_all_local_listeners
  read -r -p "输入需要管理的 TCP 端口；输入 d 查看全部 Docker 容器内部监听（直接回车返回）：" port
  [[ -n "$port" ]] || return 0
  case "$port" in
    d|D)
      show_all_docker_internal_listeners
      return
      ;;
  esac
  if ! is_valid_port "$port"; then
    error "端口必须是 1-65535 之间的整数。"
    return 1
  fi
  listener="$(local_tcp_listener_details "$port")"
  if [[ -z "$listener" ]]; then
    warn "未发现 TCP 端口 $port 处于监听状态。"
    return 0
  fi
  printf '\n%s端口 %s 的监听详情%s\n%s\n' "$BOLD" "$port" "$RESET" "$listener"
  docker_mapping="$(docker_mapping_for_host_port "$port")"
  if [[ -n "$docker_mapping" ]]; then
    IFS=$'\t' read -r container_id container_name container_port host_ip <<< "$docker_mapping"
    show_docker_container_internal_listeners "$container_id" "$container_name"
    show_docker_mapping_plan "$container_id" "$container_name" "$container_port" "$host_ip" "$port"
    return
  fi
  process="$(printf '%s\n' "$listener" | listener_process_from_details)"
  if [[ "$process" == "docker-proxy" ]]; then
    warn "该端口由 Docker 发布，但未能读取容器端口映射，不能按通用 systemd 服务修改。"
    show_running_docker_containers
    info "请确认已升级到当前版本，并检查 docker inspect 的 Ports 信息。"
    return 1
  fi
  show_native_listener_launch_info "$listener"
  if [[ "$process" == "kopia" ]]; then
    manage_kopia_listener "$port" "$listener"
  else
    unit="$(systemd_unit_for_pid "$(printf '%s\n' "$listener" | listener_pid_from_details)")"
    if [[ -n "$unit" ]]; then
      manage_generic_systemd_listener "$port" "$listener" "$unit"
    else
      info "已识别进程：${process:-未知}。该服务不由 systemd 直接管理，请在其自身配置或原管理面板中调整监听地址。"
    fi
  fi
}

delete_proxy() {
  local domain target rollback_file

  if [[ ! -x "$REAL_CADDY" ]]; then
    error "Caddy 尚未安装。"
    return 1
  fi

  if ! compgen -G "${SITES_DIR}/*.caddy" >/dev/null 2>&1; then
    warn "暂无可删除的站点配置。"
    return 0
  fi

  printf '\n可删除的站点（域名 -> 当前后端服务）：\n'
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

  confirm_action "确认删除 $domain 的反向代理配置？" || { info "已取消。"; return 0; }

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
  printf '\n%sCaddy 端口监听与 Docker 映射%s\n' "$BOLD" "$RESET"
  if command -v ss >/dev/null 2>&1; then
    ss -ltnp 2>/dev/null | sed -n '1p;/caddy/p;/docker-proxy/p;/:80 /p;/:443 /p' | localize_ss_listener_header
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltnp 2>/dev/null | sed -n '1,2p;/caddy/p;/docker-proxy/p;/:80 /p;/:443 /p' | localize_netstat_listener_header
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
  printf '  2. 安装或更新 Caddy\n'
  printf '  3. 更新 CaddyCtl 管理菜单\n'
  printf '  4. 卸载 Caddy 或 CaddyCtl\n'
  printf '  5. 新增反向代理\n'
  printf '  6. 修改现有反向代理\n'
  printf '  7. 查看当前反向代理配置\n'
  printf '  8. 删除反向代理\n'
  printf '  9. 校验并重载 Caddy\n'
  printf ' 10. 查看 Caddy 服务日志\n'
  printf ' 11. 查看 Caddy 端口监听与 Docker 映射\n'
  printf ' 12. 检测后端服务监听与连通性\n'
  printf ' 13. 本机服务端口监听助手\n'
  printf '  0. 退出\n'
  printf '%s============================================%s\n' "$BLUE" "$RESET"
  printf '提示：退出后可在终端输入 caddyctl 再次打开本菜单。\n'
}

show_status_detail() {
  local active enabled pid started answer

  printf '\n%sCaddy 运行状态详情%s\n' "$BOLD" "$RESET"
  status_line
  printf '\n配置文件：%s\n' "$CADDYFILE"
  printf '站点配置目录：%s\n' "$SITES_DIR"

  if ! command -v systemctl >/dev/null 2>&1; then
    warn "当前系统未提供 systemctl，无法读取更多服务详情。"
    return 0
  fi

  active="$(systemctl is-active caddy 2>/dev/null || true)"
  enabled="$(systemctl is-enabled caddy 2>/dev/null || true)"
  pid="$(systemctl show caddy --property=MainPID --value 2>/dev/null || true)"
  started="$(systemctl show caddy --property=ActiveEnterTimestamp --value 2>/dev/null || true)"

  case "$active" in
    active) printf '服务状态：正常运行\n' ;;
    inactive) printf '服务状态：未运行\n' ;;
    failed) printf '服务状态：启动失败\n' ;;
    *) printf '服务状态：%s\n' "${active:-未知}" ;;
  esac
  [[ "$enabled" == "enabled" ]] && printf '开机启动：已启用\n' || printf '开机启动：未启用\n'
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] && printf '主进程 PID：%s\n' "$pid"
  [[ -n "$started" && "$started" != "n/a" ]] && printf '本次启动时间：%s\n' "$started"

  read -r -p "是否查看原始 systemd 服务详情？[y/N]：" answer
  [[ "$answer" =~ ^[Yy]$ ]] || return 0
  printf '\n%s原始 systemd 服务详情%s\n' "$BOLD" "$RESET"
  systemctl status caddy --no-pager -l 2>/dev/null || true
}

main_menu() {
  local choice
  while true; do
    draw_menu
    read -r -p "请选择 [0-13]：" choice || exit 0
    printf '\n'

    case "$choice" in
      1) show_status_detail; pause_menu ;;
      2) install_or_update_caddy; pause_menu ;;
      3) update_manager; pause_menu ;;
      4) uninstall_menu; pause_menu ;;
      5) configure_proxy; pause_menu ;;
      6) edit_proxy_config; pause_menu ;;
      7) show_config; pause_menu ;;
      8) delete_proxy; pause_menu ;;
      9) validate_and_reload; pause_menu ;;
      10) show_logs; pause_menu ;;
      11) show_listeners; pause_menu ;;
      12) diagnose_upstream; pause_menu ;;
      13) local_service_listener_assistant; pause_menu ;;
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

if [[ $# -eq 1 && "$1" == "--install-manager" ]]; then
  require_root "$@"
  install_manager_command
  success "CaddyCtl 管理菜单已安装。请在菜单中选择“安装或更新 Caddy”继续。"
  info "以后可在终端直接输入 caddyctl 打开管理菜单。"
  main_menu
  exit 0
fi

if [[ $# -ne 0 ]]; then
  show_command_usage
  exit 2
fi
require_root "$@"
main_menu
