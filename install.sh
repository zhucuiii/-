#!/usr/bin/env bash
#
# One-line installer for the SSH terminal console and tc limiter.
#
set -Eeuo pipefail

RAW_BASE="${RAW_BASE:-}"
REPOSITORY="${REPOSITORY:-zhucuiii/-}"
INSTALL_REF="${INSTALL_REF:-main}"
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
    local accept="${3:-}"
    local -a headers=()
    if command -v curl >/dev/null 2>&1; then
        [[ -z "$accept" ]] || headers=(-H "Accept: $accept")
        curl -fsSL --retry 3 --connect-timeout 15 --max-time 120 "${headers[@]}" "$url" -o "$target"
    elif command -v wget >/dev/null 2>&1; then
        [[ -z "$accept" ]] || headers=("--header=Accept: $accept")
        wget -q --timeout=120 --tries=3 "${headers[@]}" -O "$target" "$url"
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

if [[ -z "$RAW_BASE" ]]; then
    # Resolve the ref once so all components come from the same commit.
    if [[ "$INSTALL_REF" =~ ^[0-9a-f]{40}$ ]]; then
        commit="$INSTALL_REF"
    else
        download "https://api.github.com/repos/$REPOSITORY/commits/${INSTALL_REF//\//%2F}" "$tmp_dir/ref" application/vnd.github.sha
        commit="$(tr -d '\r\n' <"$tmp_dir/ref")"
        [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || {
            printf '无法解析安装版本，未修改系统文件。\n' >&2
            exit 1
        }
    fi
    RAW_BASE="https://raw.githubusercontent.com/$REPOSITORY/$commit"
    printf '[portctl] 安装版本: %s\n' "$commit"
fi

printf '[portctl] 下载组件...\n'
download "$RAW_BASE/portctl.sh" "$tmp_dir/portctl.sh"
download "$RAW_BASE/policy_engine.sh" "$tmp_dir/policy_engine.sh"
download "$RAW_BASE/limit_ports.sh" "$tmp_dir/limit_ports.sh"
download "$RAW_BASE/config/limit-ports.example" "$tmp_dir/limit-ports.example"
download "$RAW_BASE/systemd/limit-ports.service" "$tmp_dir/limit-ports.service"

for script in portctl.sh policy_engine.sh limit_ports.sh; do
    bash -n "$tmp_dir/$script"
done

install -d -m 0755 "$BIN_DIR" "$CONFIG_DIR" "$SYSTEMD_DIR" "$ALIAS_DIR"
targets=("$BIN_DIR/portctl.sh" "$BIN_DIR/policy_engine.sh" "$BIN_DIR/limit_ports.sh"
    "$SYSTEMD_DIR/limit-ports.service" "$ALIAS_DIR/zc" "$CONFIG_DIR/limit-ports")
mkdir "$tmp_dir/backup"
for i in "${!targets[@]}"; do
    target="${targets[i]}"
    [[ ! -d "$target" || -L "$target" ]] || {
        printf '安装目标是目录: %s\n' "$target" >&2
        exit 1
    }
    if [[ -e "$target" || -L "$target" ]]; then
        cp -a "$target" "$tmp_dir/backup/$i"
    fi
done

rollback_install() {
    local rc="$1" i target
    trap - ERR
    printf '[portctl] 安装失败，正在恢复安装前的文件...\n' >&2
    for i in "${!targets[@]}"; do
        target="${targets[i]}"
        if [[ -e "$tmp_dir/backup/$i" || -L "$tmp_dir/backup/$i" ]]; then
            cp -a --remove-destination "$tmp_dir/backup/$i" "$target" ||
                printf '恢复失败: %s\n' "$target" >&2
        else
            rm -f "$target"
        fi
    done
    command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload || true
    exit "$rc"
}

atomic_install() {
    local mode="$1" source="$2" target="$3" staged
    staged="$(mktemp "$(dirname -- "$target")/.portctl.XXXXXX")" || return 1
    if ! install -m "$mode" "$source" "$staged" || ! mv -fT "$staged" "$target"; then
        rm -f "$staged"
        return 1
    fi
}

trap 'rollback_install "$?"' ERR
atomic_install 0755 "$tmp_dir/portctl.sh" "$BIN_DIR/portctl.sh"
atomic_install 0644 "$tmp_dir/policy_engine.sh" "$BIN_DIR/policy_engine.sh"
atomic_install 0755 "$tmp_dir/limit_ports.sh" "$BIN_DIR/limit_ports.sh"
atomic_install 0644 "$tmp_dir/limit-ports.service" "$SYSTEMD_DIR/limit-ports.service"
ln -sfn "$BIN_DIR/portctl.sh" "$ALIAS_DIR/zc"

if [[ ! -e "$CONFIG_DIR/limit-ports" ]]; then
    atomic_install 0644 "$tmp_dir/limit-ports.example" "$CONFIG_DIR/limit-ports"
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

trap - ERR
printf '\n[portctl] 安装完成。\n'
printf '运行控制台: sudo %s/portctl.sh\n' "$BIN_DIR"
printf '快捷命令:   zc\n'
printf '修改配置:   sudo editor %s/limit-ports\n' "$CONFIG_DIR"
printf '应用速率:   sudo %s/limit_ports.sh apply --speed 20mbit\n' "$BIN_DIR"

if (( OPEN_MENU )) && [[ -t 0 && -t 1 ]]; then
    exec "$ALIAS_DIR/zc"
fi
