#!/usr/bin/env bash
#
# SSH terminal menu for the tc port limiter.
# No dialog/whiptail dependency is required.
#
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-/etc/default/limit-ports}"
LIMIT_SCRIPT="${LIMIT_SCRIPT:-/usr/local/sbin/limit_ports.sh}"
[[ -x "$LIMIT_SCRIPT" ]] || LIMIT_SCRIPT="$ROOT_DIR/limit_ports.sh"

if [[ -r "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

NIC="${NIC:-eth0}"
SPEED="${SPEED:-12mbit}"
DEFAULT_RATE="${DEFAULT_RATE:-1000mbit}"
PORT_START="${PORT_START:-10001}"
PORT_END="${PORT_END:-10200}"

ESC=$'\033'
RESET="${ESC}[0m"
BOLD="${ESC}[1m"
CYAN="${ESC}[96m"
GREEN="${ESC}[92m"
DIM="${ESC}[2m"
YELLOW="${ESC}[93m"
RED="${ESC}[91m"
BLUE="${ESC}[94m"

cleanup() {
    printf '%s[?25h%s' "$ESC" "$RESET"
}
trap cleanup EXIT

clear_screen() {
    printf '%s[2J%s[H' "$ESC" "$ESC"
}

pause_screen() {
    printf '\n%s按 Enter 返回主菜单...%s' "$DIM" "$RESET"
    read -r
}

run_root() {
    if (( EUID == 0 )); then
        "$@"
    else
        command -v sudo >/dev/null 2>&1 ||
            die "当前用户不是 root，且系统没有 sudo。"
        sudo "$@"
    fi
}

die() {
    printf '\n%s错误:%s %s\n' "$RED" "$RESET" "$*" >&2
    pause_screen
}

current_rate_mb() {
    case "$1" in
        *mbit) awk "BEGIN { printf \"%.2f MB/s\", ${1%mbit}/8 }" ;;
        *gbit) awk "BEGIN { printf \"%.2f MB/s\", ${1%gbit}*1000/8 }" ;;
        *) printf "%s" "$1" ;;
    esac
}

draw_brand() {
    printf '%s%sPORT//CTL%s\n' "$CYAN" "$BOLD" "$RESET"
    printf '%sSSH 服务器端口控制台  v0.2.0%s\n' "$CYAN" "$RESET"
    printf '%s输入编号进入模块，0 退出，00 刷新%s\n' "$DIM" "$RESET"
}

draw_status() {
    local host
    host="$(hostname 2>/dev/null || printf 'unknown')"
    printf '\n%s主机:%s %-24s %s网卡:%s %-10s %s规则:%s %s\n' \
        "$DIM" "$RESET" "$host" "$DIM" "$RESET" "$NIC" "$DIM" "$RESET" \
        "$(current_rate_mb "$SPEED")"
}

draw_menu() {
    printf '\n%s----------------------------------------%s\n' "$BLUE" "$RESET"
    printf '%s01.%s  %s端口限速%s\n' "$CYAN" "$RESET" "$GREEN" "$RESET"
    printf '%s02.%s  %s系统信息%s\n' "$CYAN" "$RESET" "$GREEN" "$RESET"
    printf '%s03.%s  %s服务管理%s\n' "$CYAN" "$RESET" "$GREEN" "$RESET"
    printf '%s04.%s  %s防火墙规则%s\n' "$CYAN" "$RESET" "$GREEN" "$RESET"
    printf '%s05.%s  %s日志中心%s\n' "$CYAN" "$RESET" "$GREEN" "$RESET"
    printf '%s06.%s  %s脚本更新%s\n' "$CYAN" "$RESET" "$GREEN" "$RESET"
    printf '%s07.%s  %s网络诊断%s\n' "$CYAN" "$RESET" "$GREEN" "$RESET"
    printf '%s08.%s  %s进程查看%s\n' "$CYAN" "$RESET" "$GREEN" "$RESET"
    printf '%s09.%s  %s连接统计%s\n' "$CYAN" "$RESET" "$GREEN" "$RESET"
    printf '%s10.%s  %s系统资源%s\n' "$CYAN" "$RESET" "$GREEN" "$RESET"
    printf '%s11.%s  %s配置中心%s\n' "$CYAN" "$RESET" "$GREEN" "$RESET"
    printf '%s12.%s  %s扩展模块%s\n' "$CYAN" "$RESET" "$GREEN" "$RESET"
    printf '%s----------------------------------------%s\n' "$BLUE" "$RESET"
    printf '%s00.%s  %s刷新状态%s\n' "$CYAN" "$RESET" "$GREEN" "$RESET"
    printf '%s0.%s   %s退出控制台%s\n' "$CYAN" "$RESET" "$GREEN" "$RESET"
}

