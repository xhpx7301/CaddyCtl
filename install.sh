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

download_manager() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --proto '=https' --tlsv1.2 "$SOURCE_URL" -o "$MANAGER_SCRIPT"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$MANAGER_SCRIPT" "$SOURCE_URL"
  else
    printf '需要 curl 或 wget 才能下载安装程序。\n' >&2
    exit 1
  fi
}

download_manager
chmod 0755 "$MANAGER_SCRIPT"
bash "$MANAGER_SCRIPT" --install
