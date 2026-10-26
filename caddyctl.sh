#!/usr/bin/env bash

# CaddyCtl - an interactive manager for a package-installed Caddy.
# Run without arguments to open the menu. Keep the official `caddy` command
# for the Caddy CLI; this project installs the separate `caddyctl` command.

set -uo pipefail

readonly PROJECT_NAME="CaddyCtl"
readonly MANAGER_VERSION="3.3.59"
readonly MANAGER_SOURCE_URL="${CADDYCTL_SOURCE_URL:-https://raw.githubusercontent.com/xhpx7301/CaddyCtl/main/caddyctl.sh}"
readonly REAL_CADDY="/usr/bin/caddy"
readonly CADDYFILE="/etc/caddy/Caddyfile"
readonly SITES_DIR="/etc/caddy/sites"
readonly CADDY_CONFIG_DIR="/etc/caddy"
readonly CADDY_DATA_DIR="/var/lib/caddy"
readonly BACKUP_DIR="/var/backups/caddyctl"
readonly MANAGER_DIR="/usr/local/lib/caddyctl"
readonly MANAGER_SCRIPT="${MANAGER_DIR}/caddyctl.sh"
readonly MANAGER_COMMAND="/usr/local/bin/caddyctl"
readonly LISTENER_COMMAND="/usr/local/bin/pl"
readonly LEGACY_LISTENER_COMMAND="/usr/local/bin/caddyctl-listen"
readonly LEGACY_MANAGER_COMMAND="/usr/local/bin/caddy"
readonly CADDY_L4_BINARY="/usr/local/bin/caddy-l4"
readonly CADDY_L4_SERVICE_DROPIN="/etc/systemd/system/caddy.service.d/caddyctl-l4.conf"
readonly CADDY_L4_STATE_FILE="/etc/caddy/caddyctl-layer4.tsv"
readonly CADDY_L4_DISABLED_SITE_SUFFIX=".caddyctl-disabled"
readonly CADDY_L4_MARKER_BEGIN="# BEGIN CADDYCTL LAYER4"
readonly CADDY_L4_MARKER_END="# END CADDYCTL LAYER4"
readonly CADDY_L4_MIN_FREE_KB=1572864
readonly CADDY_L4_PREBUILT_MIN_FREE_KB=131072
readonly CADDY_L4_PLUGIN_VERSION="${CADDYCTL_L4_PLUGIN_VERSION:-v0.1.2}"
readonly CADDY_L4_PREBUILT_URL="${CADDYCTL_L4_PREBUILT_URL:-https://caddyserver.com/api/download}"
readonly CADDY_GITHUB_API="https://api.github.com/repos/caddyserver/caddy/releases/latest"
readonly CADDY_GITHUB_RELEASE="https://github.com/caddyserver/caddy/releases/download"
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
  read -r -p "按 Enter 键返回${1:-主菜单}..." _ || true
}

confirm_action() {
  local prompt="$1"
  local answer

  read -r -p "$prompt [y/N，回车默认 N]：" answer || return 1
  [[ "$answer" =~ ^[Yy]$ ]]
}

manager_source() {
  local source_path="${BASH_SOURCE[0]}"
  readlink -f "$source_path" 2>/dev/null || printf '%s\n' "$source_path"
}

show_command_usage() {
  printf '%s\n' "$PROJECT_NAME 是 Caddy 的管理菜单。"
  printf '%s\n' "用法：caddyctl [listen|--listen|--install]"
  printf '%s\n' "  listen/--listen  直接打开本机服务端口监听助手"
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

caddy_runtime_binary() {
  if [[ -x "$CADDY_L4_BINARY" ]] \
      && "$CADDY_L4_BINARY" list-modules 2>/dev/null | grep -Fq 'layer4'; then
    printf '%s\n' "$CADDY_L4_BINARY"
  else
    printf '%s\n' "$REAL_CADDY"
  fi
}

caddy_l4_enabled() {
  [[ -f "$CADDY_L4_SERVICE_DROPIN" ]] \
    && grep -Fq "$CADDY_L4_BINARY run" "$CADDY_L4_SERVICE_DROPIN" \
    && grep -Fq "$CADDY_L4_MARKER_BEGIN" "$CADDYFILE" 2>/dev/null
}

filesystem_free_kb() {
  local path="$1"
  df -Pk "$path" 2>/dev/null | awk 'NR == 2 {print $4}'
}

choose_caddy_l4_build_parent() {
  local candidate free best_path="" best_free=0
  for candidate in /var/cache/caddyctl /var/lib/caddyctl /usr/local/lib/caddyctl /root; do
    mkdir -p -- "$candidate" 2>/dev/null || continue
    free="$(filesystem_free_kb "$candidate")"
    [[ "$free" =~ ^[0-9]+$ ]] || continue
    if (( free > best_free )); then
      best_free="$free"
      best_path="$candidate"
    fi
  done
  [[ -n "$best_path" ]] || return 1
  printf '%s\n' "$best_path"
}

check_caddy_l4_build_space() {
  local build_parent="$1" free
  free="$(filesystem_free_kb "$build_parent")"
  if [[ ! "$free" =~ ^[0-9]+$ ]] || (( free < CADDY_L4_MIN_FREE_KB )); then
    error "构建 caddy-l4 前至少需要约 1.5 GiB 可用空间；构建目录所在文件系统可用 ${free:-未知} KiB。请先清理磁盘后重试。"
    return 1
  fi
}

cleanup_caddy_l4_build_cache() {
  local path
  # Older CaddyCtl releases used the default root Go cache and could leave
  # several hundred MiB behind after an interrupted build. These caches are
  # disposable and are recreated inside the temporary build directory below.
  if command -v go >/dev/null 2>&1; then
    go clean -cache -modcache >/dev/null 2>&1 || true
  fi
  for path in /tmp/builderenv_* /tmp/caddyctl-l4-build.* /tmp/go-build* /tmp/go-build*_*; do
    [[ -e "$path" ]] || continue
    rm -rf -- "$path"
  done
}

caddy_l4_arch() {
  case "$(uname -m 2>/dev/null || true)" in
    x86_64|amd64) printf 'amd64\n' ;;
    aarch64|arm64) printf 'arm64\n' ;;
    armv7l|armv7) printf 'armv7\n' ;;
    armv6l|armv6) printf 'armv6\n' ;;
    ppc64le) printf 'ppc64le\n' ;;
    riscv64) printf 'riscv64\n' ;;
    s390x) printf 's390x\n' ;;
    *) return 1 ;;
  esac
}

caddy_l4_prebuilt_url() {
  local architecture="$1" separator='?'
  [[ "$CADDY_L4_PREBUILT_URL" == *\?* ]] && separator='&'
  printf '%s%sos=linux&arch=%s&p=github.com/mholt/caddy-l4%%40%s\n' \
    "$CADDY_L4_PREBUILT_URL" "$separator" "$architecture" "$CADDY_L4_PLUGIN_VERSION"
}

