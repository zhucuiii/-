#!/usr/bin/env bash
#
# One-line installer for the SSH terminal console and tc limiter.
#
set -Eeuo pipefail

RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/zhucuiii/-/main}"
BIN_DIR="${BIN_DIR:-/usr/local/sbin}"
CONFIG_DIR="${CONFIG_DIR:-/etc/default}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
ALIAS_DIR="${ALIAS_DIR:-/usr/local/bin}"
ENABLE_SERVICE=0
OPEN_MENU=1

usage() {
    cat <<'USAGE'
用法:
  install.sh [--enable] [--no-menu]

选项:
  --enable    安装后立即启用并启动 limit-ports.service
  --no-menu   安装完成后不自动打开 SSH 菜单
USAGE
}

for arg in "$@"; do
    case "$arg" in
        --enable) ENABLE_SERVICE=1 ;;
        --no-menu) OPEN_MENU=0 ;;
        -h|--help) usage; exit 0 ;;
        *) printf '未知参数: %s\n' "$arg" >&2; usage >&2; exit 2 ;;
    esac
done

[[ "${EUID}" -eq 0 ]] || {
    printf '请使用 root 运行，例如: sudo bash install.sh\n' >&2
    exit 1
}

download() {
    local url="$1"
    local target="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 "$url" -o "$target"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$target" "$url"
    else
        printf '需要 curl 或 wget。\n' >&2
        exit 1
    fi
    [[ -s "$target" ]] || {
        printf '下载失败或文件为空: %s\n' "$url" >&2
        exit 1
    }
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

printf '[portctl] 下载组件...\n'
download "$RAW_BASE/portctl.sh" "$tmp_dir/portctl.sh"
download "$RAW_BASE/limit_ports.sh" "$tmp_dir/limit_ports.sh"
download "$RAW_BASE/config/limit-ports.example" "$tmp_dir/limit-ports.example"
download "$RAW_BASE/systemd/limit-ports.service" "$tmp_dir/limit-ports.service"

install -d -m 0755 "$BIN_DIR" "$CONFIG_DIR" "$SYSTEMD_DIR" "$ALIAS_DIR"
install -m 0755 "$tmp_dir/portctl.sh" "$BIN_DIR/portctl.sh"
install -m 0755 "$tmp_dir/limit_ports.sh" "$BIN_DIR/limit_ports.sh"
install -m 0644 "$tmp_dir/limit-ports.service" "$SYSTEMD_DIR/limit-ports.service"
ln -sfn "$BIN_DIR/portctl.sh" "$ALIAS_DIR/zc"

if [[ ! -e "$CONFIG_DIR/limit-ports" ]]; then
    install -m 0644 "$tmp_dir/limit-ports.example" "$CONFIG_DIR/limit-ports"
    printf '[portctl] 已创建默认配置: %s/limit-ports\n' "$CONFIG_DIR"
else
    printf '[portctl] 保留现有配置: %s/limit-ports\n' "$CONFIG_DIR"
fi

if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload
    if (( ENABLE_SERVICE )); then
        systemctl enable --now limit-ports.service
        printf '[portctl] limit-ports.service 已启用并启动。\n'
    fi
fi

printf '\n[portctl] 安装完成。\n'
printf '运行控制台: sudo %s/portctl.sh\n' "$BIN_DIR"
printf '快捷命令:   zc\n'
printf '修改配置:   sudo editor %s/limit-ports\n' "$CONFIG_DIR"
printf '应用速率:   sudo %s/limit_ports.sh apply --speed 20mbit\n' "$BIN_DIR"

if (( OPEN_MENU )) && [[ -t 0 && -t 1 ]]; then
    exec "$ALIAS_DIR/zc"
fi