show_limit_menu() {
    clear_screen
    draw_brand
    printf '\n%s[01] 端口限速%s\n' "$YELLOW" "$RESET"
    printf '%s当前配置:%s %s:%s-%s  %s/端口  (%s)\n' \
        "$DIM" "$RESET" "$NIC" "$PORT_START" "$PORT_END" "$SPEED" \
        "$(current_rate_mb "$SPEED")"
    printf '\n%sA%s 立即应用当前配置\n' "$GREEN" "$RESET"
    printf '%sS%s 临时设置每端口速率\n' "$GREEN" "$RESET"
    printf '%sR%s 查看 tc 规则统计\n' "$GREEN" "$RESET"
    printf '%sB%s 返回主菜单\n' "$GREEN" "$RESET"
    printf '\n%s选择:%s ' "$CYAN" "$RESET"
    read -r choice

    case "${choice,,}" in
        a)
            run_root "$LIMIT_SCRIPT" apply || true
            pause_screen
            ;;
        s)
            printf '输入速率（例如 8mbit、12mbit、20mbit）: '
            read -r new_speed
            if [[ -n "$new_speed" ]]; then
                run_root "$LIMIT_SCRIPT" apply --speed "$new_speed" || true
                SPEED="$new_speed"
            fi
            pause_screen
            ;;
        r)
            run_root tc -s qdisc show dev "$NIC" || true
            run_root tc -s class show dev "$NIC" || true
            pause_screen
            ;;
        b|"") ;;
        *) printf '%s未知选项%s\n' "$RED" "$RESET"; pause_screen ;;
    esac
}

show_system_info() {
    clear_screen
    draw_brand
    printf '\n%s[02] 系统信息%s\n\n' "$YELLOW" "$RESET"
    printf '%s内核:%s %s\n' "$DIM" "$RESET" "$(uname -srmo 2>/dev/null || printf 'unknown')"
    printf '%s主机:%s %s\n' "$DIM" "$RESET" "$(hostname 2>/dev/null || printf 'unknown')"
    printf '%s时间:%s %s\n' "$DIM" "$RESET" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    printf '\n%s网卡状态%s\n' "$CYAN" "$RESET"
    ip -br addr show 2>/dev/null || true
    pause_screen
}

show_service_menu() {
    clear_screen
    draw_brand
    printf '\n%s[03] 服务管理%s\n\n' "$YELLOW" "$RESET"
    printf '%s1%s 启动并设置开机自启\n' "$GREEN" "$RESET"
    printf '%s2%s 重启限速服务\n' "$GREEN" "$RESET"
    printf '%s3%s 停止限速服务\n' "$GREEN" "$RESET"
    printf '%s4%s 查看服务状态\n' "$GREEN" "$RESET"
    printf '%sB%s 返回\n\n' "$GREEN" "$RESET"
    printf '%s选择:%s ' "$CYAN" "$RESET"
    read -r choice
    case "$choice" in
        1)
            run_root systemctl enable --now limit-ports.service || true
            pause_screen
            ;;
        2)
            run_root systemctl restart limit-ports.service || true
            pause_screen
            ;;
        3)
            run_root systemctl stop limit-ports.service || true
            pause_screen
            ;;
        4)
            run_root systemctl --no-pager --full status limit-ports.service || true
            pause_screen
            ;;
        b|B|"") ;;
        *) printf '%s未知选项%s\n' "$RED" "$RESET"; pause_screen ;;
    esac
}

show_logs() {
    clear_screen
    draw_brand
    printf '\n%s[05] 日志中心%s\n\n' "$YELLOW" "$RESET"
    journalctl -u limit-ports.service -n 40 --no-pager 2>/dev/null ||
        printf '%s暂无 systemd 日志。%s\n' "$DIM" "$RESET"
    pause_screen
}

update_script() {
    clear_screen
    draw_brand
    printf '\n%s[06] 脚本更新%s\n\n' "$YELLOW" "$RESET"
    if git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git -C "$ROOT_DIR" pull --ff-only
    else
        printf '%s当前脚本不是 Git 工作目录。%s\n' "$RED" "$RESET"
    fi
    pause_screen
}

show_placeholder() {
    local title="$1"
    clear_screen
    draw_brand
    printf '\n%s%s%s\n\n' "$YELLOW" "$title" "$RESET"
    printf '%s模块入口已预留，后续功能可以直接添加到 portctl.sh。%s\n' "$DIM" "$RESET"
    pause_screen
}

main_menu() {
    while true; do
        clear_screen
        draw_brand
        draw_status
        draw_menu
        printf '\n%s请输入你的选择:%s ' "$GREEN" "$RESET"
        read -r choice
        case "$choice" in
            1|01) show_limit_menu ;;
            2|02) show_system_info ;;
            3|03) show_service_menu ;;
            4|04) show_placeholder "[04] 防火墙规则" ;;
            5|05) show_logs ;;
            6|06) update_script ;;
            7|07) show_placeholder "[07] 网络诊断" ;;
            8|08) show_placeholder "[08] 进程查看" ;;
            9|09) show_placeholder "[09] 连接统计" ;;
            10) show_placeholder "[10] 系统资源" ;;
            11) show_placeholder "[11] 配置中心" ;;
            12) show_placeholder "[12] 扩展模块" ;;
            00) continue ;;
            0|q|Q)
                clear_screen
                printf '%s控制台已退出。%s\n' "$CYAN" "$RESET"
                break
                ;;
            *) printf '%s无效选择，请输入菜单编号。%s\n' "$RED" "$RESET"; sleep 1 ;;
        esac
    done
}

case "${1:-menu}" in
    menu) main_menu ;;
    --help|-h)
        printf '用法: %s [menu]\n' "$0"
        printf 'SSH 登录服务器后直接运行即可。默认进入交互式终端菜单。\n'
        ;;
    *)
        printf '未知参数: %s\n' "$1" >&2
        exit 2
        ;;
esac
