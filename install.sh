#!/usr/bin/env bash

# Bootstrap CaddyCtl from the public project repository.
set -Eeuo pipefail

readonly SOURCE_URL="${CADDYCTL_SOURCE_URL:-https://raw.githubusercontent.com/xhpx7301/CaddyCtl/main/caddyctl.sh}"
readonly TEMP_DIR="$(mktemp -d)"
readonly MANAGER_SCRIPT="${TEMP_DIR}/caddyctl.sh"

cleanup() {
  rm -rf -- "$TEMP_DIR"
}
trap cleanup EXIT

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

download_manager() {
  local immutable_url download_url

  immutable_url="$(github_raw_immutable_url "$SOURCE_URL" || true)"
  if [[ -n "$immutable_url" ]] && download_url_to_file "$immutable_url" "$MANAGER_SCRIPT"; then
    return 0
  fi
  download_url="$(cache_busted_github_raw_url "$SOURCE_URL")"
  if ! download_url_to_file "$download_url" "$MANAGER_SCRIPT"; then
    printf '需要可用的 curl 或 wget，且无法下载 CaddyCtl 安装程序。\n' >&2
    return 1
  fi
}

download_manager
chmod 0755 "$MANAGER_SCRIPT"

if [[ ! -r /dev/tty ]]; then
  printf '未检测到可交互终端，无法打开 CaddyCtl 菜单。请在 SSH 终端中运行此命令。\n' >&2
  exit 1
fi

# `curl | bash` consumes standard input, so hand menu input back to the terminal.
bash "$MANAGER_SCRIPT" --install-manager </dev/tty