install_caddy_l4_prebuilt() {
  local architecture build_parent download_dir temp_binary download_url free

  architecture="$(caddy_l4_arch)" || {
    warn "当前 CPU 架构没有匹配的预编译 caddy-l4，准备使用 Go 构建。"
    return 1
  }
  build_parent="$(choose_caddy_l4_build_parent)" || {
    warn "找不到预编译二进制下载目录，准备使用 Go 构建。"
    return 1
  }
  free="$(filesystem_free_kb "$build_parent")"
  if [[ ! "$free" =~ ^[0-9]+$ ]] || (( free < CADDY_L4_PREBUILT_MIN_FREE_KB )); then
    warn "预编译二进制下载目录可用空间不足，准备使用 Go 构建。"
    return 1
  fi
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    warn "未找到 curl 或 wget，准备使用 Go 构建。"
    return 1
  fi

  download_dir="$(mktemp -d "${build_parent}/caddyctl-l4-download.XXXXXX")" || return 1
  temp_binary="${download_dir}/caddy-l4"
  download_url="$(caddy_l4_prebuilt_url "$architecture")"
  info "正在下载预编译 caddy-l4（${architecture}，插件 ${CADDY_L4_PLUGIN_VERSION}）..."
  if ! download_url_to_file "$download_url" "$temp_binary"; then
    rm -rf -- "$download_dir"
    warn "预编译 caddy-l4 下载失败，准备使用 Go 构建。"
    return 1
  fi
  chmod 0755 "$temp_binary"
  if ! "$temp_binary" list-modules 2>/dev/null | grep -Fq 'layer4'; then
    rm -rf -- "$download_dir"
    warn "预编译文件未包含 layer4 模块，准备使用 Go 构建。"
    return 1
  fi
  if ! install -m 0755 "$temp_binary" "$CADDY_L4_BINARY"; then
    rm -rf -- "$download_dir"
    error "预编译 caddy-l4 安装失败。"
    return 1
  fi
  rm -rf -- "$download_dir"
  success "已安装预编译 caddy-l4。"
  return 0
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

  if [[ -f "$LEGACY_LISTENER_COMMAND" ]] \
      && grep -Fq '# CaddyCtl listener shortcut' "$LEGACY_LISTENER_COMMAND" 2>/dev/null; then
    backup_file "$LEGACY_LISTENER_COMMAND" "caddyctl-listen-command-before-rename"
    rm -f -- "$LEGACY_LISTENER_COMMAND"
  fi

  cat >"$MANAGER_COMMAND" <<'WRAPPER'
#!/usr/bin/env bash
set -uo pipefail

# CaddyCtl command wrapper
readonly MANAGER_SCRIPT="/usr/local/lib/caddyctl/caddyctl.sh"
readonly COMMAND_NAME="${0##*/}"

if [[ "$COMMAND_NAME" == "pl" ]]; then
  if [[ $# -ne 0 ]]; then
    printf 'pl 不接受参数；直接运行即可打开本机服务端口监听助手。\n' >&2
    exit 2
  fi
  set -- listen
fi

if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--install" && "$1" != "listen" ) ]]; then
  printf 'caddyctl 仅支持无参数、listen 或 --install。官方 CLI 请使用 caddy。\n' >&2
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
  chmod 0755 "$MANAGER_COMMAND" || {
    error "无法设置 $MANAGER_COMMAND 的可执行权限。"
    return 1
  }
  [[ -x "$MANAGER_COMMAND" ]] || {
    error "$MANAGER_COMMAND 仍不可执行，请检查 /usr/local/bin 的挂载和权限。"
    return 1
  }

  if [[ ( -e "$LISTENER_COMMAND" || -L "$LISTENER_COMMAND" ) ]] \
      && [[ ! "$LISTENER_COMMAND" -ef "$MANAGER_COMMAND" ]]; then
    warn "$LISTENER_COMMAND 已存在，将先备份再安装端口助手快捷命令。"
    backup_file "$LISTENER_COMMAND" "pl-command"
  fi
  rm -f -- "$LISTENER_COMMAND"
  ln -s "$MANAGER_COMMAND" "$LISTENER_COMMAND" || {
    error "无法创建快捷命令 $LISTENER_COMMAND。"
    return 1
  }
  [[ -x "$LISTENER_COMMAND" && "$LISTENER_COMMAND" -ef "$MANAGER_COMMAND" ]] || {
    error "$LISTENER_COMMAND 未正确指向 $MANAGER_COMMAND。"
    return 1
  }
}

ensure_manager_commands() {
  local source_path

  source_path="$(manager_source)"
  [[ "$source_path" == "$MANAGER_SCRIPT" ]] || return 0
  if [[ -x "$MANAGER_COMMAND" ]] \
      && grep -Fq '# CaddyCtl command wrapper' "$MANAGER_COMMAND" 2>/dev/null \
      && grep -Fq '"$1" != "listen"' "$MANAGER_COMMAND" 2>/dev/null \
      && [[ -x "$LISTENER_COMMAND" ]] \
      && [[ "$LISTENER_COMMAND" -ef "$MANAGER_COMMAND" ]]; then
    return 0
  fi

  info "正在同步 CaddyCtl 命令入口与 pl 快捷命令..."
  if ! install_manager_command; then
    error "命令入口同步失败；未继续进入管理菜单。"
    return 1
  fi
  success "命令入口已同步；可直接输入 pl 打开本机服务端口监听助手。"
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

download_url_to_file() {
  local source_url="$1"
  local destination="$2"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --proto '=https' --tlsv1.2 \
      --retry 3 --retry-delay 1 --connect-timeout 15 \
      -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
      "$source_url" -o "$destination"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$destination" \
      --tries=3 --timeout=15 \
      --header='Cache-Control: no-cache' --header='Pragma: no-cache' \
      "$source_url"
  else
    return 1
  fi
}

github_raw_immutable_url() {
  local source_url="$1"
  local owner repository revision path api_url commit

  if [[ "$source_url" =~ ^https://raw\.githubusercontent\.com/([^/]+)/([^/]+)/([^/?]+)/([^?]+)$ ]]; then
    owner="${BASH_REMATCH[1]}"
    repository="${BASH_REMATCH[2]}"
    revision="${BASH_REMATCH[3]}"
    path="${BASH_REMATCH[4]}"
  else
    return 1
  fi
  api_url="https://api.github.com/repos/${owner}/${repository}/commits/${revision}"

  if command -v curl >/dev/null 2>&1; then
    commit="$(curl -fsSL --proto '=https' --tlsv1.2 \
      --retry 2 --retry-delay 1 --connect-timeout 15 \
      -H 'Accept: application/vnd.github+json' "$api_url" \
      | sed -n 's/^[[:space:]]*"sha":[[:space:]]*"\([0-9a-f]\{40\}\)".*/\1/p' | head -n 1)" || return 1
  elif command -v wget >/dev/null 2>&1; then
    commit="$(wget -qO- --tries=2 --timeout=15 \
      --header='Accept: application/vnd.github+json' "$api_url" \
      | sed -n 's/^[[:space:]]*"sha":[[:space:]]*"\([0-9a-f]\{40\}\)".*/\1/p' | head -n 1)" || return 1
  else
    return 1
  fi
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || return 1
  printf 'https://raw.githubusercontent.com/%s/%s/%s/%s\n' "$owner" "$repository" "$commit" "$path"
}

download_manager_script() {
  local destination="$1"
  local immutable_url source_url

  immutable_url="$(github_raw_immutable_url "$MANAGER_SOURCE_URL" || true)"
  if [[ -n "$immutable_url" ]] && download_url_to_file "$immutable_url" "$destination"; then
    return 0
  fi
  source_url="$(cache_busted_github_raw_url "$MANAGER_SOURCE_URL")"
  if ! download_url_to_file "$source_url" "$destination"; then
    error "需要可用的 curl 或 wget，且无法下载 CaddyCtl 更新。"
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
    ensure_manager_commands
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

caddy_service_identity() {
  local service_user service_group
  service_user="$(systemctl show caddy --property=User --value 2>/dev/null)" || return 1
  service_user="${service_user:-root}"
  service_group="$(systemctl show caddy --property=Group --value 2>/dev/null)" || return 1
  service_group="${service_group:-$(id -gn "$service_user")}"
  id "$service_user" >/dev/null 2>&1 && [[ -n "$service_group" ]] || {
    error "无法确定 Caddy 服务用户和用户组，请检查 systemctl cat caddy。"
    return 1
  }
  printf '%s\t%s\n' "$service_user" "$service_group"
}

prepare_caddy_permissions() {
  local service_user service_group identity
  identity="$(caddy_service_identity)" || return 1
  IFS=$'\t' read -r service_user service_group <<<"$identity"

  # Root owns configuration; the service group may traverse and read it.
  # Never recursively change certificate files or expose the private TSV state.
  if ! install -d -o root -g "$service_group" -m 0750 "$CADDY_CONFIG_DIR" "$SITES_DIR" \
      || ! install -d -o "$service_user" -g "$service_group" -m 0750 "$CADDY_DATA_DIR"; then
    error "无法设置 Caddy 配置目录或数据目录权限。"
    return 1
  fi
  if [[ -f "$CADDYFILE" ]]; then
    chgrp "$service_group" "$CADDYFILE" && chmod g+r "$CADDYFILE" || {
      error "无法设置 Caddyfile 的服务用户读取权限。"
      return 1
    }
  fi
}

validate_caddy_config() {
  local runtime="${1:-$(caddy_runtime_binary)}" service_user service_group identity
  prepare_caddy_permissions || return 1
  identity="$(caddy_service_identity)" || return 1
  IFS=$'\t' read -r service_user service_group <<<"$identity"
  if ! command -v runuser >/dev/null 2>&1; then
    error "未找到 runuser，无法以 Caddy 服务用户身份校验配置。请安装 util-linux。"
    return 1
  fi
  # Match the package service's data paths instead of inheriting root's XDG paths.
  if ! runuser -u "$service_user" -g "$service_group" -- env \
      HOME="$CADDY_DATA_DIR" XDG_CONFIG_HOME="$CADDY_DATA_DIR/.config" \
      XDG_DATA_HOME="$CADDY_DATA_DIR/.local/share" \
      "$runtime" validate --config "$CADDYFILE" --adapter caddyfile; then
    error "以服务用户 ${service_user}:${service_group} 校验失败，未启动或重载新配置；请检查上方的配置及权限错误。"
    return 1
  fi
}

preserve_caddyfile_permissions() {
  local temp_file="$1"
  chown --reference="$CADDYFILE" "$temp_file" \
    && chmod --reference="$CADDYFILE" "$temp_file"
}

initialize_caddyfile() {
  prepare_caddy_permissions || return 1

  if [[ ! -f "$CADDYFILE" ]]; then
    cat >"$CADDYFILE" <<EOF
$IMPORT_BEGIN
import $SITES_DIR/*.caddy
$IMPORT_END
EOF
    prepare_caddy_permissions
    return $?
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
  prepare_caddy_permissions
}

state_has_panel() {
  [[ -f "$CADDY_L4_STATE_FILE" ]] && awk -F '\t' '$1 == "P" {found=1} END {exit !found}' "$CADDY_L4_STATE_FILE"
}

state_has_reality() {
  [[ -f "$CADDY_L4_STATE_FILE" ]] && awk -F '\t' '$1 == "R" {found=1} END {exit !found}' "$CADDY_L4_STATE_FILE"
}

write_caddy_l4_block() {
  local panel_domain="${1:-}" panel_backend="${2:-}"
  local existing temp_file reality_sni reality_host reality_port route_name route_index=0 panel_host panel_port

  [[ -f "$CADDYFILE" ]] || { initialize_caddyfile || return 1; }
  if [[ -z "$panel_domain" || -z "$panel_backend" ]]; then
    IFS=$'\t' read -r panel_domain panel_host panel_port <<<"$(read_caddy_l4_panel)"
    if [[ -n "$panel_domain" && -n "$panel_host" && -n "$panel_port" ]]; then
      panel_backend="$(format_upstream_host "$panel_host"):${panel_port}"
    else
      panel_domain=""
      panel_backend=""
    fi
  fi
  existing="$(mktemp)" || return 1
  awk -v begin="$CADDY_L4_MARKER_BEGIN" -v end="$CADDY_L4_MARKER_END" '
    $0 == begin { skip=1; next }
    $0 == end { skip=0; next }
    !skip { print }
  ' "$CADDYFILE" >"$existing" || { rm -f -- "$existing"; return 1; }

  if [[ "$(awk 'NF && $0 !~ /^[[:space:]]*#/ { print; exit }' "$existing")" == "{" ]]; then
    rm -f -- "$existing"
    error "现有 Caddyfile 已包含全局 options 块，无法自动插入 caddy-l4 配置；请先手工合并 layer4 配置。"
    return 1
  fi

  temp_file="$(mktemp "${CADDYFILE}.caddyctl.XXXXXX")" || { rm -f -- "$existing"; return 1; }
  cat >"$temp_file" <<EOF
$CADDY_L4_MARKER_BEGIN
{
    servers :443 {
        listener_wrappers {
            layer4 {
EOF
  if [[ -n "$panel_domain" && -n "$panel_backend" ]]; then
    cat >>"$temp_file" <<EOF
                @caddyctl_panel tls {
                    sni $panel_domain
                    alpn http/1.1 http/1.0
                }
                route @caddyctl_panel {
                    tls {
                        connection_policy {
                            alpn http/1.1
                        }
                    }
                    proxy tcp/$panel_backend
                }
EOF
  fi
  while IFS=$'\t' read -r reality_sni reality_host reality_port; do
    [[ -n "$reality_sni" ]] || continue
    ((route_index+=1))
    route_name="caddyctl_reality_${route_index}"
    printf '\n                @%s tls sni %s\n' "$route_name" "$reality_sni" >>"$temp_file"
    printf '                route @%s {\n' "$route_name" >>"$temp_file"
    printf '                    proxy tcp/%s:%s\n' "$(format_upstream_host "$reality_host")" "$reality_port" >>"$temp_file"
    printf '                }\n' >>"$temp_file"
  done < <(awk -F '\t' '$1 == "R" {print $2 "\t" $3 "\t" $4}' "$CADDY_L4_STATE_FILE" 2>/dev/null)
  cat >>"$temp_file" <<EOF
            }
            tls
        }
    }
}
$CADDY_L4_MARKER_END

EOF
  cat "$existing" >>"$temp_file" || { rm -f -- "$existing" "$temp_file"; return 1; }
  preserve_caddyfile_permissions "$temp_file" || { rm -f -- "$existing" "$temp_file"; return 1; }
  backup_file "$CADDYFILE" "Caddyfile-before-layer4"
  if ! mv -f -- "$temp_file" "$CADDYFILE"; then
    rm -f -- "$existing" "$temp_file"
    return 1
  fi
  rm -f -- "$existing"
}

remove_caddy_l4_block() {
  local temp_file
  temp_file="$(mktemp "${CADDYFILE}.caddyctl.XXXXXX")" || return 1
  awk -v begin="$CADDY_L4_MARKER_BEGIN" -v end="$CADDY_L4_MARKER_END" '$0 == begin {skip=1; next} $0 == end {skip=0; next} !skip {print}' "$CADDYFILE" >"$temp_file" || { rm -f -- "$temp_file"; return 1; }
  preserve_caddyfile_permissions "$temp_file" \
    && mv -f -- "$temp_file" "$CADDYFILE" || { rm -f -- "$temp_file"; return 1; }
}

write_caddy_l4_panel_site() {
  local panel_domain="$1"
  local panel_host="$2"
  local panel_port="$3"
  local target temp_file rollback_file="" had_existing=false

  target="$(site_path_for_domain "$panel_domain")"
  if [[ -f "$target" ]] && ! grep -Fq '# 由 CaddyCtl 管理：443 SNI 分流后的 3x-ui 面板入口。' "$target"; then
    error "面板域名已有站点配置：$target；为避免覆盖现有反代，已取消。"
    return 1
  fi
  temp_file="$(mktemp "${SITES_DIR}/.${panel_domain}.XXXXXX")" || return 1
  cat >"$temp_file" <<EOF
# 由 CaddyCtl 管理：443 SNI 分流后的 3x-ui 面板入口。
${panel_domain} {
    reverse_proxy http://$(format_upstream_host "$panel_host"):$panel_port
}
EOF
  "$REAL_CADDY" fmt --overwrite "$temp_file" >/dev/null 2>&1 || true

  if [[ -f "$target" ]]; then
    had_existing=true
    rollback_file="$(mktemp)" || { rm -f -- "$temp_file"; return 1; }
    cp -a -- "$target" "$rollback_file" || { rm -f -- "$temp_file" "$rollback_file"; return 1; }
    backup_file "$target" "${panel_domain}.caddy-before-layer4"
  fi
  if ! install -m 0644 "$temp_file" "$target"; then
    rm -f -- "$temp_file" "$rollback_file"
    return 1
  fi
  rm -f -- "$temp_file"
  printf '%s\t%s\n' "$had_existing" "$rollback_file"
}

restore_caddy_l4_panel_site() {
  local panel_domain="$1" had_existing="$2" rollback_file="$3" target
  target="$(site_path_for_domain "$panel_domain")"
  if [[ "$had_existing" == true && -f "$rollback_file" ]]; then
    install -m 0644 "$rollback_file" "$target"
  else
    rm -f -- "$target"
  fi
  [[ -z "$rollback_file" ]] || rm -f -- "$rollback_file"
}

read_caddy_l4_panel() {
  awk -F '\t' '$1 == "P" {print $2 "\t" $3 "\t" $4; exit}' "$CADDY_L4_STATE_FILE" 2>/dev/null
}

apply_caddy_l4_state() {
  local panel_domain panel_host panel_port old_caddy old_site runtime old_state old_panel_domain old_panel_site_backup="" old_panel_site_path=""
  local -a panel=()
  local site_existed=false
  [[ -f "$CADDY_L4_STATE_FILE" ]] || { error "未找到 443 复用配置。"; return 1; }
  IFS=$'\t' read -r -a panel <<<"$(read_caddy_l4_panel)"
  panel_domain="${panel[0]:-}"; panel_host="${panel[1]:-}"; panel_port="${panel[2]:-}"
  old_panel_domain="${1:-$panel_domain}"
  if [[ -n "$panel_domain" ]]; then
    is_valid_domain "$panel_domain" && is_valid_upstream_host "$panel_host" && is_valid_port "$panel_port" || {
      error "面板配置无效。"
      return 1
    }
    if [[ -f "$(site_path_for_domain "$panel_domain")" ]] \
        && ! grep -Fq '# 由 CaddyCtl 管理：443 SNI 分流后的 3x-ui 面板入口。' "$(site_path_for_domain "$panel_domain")"; then
      error "面板域名已有其他站点配置，拒绝覆盖。"
      return 1
    fi
  fi
  if ! state_has_panel && ! state_has_reality; then
    error "至少需要配置面板映射或 Reality 映射。"
    return 1
  fi
  old_caddy="$(mktemp)" || return 1
  cp -a "$CADDYFILE" "$old_caddy" || { rm -f "$old_caddy"; return 1; }
  old_state="$(mktemp)" || { rm -f "$old_caddy"; return 1; }
  cp -a "$CADDY_L4_STATE_FILE" "$old_state" || { rm -f "$old_caddy" "$old_state"; return 1; }
  old_site="$(mktemp)" || { rm -f "$old_caddy" "$old_state"; return 1; }
  if [[ -n "$panel_domain" && -f "$(site_path_for_domain "$panel_domain")" ]]; then
    site_existed=true
    cp -a "$(site_path_for_domain "$panel_domain")" "$old_site"
  fi
  if [[ -n "$panel_domain" && "$old_panel_domain" != "$panel_domain" ]] \
      && grep -Fq '# 由 CaddyCtl 管理：443 SNI 分流后的 3x-ui 面板入口。' "$(site_path_for_domain "$old_panel_domain")" 2>/dev/null; then
    old_panel_site_path="$(site_path_for_domain "$old_panel_domain")"
    old_panel_site_backup="$(mktemp)" || { rm -f "$old_caddy" "$old_state" "$old_site"; return 1; }
    cp -a "$old_panel_site_path" "$old_panel_site_backup" || { rm -f "$old_caddy" "$old_state" "$old_site" "$old_panel_site_backup"; return 1; }
    backup_file "$old_panel_site_path" "${old_panel_domain}.caddy-before-layer4-rename"
    rm -f -- "$old_panel_site_path"
  fi
  if [[ -n "$panel_domain" ]] && ! write_caddy_l4_panel_site "$panel_domain" "$panel_host" "$panel_port" >/dev/null; then
    [[ -z "$old_panel_site_backup" ]] || install -m 0644 "$old_panel_site_backup" "$old_panel_site_path"
    rm -f "$old_caddy" "$old_state" "$old_site" "$old_panel_site_backup"
    return 1
  fi
  write_caddy_l4_block "$panel_domain" "$( [[ -n "$panel_domain" ]] && printf '%s:%s' "$(format_upstream_host "$panel_host")" "$panel_port" )" || {
    cp -a "$old_caddy" "$CADDYFILE"
    cp -a "$old_state" "$CADDY_L4_STATE_FILE"
    if [[ -n "$panel_domain" ]]; then restore_caddy_l4_panel_site "$panel_domain" "$site_existed" "$old_site"; fi
    [[ -z "$old_panel_site_backup" ]] || install -m 0644 "$old_panel_site_backup" "$old_panel_site_path"
    rm -f "$old_caddy" "$old_state" "$old_site" "$old_panel_site_backup"
    return 1
  }
  runtime="$(caddy_runtime_binary)"
  if ! validate_caddy_config "$runtime" || ! systemctl restart caddy; then
    error "新映射校验或重启失败，恢复之前配置。"
    cp -a "$old_caddy" "$CADDYFILE"
    cp -a "$old_state" "$CADDY_L4_STATE_FILE"
    if [[ -n "$panel_domain" ]]; then restore_caddy_l4_panel_site "$panel_domain" "$site_existed" "$old_site"; fi
    [[ -z "$old_panel_site_backup" ]] || install -m 0644 "$old_panel_site_backup" "$old_panel_site_path"
    systemctl restart caddy >/dev/null 2>&1 || true
    rm -f "$old_caddy" "$old_state" "$old_site" "$old_panel_site_backup"
    return 1
  fi
  rm -f "$old_caddy" "$old_site" "$old_state" "$old_panel_site_backup"
  success "443 SNI 分流配置已应用。"
}

print_caddy_l4_state() {
  local type name host port count
  if [[ ! -r "$CADDY_L4_STATE_FILE" ]]; then
    warn "未找到复用状态文件，请检查 $CADDY_L4_STATE_FILE。"
    return 1
  fi
  if state_has_panel; then
    printf '\n面板入口（HTTPS → HTTP）：\n'
    while IFS=$'\t' read -r type name host port; do
      [[ "$type" == P ]] && printf '  https://%s -> http://%s:%s\n' "$name" "$(format_upstream_host "$host")" "$port"
    done <"$CADDY_L4_STATE_FILE"
  else
    printf '\n面板入口：未配置（当前仅使用 Reality 映射）\n'
  fi
  count="$(awk -F '\t' '$1 == "R" {n++} END {print n+0}' "$CADDY_L4_STATE_FILE")"
  printf '\nReality SNI 映射（%s 个，公网 TCP 443）：\n' "$count"
  while IFS=$'\t' read -r type name host port; do
    [[ "$type" == R ]] || continue
    printf '  - %s -> %s:%s\n' "$name" "$(format_upstream_host "$host")" "$port"
  done <"$CADDY_L4_STATE_FILE"
  if ((count == 0)); then
    printf '  暂无映射，可在“管理 Reality 映射”中添加。\n'
  fi
}

show_caddy_l4_state() {
  if ! caddy_l4_enabled; then
    warn "443 SNI 分流当前未启用。"
    return 0
  fi
  print_caddy_l4_state
}

show_caddy_l4_saved_state() {
  if [[ ! -f "$CADDY_L4_STATE_FILE" ]]; then
    return 1
  fi
  printf '\n已保存配置（当前未使用）：\n'
  print_caddy_l4_state
}

draw_caddy_l4_header() {
  local title="$1" active l4_color panel_color reality_color l4_text panel_text reality_text
  if [[ -t 1 ]]; then clear 2>/dev/null || true; fi
  printf '%s============================================%s\n' "$BLUE" "$RESET"
  printf '%s  %s%s\n' "$BOLD" "$title" "$RESET"
  printf '%s============================================%s\n' "$BLUE" "$RESET"
  active="$(service_value is-active)"
  case "$active" in
    active) active='运行中' ;;
    inactive) active='未运行' ;;
    failed) active='启动失败' ;;
    *) active="${active:-未知}" ;;
  esac
  if caddy_l4_enabled; then
    l4_text='已启用'; l4_color="$GREEN"
    if state_has_panel; then panel_text='已启用'; panel_color="$GREEN"; else panel_text='未启用'; panel_color="$RED"; fi
    if state_has_reality; then reality_text='已启用'; reality_color="$GREEN"; else reality_text='未启用'; reality_color="$RED"; fi
  elif [[ -f "$CADDY_L4_STATE_FILE" ]]; then
    l4_text='未启用（配置已保存）'; l4_color="$YELLOW"
    if state_has_panel; then panel_text='已保存'; panel_color="$YELLOW"; else panel_text='未配置'; panel_color="$RED"; fi
    if state_has_reality; then reality_text='已保存'; reality_color="$YELLOW"; else reality_text='未配置'; reality_color="$RED"; fi
  else
    l4_text='未配置'; l4_color="$RED"
    panel_text='未配置'; panel_color="$RED"
    reality_text='未配置'; reality_color="$RED"
  fi
  printf '443 复用：%s%s%s | Caddy：%s | 面板映射：%s%s%s | Reality 映射：%s%s%s\n' \
    "$l4_color" "$l4_text" "$RESET" "$active" \
    "$panel_color" "$panel_text" "$RESET" \
    "$reality_color" "$reality_text" "$RESET"
}

manage_caddy_l4_reality() {
  local action
  [[ -f "$CADDY_L4_STATE_FILE" ]] || { error "请先初始化 443 端口复用。"; return 1; }
  while true; do
    draw_caddy_l4_header 'Reality 映射管理'
    show_caddy_l4_state
    printf '\n%s--------------------------------------------%s\n' "$BLUE" "$RESET"
    printf '  1. 添加 Reality 映射\n'
    printf '  2. 修改 Reality 映射\n'
    printf '  3. 删除 Reality 映射\n'
    printf '  0. 返回 443 端口复用菜单\n'
    printf '%s--------------------------------------------%s\n' "$BLUE" "$RESET"
    printf '提示：SNI 填写 Xray Reality 的 serverName。\n'
    read -r -p '请选择操作 [0-3]：' action || return 0
    case "$action" in
      1|2|3) edit_caddy_l4_reality "$action"; pause_menu 'Reality 映射菜单' ;;
      0) return 0 ;;
      *) error '无效选项，请输入 0-3。'; pause_menu 'Reality 映射菜单' ;;
    esac
  done
}

edit_caddy_l4_reality() {
  local action="$1" sni host port tmp existing_type existing_sni existing_host existing_port choice index=0 state_backup
  local -a rows=()
  [[ -f "$CADDY_L4_STATE_FILE" ]] || { error "请先初始化 443 端口复用。"; return 1; }
  printf '\n'
  case "$action" in
    1)
      printf '%s添加 Reality 映射%s\n' "$BOLD" "$RESET"
      read -r -p 'Reality serverName（SNI）：' sni
      sni="${sni,,}"
      is_valid_domain "$sni" || { error 'SNI 域名格式不正确。'; return 1; }
      [[ "$sni" != "$(awk -F '\t' '$1=="P"{print $2;exit}' "$CADDY_L4_STATE_FILE")" ]] || { error 'SNI 与面板域名冲突。'; return 1; }
      if awk -F '\t' -v s="$sni" '$1=="R" && $2==s {found=1} END{exit !found}' "$CADDY_L4_STATE_FILE"; then
        error '该 SNI 已存在；相同 SNI 不能映射到多个不同端口。'
        return 1
      fi
      read -r -p 'Xray Reality 后端地址 [127.0.0.1]：' host; host="${host:-127.0.0.1}"; host="${host#[}"; host="${host%]}"
      is_valid_upstream_host "$host" || { error '后端地址格式不正确。'; return 1; }
      read -r -p 'Xray Reality 高位端口：' port
      is_valid_port "$port" && [[ "$port" != 443 ]] || { error '请输入 1-65535 且非 443 的端口。'; return 1; }
      state_backup="$(mktemp)" || return 1
      cp -a "$CADDY_L4_STATE_FILE" "$state_backup" || { rm -f "$state_backup"; return 1; }
      printf 'R\t%s\t%s\t%s\n' "$sni" "$host" "$port" >>"$CADDY_L4_STATE_FILE"
      if ! apply_caddy_l4_state; then cp -a "$state_backup" "$CADDY_L4_STATE_FILE"; rm -f "$state_backup"; return 1; fi
      rm -f "$state_backup"
      ;;
    2|3)
      [[ "$action" == 2 ]] && printf '选择要修改的映射：\n' || printf '选择要删除的映射：\n'
      while IFS=$'\t' read -r existing_type existing_sni existing_host existing_port; do
        [[ "$existing_type" == R ]] || continue
        ((index+=1)); rows+=("$existing_sni|$existing_host|$existing_port")
        printf '  [%d] %s -> %s:%s\n' "$index" "$existing_sni" "$(format_upstream_host "$existing_host")" "$existing_port"
      done <"$CADDY_L4_STATE_FILE"
      ((${#rows[@]} > 0)) || { warn '暂无可管理的 Reality 映射，请先添加。'; return 0; }
      printf '  [0] 取消\n'
      read -r -p "请选择映射编号 [0-${#rows[@]}]：" choice || return 0
      [[ "$choice" == 0 ]] && return 0
      [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#rows[@]})) || { error '无效编号。'; return 1; }
      IFS='|' read -r sni host port <<<"${rows[$((choice-1))]}"
      if [[ "$action" == 2 ]]; then
        local old_sni="$sni"
        read -r -p "新的 Reality serverName [${sni}]：" sni; sni="${sni:-$old_sni}"; sni="${sni,,}"
        is_valid_domain "$sni" || { error 'SNI 域名格式不正确。'; return 1; }
        [[ "$sni" != "$(awk -F '\t' '$1=="P"{print $2;exit}' "$CADDY_L4_STATE_FILE")" ]] || { error 'SNI 与面板域名冲突。'; return 1; }
        if [[ "$sni" != "$old_sni" ]] && awk -F '\t' -v s="$sni" '$1=="R" && $2==s {found=1} END{exit !found}' "$CADDY_L4_STATE_FILE"; then
          error '该 SNI 已被其他入站使用。'; return 1
        fi
        read -r -p "Xray 后端地址 [${host}]：" host; host="${host:-$(awk -F '|' '{print $2}' <<<"${rows[$((choice-1))]}")}"; host="${host#[}"; host="${host%]}"
        is_valid_upstream_host "$host" || { error '后端地址格式不正确。'; return 1; }
        read -r -p "Xray 高位端口 [${port}]：" port; port="${port:-$(awk -F '|' '{print $3}' <<<"${rows[$((choice-1))]}")}";
        is_valid_port "$port" && [[ "$port" != 443 ]] || { error '请输入 1-65535 且非 443 的端口。'; return 1; }
      else
        confirm_action "确认删除 ${sni} -> ${host}:${port}？" || return 0
      fi
      state_backup="$(mktemp)" || return 1
      cp -a "$CADDY_L4_STATE_FILE" "$state_backup" || { rm -f "$state_backup"; return 1; }
      tmp="$(mktemp)" || return 1
      if [[ "$action" == 2 ]]; then
        awk -F '\t' -v old="$old_sni" -v s="$sni" -v h="$host" -v p="$port" 'BEGIN{OFS="\t"} $1=="R" && $2==old {$2=s;$3=h;$4=p} {print}' "$CADDY_L4_STATE_FILE" >"$tmp"
      else
        awk -F '\t' -v s="$sni" '!($1=="R" && $2==s)' "$CADDY_L4_STATE_FILE" >"$tmp"
      fi
      cat "$tmp" >"$CADDY_L4_STATE_FILE"; rm -f "$tmp"
      if ! apply_caddy_l4_state; then cp -a "$state_backup" "$CADDY_L4_STATE_FILE"; rm -f "$state_backup"; return 1; fi
      rm -f "$state_backup"
      ;;
    0) return 0 ;;
    *) error '无效选项。'; return 1 ;;
  esac
}

add_caddy_l4_panel() {
  local domain host port state_backup
  [[ -f "$CADDY_L4_STATE_FILE" ]] || { error "请先初始化 443 映射。"; return 1; }
  state_has_panel && { error "面板映射已存在，请选择修改面板入口。"; return 1; }
  printf '\n%s添加面板映射%s\n' "$BOLD" "$RESET"
  read -r -p '3x-ui 面板域名：' domain; domain="${domain,,}"
  is_valid_domain "$domain" || { error '域名格式不正确。'; return 1; }
  if awk -F '\t' -v d="$domain" '$1=="R" && $2==d {found=1} END{exit !found}' "$CADDY_L4_STATE_FILE"; then
    error '面板域名与 Reality SNI 冲突。'; return 1
  fi
  read -r -p '3x-ui 面板后端地址 [127.0.0.1]：' host; host="${host:-127.0.0.1}"; host="${host#[}"; host="${host%]}"
  is_valid_upstream_host "$host" || { error '后端地址格式不正确。'; return 1; }
  read -r -p '3x-ui 面板 HTTP 端口：' port
  is_valid_port "$port" || { error '端口格式不正确。'; return 1; }
  state_backup="$(mktemp)" || return 1
  cp -a "$CADDY_L4_STATE_FILE" "$state_backup" || { rm -f "$state_backup"; return 1; }
  printf 'P\t%s\t%s\t%s\n' "$domain" "$host" "$port" >>"$CADDY_L4_STATE_FILE"
  if ! apply_caddy_l4_state; then
    cp -a "$state_backup" "$CADDY_L4_STATE_FILE"; rm -f "$state_backup"; return 1
  fi
  rm -f "$state_backup"
}

edit_caddy_l4_panel() {
  local old_domain host port domain tmp state_backup
  IFS=$'\t' read -r old_domain host port <<<"$(read_caddy_l4_panel)"
  printf '\n%s修改面板入口%s\n' "$BOLD" "$RESET"
  info '直接按 Enter 保留当前值；后端端口填写 3x-ui 的 HTTP 端口。'
  read -r -p "面板域名 [${old_domain}]：" domain; domain="${domain:-$old_domain}"; domain="${domain,,}"
  is_valid_domain "$domain" || { error '域名格式不正确。'; return 1; }
  read -r -p "面板 HTTP 地址 [${host}]：" host; host="${host:-$(awk -F '\t' '$1=="P"{print $3;exit}' "$CADDY_L4_STATE_FILE")}"; host="${host#[}"; host="${host%]}"
  is_valid_upstream_host "$host" || { error '后端地址格式不正确。'; return 1; }
  read -r -p "面板 HTTP 端口 [${port}]：" port; port="${port:-$(awk -F '\t' '$1=="P"{print $4;exit}' "$CADDY_L4_STATE_FILE")}";
  is_valid_port "$port" || { error '端口格式不正确。'; return 1; }
  if awk -F '\t' -v d="$domain" '$1=="R" && $2==d {found=1} END{exit !found}' "$CADDY_L4_STATE_FILE"; then
    error '面板 SNI 与 Reality SNI 冲突。'; return 1
  fi
  state_backup="$(mktemp)" || return 1
  cp -a "$CADDY_L4_STATE_FILE" "$state_backup" || { rm -f "$state_backup"; return 1; }
  tmp="$(mktemp)" || return 1
  awk -F '\t' -v d="$domain" -v h="$host" -v p="$port" 'BEGIN{OFS="\t"} $1=="P"{$2=d;$3=h;$4=p} {print}' "$CADDY_L4_STATE_FILE" >"$tmp"
  cat "$tmp" >"$CADDY_L4_STATE_FILE"; rm -f "$tmp"
  if ! apply_caddy_l4_state "$old_domain"; then cp -a "$state_backup" "$CADDY_L4_STATE_FILE"; rm -f "$state_backup"; return 1; fi
  rm -f "$state_backup"
}

enable_saved_caddy_l4() {
  local panel_domain="" panel_host="" panel_port="" target="" disabled_site="" site_state="" site_rollback=""
  local caddyfile_existed=false site_existed=false dropin_existed=false
  local snapshot_dir runtime

  [[ -f "$CADDY_L4_STATE_FILE" ]] || { error "没有找到已保存的 443 复用配置，请先初始化。"; return 1; }
  if state_has_panel; then
    IFS=$'\t' read -r panel_domain panel_host panel_port <<<"$(read_caddy_l4_panel)"
    is_valid_domain "$panel_domain" && is_valid_upstream_host "$panel_host" && is_valid_port "$panel_port" || {
      error "已保存的面板配置无效，无法重新启用。"; return 1;
    }
    target="$(site_path_for_domain "$panel_domain")"
    disabled_site="${target}${CADDY_L4_DISABLED_SITE_SUFFIX}"
    if [[ -f "$target" ]] && ! grep -Fq '# 由 CaddyCtl 管理：443 SNI 分流后的 3x-ui 面板入口。' "$target"; then
      error "面板域名已有其他站点配置，拒绝覆盖：$target"; return 1
    fi
  fi
  state_has_panel || state_has_reality || { error "保存的配置没有面板或 Reality 映射。"; return 1; }
  confirm_action "使用已保存配置重新启用 443 SNI 分流？" || { info "已取消。"; return 0; }
  install_caddy_l4_binary || return 1
  snapshot_dir="$(mktemp -d)" || return 1
  if [[ -f "$CADDYFILE" ]]; then caddyfile_existed=true; cp -a "$CADDYFILE" "${snapshot_dir}/Caddyfile" || { rm -rf -- "$snapshot_dir"; return 1; }; fi
  if [[ -n "$target" && -f "$target" ]]; then site_existed=true; cp -a "$target" "${snapshot_dir}/panel.caddy" || { rm -rf -- "$snapshot_dir"; return 1; }; fi
  if [[ -f "$CADDY_L4_SERVICE_DROPIN" ]]; then dropin_existed=true; cp -a "$CADDY_L4_SERVICE_DROPIN" "${snapshot_dir}/caddyctl-l4.conf" || { rm -rf -- "$snapshot_dir"; return 1; }; fi
  initialize_caddyfile || { rm -rf -- "$snapshot_dir"; return 1; }
  if [[ -n "$panel_domain" && -f "$disabled_site" ]] && grep -Fq '# 由 CaddyCtl 管理：443 SNI 分流后的 3x-ui 面板入口。' "$disabled_site"; then
    install -m 0644 "$disabled_site" "$target" && site_state=restored
  elif [[ -n "$panel_domain" ]]; then
    site_state="$(write_caddy_l4_panel_site "$panel_domain" "$panel_host" "$panel_port")" || site_state=""
    IFS=$'\t' read -r _ site_rollback <<<"$site_state"
  else
    site_state=ready
  fi
  if [[ -z "$site_state" ]] \
      || ! write_caddy_l4_block "$panel_domain" "${panel_domain:+$(format_upstream_host "$panel_host"):$panel_port}" \
      || ! enable_caddy_l4_service; then
    error "重新启用配置失败，正在恢复。"
    remove_caddy_l4_block >/dev/null 2>&1 || true
    disable_caddy_l4_service >/dev/null 2>&1 || true
    if [[ "$caddyfile_existed" == true ]]; then cp -a "${snapshot_dir}/Caddyfile" "$CADDYFILE"; else rm -f -- "$CADDYFILE"; fi
    if [[ "$site_existed" == true ]]; then cp -a "${snapshot_dir}/panel.caddy" "$target"; elif [[ -n "$target" ]]; then rm -f -- "$target"; fi
    if [[ "$dropin_existed" == true ]]; then install -d -m 0755 "$(dirname "$CADDY_L4_SERVICE_DROPIN")"; cp -a "${snapshot_dir}/caddyctl-l4.conf" "$CADDY_L4_SERVICE_DROPIN"; fi
    systemctl daemon-reload >/dev/null 2>&1 || true
    rm -rf -- "$snapshot_dir"; return 1
  fi
  runtime="$(caddy_runtime_binary)"
  if ! validate_caddy_config "$runtime" || ! systemctl restart caddy; then
    error "重新启用后的配置校验或重启失败，正在恢复。"
    remove_caddy_l4_block >/dev/null 2>&1 || true
    disable_caddy_l4_service >/dev/null 2>&1 || true
    if [[ "$caddyfile_existed" == true ]]; then cp -a "${snapshot_dir}/Caddyfile" "$CADDYFILE"; else rm -f -- "$CADDYFILE"; fi
    if [[ "$site_existed" == true ]]; then cp -a "${snapshot_dir}/panel.caddy" "$target"; elif [[ -n "$target" ]]; then rm -f -- "$target"; fi
    if [[ "$dropin_existed" == true ]]; then install -d -m 0755 "$(dirname "$CADDY_L4_SERVICE_DROPIN")"; cp -a "${snapshot_dir}/caddyctl-l4.conf" "$CADDY_L4_SERVICE_DROPIN"; fi
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl restart caddy >/dev/null 2>&1 || true
    rm -rf -- "$snapshot_dir"; return 1
  fi
  [[ -z "$site_rollback" ]] || rm -f -- "$site_rollback"
  [[ -z "$disabled_site" ]] || rm -f -- "$disabled_site"
  rm -rf -- "$snapshot_dir"
  success "已使用保存的配置重新启用 443 SNI 分流。"
  print_caddy_l4_state
}

install_caddy_l4_binary() {
  local package_manager build_parent build_dir temp_binary xcaddy_path

  if [[ -x "$CADDY_L4_BINARY" ]] \
      && "$CADDY_L4_BINARY" list-modules 2>/dev/null | grep -Fq 'layer4'; then
    return 0
  fi
  if install_caddy_l4_prebuilt; then
    return 0
  fi
  warn "预编译 caddy-l4 不可用，改用 Go 源码构建；这可能需要较多磁盘空间。"
  cleanup_caddy_l4_build_cache
  build_parent="$(choose_caddy_l4_build_parent)" || {
    error "找不到可用的本地构建目录。"
    return 1
  }
  check_caddy_l4_build_space "$build_parent" || return 1
  if ! command -v go >/dev/null 2>&1; then
    package_manager="$(detect_package_manager)"
    case "$package_manager" in
      apt)
        if ! DEBIAN_FRONTEND=noninteractive apt-get update \
            || ! DEBIAN_FRONTEND=noninteractive apt-get install -y golang-go; then
          apt-get clean >/dev/null 2>&1 || true
          rm -rf /var/lib/apt/lists/*
          return 1
        fi
        apt-get clean >/dev/null 2>&1 || true
        rm -rf /var/lib/apt/lists/*
        ;;
      dnf) dnf install -y golang || return 1 ;;
      *) error "未找到 Go，无法构建带 caddy-l4 的 Caddy。"; return 1 ;;
    esac
  fi
  if ! command -v go >/dev/null 2>&1; then
    error "Go 安装后仍不可用，无法构建带 caddy-l4 的 Caddy。"
    return 1
  fi
  build_dir="$(mktemp -d "${build_parent}/caddyctl-l4-build.XXXXXX")" || return 1
  trap 'rm -rf -- "$build_dir"; exit 130' INT TERM
  temp_binary="${build_dir}/caddy-l4"
  xcaddy_path="$(command -v xcaddy 2>/dev/null || true)"
  if [[ -z "$xcaddy_path" ]]; then
    info "正在临时构建 xcaddy（构建缓存仅保存在临时目录）..."
    mkdir -p "$build_dir/tmp" "$build_dir/gotmp" || {
      rm -rf -- "$build_dir"
      trap - INT TERM
      error "无法创建 Go 临时目录。"
      return 1
    }
    if ! env TMPDIR="$build_dir/tmp" GOTMPDIR="$build_dir/gotmp" GOPATH="${build_dir}/gopath" GOMODCACHE="${build_dir}/modcache" GOCACHE="${build_dir}/gocache" GOBIN="${build_dir}/bin" \
      go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest; then
      rm -rf -- "$build_dir"
      trap - INT TERM
      error "xcaddy 构建失败。"
      return 1
    fi
    xcaddy_path="${build_dir}/bin/xcaddy"
  fi
  if [[ ! -x "$xcaddy_path" ]]; then
    rm -rf -- "$build_dir"
    trap - INT TERM
    error "xcaddy 不可用。"
    return 1
  fi
  info "正在构建带 caddy-l4 的 Caddy，这可能需要几分钟..."
  mkdir -p "$build_dir/tmp" "$build_dir/gotmp" || {
    rm -rf -- "$build_dir"
    trap - INT TERM
    error "无法创建 Go 临时目录。"
    return 1
  }
  if ! env TMPDIR="$build_dir/tmp" GOTMPDIR="$build_dir/gotmp" GOPATH="${build_dir}/gopath" GOMODCACHE="${build_dir}/modcache" GOCACHE="${build_dir}/gocache" \
      "$xcaddy_path" build --output "$temp_binary" --with github.com/mholt/caddy-l4; then
    rm -rf -- "$build_dir"
    trap - INT TERM
    error "caddy-l4 构建失败。"
    return 1
  fi
  if ! "$temp_binary" list-modules 2>/dev/null | grep -Fq 'layer4'; then
    rm -rf -- "$build_dir"
    trap - INT TERM
    error "构建结果未包含 layer4 模块。"
    return 1
  fi
  if ! install -m 0755 "$temp_binary" "$CADDY_L4_BINARY"; then
    rm -rf -- "$build_dir"
    trap - INT TERM
    return 1
  fi
  rm -rf -- "$build_dir"
  trap - INT TERM
}

enable_caddy_l4_service() {
  install -d -m 0755 "$(dirname "$CADDY_L4_SERVICE_DROPIN")"
  cat >"$CADDY_L4_SERVICE_DROPIN" <<EOF
[Service]
ExecStart=
ExecStart=$CADDY_L4_BINARY run --environ --config $CADDYFILE --adapter caddyfile
EOF
  systemctl daemon-reload
}

disable_caddy_l4_service() {
  rm -f -- "$CADDY_L4_SERVICE_DROPIN"
  systemctl daemon-reload
}

configure_caddy_l4() {
  local mode panel_domain="" panel_host="" panel_port="" reality_sni="" reality_host="" reality_port="" reality_backend=""
  local site_state had_existing rollback_file snapshot_dir caddyfile_existed=false state_existed=false dropin_existed=false
  local runtime

  if [[ ! -x "$REAL_CADDY" ]]; then
    error "请先安装 Caddy。"
    return 1
  fi
  printf '\n%s443 端口复用（caddy-l4 SNI 分流）%s\n' "$BOLD" "$RESET"
  printf '请选择要启用的映射：\n'
  printf '  1. 面板映射 + Reality 映射\n'
  printf '  2. 仅 Reality 映射（适合 Realm 中转）\n'
  printf '  3. 仅面板映射\n'
  printf '  0. 返回\n'
  read -r -p '请选择 [0-3]：' mode || return 0
  [[ "$mode" == 0 ]] && return 0
  [[ "$mode" =~ ^[123]$ ]] || { error '无效选项，请输入 0-3。'; return 1; }

  if [[ "$mode" != 2 ]]; then
    info "面板端口按 HTTP 处理；caddy-l4 会终止面板域名的 TLS，再将 HTTP 转发到 3x-ui。"
    read -r -p "3x-ui 面板域名：" panel_domain; panel_domain="${panel_domain,,}"
    is_valid_domain "$panel_domain" || { error "面板域名格式不正确。"; return 1; }
    read -r -p "3x-ui 面板后端地址 [127.0.0.1]：" panel_host; panel_host="${panel_host:-127.0.0.1}"; panel_host="${panel_host#[}"; panel_host="${panel_host%]}"
    is_valid_upstream_host "$panel_host" || { error "面板后端地址格式不正确。"; return 1; }
    read -r -p "3x-ui 面板 HTTP 端口：" panel_port
    is_valid_port "$panel_port" || { error "面板端口必须是 1-65535 之间的整数。"; return 1; }
  fi
  if [[ "$mode" != 3 ]]; then
    read -r -p "Reality serverName（SNI）：" reality_sni; reality_sni="${reality_sni,,}"
    is_valid_domain "$reality_sni" || { error "Reality SNI 必须是有效域名。"; return 1; }
    [[ -z "$panel_domain" || "$reality_sni" != "$panel_domain" ]] || { error "面板域名和 Reality SNI 不能相同。"; return 1; }
    read -r -p "Xray Reality 后端地址（可填写 Realm 本机监听地址）[127.0.0.1]：" reality_host
    reality_host="${reality_host:-127.0.0.1}"; reality_host="${reality_host#[}"; reality_host="${reality_host%]}"
    is_valid_upstream_host "$reality_host" || { error "Reality 后端地址格式不正确。"; return 1; }
    read -r -p "Xray/Realm Reality 后端端口：" reality_port
    is_valid_port "$reality_port" || { error "Reality 端口必须是 1-65535 之间的整数。"; return 1; }
    [[ "$reality_port" != 443 ]] || { error "Reality 后端端口不能使用 443，否则会与 Caddy 冲突。"; return 1; }
    reality_backend="$(format_upstream_host "$reality_host"):${reality_port}"
  fi
  if ! confirm_action "确认启用 443 SNI 分流（面板：${panel_domain:-未配置}；Reality：${reality_sni:-未配置}）？"; then
    info "已取消。"
    return 0
  fi
  if ! install_caddy_l4_binary; then return 1; fi
  snapshot_dir="$(mktemp -d)" || return 1
  if [[ -f "$CADDYFILE" ]]; then caddyfile_existed=true; cp -a "$CADDYFILE" "${snapshot_dir}/Caddyfile" || { rm -rf -- "$snapshot_dir"; return 1; }; fi
  if [[ -f "$CADDY_L4_STATE_FILE" ]]; then state_existed=true; cp -a "$CADDY_L4_STATE_FILE" "${snapshot_dir}/state.tsv" || { rm -rf -- "$snapshot_dir"; return 1; }; fi
  if [[ -f "$CADDY_L4_SERVICE_DROPIN" ]]; then dropin_existed=true; cp -a "$CADDY_L4_SERVICE_DROPIN" "${snapshot_dir}/caddyctl-l4.conf" || { rm -rf -- "$snapshot_dir"; return 1; }; fi
  initialize_caddyfile || { rm -rf -- "$snapshot_dir"; return 1; }
  : >"$CADDY_L4_STATE_FILE"
  [[ -z "$panel_domain" ]] || printf 'P\t%s\t%s\t%s\n' "$panel_domain" "$panel_host" "$panel_port" >>"$CADDY_L4_STATE_FILE"
  [[ -z "$reality_sni" ]] || printf 'R\t%s\t%s\t%s\n' "$reality_sni" "$reality_host" "$reality_port" >>"$CADDY_L4_STATE_FILE"
  chmod 0600 "$CADDY_L4_STATE_FILE"
  if [[ -n "$panel_domain" ]]; then
    site_state="$(write_caddy_l4_panel_site "$panel_domain" "$panel_host" "$panel_port")" || {
      if [[ "$state_existed" == true ]]; then cp -a "${snapshot_dir}/state.tsv" "$CADDY_L4_STATE_FILE"; else rm -f -- "$CADDY_L4_STATE_FILE"; fi
      if [[ "$caddyfile_existed" == true ]]; then cp -a "${snapshot_dir}/Caddyfile" "$CADDYFILE"; else rm -f -- "$CADDYFILE"; fi
      rm -rf -- "$snapshot_dir"; return 1
    }
    IFS=$'\t' read -r had_existing rollback_file <<< "$site_state"
  else
    had_existing=false
  fi
  if ! write_caddy_l4_block "$panel_domain" "${panel_domain:+$(format_upstream_host "$panel_host"):$panel_port}"; then
    [[ -z "$panel_domain" ]] || restore_caddy_l4_panel_site "$panel_domain" "$had_existing" "$rollback_file"
    if [[ "$state_existed" == true ]]; then cp -a "${snapshot_dir}/state.tsv" "$CADDY_L4_STATE_FILE"; else rm -f -- "$CADDY_L4_STATE_FILE"; fi
    if [[ "$caddyfile_existed" == true ]]; then cp -a "${snapshot_dir}/Caddyfile" "$CADDYFILE"; else rm -f -- "$CADDYFILE"; fi
    rm -rf -- "$snapshot_dir"; return 1
  fi
  enable_caddy_l4_service || {
    remove_caddy_l4_block || true
    [[ -z "$panel_domain" ]] || restore_caddy_l4_panel_site "$panel_domain" "$had_existing" "$rollback_file"
    if [[ "$dropin_existed" == true ]]; then cp -a "${snapshot_dir}/caddyctl-l4.conf" "$CADDY_L4_SERVICE_DROPIN"; else rm -f -- "$CADDY_L4_SERVICE_DROPIN"; fi
    if [[ "$state_existed" == true ]]; then cp -a "${snapshot_dir}/state.tsv" "$CADDY_L4_STATE_FILE"; else rm -f -- "$CADDY_L4_STATE_FILE"; fi
    if [[ "$caddyfile_existed" == true ]]; then cp -a "${snapshot_dir}/Caddyfile" "$CADDYFILE"; else rm -f -- "$CADDYFILE"; fi
    systemctl daemon-reload >/dev/null 2>&1 || true
    rm -rf -- "$snapshot_dir"; return 1
  }
  runtime="$(caddy_runtime_binary)"
  if ! validate_caddy_config "$runtime" || ! systemctl restart caddy; then
    error "caddy-l4 配置校验或 Caddy 重启失败，正在恢复。"
    disable_caddy_l4_service
    remove_caddy_l4_block || true
    [[ -z "$panel_domain" ]] || restore_caddy_l4_panel_site "$panel_domain" "$had_existing" "$rollback_file"
    if [[ "$dropin_existed" == true ]]; then install -d -m 0755 "$(dirname "$CADDY_L4_SERVICE_DROPIN")"; cp -a "${snapshot_dir}/caddyctl-l4.conf" "$CADDY_L4_SERVICE_DROPIN"; fi
    if [[ "$state_existed" == true ]]; then cp -a "${snapshot_dir}/state.tsv" "$CADDY_L4_STATE_FILE"; else rm -f -- "$CADDY_L4_STATE_FILE"; fi
    if [[ "$caddyfile_existed" == true ]]; then cp -a "${snapshot_dir}/Caddyfile" "$CADDYFILE"; else rm -f -- "$CADDYFILE"; fi
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl restart caddy >/dev/null 2>&1 || true
    rm -rf -- "$snapshot_dir"; return 1
  fi
  rm -rf -- "$snapshot_dir"
  success "443 SNI 分流已启用。"
  [[ -z "$panel_domain" ]] || info "面板：https://${panel_domain}:443 -> caddy-l4 TLS 终止 -> HTTP ${panel_host}:${panel_port}"
  [[ -z "$reality_sni" ]] || info "Reality：SNI ${reality_sni}:443 -> ${reality_host}:${reality_port}"
  [[ "$mode" != 2 ]] || info "当前为仅 Reality 映射模式，适合将后端端口填写为 Realm 的本机监听端口。"
  warn "请确保 Xray/Realm 后端仅监听回环地址或受限内网地址，避免绕过 Caddy 直接暴露。"
}

disable_caddy_l4() {
  local runtime temp_dir site_backup_dir panel_site disabled_panel_site="" had_dropin=false temp_file
  if ! caddy_l4_enabled; then
    warn "当前未检测到 CaddyCtl 管理的 caddy-l4 配置。"
    return 0
  fi
  confirm_action "确认停用 443 SNI 分流并恢复官方 Caddy 服务（保留面板和 Reality 设置）？" || { info "已取消。"; return 0; }
  temp_dir="$(mktemp -d)" || return 1
  site_backup_dir="${temp_dir}/sites"
  mkdir -p "$site_backup_dir"
  cp -a "$CADDYFILE" "${temp_dir}/Caddyfile" || { rm -rf -- "$temp_dir"; return 1; }
  if [[ -f "$CADDY_L4_SERVICE_DROPIN" ]]; then
    had_dropin=true
    cp -a "$CADDY_L4_SERVICE_DROPIN" "${temp_dir}/caddyctl-l4.conf" || { rm -rf -- "$temp_dir"; return 1; }
  fi
  for panel_site in "$SITES_DIR"/*.caddy; do
    [[ -f "$panel_site" ]] || continue
    if grep -Fq '# 由 CaddyCtl 管理：443 SNI 分流后的 3x-ui 面板入口。' "$panel_site"; then
      cp -a -- "$panel_site" "$site_backup_dir/$(basename "$panel_site")" || { rm -rf -- "$temp_dir"; return 1; }
      disabled_panel_site="${panel_site}${CADDY_L4_DISABLED_SITE_SUFFIX}"
      backup_file "$panel_site" "$(basename "$panel_site").before-layer4-disable" \
        && cp -a -- "$panel_site" "$disabled_panel_site" || { rm -rf -- "$temp_dir"; return 1; }
    fi
  done
  temp_file="${temp_dir}/Caddyfile.new"
  awk -v begin="$CADDY_L4_MARKER_BEGIN" -v end="$CADDY_L4_MARKER_END" '$0 == begin {skip=1; next} $0 == end {skip=0; next} !skip {print}' "$CADDYFILE" >"$temp_file" || { rm -rf -- "$temp_dir"; return 1; }
  backup_file "$CADDYFILE" "Caddyfile-before-layer4-disable"
  preserve_caddyfile_permissions "$temp_file" || { rm -rf -- "$temp_dir"; return 1; }
  mv -f -- "$temp_file" "$CADDYFILE" || { rm -rf -- "$temp_dir"; return 1; }
  for panel_site in "$SITES_DIR"/*.caddy; do
    [[ -f "$panel_site" ]] || continue
    if grep -Fq '# 由 CaddyCtl 管理：443 SNI 分流后的 3x-ui 面板入口。' "$panel_site"; then
      rm -f -- "$panel_site"
    fi
  done
  disable_caddy_l4_service
  runtime="$REAL_CADDY"
  if ! validate_caddy_config "$runtime" || ! systemctl restart caddy; then
    error "关闭复用后的校验或重启失败，正在恢复原配置。"
    cp -a "${temp_dir}/Caddyfile" "$CADDYFILE"
    if [[ "$had_dropin" == true ]]; then
      install -d -m 0755 "$(dirname "$CADDY_L4_SERVICE_DROPIN")"
      cp -a "${temp_dir}/caddyctl-l4.conf" "$CADDY_L4_SERVICE_DROPIN"
    fi
    cp -a "$site_backup_dir"/. "$SITES_DIR"/ 2>/dev/null || true
    [[ -z "$disabled_panel_site" ]] || rm -f -- "$disabled_panel_site"
    systemctl daemon-reload
    systemctl restart caddy >/dev/null 2>&1 || true
    rm -rf -- "$temp_dir"
    return 1
  fi
  rm -rf -- "$temp_dir"
  success "443 SNI 分流已关闭，Caddy 已恢复使用官方二进制。"
  info "原面板与 Reality 映射已保留在 $CADDY_L4_STATE_FILE。面板站点已移至 ${disabled_panel_site:-站点目录}，当前不参与 Caddy 配置。"
}

caddy_l4_menu() {
  local choice
  while true; do
    draw_caddy_l4_header '443 端口复用管理'
    if caddy_l4_enabled; then
      show_caddy_l4_state
      printf '\n%s--------------------------------------------%s\n' "$BLUE" "$RESET"
      printf '操作菜单：\n'
      printf '  1. 管理 Reality 映射（添加 / 修改 / 删除）\n'
      if state_has_panel; then
        printf '  2. 修改面板入口（域名 / HTTP 后端）\n'
      else
        printf '  2. 配置面板映射（当前未启用）\n'
      fi
      printf '  3. 校验并应用当前配置\n'
      printf '  4. 关闭 443 端口复用\n'
      printf '  0. 返回主菜单\n'
      printf '%s--------------------------------------------%s\n' "$BLUE" "$RESET"
      read -r -p '请选择操作 [0-4]：' choice || return 0
      case "$choice" in
        1) manage_caddy_l4_reality ;;
        2) if state_has_panel; then edit_caddy_l4_panel; else add_caddy_l4_panel; fi; pause_menu '443 端口复用菜单' ;;
        3) apply_caddy_l4_state; pause_menu '443 端口复用菜单' ;;
        4) disable_caddy_l4; pause_menu '443 端口复用菜单' ;;
        0) return 0 ;;
        *) error '无效选项，请输入 0-4。'; pause_menu '443 端口复用菜单' ;;
      esac
    else
      if [[ -f "$CADDY_L4_STATE_FILE" ]]; then
        show_caddy_l4_saved_state
        printf '\n说明：当前复用未使用，保存的映射可重新启用。\n'
        printf '\n%s--------------------------------------------%s\n' "$BLUE" "$RESET"
        printf '  1. 使用已保存配置重新启用\n'
        printf '  2. 重新初始化映射\n'
        printf '  0. 返回主菜单\n'
        printf '%s--------------------------------------------%s\n' "$BLUE" "$RESET"
        read -r -p '请选择操作 [0-2]：' choice || return 0
        case "$choice" in
          1) enable_saved_caddy_l4; pause_menu '443 端口复用菜单' ;;
          2) configure_caddy_l4; pause_menu '443 端口复用菜单' ;;
          0) return 0 ;;
          *) error '无效选项，请输入 0-2。'; pause_menu '443 端口复用菜单' ;;
        esac
        continue
      fi
      printf '\n说明：可分别启用面板映射和 Reality 映射，共用公网 TCP 443。\n'
      printf '      仅 Reality 映射适合搭配 Realm 做中转。\n'
      printf '\n%s--------------------------------------------%s\n' "$BLUE" "$RESET"
      printf '  1. 初始化 443 映射\n'
      printf '  0. 返回主菜单\n'
      printf '%s--------------------------------------------%s\n' "$BLUE" "$RESET"
      read -r -p '请选择操作 [0-1]：' choice || return 0
      case "$choice" in
        1) configure_caddy_l4; pause_menu '443 端口复用菜单' ;;
        0) return 0 ;;
        *) error '无效选项，请输入 0-1。'; pause_menu '443 端口复用菜单' ;;
      esac
    fi
  done
}

install_caddy_apt() {
  local apt_ready=0

  if apt-get update; then
    apt_ready=1
  else
    warn "apt 软件源更新失败，将尝试 GitHub Release 安装 Caddy。"
  fi

  if ! DEBIAN_FRONTEND=noninteractive apt-get install -y \
      ca-certificates curl debian-keyring debian-archive-keyring \
      apt-transport-https gnupg; then
    warn "apt 依赖安装失败，继续尝试 GitHub Release。"
  fi

  if [[ $apt_ready -eq 1 ]] && command -v curl >/dev/null 2>&1 \
      && command -v gpg >/dev/null 2>&1; then
    install -d -m 0755 /usr/share/keyrings
    if curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg; then
      chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg
      if curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
          -o /etc/apt/sources.list.d/caddy-stable.list; then
        chmod o+r /etc/apt/sources.list.d/caddy-stable.list
        if apt-get update \
            && DEBIAN_FRONTEND=noninteractive apt-get install -y caddy; then
          return 0
        fi
      fi
    fi
    warn "Caddy 官方 apt 软件源不可用，将改用 GitHub Release。"
  fi

  disable_caddy_apt_source
  install_caddy_github_deb
}

disable_caddy_apt_source() {
  local source_file="/etc/apt/sources.list.d/caddy-stable.list"

  if [[ -f "$source_file" ]]; then
    mv -- "$source_file" "${source_file}.disabled"
    warn "已停用不可用的 Caddy apt 软件源：${source_file}"
  fi
}

caddy_github_arch() {
  case "$(dpkg --print-architecture 2>/dev/null || true)" in
    amd64) printf 'amd64\n' ;;
    arm64) printf 'arm64\n' ;;
    armhf) printf 'armv7\n' ;;
    armel) printf 'armv6\n' ;;
    ppc64el) printf 'ppc64le\n' ;;
    riscv64) printf 'riscv64\n' ;;
    s390x) printf 's390x\n' ;;
    *)
      error "GitHub Release 暂不提供当前 Debian 架构的 Caddy 安装包。"
      return 1
      ;;
  esac
}

install_caddy_github_deb() {
  local architecture version package_name temp_dir checksum_line

  if ! command -v dpkg >/dev/null 2>&1; then
    error "未检测到 dpkg，无法安装 GitHub 提供的 Debian 软件包。"
    return 1
  fi
  if ! command -v sha512sum >/dev/null 2>&1; then
    error "未检测到 sha512sum，无法校验 Caddy 安装包。"
    return 1
  fi
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    error "需要 curl 或 wget 才能从 GitHub 下载 Caddy。"
    return 1
  fi

  architecture="$(caddy_github_arch)" || return 1
  temp_dir="$(mktemp -d)" || {
    error "无法创建 Caddy 下载临时目录。"
    return 1
  }

  version="$(download_url_to_file "$CADDY_GITHUB_API" - 2>/dev/null \
    | sed -n 's/.*"tag_name":[[:space:]]*"v\([^"]*\)".*/\1/p' | head -n 1)"
  if [[ -z "$version" ]]; then
    rm -rf -- "$temp_dir"
    error "无法从 GitHub 获取 Caddy 最新稳定版本。"
    return 1
  fi

  package_name="caddy_${version}_linux_${architecture}.deb"
  info "正在从 GitHub 下载 Caddy ${version}（${architecture}）..."
  if ! download_url_to_file \
      "${CADDY_GITHUB_RELEASE}/v${version}/${package_name}" \
      "${temp_dir}/${package_name}" \
      || ! download_url_to_file \
      "${CADDY_GITHUB_RELEASE}/v${version}/caddy_${version}_checksums.txt" \
      "${temp_dir}/checksums.txt"; then
    rm -rf -- "$temp_dir"
    error "无法下载 Caddy GitHub Release。"
    return 1
  fi

  checksum_line="$(awk -v name="$package_name" '$2 == name { print; exit }' \
    "${temp_dir}/checksums.txt")"
  if [[ -z "$checksum_line" ]] \
      || ! (cd "$temp_dir" && printf '%s\n' "$checksum_line" | sha512sum -c -); then
    rm -rf -- "$temp_dir"
    error "Caddy 安装包 SHA-512 校验失败，已停止安装。"
    return 1
  fi

  if ! dpkg -i "${temp_dir}/${package_name}"; then
    if ! DEBIAN_FRONTEND=noninteractive apt-get -f install -y; then
      rm -rf -- "$temp_dir"
      error "Caddy 软件包安装失败，依赖修复也未成功。"
      return 1
    fi
  fi
  rm -rf -- "$temp_dir"
  success "已从 GitHub Release 安装 Caddy ${version}。"
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

  initialize_caddyfile || return 1
  install_manager_command || return 1

  if ! validate_caddy_config; then
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
  local package_manager update_succeeded=0

  if [[ ! -x "$REAL_CADDY" ]]; then
    warn "Caddy 尚未安装。"
    return 1
  fi

  backup_file "$CADDYFILE" "Caddyfile-before-update"
  package_manager="$(detect_package_manager)"
  info "更新前版本：$($REAL_CADDY version 2>/dev/null || printf '未知')"

  case "$package_manager" in
    apt)
      if apt-get update \
          && DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade caddy; then
        update_succeeded=1
      else
        warn "apt 更新 Caddy 失败，将尝试从 GitHub Release 更新。"
        disable_caddy_apt_source
        install_caddy_github_deb && update_succeeded=1
      fi
      ;;
    dnf)
      if dnf upgrade -y caddy; then
        update_succeeded=1
      fi
      ;;
    *)
      error "无法识别包管理器。"
      return 1
      ;;
  esac

  if [[ $update_succeeded -ne 1 ]]; then
    error "Caddy 更新失败。"
    return 1
  fi

  if caddy_l4_enabled; then
    info "检测到已启用 caddy-l4，正在确保自定义 Caddy 二进制仍可用..."
    install_caddy_l4_binary || {
      error "caddy-l4 二进制准备失败，未重启 Caddy。"
      return 1
    }
  fi

  install_manager_command || return 1
  validate_caddy_config || return 1
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
  if caddy_l4_enabled; then
    disable_caddy_l4_service
  fi
  rm -f -- "$CADDY_L4_BINARY"
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
  backup_file "$LISTENER_COMMAND" "pl-command-before-uninstall"
  if [[ -f "$LEGACY_LISTENER_COMMAND" ]] \
      && grep -Fq '# CaddyCtl listener shortcut' "$LEGACY_LISTENER_COMMAND" 2>/dev/null; then
    backup_file "$LEGACY_LISTENER_COMMAND" "caddyctl-listen-command-before-uninstall"
  fi
  rm -f -- "$MANAGER_COMMAND" "$LISTENER_COMMAND" "$LEGACY_LISTENER_COMMAND" "$MANAGER_SCRIPT"
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
  warn "这还将永久删除 Caddy 配置、站点配置、证书数据和 CaddyCtl 备份。"
  warn "将删除：${CADDY_CONFIG_DIR}、${CADDY_DATA_DIR}、${BACKUP_DIR}。"
  confirm_action "确认完全卸载 Caddy 和 CaddyCtl？" || { info "已取消。"; return 0; }

  remove_caddy_package || return 1
  remove_manager_files
  rm -rf -- "$CADDY_CONFIG_DIR" "$CADDY_DATA_DIR" "$BACKUP_DIR"
  success "Caddy、CaddyCtl、配置、证书数据和备份均已完全卸载。"
}

uninstall_menu() {
  local choice

  printf '\n%s请选择卸载内容%s\n' "$BOLD" "$RESET"
  printf '  1. 卸载 Caddy（保留配置、证书和 CaddyCtl）\n'
  printf '  2. 卸载 CaddyCtl 管理菜单（保留 Caddy、配置和证书）\n'
  printf '  3. 完全卸载 Caddy 和 CaddyCtl（删除配置、证书和备份）\n'
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
  local runtime
  runtime="$(caddy_runtime_binary)"
  if ! validate_caddy_config "$runtime"; then
    return 1
  fi

  if systemctl is-active --quiet caddy; then
    # The package unit's default ExecReload may call /usr/bin/caddy. When
    # caddy-l4 is active that binary cannot parse the layer4 module, so use
    # the service restart path and let the systemd drop-in start caddy-l4.
    if caddy_l4_enabled; then
      systemctl restart caddy
    else
      systemctl reload caddy
    fi
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

  initialize_caddyfile || return 1
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

  read -r -p "2. 后端服务地址（Docker 通常填 127.0.0.1；其他服务填实际监听地址，默认 127.0.0.1）：" upstream_host
  upstream_host="${upstream_host:-127.0.0.1}"
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

SITE_CHOICES=()
SELECTED_SITE_PATH=''
SELECTED_SITE_DOMAIN=''

load_site_choices() {
  local site

  SITE_CHOICES=()
  for site in "$SITES_DIR"/*.caddy; do
    [[ -f "$site" ]] || continue
    SITE_CHOICES+=("$site")
  done
}

show_site_choices() {
  local site domain settings upstream_scheme upstream_host upstream_port
  local index=1

  load_site_choices
  for site in "${SITE_CHOICES[@]}"; do
    domain="${site##*/}"
    domain="${domain%.caddy}"
    settings="$(read_proxy_settings "$site" || true)"
    if [[ -n "$settings" ]]; then
      IFS=$'\t' read -r upstream_scheme upstream_host upstream_port <<< "$settings"
      printf '  %d. %s  ->  %s://%s:%s\n' \
        "$index" "$domain" "$upstream_scheme" "$(format_upstream_host "$upstream_host")" "$upstream_port"
    else
      printf '  %d. %s  ->  自定义 Caddy 配置\n' "$index" "$domain"
    fi
    ((index++))
  done
}

select_site_choice() {
  local prompt="$1"
  local choice

  load_site_choices
  read -r -p "$prompt" choice || return 1
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#SITE_CHOICES[@]} )); then
    error "无效站点编号：$choice"
    return 1
  fi

  SELECTED_SITE_PATH="${SITE_CHOICES[choice-1]}"
  SELECTED_SITE_DOMAIN="${SELECTED_SITE_PATH##*/}"
  SELECTED_SITE_DOMAIN="${SELECTED_SITE_DOMAIN%.caddy}"
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
  select_site_choice "输入需要修改的站点编号：" || return 1
  domain="$SELECTED_SITE_DOMAIN"
  target="$SELECTED_SITE_PATH"
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

  read -r -p "是否查看原始 Caddy 配置？[y/N，回车默认 N]：" answer
  [[ "$answer" =~ ^[Yy]$ ]] && show_raw_config
}

is_local_upstream_host() {
  local host="$1"

  case "$host" in
    localhost|127.0.0.1|::1) return 0 ;;
  esac

  if command -v ip >/dev/null 2>&1 \
      && ip -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$host"; then
    return 0
  fi

  # Docker bridge gateways are host-side addresses, but some Docker/runtime
  # combinations do not expose the bridge interface through `ip addr`.
  command -v docker >/dev/null 2>&1 || return 1
  docker network ls -q 2>/dev/null | while read -r network_id; do
    docker network inspect --format '{{(index .IPAM.Config 0).Gateway}}' "$network_id" 2>/dev/null
  done | awk 'NF' | grep -Fxq "$host"
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

  printf '\n%s检测 Caddy 后端服务监听与连通性%s\n' "$BOLD" "$RESET"
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

docker_published_listener_services() {
  local container_id

  command -v docker >/dev/null 2>&1 || return 0
  docker info >/dev/null 2>&1 || return 0
  while IFS= read -r container_id; do
    [[ -n "$container_id" ]] || continue
    docker inspect --format '{{range $containerPort, $bindings := .NetworkSettings.Ports}}{{range $bindings}}{{printf "%s\t%s\t%s\t" .HostIp .HostPort $containerPort}}{{with index $.Config.Labels "com.docker.compose.service"}}{{.}}{{else}}{{$.Name}}{{end}}{{println}}{{end}}{{end}}' "$container_id" 2>/dev/null
  done < <(docker ps -q 2>/dev/null)
}

format_listener_table() {
  local docker_services="$1"
  local listener_command="$2"

  awk -v docker_services="$docker_services" -v listener_command="$listener_command" '
    function normalized_host(host) {
      sub(/^\[/, "", host)
      sub(/\]$/, "", host)
      return host
    }
    function add_service(services, key, service, current) {
      current = services[key]
      if (current == "") {
        services[key] = service
      } else if (index("," current ",", "," service ",") == 0) {
        services[key] = current "," service
      }
    }
    function visible_length(value) {
      return value == "未知" ? 4 : length(value)
    }
    function print_spaces(count, i) {
      for (i = 0; i < count; i++) {
        printf " "
      }
    }
    function print_header_field(label, label_width, field_width) {
      printf "%s", label
      print_spaces(field_width - label_width + 2)
    }
    function print_data_field(value, field_width) {
      printf "%s", value
      print_spaces(field_width - visible_length(value) + 2)
    }
    function print_table_header() {
      if (listener_command == "netstat") {
        print_header_field("协议", 4, width[1])
      } else {
        print_header_field("状态", 4, width[1])
      }
      print_header_field("接收队列", 8, width[2])
      print_header_field("发送队列", 8, width[3])
      print_header_field("本地监听地址:端口", 17, width[4])
      print_header_field("服务实际端口", 12, width[5])
      if (listener_command == "netstat") {
        print_header_field("状态", 4, width[6])
        print_header_field("服务名称", 8, width[7])
      } else {
        print_header_field("服务名称", 8, width[6])
      }
      print "进程"
    }
    BEGIN {
      width[1] = 7
      width[2] = 8
      width[3] = 8
      width[4] = 18
      width[5] = 14
      width[6] = 7
      width[7] = 12
      if (listener_command != "netstat") {
        width[6] = 12
      }
      mapping_count = split(docker_services, mappings, "\n")
      for (i = 1; i <= mapping_count; i++) {
        field_count = split(mappings[i], fields, "\t")
        if (field_count < 4 || fields[1] == "" || fields[2] == "" || fields[3] == "" || fields[4] == "") {
          continue
        }
        sub(/^\/+/, "", fields[4])
        host = normalized_host(fields[1])
        add_service(service_by_binding, host SUBSEP fields[2], fields[4])
        add_service(service_by_port, fields[2], fields[4])
        add_service(actual_port_by_binding, host SUBSEP fields[2], fields[3])
        add_service(actual_port_by_port, fields[2], fields[3])
      }
    }
    listener_command == "netstat" && NR <= 2 {
      next
    }
    listener_command != "netstat" && NR == 1 {
      next
    }
    NF < (listener_command == "netstat" ? 6 : 5) {
      next
    }
    {
      process_field = listener_command == "netstat" ? 7 : 6
      process = ""
      for (i = process_field; i <= NF; i++) {
        process = process (process == "" ? "" : " ") $i
      }
      service = "-"
      address = $4
      port = address
      sub(/^.*:/, "", port)
      host = address
      sub(/:[^:]*$/, "", host)
      host = normalized_host(host)
      actual_port = port "/tcp"
      if (process ~ /docker-proxy/) {
        service = service_by_binding[host SUBSEP port]
        if (service == "") {
          service = service_by_port[port]
        }
        if (service == "") {
          service = "未知"
        }
        actual_port = actual_port_by_binding[host SUBSEP port]
        if (actual_port == "") {
          actual_port = actual_port_by_port[port]
        }
        if (actual_port == "") {
          actual_port = "未知"
        }
      }
      row_count++
      field[row_count, 1] = $1
      field[row_count, 2] = $2
      field[row_count, 3] = $3
      field[row_count, 4] = $4
      field[row_count, 5] = actual_port
      if (listener_command == "netstat") {
        field[row_count, 6] = $6
        field[row_count, 7] = service
        field[row_count, 8] = process
        for (i = 1; i <= 7; i++) {
          if (visible_length(field[row_count, i]) > width[i]) {
            width[i] = visible_length(field[row_count, i])
          }
        }
      } else {
        field[row_count, 6] = service
        field[row_count, 7] = process
        for (i = 1; i <= 6; i++) {
          if (visible_length(field[row_count, i]) > width[i]) {
            width[i] = visible_length(field[row_count, i])
          }
        }
      }
    }
    END {
      if (listener_command == "netstat") {
        print "TCP 监听端口（仅服务端）"
      }
      print_table_header()
      for (row = 1; row <= row_count; row++) {
        if (listener_command == "netstat") {
          for (i = 1; i <= 7; i++) {
            print_data_field(field[row, i], width[i])
          }
          print field[row, 8]
        } else {
          for (i = 1; i <= 6; i++) {
            print_data_field(field[row, i], width[i])
          }
          print field[row, 7]
        }
      }
    }
  '
}

localize_ss_listener_header() {
  local docker_services

  docker_services="$(docker_published_listener_services)"
  format_listener_table "$docker_services" ss
}

localize_netstat_listener_header() {
  local docker_services

  docker_services="$(docker_published_listener_services)"
  format_listener_table "$docker_services" netstat
}

show_all_local_listeners() {
  printf '\n%s本机 TCP 服务监听地址%s\n' "$BOLD" "$RESET"
  info "127.0.0.1 表示仅本机；* 或 0.0.0.0 表示所有 IPv4；具体 IP 表示仅该网卡。"
  info "服务实际端口：Docker 显示容器内部端口；systemd 和普通进程显示本地监听端口。"
  info "docker-proxy 表示宿主机发布端口；服务名称列优先显示 Compose 服务名，否则显示容器名。"
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

  # Monitoring/sidecar containers often reuse the NPM name prefix but are not
  # the proxy manager that should receive gateway traffic.
  case "$image:$container_name" in
    *monitor*|*metrics*|*exporter*) return 1 ;;
  esac

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

    network_ips="$(docker inspect --format '{{range $name, $network := .NetworkSettings.Networks}}{{$name}}={{$network.IPAddress}}{{println}}{{end}}' "$container_id" 2>/dev/null | awk 'NF' | paste -sd ',' -)"
    [[ -n "$network_ips" ]] || network_ips="-"

    listeners=""
    detection=""
    if docker exec "$container_id" ss -ltnH >/dev/null 2>&1; then
      listeners="$(docker exec "$container_id" ss -ltnH 2>/dev/null | awk '$4 !~ /^127\.0\.0\.11:/ {print $4}' | paste -sd ',' -)"
      detection="ss 实际检测"
    elif docker exec "$container_id" netstat -ltn >/dev/null 2>&1; then
      listeners="$(docker exec "$container_id" netstat -ltn 2>/dev/null | awk '$1 ~ /^tcp/ && $4 !~ /^127\.0\.0\.11:/ {print $4}' | paste -sd ',' -)"
      detection="netstat 实际检测"
    else
      exposed_ports="$(docker inspect --format '{{range $port, $_ := .Config.ExposedPorts}}{{println $port}}{{end}}' "$container_id" 2>/dev/null | awk 'NF' | paste -sd ',' -)"
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

preferred_npm_gateway_target() {
  local target container_id container_name network gateway
  local -a targets=("$@")

  (( ${#targets[@]} > 0 )) || return 1
  # NPMCtl creates npmctl_default. Prefer it when NPM is attached to several
  # bridge networks, then fall back to Docker's default bridge.
  for target in "${targets[@]}"; do
    IFS=$'\t' read -r container_id container_name network gateway <<< "$target"
    if [[ "$network" == npmctl_default ]]; then
      printf '%s\n' "$target"
      return 0
    fi
  done
  for target in "${targets[@]}"; do
    IFS=$'\t' read -r container_id container_name network gateway <<< "$target"
    if [[ "$network" == bridge ]]; then
      printf '%s\n' "$target"
      return 0
    fi
  done
  printf '%s\n' "${targets[0]}"
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
  printf '  1. [宿主机 Caddy] 仅本机反代：127.0.0.1:%s（Docker NPM 不可访问）\n' "$port"
  printf '  2. [Docker NPM] 经 Docker 网关访问（自动识别；需应用支持绑定该地址）\n'
  printf '  3. [指定网卡] 仅指定服务器 IPv4 地址可访问（适用于内网或特定公网 IP）\n'
  printf '  4. [公网] 所有 IPv4 可访问：0.0.0.0:%s（需配置防火墙）\n' "$port"
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
      info "将请求应用监听 ${npm_gateway}:${port}；这不是将 systemd 服务挂载到 NPM 容器。"
      ;;
    3)
      read -r -p "服务器本机 IPv4 地址：" manual_host
      if ! is_valid_ipv4 "$manual_host" || ! is_local_upstream_host "$manual_host"; then
        error "该地址不是服务器当前网卡上的 IPv4 地址。"
        return 1
      fi
      GENERIC_BIND_HOST="$manual_host"
      ;;
    4)
      GENERIC_BIND_HOST="0.0.0.0"
      warn "此端口将接受所有 IPv4 网络接口的连接，请仅在防火墙允许可信来源。"
      ;;
    0) return 1 ;;
    *) error "无效选项：$mode"; return 1 ;;
  esac
}

generic_systemd_config_search_paths() {
  local unit="$1"
  local unit_base="${unit%.service}"
  local environment_file working_directory executable_path directory
  local -a directories

  while IFS= read -r environment_file; do
    [[ -n "$environment_file" && -f "$environment_file" ]] && printf '%s\n' "$environment_file"
  done < <(
    systemctl cat "$unit" --no-pager 2>/dev/null \
      | sed -nE 's/^[[:space:]]*EnvironmentFile=-?([^[:space:]"]+).*$/\1/p'
  )

  working_directory="$(systemctl show "$unit" --property=WorkingDirectory --value 2>/dev/null || true)"
  executable_path="$(
    systemctl show "$unit" --property=ExecStart --value 2>/dev/null \
      | sed -n 's/.*path=\([^ ;}]*\).*/\1/p' | head -n 1
  )"
  directories=(
    "$working_directory"
    "$(dirname -- "$executable_path" 2>/dev/null || true)"
    "/etc/${unit_base}"
  )
  for directory in "${directories[@]}"; do
    [[ -n "$directory" && "$directory" != "/" && -d "$directory" ]] || continue
    find "$directory" -maxdepth 3 -type f \
      \( -name '*.conf' -o -name '*.config' -o -name '*.env' -o -name '*.ini' \
         -o -name '*.json' -o -name '*.toml' -o -name '*.yaml' -o -name '*.yml' \) \
      -print 2>/dev/null
  done
  for environment_file in "/etc/default/${unit_base}" "/etc/${unit_base}.conf"; do
    [[ -f "$environment_file" ]] && printf '%s\n' "$environment_file"
  done
}

generic_systemd_listener_config_candidates() {
  local unit="$1"
  local port="$2"
  local config_path address match_lines
  local -a addresses=(
    "127.0.0.1:${port}"
    "0.0.0.0:${port}"
    "*:${port}"
    "[::]:${port}"
    ":::${port}"
  )

  while IFS= read -r config_path; do
    [[ -f "$config_path" && -r "$config_path" ]] || continue
    grep -Iq . "$config_path" 2>/dev/null || continue
    for address in "${addresses[@]}"; do
      match_lines="$(grep -Foc -- "$address" "$config_path" 2>/dev/null || true)"
      [[ "$match_lines" == "1" ]] && printf '%s\t%s\n' "$config_path" "$address"
    done
  done < <(generic_systemd_config_search_paths "$unit" | awk 'NF && !seen[$0]++')
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
  local mode config_path old_address selection automatic_answer manual_config_answer selected_candidate
  local -a config_candidates

  while true; do
    printf '\n%s通用 systemd 监听地址管理%s\n' "$BOLD" "$RESET"
    printf '服务：%s\n当前监听：\n%s\n' "$unit" "$listener"
    printf '优先自动识别应用配置中的精确地址；不会修改 systemd ExecStart。\n'
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
      mapfile -t config_candidates < <(generic_systemd_listener_config_candidates "$unit" "$port")
      if (( ${#config_candidates[@]} > 0 )); then
        printf '\n%s自动识别到的应用监听配置%s\n' "$BOLD" "$RESET"
        if (( ${#config_candidates[@]} == 1 )); then
          selected_candidate="${config_candidates[0]}"
        else
          for ((selection = 0; selection < ${#config_candidates[@]}; selection++)); do
            IFS=$'\t' read -r config_path old_address <<< "${config_candidates[$selection]}"
            printf '  %d. %s（当前：%s）\n' "$((selection + 1))" "$config_path" "$old_address"
          done
          read -r -p "请选择 [1-${#config_candidates[@]}]（直接回车改为手动填写）：" selection
          if [[ -z "$selection" ]]; then
            config_candidates=()
          elif [[ "$selection" =~ ^[0-9]+$ ]] && (( selection >= 1 && selection <= ${#config_candidates[@]} )); then
            selected_candidate="${config_candidates[$((selection - 1))]}"
          else
            error "无效选项：$selection"
            continue
          fi
        fi
        if (( ${#config_candidates[@]} > 0 )); then
          IFS=$'\t' read -r config_path old_address <<< "$selected_candidate"
          info "已识别配置：${config_path}；当前监听：${old_address}。"
          read -r -p "自动备份、替换为 ${GENERIC_BIND_HOST}:${port} 并重启 ${unit}？[y/N，回车默认 N]：" automatic_answer
          automatic_answer="${automatic_answer:-N}"
          case "$automatic_answer" in
            Y|y)
              if apply_generic_systemd_listener_address "$unit" "$port" "$config_path" "$old_address" "$GENERIC_BIND_HOST"; then
                if [[ -n "$GENERIC_NPM_CONTAINER_ID" ]]; then
                  verify_npm_gateway_connection "$GENERIC_NPM_CONTAINER_ID" "$GENERIC_NPM_CONTAINER_NAME" "$GENERIC_NPM_GATEWAY" "$port" || true
                fi
              fi
              continue
              ;;
            N|n) info "已取消自动修改。"; continue ;;
            *) error "请输入 y 或 n。"; continue ;;
          esac
        fi
      fi
      warn "未自动识别到唯一的文本配置监听地址，需手动指定。"
      if [[ -n "$GENERIC_NPM_GATEWAY" ]]; then
        info "选项 2 的目标监听地址为 ${GENERIC_NPM_GATEWAY}:${port}；端口存储在数据库或面板内部的服务无法由通用文本替换安全修改。"
      else
        info "端口存储在数据库或面板内部的服务无法由通用文本替换安全修改。"
      fi
      read -r -p "是否手动指定应用文本配置文件？[y/N，回车默认 N]：" manual_config_answer
      manual_config_answer="${manual_config_answer:-N}"
      case "$manual_config_answer" in
        Y|y) ;;
        N|n) info "已取消手动配置。"; continue ;;
        *) error "请输入 y 或 n。"; continue ;;
      esac
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

show_gateway_networks() {
  local container_reference="$1"
  local container_name="$2"
  local rows name gateway ip members member member_ip driver project default_network role index=0

  if ! docker inspect "$container_reference" >/dev/null 2>&1; then
    error "NPM 容器 ${container_reference} 不存在或未运行。"
    return 1
  fi

  printf '\n%sNPM 网关与网络连接%s\n' "$BOLD" "$RESET"
  project="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "$container_reference" 2>/dev/null || true)"
  default_network="${project:-npmctl}_default"
  printf 'NPM 容器：%s\n' "$container_name"
  printf 'NPM 当前加入的 Docker 网络：\n'
  rows="$(docker inspect --format '{{range $name, $network := .NetworkSettings.Networks}}{{$name}}|{{$network.Gateway}}|{{$network.IPAddress}}{{"\n"}}{{end}}' "$container_reference" 2>/dev/null || true)"
  if [[ -z "$rows" ]]; then
    warn 'NPM 当前没有连接到任何 Docker bridge 网络（可能是 host 网络模式）。'
  fi
  while IFS='|' read -r name gateway ip; do
    [[ -n "$name" ]] || continue
    ((index += 1))
    driver="$(docker network inspect --format '{{.Driver}}' "$name" 2>/dev/null || printf '未知')"
    role='附加网络'
    [[ "$name" == "$default_network" || "$name" == 'npmctl_default' ]] && role='NPM 默认 Compose bridge 网络'
    printf '  %d. %s\n' "$index" "$name"
    printf '     类型：%s | 用途：%s\n' "$driver" "$role"
    printf '     网关：%s | NPM 容器 IP：%s\n' "${gateway:--}" "${ip:--}"
    members="$(docker network inspect --format '{{range $id, $container := .Containers}}{{$container.Name}}|{{$container.IPv4Address}}{{"\n"}}{{end}}' "$name" 2>/dev/null || true)"
    if [[ -n "$members" ]]; then
      printf '     同网络容器：\n'
      while IFS='|' read -r member member_ip; do
        [[ -n "$member" ]] || continue
        if [[ "$member" == "$container_name" ]]; then
          printf '       - %s（当前 NPM，IP %s）\n' "$member" "${member_ip:--}"
        else
          printf '       - %s（IP %s）\n' "$member" "${member_ip:--}"
        fi
      done <<< "$members"
    else
      printf '     同网络容器：无\n'
    fi
  done <<< "$rows"
  show_docker_default_bridge_network "$container_name"
  printf '\n网关地址由 Docker 网络决定；同网络容器可直接使用容器名和容器端口互相访问。\n'
  printf 'Compose 重建后如需保留额外网络，应在对应 Compose 配置中声明。\n'
}

show_docker_default_bridge_network() {
  local container_name="$1"
  local gateway members member member_ip npm_member=0
  docker network inspect bridge >/dev/null 2>&1 || return 0
  gateway="$(docker network inspect --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' bridge 2>/dev/null || true)"
  members="$(docker network inspect --format '{{range $id, $container := .Containers}}{{$container.Name}}|{{$container.IPv4Address}}{{"\n"}}{{end}}' bridge 2>/dev/null || true)"
  printf '\nDocker 系统默认 bridge 网络：\n'
  printf '  网络：bridge | 驱动：bridge | 网关：%s\n' "${gateway:--}"
  if [[ -n "$members" ]]; then
    printf '  网络成员：\n'
    while IFS='|' read -r member member_ip; do
      [[ -n "$member" ]] || continue
      [[ "$member" == "$container_name" ]] && npm_member=1
      printf '    - %s（IP %s）\n' "$member" "${member_ip:--}"
    done <<< "$members"
  else
    printf '  网络成员：无\n'
  fi
  if (( npm_member == 1 )); then
    printf '  NPM 状态：已加入 Docker 系统默认 bridge 网络。\n'
  else
    printf '  NPM 状态：未加入；Compose 默认网络与系统默认 bridge 是不同网络。\n'
  fi
}

select_shared_docker_network() {
  local selected network driver gateway members member_count index
  local -a networks=()

  while IFS= read -r network; do
    [[ -n "$network" && "$network" != host && "$network" != none ]] || continue
    networks+=("$network")
  done < <(docker network ls --format '{{.Name}}' 2>/dev/null)
  ((${#networks[@]} > 0)) || { warn '未找到可用于共享的 Docker bridge 网络。'; return 1; }

  printf '\nDocker 共享网络：\n'
  for index in "${!networks[@]}"; do
    network="${networks[$index]}"
    driver="$(docker network inspect --format '{{.Driver}}' "$network" 2>/dev/null || printf '%s' '未知')"
    gateway="$(docker network inspect --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' "$network" 2>/dev/null || true)"
    members="$(docker network inspect --format '{{range $id, $container := .Containers}}{{$container.Name}}{{"\n"}}{{end}}' "$network" 2>/dev/null || true)"
    member_count=0
    [[ -z "$members" ]] || member_count="$(printf '%s\n' "$members" | awk 'NF { count++ } END { print count + 0 }')"
    printf '  %d. %s（驱动：%s，网关：%s，服务：%s 个）\n' \
      "$((index + 1))" "$network" "$driver" "${gateway:--}" "$member_count"
  done
  read -r -p "选择网络 [1-${#networks[@]}，回车取消]：" selected || return 1
  [[ -n "$selected" ]] || return 1
  [[ "$selected" =~ ^[0-9]+$ ]] && ((selected >= 1 && selected <= ${#networks[@]})) || { error '无效选项。'; return 1; }
  SELECTED_DOCKER_NETWORK="${networks[$((selected - 1))]}"
}

connect_service_network() {
  local selected network container index
  local -a candidates=()
  select_shared_docker_network || return 0
  network="$SELECTED_DOCKER_NETWORK"

  while IFS= read -r container; do
    [[ -n "$container" ]] || continue
    docker_container_has_network "$container" "$network" || candidates+=("$container")
  done < <(docker ps -a --format '{{.Names}}' 2>/dev/null)
  ((${#candidates[@]} > 0)) || { warn "网络 ${network} 已包含所有 Docker 容器服务。"; return 0; }

  printf '\n网络 %s 中尚未加入的服务：\n' "$network"
  for index in "${!candidates[@]}"; do
    printf '  %d. %s\n' "$((index + 1))" "${candidates[$index]}"
  done
  read -r -p "选择要加入的服务 [1-${#candidates[@]}，回车取消]：" selected || return 0
  [[ -n "$selected" ]] || return 0
  [[ "$selected" =~ ^[0-9]+$ ]] && ((selected >= 1 && selected <= ${#candidates[@]})) || { error '无效选项。'; return 1; }
  container="${candidates[$((selected - 1))]}"
  confirm_action "确认将服务 ${container} 加入网络 ${network}？" || { info '已取消。'; return 0; }
  if docker network connect "$network" "$container"; then
    success "已将服务 ${container} 加入网络 ${network}。"
    info '该网络连接由 Docker 即时修改；Compose 重建容器后可能需要重新配置。'
  else
    error "无法将服务 ${container} 加入网络 ${network}。"
    return 1
  fi
}

disconnect_service_network() {
  local selected network container member_ip index image container_name
  local -a members=() member_rows=()
  select_shared_docker_network || return 0
  network="$SELECTED_DOCKER_NETWORK"

  while IFS='|' read -r container member_ip; do
    [[ -n "$container" ]] || continue
    member_rows+=("$container|$member_ip")
    members+=("$container")
  done < <(docker network inspect --format '{{range $id, $container := .Containers}}{{$container.Name}}|{{$container.IPv4Address}}{{"\n"}}{{end}}' "$network" 2>/dev/null)
  ((${#members[@]} > 0)) || { warn "网络 ${network} 当前没有容器服务。"; return 0; }

  printf '\n网络 %s 中的服务：\n' "$network"
  for index in "${!member_rows[@]}"; do
    IFS='|' read -r container member_ip <<< "${member_rows[$index]}"
    printf '  %d. %s（IP：%s）\n' "$((index + 1))" "$container" "${member_ip:--}"
  done
  read -r -p "选择要移除的服务 [1-${#members[@]}，回车取消]：" selected || return 0
  [[ -n "$selected" ]] || return 0
  [[ "$selected" =~ ^[0-9]+$ ]] && ((selected >= 1 && selected <= ${#members[@]})) || { error '无效选项。'; return 1; }
  container="${members[$((selected - 1))]}"
  IFS='|' read -r image container_name < <(docker inspect --format '{{.Config.Image}}|{{.Name}}' "$container" 2>/dev/null)
  container_name="${container_name#/}"
  if is_npm_container "$image" "$container_name"; then
    warn "移除 NPM ${container} 后，它将无法通过该网络访问同网络服务。"
  fi
  confirm_action "确认将服务 ${container} 从网络 ${network} 移除？" || { info '已取消。'; return 0; }
  if docker network disconnect "$network" "$container"; then
    success "已将服务 ${container} 从网络 ${network} 移除。"
    info '该网络连接由 Docker 即时修改；Compose 重建容器后可能需要重新配置。'
  else
    error "无法将服务 ${container} 从网络 ${network} 移除。"
    return 1
  fi
}

gateway_settings_menu() {
  local choice container_id container_name image selected
  local -a containers=()

  command -v docker >/dev/null 2>&1 || { error '未检测到 Docker 命令。'; return 1; }
  docker info >/dev/null 2>&1 || { error '无法连接 Docker 服务。'; return 1; }
  mapfile -t containers < <(find_npm_containers)
  if ((${#containers[@]} == 0)); then
    warn '未自动识别到运行中的 Nginx Proxy Manager 容器。'
    show_running_docker_containers
    read -r -p '输入 NPM 容器名称或 ID（直接回车返回）: ' container_id || return 0
    [[ -n "$container_id" ]] || return 0
    IFS='|' read -r container_id container_name image < <(docker inspect --format '{{.Id}}|{{.Name}}|{{.Config.Image}}' "$container_id" 2>/dev/null)
    container_name="${container_name#/}"
    if [[ -z "$container_id" ]] || ! is_npm_container "$image" "$container_name"; then
      error '所选容器无法识别为 Nginx Proxy Manager。'
      return 1
    fi
  elif ((${#containers[@]} == 1)); then
    IFS=$'\t' read -r container_id container_name image <<< "${containers[0]}"
  else
    printf '\n检测到多个 NPM 容器：\n'
    for choice in "${!containers[@]}"; do
      IFS=$'\t' read -r container_id container_name image <<< "${containers[$choice]}"
      printf '  %d. %s（镜像：%s）\n' "$((choice + 1))" "$container_name" "$image"
    done
    read -r -p "选择 NPM 容器 [1-${#containers[@]}，回车返回]：" selected || return 0
    [[ -n "$selected" ]] || return 0
    [[ "$selected" =~ ^[0-9]+$ ]] && ((selected >= 1 && selected <= ${#containers[@]})) || { error '无效选项。'; return 1; }
    IFS=$'\t' read -r container_id container_name image <<< "${containers[$((selected - 1))]}"
  fi

  while true; do
    printf '\n%s网关设置%s（NPM：%s）\n' "$BOLD" "$RESET" "$container_name"
    printf '  1. 查看当前网关与网络\n'
    printf '  2. 将服务加入 Docker 网络\n'
    printf '  3. 从 Docker 网络移除服务\n'
    printf '  4. 本机 TCP 服务监听地址\n'
    printf '  0. 返回\n'
    read -r -p '请选择 [0-4]：' choice || return 0
    case "$choice" in
      1) show_gateway_networks "$container_id" "$container_name"; pause_menu ;;
      2) connect_service_network; pause_menu ;;
      3) disconnect_service_network; pause_menu ;;
      4) show_all_local_listeners; pause_menu ;;
      0) return 0 ;;
      *) error '无效选项。'; pause_menu ;;
    esac
  done
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
  local temp_file line mapping_regex port_suffix line_suffix match_count=0 variable_mapping_detected=false

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
    [[ "$line" =~ ^[[:space:]]*-[[:space:]]*.*\$\{ ]] && variable_mapping_detected=true
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
    if [[ "$variable_mapping_detected" == true ]]; then
      warn "Compose 端口映射由环境变量管理，CaddyCtl 无法安全判断变量来源，未自动修改。"
      info "请使用应用自身的管理工具，或修改对应 env 文件后重建容器。"
    else
      warn "未能在 Compose 文件中唯一识别当前端口映射，未自动修改。"
    fi
    return 1
  fi
  chmod --reference="$config_path" "$temp_file" || {
    rm -f -- "$temp_file"
    return 1
  }
  mv -- "$temp_file" "$config_path"
}

is_kopiactl_web_ui_container() {
  local container_name="$1"

  [[ "$container_name" == kopia-web-ui ]] || return 1
  [[ -x /usr/local/bin/kopiactl ]] || return 1
  [[ -f /opt/kopiactl/kopiactl.env ]] || return 1
  grep -qx 'INSTALL_MODE=docker' /opt/kopiactl/kopiactl.env 2>/dev/null
}

apply_kopiactl_web_ui_bind_address() {
  local bind_host="$1"
  local host_port="$2"
  local internal_port="$3"

  info "检测到 KopiaCtl 管理的 Web UI，交由 KopiaCtl 修改发布范围并重建容器。"
  /usr/local/bin/kopiactl web-ui set-bind "$bind_host" || {
    error 'KopiaCtl 未能修改 Web UI 发布范围。请先将 KopiaCtl 更新到支持该命令的版本。'
    return 1
  }
  if ! wait_for_docker_port_mapping "$host_port" "$bind_host" "${internal_port}/tcp"; then
    error 'KopiaCtl 命令已执行，但未检测到预期端口映射。请查看 KopiaCtl 的 Web UI 状态。'
    return 1
  fi
  success "KopiaCtl Web UI 已改为 ${bind_host}:${host_port}:${internal_port}。"
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
    read -r -p "立即创建 Docker 共享网络 ${shared_network}？[y/N，回车默认 N]：" create_network_answer
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
    read -r -p "立即将 NPM ${npm_container_name} 和应用 ${app_container_name} 加入 ${shared_network}？[y/N，回车默认 N]：" connect_network_answer
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
  warn "本向导不会修改当前 ports。确认共享网络已持久化且 NPM 访问正常后，可自行移除不再需要的端口映射并重建应用容器。"
}

show_docker_mapping_plan() {
  local container_id="$1"
  local container_name="$2"
  local container_port="$3"
  local current_host_ip="$4"
  local host_port="$5"
  local mode bind_host internal_port project service workdir config_files auto_apply_answer
  local compat_target compat_container_id compat_container_name compat_network compat_gateway compat_gateway_display manual_container selection i preferred_index
  local -a compat_targets

  internal_port="${container_port%/tcp}"
  project="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "$container_id" 2>/dev/null || true)"
  service="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "$container_id" 2>/dev/null || true)"
  workdir="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$container_id" 2>/dev/null || true)"
  config_files="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$container_id" 2>/dev/null || true)"
  mapfile -t compat_targets < <(find_npm_gateway_targets)
  compat_gateway_display="<选择后确定>"
  if (( ${#compat_targets[@]} == 1 )); then
    IFS=$'\t' read -r compat_container_id compat_container_name compat_network compat_gateway <<< "${compat_targets[0]}"
    compat_gateway_display="$compat_gateway"
  elif (( ${#compat_targets[@]} > 1 )); then
    compat_target="$(preferred_npm_gateway_target "${compat_targets[@]}")"
    IFS=$'\t' read -r compat_container_id compat_container_name compat_network compat_gateway <<< "$compat_target"
    compat_gateway_display="$compat_gateway（默认；检测到 ${#compat_targets[@]} 个网关）"
  fi

  printf '\n%sDocker 容器访问与端口发布%s\n' "$BOLD" "$RESET"
  if [[ -n "$project" ]]; then
    printf '启动方式：Docker 容器（Compose 管理）\n'
  else
    printf '启动方式：Docker 容器\n'
  fi
  printf '容器：%s\n宿主机发布地址：%s:%s（docker-proxy）\n容器内部端口：%s（共享网络/NPM 直连使用）\n' \
    "$container_name" "${current_host_ip:-0.0.0.0}" "$host_port" "$container_port"
  info "选项 1 只配置共享网络并保留当前 ports；选项 2-4 才会修改端口发布地址。"
  printf '  1. [推荐] 配置 NPM 与应用共享网络（不修改当前端口映射）\n'
  printf '  2. [兼容] NPM 经 Docker bridge 网关中转：%s:%s:%s（仅发布到该网关）\n' "$compat_gateway_display" "$host_port" "$internal_port"
  printf '  3. [宿主机 Caddy] 仅发布到本机：127.0.0.1:%s:%s\n' "$host_port" "$internal_port"
  printf '  4. [公网] 任何来源可访问：0.0.0.0:%s:%s\n' "$host_port" "$internal_port"
  printf '  0. 返回\n'
  read -r -p "请选择 [0-4]：" mode

  case "$mode" in
    1)
      show_npm_shared_network_guide "$container_id" "$container_name" "$container_port"
      return
      ;;
    2)
      if (( ${#compat_targets[@]} == 0 )); then
        warn "未自动检测到带 IPv4 Docker bridge 网关的 NPM 容器。"
        show_running_docker_containers
        read -r -p "输入 NPM 容器名称或 ID（直接回车返回）: " manual_container
        [[ -n "$manual_container" ]] || return 0
        mapfile -t compat_targets < <(docker_gateway_targets_for_container "$manual_container")
      fi
      if (( ${#compat_targets[@]} == 0 )); then
        error "未找到 NPM 容器的 IPv4 Docker bridge 网关，无法生成兼容映射。"
        return 1
      fi
      if (( ${#compat_targets[@]} == 1 )); then
        compat_target="${compat_targets[0]}"
      else
        preferred_index=1
        compat_target="$(preferred_npm_gateway_target "${compat_targets[@]}")"
        IFS=$'\t' read -r compat_container_id compat_container_name compat_network compat_gateway <<< "$compat_target"
        printf '\n检测到多个 NPM Docker 网络网关（回车使用推荐项）：\n'
        for ((i = 0; i < ${#compat_targets[@]}; i++)); do
          IFS=$'\t' read -r compat_container_id compat_container_name compat_network compat_gateway <<< "${compat_targets[$i]}"
          if [[ "$compat_targets[$i]" == "$compat_target" ]]; then
            preferred_index=$((i + 1))
            printf '  %d. 容器 %s，网络 %s，网关 %s [推荐]\n' "$((i + 1))" "$compat_container_name" "$compat_network" "$compat_gateway"
          else
            printf '  %d. 容器 %s，网络 %s，网关 %s\n' "$((i + 1))" "$compat_container_name" "$compat_network" "$compat_gateway"
          fi
        done
        read -r -p "请选择 [1-${#compat_targets[@]}，默认 ${preferred_index}]: " selection
        selection="${selection:-$preferred_index}"
        if [[ ! "$selection" =~ ^[0-9]+$ ]] || (( selection < 1 || selection > ${#compat_targets[@]} )); then
          error "无效选项：$selection"
          return 1
        fi
        compat_target="${compat_targets[$((selection - 1))]}"
      fi
      IFS=$'\t' read -r compat_container_id compat_container_name compat_network compat_gateway <<< "$compat_target"
      if ! is_local_upstream_host "$compat_gateway"; then
        error "检测到的 Docker 网关 ${compat_gateway} 不是本机地址，无法作为端口发布地址。"
        return 1
      fi
      bind_host="$compat_gateway"
      info "检测到 NPM 容器 ${compat_container_name} 的 Docker 网关：${compat_gateway}（网络 ${compat_network}）。"
      info "Compose 目标映射：${compat_gateway}:${host_port}:${internal_port}。"
      info "重建后在 NPM 中填写上游地址 ${compat_gateway}:${host_port}。"
      ;;
    3)
      bind_host="127.0.0.1"
      info "仅修改宿主机发布地址为 127.0.0.1:${host_port}；容器内部端口仍为 ${internal_port}。"
      info "此端口供宿主机上的 Caddy、Nginx 等反代；Docker 内的 NPM 不能经 127.0.0.1:${host_port} 访问。"
      ;;
    4)
      bind_host="0.0.0.0"
      warn "此容器端口将接受所有 IPv4 网络接口的连接，请限制防火墙来源。"
      ;;
    0) return 0 ;;
    *) error "无效选项：$mode"; return 1 ;;
  esac

  if is_kopiactl_web_ui_container "$container_name"; then
    if [[ "$current_host_ip" == "$bind_host" ]]; then
      info "当前 KopiaCtl Web UI 端口映射已是目标地址，无需修改。"
      return 0
    fi
    read -r -p "交由 KopiaCtl 修改 Web UI 发布范围并重建容器？[y/N，回车默认 N]：" auto_apply_answer
    auto_apply_answer="${auto_apply_answer:-N}"
    case "$auto_apply_answer" in
      Y|y) apply_kopiactl_web_ui_bind_address "$bind_host" "$host_port" "$internal_port" ;;
      N|n) info "未自动修改。可在 KopiaCtl 的“修改 Web UI 发布范围”中设置为 ${bind_host}。" ;;
      *) error "请输入 Y 或 n。"; return 1 ;;
    esac
    return
  fi

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
      read -r -p "自动备份、修改 Compose 并重建服务 ${service}？[y/N，回车默认 N]：" auto_apply_answer
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

  while true; do
    printf '\n%s本机服务端口监听助手%s\n' "$BOLD" "$RESET"
    info "先列出本机服务，再输入需要查看或修改的端口。可将手工启动的 Kopia 接管为 systemd 服务。"
    show_all_local_listeners
    read -r -p "输入需要管理的 TCP 端口；输入 d 查看全部 Docker 容器内部监听（查询后返回此处；直接回车返回主菜单）：" port
    [[ -n "$port" ]] || return 0
    case "$port" in
      d|D)
        show_all_docker_internal_listeners
        read -r -p "按 Enter 键返回本机服务端口监听助手..." _ || true
        continue
        ;;
    esac
    break
  done
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
  local domain target rollback_file answer

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
  select_site_choice "输入需要删除的站点编号：" || return 1
  domain="$SELECTED_SITE_DOMAIN"
  target="$SELECTED_SITE_PATH"

  read -r -p "确认删除 $domain 的反向代理配置？[Y/n，回车确认]：" answer || {
    info "已取消。"
    return 0
  }
  if [[ "$answer" =~ ^[Nn]$ ]]; then
    info "已取消。"
    return 0
  fi

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
  local installed_color="$YELLOW" active_color="$YELLOW" enabled_color="$YELLOW"
  local service_active service_enabled l4_text l4_color panel_text panel_color reality_text reality_color

  if [[ -x "$REAL_CADDY" ]]; then
    installed="已安装"
    installed_color="$GREEN"
    version="$($REAL_CADDY version 2>/dev/null || printf '未知')"
  fi

  service_active="$(service_value is-active)"
  case "$service_active" in
    active) active="运行中"; active_color="$GREEN" ;;
    failed) active="启动失败"; active_color="$RED" ;;
    activating|deactivating) active="状态转换中" ;;
    inactive) active="未运行" ;;
    *) active="${service_active:-不可用}" ;;
  esac

  service_enabled="$(service_value is-enabled)"
  case "$service_enabled" in
    enabled) enabled="已启用"; enabled_color="$GREEN" ;;
    disabled) enabled="未启用" ;;
    masked) enabled="已屏蔽"; enabled_color="$RED" ;;
    *) enabled="${service_enabled:-不可用}" ;;
  esac

  if [[ -d "$SITES_DIR" ]]; then
    site_count="$(find "$SITES_DIR" -maxdepth 1 -type f -name '*.caddy' 2>/dev/null | wc -l | tr -d ' ')"
  fi

  printf '安装：%s%s%s | 服务：%s%s%s | 开机启动：%s%s%s | 站点数：%s\n' \
    "$installed_color" "$installed" "$RESET" \
    "$active_color" "$active" "$RESET" \
    "$enabled_color" "$enabled" "$RESET" \
    "$site_count"
  printf 'Caddy 版本：%s | CaddyCtl 版本：%s\n' "$version" "$MANAGER_VERSION"
  if caddy_l4_enabled; then
    l4_text='已启用'; l4_color="$GREEN"
    if state_has_panel; then panel_text='已启用'; panel_color="$GREEN"; else panel_text='未启用'; panel_color="$RED"; fi
    if state_has_reality; then reality_text='已启用'; reality_color="$GREEN"; else reality_text='未启用'; reality_color="$RED"; fi
  elif [[ -f "$CADDY_L4_STATE_FILE" ]]; then
    l4_text='未启用（配置已保存）'; l4_color="$YELLOW"
    if state_has_panel; then panel_text='已保存'; panel_color="$YELLOW"; else panel_text='未配置'; panel_color="$RED"; fi
    if state_has_reality; then reality_text='已保存'; reality_color="$YELLOW"; else reality_text='未配置'; reality_color="$RED"; fi
  else
    l4_text='未配置'; l4_color="$RED"
    panel_text='未配置'; panel_color="$RED"
    reality_text='未配置'; reality_color="$RED"
  fi
  printf '443 复用：%s%s%s | 面板映射：%s%s%s | Reality 映射：%s%s%s\n' \
    "$l4_color" "$l4_text" "$RESET" \
    "$panel_color" "$panel_text" "$RESET" \
    "$reality_color" "$reality_text" "$RESET"
}

draw_menu() {
  clear 2>/dev/null || true
  printf '%s============================================%s\n' "$BLUE" "$RESET"
  printf '%s              CaddyCtl 管理菜单%s\n' "$BOLD" "$RESET"
  printf '%s============================================%s\n' "$BLUE" "$RESET"
  status_line
  printf '%s--------------------------------------------%s\n' "$BLUE" "$RESET"
  printf '  1. 更新 CaddyCtl 管理菜单\n'
  printf '  2. 本机服务端口监听助手\n'
  printf '  3. 网关设置（查看、连接或断开 Docker 网络）\n'
  printf '  4. 查看运行状态\n'
  printf '  5. 安装或更新 Caddy\n'
  printf '  6. 新增反向代理\n'
  printf '  7. 修改现有反向代理\n'
  printf '  8. 查看当前反向代理配置\n'
  printf '  9. 删除反向代理\n'
  printf ' 10. 校验并重载 Caddy\n'
  printf ' 11. 查看 Caddy 端口监听与 Docker 映射\n'
  printf ' 12. 检测 Caddy 后端服务监听与连通性\n'
  printf ' 13. 查看 Caddy 服务日志\n'
  printf ' 14. 卸载 Caddy 或 CaddyCtl\n'
  printf ' 15. 443 端口复用（caddy-l4 SNI 分流）\n'
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

  read -r -p "是否查看原始 systemd 服务详情？[y/N，回车默认 N]：" answer
  [[ "$answer" =~ ^[Yy]$ ]] || return 0
  printf '\n%s原始 systemd 服务详情%s\n' "$BOLD" "$RESET"
  systemctl status caddy --no-pager -l 2>/dev/null || true
}

main_menu() {
  local choice
  while true; do
    draw_menu
    read -r -p "请选择 [0-15]：" choice || exit 0
    printf '\n'

    case "$choice" in
      1) update_manager; pause_menu ;;
      2) local_service_listener_assistant; pause_menu ;;
      3) gateway_settings_menu; pause_menu ;;
      4) show_status_detail; pause_menu ;;
      5) install_or_update_caddy; pause_menu ;;
      6) configure_proxy; pause_menu ;;
      7) edit_proxy_config; pause_menu ;;
      8) show_config; pause_menu ;;
      9) delete_proxy; pause_menu ;;
      10) validate_and_reload; pause_menu ;;
      11) show_listeners; pause_menu ;;
      12) diagnose_upstream; pause_menu ;;
      13) show_logs; pause_menu ;;
      14) uninstall_menu; pause_menu ;;
      15) caddy_l4_menu ;;
      0) exit 0 ;;
      *) warn "无效选项：$choice"; pause_menu ;;
    esac
  done
}

if [[ $# -eq 1 && ( "$1" == "--help" || "$1" == "-h" ) ]]; then
  show_command_usage
  exit 0
fi

if [[ $# -eq 1 && ( "$1" == "--listen" || "$1" == "listen" ) ]]; then
  require_root "$@"
  local_service_listener_assistant
  exit $?
fi

if [[ $# -eq 1 && "$1" == "--install" ]]; then
  require_root "$@"
  install_caddy || exit $?
  main_menu
  exit 0
fi

if [[ $# -eq 1 && "$1" == "--install-manager" ]]; then
  require_root "$@"
  install_manager_command || exit $?
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
ensure_manager_commands || exit $?
main_menu
