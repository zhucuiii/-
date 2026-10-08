#!/usr/bin/env bash
#
# SSH terminal menu for the tc port limiter.
# No dialog/whiptail dependency is required.
#
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-/etc/default/limit-ports}"
LIMIT_SCRIPT="${LIMIT_SCRIPT:-/usr/local/sbin/limit_ports.sh}"
INSTALL_URL="${INSTALL_URL:-https://raw.githubusercontent.com/zhucuiii/-/main/install.sh}"
if [[ ! -f "$LIMIT_SCRIPT" ]]; then
    LIMIT_SCRIPT="$ROOT_DIR/limit_ports.sh"
fi
SELF_PATH="$ROOT_DIR/$(basename -- "${BASH_SOURCE[0]}")"

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

# 非交互场景（systemd 单元、命令行管道）不要输出颜色转义序列。
if [[ ! -t 1 ]]; then
    RESET=""
    BOLD=""
    CYAN=""
    GREEN=""
    DIM=""
    YELLOW=""
    RED=""
    BLUE=""
fi

# Rules reported by `limit_ports.sh rules`, filled by load_rules().
RULE_IDX=()
RULE_START=()
RULE_END=()
RULE_RATE=()
RULE_MODE=()
RULE_PORTS=()
RULES_ERROR=""

cleanup() {
    # 非交互调用（systemd / 命令行）时不要往 stdout 写转义序列。
    if [[ -t 1 ]]; then
        printf '%s[?25h%s' "$ESC" "$RESET"
    fi
}
trap cleanup EXIT

clear_screen() {
    printf '%s[2J%s[H' "$ESC" "$ESC"
}

pause_screen() {
    printf '\n%s按 Enter 返回...%s' "$DIM" "$RESET"
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
    exit 1
}

# Read-only helper: never needs root and never needs the exec bit.
limit_local() {
    bash "$LIMIT_SCRIPT" "$@"
}

# Writable helper: applies tc rules, needs root.
limit_root() {
    run_root bash "$LIMIT_SCRIPT" "$@"
}

current_rate_mb() {
    case "$1" in
        *mbit) awk "BEGIN { printf \"%.2f MB/s\", ${1%mbit}/8 }" ;;
        *gbit) awk "BEGIN { printf \"%.2f MB/s\", ${1%gbit}*1000/8 }" ;;
        *kbit) awk "BEGIN { printf \"%.4f MB/s\", ${1%kbit}/8000 }" ;;
        *) printf "%s" "$1" ;;
    esac
}

port_range_label() {
    if [[ "$1" == "$2" ]]; then
        printf '%s' "$1"
    else
        printf '%s-%s' "$1" "$2"
    fi
}

mode_label() {
    if [[ "$1" == "shared" ]]; then
        printf '区间共享'
    else
        printf '每端口独立'
    fi
}

# ${#var} counts characters only in a UTF-8 locale; probe once so the table
# columns line up even when the SSH session runs in the C locale.
CJK_PROBE='中'
MULTIBYTE=1
if (( ${#CJK_PROBE} == 3 )); then
    MULTIBYTE=0
fi

disp_width() {
    local text="$1" ascii total wide
    ascii="${text//[! -~]/}"
    total=${#text}
    if (( MULTIBYTE )); then
        printf '%s' "$((2 * total - ${#ascii}))"
    else
        wide=$(( (total - ${#ascii}) / 3 ))
        printf '%s' "$(( ${#ascii} + 2 * wide ))"
    fi
}

# pad <text> <display width>: right-pad with spaces to the requested width.
pad() {
    local text="$1" width="$2" current
    current="$(disp_width "$text")"
    printf '%s' "$text"
    while (( current < width )); do
        printf ' '
        current=$((current + 1))
    done
}

draw_brand() {
    printf '%s%sPORT//CTL%s\n' "$CYAN" "$BOLD" "$RESET"
    printf '%sSSH 服务器端口控制台  v0.6.1%s\n' "$CYAN" "$RESET"
    printf '%s输入编号进入模块，0 退出，00 刷新%s\n' "$DIM" "$RESET"
}

draw_status() {
    local host
    host="$(hostname 2>/dev/null || printf 'unknown')"
    printf '\n%s主机:%s %-24s %s网卡:%s %-10s %s默认速率:%s %s\n' \
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
    printf '%s06.%s  %s更新脚本%s\n' "$CYAN" "$RESET" "$GREEN" "$RESET"
    printf '%s07.%s  %s卸载程序%s\n' "$CYAN" "$RESET" "$GREEN" "$RESET"
    printf '%s----------------------------------------%s\n' "$BLUE" "$RESET"
    printf '%s00.%s  %s刷新状态%s\n' "$CYAN" "$RESET" "$GREEN" "$RESET"
    printf '%s0.%s   %s退出控制台%s\n' "$CYAN" "$RESET" "$GREEN" "$RESET"
}

# ---------------------------------------------------------------- port rules

load_rules() {
    RULE_IDX=()
    RULE_START=()
    RULE_END=()
    RULE_RATE=()
    RULE_MODE=()
    RULE_PORTS=()
    RULES_ERROR=""

    # Without a config file nothing is configured. Do not fall back to
    # limit_ports.sh's built-in default range, which the user never chose.
    if [[ ! -f "$CONFIG_FILE" ]]; then
        return 0
    fi

    local out line idx start end rate mode ports
    if ! out="$(limit_local rules 2>&1)"; then
        RULES_ERROR="$out"
        return 1
    fi

    while IFS= read -r line; do
        if [[ -z "$line" || "$line" == '#'* ]]; then
            continue
        fi
        IFS=$'\t' read -r idx start end rate mode ports <<<"$line"
        RULE_IDX+=("$idx")
        RULE_START+=("$start")
        RULE_END+=("$end")
        RULE_RATE+=("$rate")
        RULE_MODE+=("$mode")
        RULE_PORTS+=("$ports")
    done <<<"$out"

    return 0
}

print_rules_table() {
    if (( ${#RULE_IDX[@]} == 0 )); then
        printf '%s  当前没有任何限速端口，应用后不会限制任何端口。%s\n' "$DIM" "$RESET"
        return 0
    fi

    local i total=0 row
    row="  $(pad '编号' 6) $(pad '端口' 18) $(pad '速率' 12) $(pad '方式' 12) 端口数"
    printf '%s%s%s\n' "$DIM" "$row" "$RESET"

    for ((i = 0; i < ${#RULE_IDX[@]}; i++)); do
        total=$((total + RULE_PORTS[i]))
        row="  $(pad "${RULE_IDX[i]}" 6) $(pad "$(port_range_label "${RULE_START[i]}" "${RULE_END[i]}")" 18) $(pad "${RULE_RATE[i]}" 12) $(pad "$(mode_label "${RULE_MODE[i]}")" 12) ${RULE_PORTS[i]}"
        printf '%s%s%s\n' "$CYAN" "$row" "$RESET"
    done

    printf '%s  合计: %s 条规则 / %s 个端口%s\n' \
        "$DIM" "${#RULE_IDX[@]}" "$total" "$RESET"
}

print_rule_by_index() {
    local want="$1" i row
    for ((i = 0; i < ${#RULE_IDX[@]}; i++)); do
        if [[ "${RULE_IDX[i]}" == "$want" ]]; then
            row="  $(pad "${RULE_IDX[i]}" 6) $(pad "$(port_range_label "${RULE_START[i]}" "${RULE_END[i]}")" 18) $(pad "${RULE_RATE[i]}" 12) $(pad "$(mode_label "${RULE_MODE[i]}")" 12) ${RULE_PORTS[i]} 端口"
            printf '%s%s%s\n' "$CYAN" "$row" "$RESET"
            return 0
        fi
    done
    return 1
}

rule_to_spec() {
    local i="$1"
    local rate="${2:-${RULE_RATE[i]}}"
    local spec
    if [[ "${RULE_START[i]}" == "${RULE_END[i]}" ]]; then
        spec="${RULE_START[i]}=${rate}"
    else
        spec="${RULE_START[i]}-${RULE_END[i]}=${rate}"
    fi
    if [[ "${RULE_MODE[i]}" == "shared" ]]; then
        spec="${spec}@shared"
    fi
    printf '%s' "$spec"
}

prompt_port() {
    local prompt="$1" value
    while true; do
        printf '%s%s%s ' "$CYAN" "$prompt" "$RESET" >&2
        read -r value || return 1
        if ! [[ "$value" =~ ^[0-9]+$ ]]; then
            printf '%s请输入数字端口。%s\n' "$RED" "$RESET" >&2
            continue
        fi
        if (( value < 1 || value > 65535 )); then
            printf '%s端口必须在 1-65535 之间。%s\n' "$RED" "$RESET" >&2
            continue
        fi
        printf '%s' "$value"
        return 0
    done
}

prompt_rate() {
    local label="$1" value unit new_rate
    while true; do
        printf '%s输入%s速率数值（只输入数字，例如 8、12、20）:%s ' \
            "$CYAN" "$label" "$RESET" >&2
        read -r value || return 1
        if [[ "$value" =~ ^([0-9]+([.][0-9]+)?)$ ]] &&
            awk "BEGIN { exit !($value > 0) }"; then
            break
        fi
        printf '%s请输入大于 0 的数字。%s\n' "$RED" "$RESET" >&2
    done

    printf '\n%s请选择计量单位:%s\n' "$CYAN" "$RESET" >&2
    printf '%s1.%s Mbit/s（兆比特/秒）\n' "$GREEN" "$RESET" >&2
    printf '%s2.%s MB/s（兆字节/秒）\n' "$GREEN" "$RESET" >&2
    printf '%s3.%s Gbit/s（千兆比特/秒）\n' "$GREEN" "$RESET" >&2
    printf '%s4.%s GB/s（千兆字节/秒）\n' "$GREEN" "$RESET" >&2
    printf '%s选择单位:%s ' "$CYAN" "$RESET" >&2
    read -r unit || return 1

    case "$unit" in
        1) new_rate="${value}mbit" ;;
        2) new_rate="$(awk "BEGIN { printf \"%.6gmbit\", $value * 8 }")" ;;
        3) new_rate="${value}gbit" ;;
        4) new_rate="$(awk "BEGIN { printf \"%.6ggbit\", $value * 8 }")" ;;
        *)
            printf '%s单位选择无效。%s\n' "$RED" "$RESET" >&2
            return 1
            ;;
    esac

    printf '%s' "$new_rate"
    return 0
}

# Upsert KEY="VALUE" pairs in the config file and comment out the legacy
# PORT_START/PORT_END keys, which PORT_SPEC replaces.
config_apply_edits() {
    local tmp stage pair key value
    tmp="$(mktemp)" || {
        printf '%s无法创建临时文件。%s\n' "$RED" "$RESET"
        return 1
    }

    if [[ -f "$CONFIG_FILE" ]]; then
        cat "$CONFIG_FILE" >"$tmp"
    else
        {
            printf '# 由 portctl 菜单创建\n'
            printf 'NIC="%s"\n' "$NIC"
            printf 'DEFAULT_RATE="%s"\n' "$DEFAULT_RATE"
        } >"$tmp"
    fi

    for pair in "$@"; do
        key="${pair%%=*}"
        value="${pair#*=}"
        stage="$(mktemp)" || {
            rm -f "$tmp"
            return 1
        }
        awk -v k="$key" -v v="$value" '
            BEGIN { done = 0 }
            $0 ~ "^[[:space:]]*" k "=" {
                if (!done) { printf "%s=\"%s\"\n", k, v; done = 1 }
                next
            }
            { print }
            END { if (!done) { print ""; printf "%s=\"%s\"\n", k, v } }
        ' "$tmp" >"$stage"
        mv -f "$stage" "$tmp"
    done

    stage="$(mktemp)" || {
        rm -f "$tmp"
        return 1
    }
    awk '
        /^[[:space:]]*(PORT_START|PORT_END)=/ { print "# 已由 PORT_SPEC 取代: " $0; next }
        { print }
    ' "$tmp" >"$stage"
    mv -f "$stage" "$tmp"

    if ! run_root install -m 0644 "$tmp" "$CONFIG_FILE"; then
        rm -f "$tmp"
        printf '%s写入配置失败: %s%s\n' "$RED" "$CONFIG_FILE" "$RESET"
        return 1
    fi

    rm -f "$tmp"
    return 0
}

apply_after_change() {
    local answer
    printf '\n%s现在立即应用新规则？[Y/n]:%s ' "$CYAN" "$RESET"
    read -r answer
    if [[ -z "$answer" || "${answer,,}" == "y" || "${answer,,}" == "yes" ]]; then
        printf '\n'
        limit_root apply || true
    else
        printf '%s已保存到配置，之后可在菜单里选择「1. 立即应用当前配置」。%s\n' \
            "$DIM" "$RESET"
    fi
    pause_screen
}

# 2/3: add a range or a single port, replacing overlapping rules.
add_rule_flow() {
    local kind="$1"
    local start end rate mode mode_choice answer

    clear_screen
    draw_brand
    if [[ "$kind" == "single" ]]; then
        printf '\n%s[01-3] 单端口限速%s\n\n' "$YELLOW" "$RESET"
    else
        printf '\n%s[01-2] 区间限速%s\n\n' "$YELLOW" "$RESET"
    fi

    start="$(prompt_port '起始端口:')" || {
        pause_screen
        return
    }

    if [[ "$kind" == "single" ]]; then
        end="$start"
    else
        while true; do
            end="$(prompt_port '结束端口:')" || {
                pause_screen
                return
            }
            if (( end >= start )); then
                break
            fi
            printf '%s结束端口不能小于起始端口 %s。%s\n' "$RED" "$start" "$RESET"
        done
    fi

    rate="$(prompt_rate '限速')" || {
        pause_screen
        return
    }

    mode="per-port"
    if [[ "$kind" == "range" ]]; then
        printf '\n%s请选择限速方式:%s\n' "$CYAN" "$RESET"
        printf '%s1.%s 每端口独立：区间内每个端口各自 %s\n' \
            "$GREEN" "$RESET" "$rate"
        printf '%s2.%s 区间共享：%s-%s 合计 %s\n' \
            "$GREEN" "$RESET" "$start" "$end" "$rate"
        printf '%s选择 [1]:%s ' "$CYAN" "$RESET"
        read -r mode_choice
        case "$mode_choice" in
            ""|1) mode="per-port" ;;
            2) mode="shared" ;;
            *)
                printf '%s已取消。%s\n' "$DIM" "$RESET"
                pause_screen
                return
                ;;
        esac
    fi

    local new_rule
    if [[ "$start" == "$end" ]]; then
        new_rule="${start}=${rate}"
    else
        new_rule="${start}-${end}=${rate}"
    fi
    if [[ "$mode" == "shared" ]]; then
        new_rule="${new_rule}@shared"
    fi

    commit_new_rule "$new_rule" "$start" "$end"
}

commit_new_rule() {
    local new_rule="$1" start="$2" end="$3"
    local i c answer spec skipped

    if ! load_rules; then
        printf '\n%s读取现有规则失败:%s\n%s\n' "$RED" "$RESET" "$RULES_ERROR"
        pause_screen
        return
    fi

    local -a conflicts=()
    for ((i = 0; i < ${#RULE_IDX[@]}; i++)); do
        if (( RULE_START[i] <= end && start <= RULE_END[i] )); then
            conflicts+=("${RULE_IDX[i]}")
        fi
    done

    if (( ${#conflicts[@]} > 0 )); then
        printf '\n%s新规则 %s 与下列已有规则重叠，将被替换:%s\n' \
            "$YELLOW" "$new_rule" "$RESET"
        for c in "${conflicts[@]}"; do
            print_rule_by_index "$c" || true
        done
        printf '\n%s确认替换？[y/N]:%s ' "$YELLOW" "$RESET"
        read -r answer
        if [[ "${answer,,}" != "y" && "${answer,,}" != "yes" ]]; then
            printf '%s已取消。%s\n' "$DIM" "$RESET"
            pause_screen
            return
        fi
    fi

    spec=""
    for ((i = 0; i < ${#RULE_IDX[@]}; i++)); do
        skipped=0
        for c in ${conflicts[@]+"${conflicts[@]}"}; do
            if [[ "$c" == "${RULE_IDX[i]}" ]]; then
                skipped=1
            fi
        done
        if (( skipped )); then
            continue
        fi
        if [[ -z "$spec" ]]; then
            spec="$(rule_to_spec "$i")"
        else
            spec="$spec $(rule_to_spec "$i")"
        fi
    done

    # Keep the existing order and append the new rule at the end.
    if [[ -z "$spec" ]]; then
        spec="$new_rule"
    else
        spec="$spec $new_rule"
    fi

    printf '\n%s新的完整规则:%s %s\n' "$DIM" "$RESET" "$spec"
    if config_apply_edits "PORT_SPEC=$spec"; then
        printf '%s已写入 %s%s\n' "$GREEN" "$CONFIG_FILE" "$RESET"
        apply_after_change
    else
        pause_screen
    fi
}

# 4: rewrite every rule with one rate.
change_all_rates() {
    local i rate spec piece

    clear_screen
    draw_brand
    printf '\n%s[01-4] 统一修改全部规则速率%s\n\n' "$YELLOW" "$RESET"

    if ! load_rules; then
        printf '%s读取规则失败:%s\n%s\n' "$RED" "$RESET" "$RULES_ERROR"
        pause_screen
        return
    fi
    print_rules_table
    if (( ${#RULE_IDX[@]} == 0 )); then
        pause_screen
        return
    fi

    printf '\n'
    rate="$(prompt_rate '统一')" || {
        pause_screen
        return
    }

    spec=""
    for ((i = 0; i < ${#RULE_IDX[@]}; i++)); do
        piece="$(rule_to_spec "$i" "$rate")"
        if [[ -z "$spec" ]]; then
            spec="$piece"
        else
            spec="$spec $piece"
        fi
    done

    printf '\n%s新规则:%s %s\n' "$DIM" "$RESET" "$spec"
    if config_apply_edits "SPEED=$rate" "PORT_SPEC=$spec"; then
        SPEED="$rate"
        printf '%s已写入 %s%s\n' "$GREEN" "$CONFIG_FILE" "$RESET"
        apply_after_change
    else
        pause_screen
    fi
}

# 5: delete selected rules.
delete_rules() {
    local answer token found i skip spec

    clear_screen
    draw_brand
    printf '\n%s[01-5] 删除限速规则%s\n\n' "$YELLOW" "$RESET"

    if ! load_rules; then
        printf '%s读取规则失败:%s\n%s\n' "$RED" "$RESET" "$RULES_ERROR"
        pause_screen
        return
    fi
    print_rules_table
    if (( ${#RULE_IDX[@]} == 0 )); then
        pause_screen
        return
    fi

    printf '\n%s输入要删除的规则编号（多个用空格分隔，直接回车取消）:%s ' \
        "$CYAN" "$RESET"
    read -r answer
    if [[ -z "$answer" ]]; then
        pause_screen
        return
    fi

    local -a del=()
    read -r -a del <<<"$answer"

    for token in "${del[@]}"; do
        if ! [[ "$token" =~ ^[0-9]+$ ]]; then
            printf '%s规则编号无效: %s%s\n' "$RED" "$token" "$RESET"
            pause_screen
            return
        fi
        found=0
        for ((i = 0; i < ${#RULE_IDX[@]}; i++)); do
            if [[ "${RULE_IDX[i]}" == "$token" ]]; then
                found=1
            fi
        done
        if (( found == 0 )); then
            printf '%s没有编号为 %s 的规则。%s\n' "$RED" "$token" "$RESET"
            pause_screen
            return
        fi
    done

    spec=""
    for ((i = 0; i < ${#RULE_IDX[@]}; i++)); do
        skip=0
        for token in "${del[@]}"; do
            if [[ "$token" == "${RULE_IDX[i]}" ]]; then
                skip=1
            fi
        done
        if (( skip )); then
            continue
        fi
        if [[ -z "$spec" ]]; then
            spec="$(rule_to_spec "$i")"
        else
            spec="$spec $(rule_to_spec "$i")"
        fi
    done

    printf '\n%s删除后剩余规则:%s %s\n' \
        "$DIM" "$RESET" "${spec:-（空，将不再限制任何端口）}"
    if config_apply_edits "PORT_SPEC=$spec"; then
        printf '%s已写入 %s%s\n' "$GREEN" "$CONFIG_FILE" "$RESET"
        apply_after_change
    else
        pause_screen
    fi
}

# 6: remove every rule.
clear_rules() {
    local answer

    clear_screen
    draw_brand
    printf '\n%s[01-6] 清空全部限速规则%s\n\n' "$YELLOW" "$RESET"

    if ! load_rules; then
        printf '%s读取规则失败:%s\n%s\n' "$RED" "$RESET" "$RULES_ERROR"
        pause_screen
        return
    fi
    print_rules_table

    printf '\n%s这会删除配置里的全部端口规则，应用后只剩默认队列。%s\n' \
        "$RED" "$RESET"
    printf '确认清空请输入 %sYES%s，其他输入取消: ' "$RED" "$RESET"
    read -r answer
    if [[ "$answer" != "YES" ]]; then
        printf '%s已取消。%s\n' "$DIM" "$RESET"
        pause_screen
        return
    fi

    if config_apply_edits 'PORT_SPEC='; then
        printf '%s已清空端口规则。%s\n' "$GREEN" "$RESET"
        apply_after_change
    else
        pause_screen
    fi
}

show_limit_menu() {
    local choice

    while true; do
        clear_screen
        draw_brand
        printf '\n%s[01] 端口限速%s\n' "$YELLOW" "$RESET"
        printf '%s网卡:%s %s    %s默认速率:%s %s (%s)\n' \
            "$DIM" "$RESET" "$NIC" "$DIM" "$RESET" "$SPEED" \
            "$(current_rate_mb "$SPEED")"

        printf '\n%s当前限速规则%s\n' "$CYAN" "$RESET"
        if load_rules; then
            print_rules_table
        else
            printf '%s  读取规则失败: %s%s\n' "$RED" "$RULES_ERROR" "$RESET"
        fi

        printf '\n%s1.%s 立即应用当前配置\n' "$GREEN" "$RESET"
        printf '%s2.%s 区间限速（批量端口）\n' "$GREEN" "$RESET"
        printf '%s3.%s 单端口限速\n' "$GREEN" "$RESET"
        printf '%s4.%s 统一修改全部规则速率\n' "$GREEN" "$RESET"
        printf '%s5.%s 删除限速规则\n' "$GREEN" "$RESET"
        printf '%s6.%s 清空全部规则\n' "$GREEN" "$RESET"
        printf '%s7.%s 查看 tc 规则统计\n' "$GREEN" "$RESET"
        printf '%s0.%s 返回主菜单\n' "$GREEN" "$RESET"
        printf '\n%s选择:%s ' "$CYAN" "$RESET"
        read -r choice

        case "$choice" in
            1)
                limit_root apply || true
                pause_screen
                ;;
            2) add_rule_flow range ;;
            3) add_rule_flow single ;;
            4) change_all_rates ;;
            5) delete_rules ;;
            6) clear_rules ;;
            7)
                run_root tc -s qdisc show dev "$NIC" || true
                run_root tc -s class show dev "$NIC" || true
                pause_screen
                ;;
            0|"") return ;;
            *)
                printf '%s请输入 1-7 或 0。%s\n' "$RED" "$RESET"
                pause_screen
                ;;
        esac
    done
}

# --------------------------------------------------------------- firewall
#
# The firewall module keeps its own declarative rule list in
# /etc/default/portctl-firewall.conf and owns a dedicated chain (iptables)
# or table (nftables) per backend, so listing, deleting and clearing rules
# are exact operations instead of scraping `iptables -L` output.
#
# Rule syntax, one per line:
#     <allow|deny> <tcp|udp|all> <port|start-end|all> [from <IP|CIDR>]
#
# Every rule matches NEW connections only (ct state new), so applying a
# ruleset never tears down an established session, including the SSH
# session the menu is running in.

FW_CONF_FILE="${FW_CONF_FILE:-/etc/default/portctl-firewall.conf}"
FW_STATE_FILE="${FW_STATE_FILE:-/var/lib/portctl/firewall.ufw}"
FW_UNIT_FILE="${FW_UNIT_FILE:-/etc/systemd/system/portctl-firewall.service}"
FW_UNIT_NAME="portctl-firewall.service"
FW_IPT_CHAIN="PORTCTL"
FW_NFT_TABLE="portctl"

FW_BACKEND_CFG="auto"
FW_SSH_PROTECT="yes"
FW_ACT=()
FW_PROTO=()
FW_PSTART=()
FW_PEND=()
FW_SRC=()
FW_NOTES=""

fw_action_label() {
    if [[ "$1" == "allow" ]]; then
        printf '放行'
    else
        printf '封禁'
    fi
}

fw_proto_label() {
    case "$1" in
        tcp) printf 'tcp' ;;
        udp) printf 'udp' ;;
        *) printf 'all' ;;
    esac
}

fw_ports_text() {
    local i="$1"
    if [[ "${FW_PSTART[i]}" == "all" ]]; then
        printf 'all'
    elif [[ "${FW_PSTART[i]}" == "${FW_PEND[i]}" ]]; then
        printf '%s' "${FW_PSTART[i]}"
    else
        printf '%s-%s' "${FW_PSTART[i]}" "${FW_PEND[i]}"
    fi
}

# 规范写法，必须能被 fw_load 再解析回去（写入配置文件用这个）。
fw_rule_text() {
    local i="$1" text
    text="${FW_ACT[i]} ${FW_PROTO[i]} $(fw_ports_text "$i")"
    if [[ -n "${FW_SRC[i]}" ]]; then
        text="$text from ${FW_SRC[i]}"
    fi
    printf '%s' "$text"
}

# 中文写法，只用于界面显示。
fw_rule_display() {
    local i="$1" text
    text="$(fw_action_label "${FW_ACT[i]}") $(fw_proto_label "${FW_PROTO[i]}") $(fw_ports_text "$i")"
    if [[ -n "${FW_SRC[i]}" ]]; then
        text="$text from ${FW_SRC[i]}"
    fi
    printf '%s' "$text"
}

fw_norm_port() {
    local value="$1"
    [[ "$value" =~ ^[0-9]+$ ]] || return 1
    printf '%s' "$((10#$value))"
}

is_ipv4_addr() {
    local -a octets=()
    IFS=. read -r -a octets <<<"${1%%/*}"
    if (( ${#octets[@]} != 4 )); then
        return 1
    fi
    local part
    for part in "${octets[@]}"; do
        [[ "$part" =~ ^[0-9]{1,3}$ ]] || return 1
        (( 10#$part <= 255 )) || return 1
    done
    return 0
}

is_ipv6_addr() {
    local ip="${1%%/*}"
    [[ "$ip" == *:* ]] || return 1
    [[ "$ip" =~ ^[0-9a-fA-F:]+$ ]] || return 1
    return 0
}

is_ip_or_cidr() {
    local value="$1" bits=""
    [[ -n "$value" ]] || return 1
    if [[ "$value" == */* ]]; then
        bits="${value#*/}"
        [[ "$bits" =~ ^[0-9]{1,3}$ ]] || return 1
    fi
    if is_ipv4_addr "$value"; then
        if [[ -n "$bits" ]]; then
            (( 10#$bits <= 32 )) || return 1
        fi
        return 0
    fi
    if is_ipv6_addr "$value"; then
        if [[ -n "$bits" ]]; then
            (( 10#$bits <= 128 )) || return 1
        fi
        return 0
    fi
    return 1
}

ipv4_to_int() {
    local -a octets=()
    IFS=. read -r -a octets <<<"$1"
    printf '%s' "$(( (10#${octets[0]} << 24) | (10#${octets[1]} << 16) | (10#${octets[2]} << 8) | 10#${octets[3]} ))"
}

# fw_cidr_covers <network|ip> <ip>
fw_cidr_covers() {
    local network="$1" ip="$2"
    [[ -n "$ip" ]] || return 1
    if [[ "$network" == */* ]]; then
        local base="${network%%/*}" bits="${network#*/}"
        if [[ "$base" == *:* || "$ip" == *:* ]]; then
            [[ "$base" == "$ip" ]] && return 0
            return 1
        fi
        [[ "$bits" =~ ^[0-9]+$ ]] || return 1
        (( bits >= 0 && bits <= 32 )) || return 1
        local mask
        mask=$(( (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
        if (( ($(ipv4_to_int "$base") & mask) == ($(ipv4_to_int "$ip") & mask) )); then
            return 0
        fi
        return 1
    fi
    if [[ "$network" == "$ip" ]]; then
        return 0
    fi
    return 1
}

fw_parse_rule_line() {
    local line="$1" where="$2" lineno="$3"
    local -a fields=()
    local action proto ports start end src="" problem="" loc="$where"

    read -r -a fields <<<"$line"
    action="${fields[0]}"
    proto="${fields[1]:-all}"
    ports="${fields[2]:-all}"

    case "$action" in
        allow) action="allow" ;;
        deny|drop|reject) action="deny" ;;
        *) problem="动作只能是 allow 或 deny" ;;
    esac

    case "${proto,,}" in
        tcp) proto="tcp" ;;
        udp) proto="udp" ;;
        all|any|"") proto="all" ;;
        *) problem="协议只能是 tcp / udp / all" ;;
    esac

    if [[ -z "$problem" ]]; then
        if [[ "$ports" == "all" || "$ports" == "*" || "$ports" == "any" ]]; then
            start="all"
            end="all"
        else
            if [[ "$ports" == *-* ]]; then
                start="${ports%%-*}"
                end="${ports#*-}"
            else
                start="$ports"
                end="$ports"
            fi
            if ! start="$(fw_norm_port "$start")" || ! end="$(fw_norm_port "$end")"; then
                problem="端口只能是数字、区间或 all"
            elif (( start < 1 || end > 65535 || end < start )); then
                problem="端口区间无效: $ports"
            fi
        fi
    fi

    if [[ -z "$problem" ]] && (( ${#fields[@]} >= 5 )) && [[ "${fields[3]}" == "from" ]]; then
        src="${fields[4]}"
        if ! is_ip_or_cidr "$src"; then
            problem="来源地址无效: $src"
        fi
    fi

    if [[ -n "$problem" ]]; then
        if [[ -n "$lineno" && "$lineno" != "0" ]]; then
            loc="$where 第 $lineno 行"
        fi
        FW_NOTES="${FW_NOTES}  ${loc}已忽略（${problem}）: $line"$'\n'
        return 0
    fi

    FW_ACT+=("$action")
    FW_PROTO+=("$proto")
    FW_PSTART+=("$start")
    FW_PEND+=("$end")
    FW_SRC+=("$src")
    return 0
}

# FW_EXTRA_RULES (optional, environment) holds rules applied for this run
# only; the menu uses it for the SSH lockout protection rule.
fw_load() {
    FW_BACKEND_CFG="auto"
    FW_SSH_PROTECT="yes"
    FW_ACT=()
    FW_PROTO=()
    FW_PSTART=()
    FW_PEND=()
    FW_SRC=()
    FW_NOTES=""

    local line lineno=0
    local -a fields=()

    if [[ -n "${FW_EXTRA_RULES:-}" ]]; then
        while IFS= read -r line; do
            if [[ -n "${line//[[:space:]]/}" ]]; then
                fw_parse_rule_line "$line" "临时规则" 0
            fi
        done <<<"$FW_EXTRA_RULES"
    fi

    [[ -f "$FW_CONF_FILE" ]] || return 0

    while IFS= read -r line; do
        lineno=$((lineno + 1))
        line="${line%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"
        if [[ -z "$line" || "$line" == '#'* ]]; then
            continue
        fi
        read -r -a fields <<<"$line"
        case "${fields[0]}" in
            backend)
                FW_BACKEND_CFG="${fields[1]:-auto}"
                continue
                ;;
            ssh-protect)
                FW_SSH_PROTECT="${fields[1]:-yes}"
                continue
                ;;
        esac
        fw_parse_rule_line "$line" "$(basename -- "$FW_CONF_FILE")" "$lineno"
    done <"$FW_CONF_FILE"

    return 0
}

fw_save() {
    local tmp i
    tmp="$(mktemp)" || {
        printf '%s无法创建临时文件。%s\n' "$RED" "$RESET"
        return 1
    }

    {
        printf '# portctl 防火墙规则（由控制台 [04] 菜单维护）\n'
        printf '# 语法: <allow|deny> <tcp|udp|all> <端口|起始-结束|all> [from <IP|CIDR>]\n'
        printf '# 规则按顺序匹配，第一条命中生效；只影响新建连接。\n'
        printf 'backend %s\n' "$FW_BACKEND_CFG"
        printf 'ssh-protect %s\n' "$FW_SSH_PROTECT"
        printf '\n'
        for ((i = 0; i < ${#FW_ACT[@]}; i++)); do
            printf '%s\n' "$(fw_rule_text "$i")"
        done
    } >"$tmp"

    if ! run_root install -m 0644 "$tmp" "$FW_CONF_FILE"; then
        rm -f "$tmp"
        printf '%s写入配置失败: %s%s\n' "$RED" "$FW_CONF_FILE" "$RESET"
        return 1
    fi
    rm -f "$tmp"
    return 0
}

fw_detect_backend() {
    if command -v iptables >/dev/null 2>&1; then
        printf 'iptables'
    elif command -v nft >/dev/null 2>&1; then
        printf 'nft'
    elif command -v ufw >/dev/null 2>&1; then
        printf 'ufw'
    else
        printf 'none'
    fi
}

fw_backend() {
    case "$FW_BACKEND_CFG" in
        iptables|nft|ufw) printf '%s' "$FW_BACKEND_CFG" ;;
        *) fw_detect_backend ;;
    esac
}

fw_backend_label() {
    case "$1" in
        iptables) printf 'iptables' ;;
        nft) printf 'nftables' ;;
        ufw) printf 'ufw' ;;
        *) printf '未找到' ;;
    esac
}

# ------------------------------------------------- SSH lockout protection

fw_ssh_ports() {
    local collected="" conn="${SSH_CONNECTION:-}" port
    if [[ -n "$conn" ]]; then
        port="$(awk '{ print $4 }' <<<"$conn")"
        if [[ "$port" =~ ^[0-9]+$ ]]; then
            collected="$collected $port"
        fi
    fi
    if command -v sshd >/dev/null 2>&1; then
        collected="$collected $(sshd -T 2>/dev/null | awk 'tolower($1)=="port"{print $2}' | tr '\n' ' ')"
    fi
    if [[ -r /etc/ssh/sshd_config ]]; then
        collected="$collected $(awk 'tolower($1)=="port"{print $2}' /etc/ssh/sshd_config 2>/dev/null | tr '\n' ' ')"
    fi
    collected="$(printf '%s\n' $collected | grep -E '^[0-9]+$' | sort -un | tr '\n' ' ' || true)"
    if [[ -z "${collected// /}" ]]; then
        collected="22 "
    fi
    printf '%s' "$collected"
}

fw_client_ip() {
    local conn="${SSH_CONNECTION:-}"
    if [[ -n "$conn" ]]; then
        printf '%s' "${conn%% *}"
    fi
}

fw_rule_covers_port() {
    local i="$1" port="$2"
    if [[ "${FW_PSTART[i]}" == "all" ]]; then
        return 0
    fi
    if (( port >= FW_PSTART[i] && port <= FW_PEND[i] )); then
        return 0
    fi
    return 1
}

# Prints the problems it finds; exits non-zero when the ruleset would cut
# off new SSH connections.
fw_safety_check() {
    local ssh_ports ip i j port risky=0 covers allowed src
    ssh_ports="$(fw_ssh_ports)"
    ip="$(fw_client_ip)"

    for ((i = 0; i < ${#FW_ACT[@]}; i++)); do
        if [[ "${FW_ACT[i]}" != "deny" ]]; then
            continue
        fi

        covers=0
        for port in $ssh_ports; do
            if fw_rule_covers_port "$i" "$port"; then
                covers=1
            fi
        done
        if (( covers == 0 )); then
            continue
        fi

        src="${FW_SRC[i]}"
        if [[ -n "$src" ]] && ! fw_cidr_covers "$src" "$ip"; then
            continue
        fi

        allowed=0
        for ((j = 0; j < i; j++)); do
            if [[ "${FW_ACT[j]}" != "allow" ]]; then
                continue
            fi
            if [[ -n "${FW_SRC[j]}" ]] && ! fw_cidr_covers "${FW_SRC[j]}" "$ip"; then
                continue
            fi
            for port in $ssh_ports; do
                if fw_rule_covers_port "$j" "$port"; then
                    allowed=1
                fi
            done
        done

        if (( allowed == 0 )); then
            printf '  规则 %s（%s）会封禁 SSH 端口 %s 的新连接\n' \
                "$((i + 1))" "$(fw_rule_display "$i")" "$ssh_ports"
            risky=1
        fi
    done

    if (( risky == 0 )); then
        return 0
    fi
    return 1
}

fw_ssh_protect_rule() {
    local ip port text=""
    ip="$(fw_client_ip)"
    [[ -n "$ip" ]] || return 1
    for port in $(fw_ssh_ports); do
        text="$text"$'\n'"allow tcp $port from $ip"
    done
    printf '%s' "${text#$'\n'}"
}

# --------------------------------------------------------------- applying

# Rules that carry no source address apply to both families.
fw_src_family() {
    if [[ -z "$1" ]]; then
        printf 'both'
    elif [[ "$1" == *:* ]]; then
        printf '6'
    else
        printf '4'
    fi
}

fw_need_family() {
    local want="$1" i family
    for ((i = 0; i < ${#FW_ACT[@]}; i++)); do
        family="$(fw_src_family "${FW_SRC[i]}")"
        if [[ "$family" == "both" || "$family" == "$want" ]]; then
            return 0
        fi
    done
    return 1
}

# "all" protocol with a specific port has to become separate tcp and udp rules.
fw_rule_protos() {
    local i="$1"
    if [[ "${FW_PROTO[i]}" == "all" ]]; then
        if [[ "${FW_PSTART[i]}" == "all" ]]; then
            printf 'all'
        else
            printf 'tcp udp'
        fi
    else
        printf '%s' "${FW_PROTO[i]}"
    fi
}

fw_iptables_emit() {
    local cmd="$1" i="$2" proto="$3"
    local -a args=(-A "$FW_IPT_CHAIN")

    if [[ -n "${FW_SRC[i]}" ]]; then
        args+=(-s "${FW_SRC[i]}")
    fi
    args+=(-m conntrack --ctstate NEW)
    if [[ "$proto" != "all" ]]; then
        args+=(-p "$proto")
    fi
    if [[ "${FW_PSTART[i]}" != "all" ]]; then
        if [[ "${FW_PSTART[i]}" == "${FW_PEND[i]}" ]]; then
            args+=(--dport "${FW_PSTART[i]}")
        else
            args+=(--dport "${FW_PSTART[i]}:${FW_PEND[i]}")
        fi
    fi
    if [[ "${FW_ACT[i]}" == "allow" ]]; then
        args+=(-j ACCEPT)
    else
        args+=(-j DROP)
    fi

    "$cmd" "${args[@]}"
}

fw_iptables_teardown() {
    local cmd
    for cmd in iptables ip6tables; do
        command -v "$cmd" >/dev/null 2>&1 || continue
        "$cmd" -D INPUT -j "$FW_IPT_CHAIN" 2>/dev/null || true
        "$cmd" -F "$FW_IPT_CHAIN" 2>/dev/null || true
        "$cmd" -X "$FW_IPT_CHAIN" 2>/dev/null || true
    done
    return 0
}

fw_iptables_apply() {
    local -a cmds=()
    if fw_need_family 4; then
        cmds+=(iptables)
    fi
    if command -v ip6tables >/dev/null 2>&1 && fw_need_family 6; then
        cmds+=(ip6tables)
    fi

    fw_iptables_teardown

    if (( ${#cmds[@]} == 0 )); then
        printf '[firewall] 没有规则需要下发，链 %s 已移除。\n' "$FW_IPT_CHAIN"
        return 0
    fi

    local cmd i proto target family
    for cmd in "${cmds[@]}"; do
        if ! "$cmd" -N "$FW_IPT_CHAIN" 2>/dev/null; then
            "$cmd" -F "$FW_IPT_CHAIN" 2>/dev/null || true
        fi
        if ! "$cmd" -I INPUT 1 -j "$FW_IPT_CHAIN"; then
            printf '[firewall] 无法把链 %s 挂到 %s 的 INPUT 上。\n' \
                "$FW_IPT_CHAIN" "$cmd" >&2
            return 1
        fi
    done

    for ((i = 0; i < ${#FW_ACT[@]}; i++)); do
        family="$(fw_src_family "${FW_SRC[i]}")"
        for proto in $(fw_rule_protos "$i"); do
            for target in "${cmds[@]}"; do
                if [[ "$family" == "4" && "$target" == "ip6tables" ]]; then
                    continue
                fi
                if [[ "$family" == "6" && "$target" == "iptables" ]]; then
                    continue
                fi
                fw_iptables_emit "$target" "$i" "$proto" || return 1
            done
        done
    done

    printf '[firewall] 已下发 %s 条规则到链 %s（%s）。\n' \
        "${#FW_ACT[@]}" "$FW_IPT_CHAIN" "${cmds[*]}"
    return 0
}

fw_nft_ports() {
    local i="$1"
    if [[ "${FW_PSTART[i]}" == "${FW_PEND[i]}" ]]; then
        printf '%s' "${FW_PSTART[i]}"
    else
        printf '%s-%s' "${FW_PSTART[i]}" "${FW_PEND[i]}"
    fi
}

fw_nft_apply() {
    local i proto line body=""

    for ((i = 0; i < ${#FW_ACT[@]}; i++)); do
        for proto in $(fw_rule_protos "$i"); do
            line="        "
            if [[ -n "${FW_SRC[i]}" ]]; then
                if [[ "${FW_SRC[i]}" == *:* ]]; then
                    line+="ip6 saddr ${FW_SRC[i]} "
                else
                    line+="ip saddr ${FW_SRC[i]} "
                fi
            fi
            if [[ "$proto" != "all" ]]; then
                line+="$proto "
                if [[ "${FW_PSTART[i]}" != "all" ]]; then
                    line+="dport $(fw_nft_ports "$i") "
                fi
            fi
            line+="ct state new "
            if [[ "${FW_ACT[i]}" == "allow" ]]; then
                line+="accept"
            else
                line+="drop"
            fi
            body+="$line"$'\n'
        done
    done

    if nft list table inet "$FW_NFT_TABLE" >/dev/null 2>&1; then
        nft delete table inet "$FW_NFT_TABLE" || return 1
    fi

    {
        printf 'table inet %s {\n' "$FW_NFT_TABLE"
        printf '    chain input {\n'
        printf '        type filter hook input priority -150; policy accept;\n'
        printf '%s' "$body"
        printf '    }\n'
        printf '}\n'
    } | nft -f - || return 1

    printf '[firewall] 已下发 %s 条规则到表 inet %s。\n' "${#FW_ACT[@]}" "$FW_NFT_TABLE"
    return 0
}

fw_ports_ufw() {
    local i="$1"
    if [[ "${FW_PSTART[i]}" == "${FW_PEND[i]}" ]]; then
        printf '%s' "${FW_PSTART[i]}"
    else
        printf '%s:%s' "${FW_PSTART[i]}" "${FW_PEND[i]}"
    fi
}

fw_ufw_spec() {
    local i="$1" spec ports proto
    if [[ "${FW_ACT[i]}" == "allow" ]]; then
        spec="allow"
    else
        spec="deny"
    fi
    proto="${FW_PROTO[i]}"
    if [[ "${FW_PSTART[i]}" == "all" ]]; then
        ports=""
    else
        ports="$(fw_ports_ufw "$i")"
    fi

    if [[ -n "${FW_SRC[i]}" ]]; then
        spec="$spec from ${FW_SRC[i]}"
        if [[ -n "$ports" ]]; then
            spec="$spec to any port $ports"
            if [[ "$proto" != "all" ]]; then
                spec="$spec proto $proto"
            fi
        fi
    elif [[ -n "$ports" ]]; then
        if [[ "$proto" != "all" ]]; then
            spec="$spec $ports/$proto"
        else
            spec="$spec $ports"
        fi
    else
        spec="$spec from any"
    fi

    printf '%s' "$spec"
}

fw_ufw_teardown() {
    [[ -r "$FW_STATE_FILE" ]] || return 0
    local line
    local -a args=()
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        read -r -a args <<<"$line"
        ufw --force delete "${args[@]}" >/dev/null 2>&1 || true
    done <"$FW_STATE_FILE"
    : >"$FW_STATE_FILE" 2>/dev/null || true
    return 0
}

fw_ufw_apply() {
    fw_ufw_teardown

    install -d -m 0755 "$(dirname -- "$FW_STATE_FILE")" || return 1
    : >"$FW_STATE_FILE" || return 1

    local i spec
    local -a args=()
    for ((i = 0; i < ${#FW_ACT[@]}; i++)); do
        spec="$(fw_ufw_spec "$i")"
        read -r -a args <<<"$spec"
        if ! ufw "${args[@]}" >/dev/null; then
            printf '[firewall] ufw 规则添加失败: %s\n' "$spec" >&2
            return 1
        fi
        printf '%s\n' "$spec" >>"$FW_STATE_FILE"
    done

    printf '[firewall] 已通过 ufw 下发 %s 条规则。\n' "${#FW_ACT[@]}"
    return 0
}

fw_apply_rules() {
    case "$(fw_backend)" in
        iptables) fw_iptables_apply ;;
        nft) fw_nft_apply ;;
        ufw) fw_ufw_apply ;;
        *)
            printf '[firewall] 找不到 iptables / nft / ufw，无法下发规则。\n' >&2
            return 1
            ;;
    esac
}

fw_clear_rules() {
    case "$(fw_backend)" in
        iptables)
            fw_iptables_teardown
            printf '[firewall] 已移除链 %s。\n' "$FW_IPT_CHAIN"
            ;;
        nft)
            if nft list table inet "$FW_NFT_TABLE" >/dev/null 2>&1; then
                nft delete table inet "$FW_NFT_TABLE" \
                    && printf '[firewall] 已删除表 inet %s。\n' "$FW_NFT_TABLE"
            else
                printf '[firewall] 表 inet %s 不存在。\n' "$FW_NFT_TABLE"
            fi
            ;;
        ufw)
            fw_ufw_teardown
            printf '[firewall] 已删除本程序通过 ufw 添加的规则。\n'
            ;;
        *)
            printf '[firewall] 找不到可用的防火墙工具。\n' >&2
            return 1
            ;;
    esac
    return 0
}

# ---------------------------------------------------------- autostart

fw_installed_self() {
    if [[ -f /usr/local/sbin/portctl.sh ]]; then
        printf '/usr/local/sbin/portctl.sh'
    else
        printf '%s' "$SELF_PATH"
    fi
}

fw_autostart_enabled() {
    command -v systemctl >/dev/null 2>&1 || return 1
    systemctl is-enabled "$FW_UNIT_NAME" >/dev/null 2>&1
}

fw_autostart_label() {
    if fw_autostart_enabled; then
        printf '已开启'
    else
        printf '未开启'
    fi
}

fw_unit_write() {
    local tmp self
    self="$(fw_installed_self)"
    tmp="$(mktemp)" || return 1

    {
        printf '[Unit]\n'
        printf 'Description=portctl firewall rules\n'
        printf 'Wants=network-online.target\n'
        printf 'After=network-online.target\n\n'
        printf '[Service]\n'
        printf 'Type=oneshot\n'
        printf 'ExecStart=%s firewall-apply\n' "$self"
        printf 'ExecStop=%s firewall-clear\n' "$self"
        printf 'RemainAfterExit=yes\n\n'
        printf '[Install]\n'
        printf 'WantedBy=multi-user.target\n'
    } >"$tmp"

    if ! run_root install -m 0644 "$tmp" "$FW_UNIT_FILE"; then
        rm -f "$tmp"
        printf '%s写入 systemd 单元失败。%s\n' "$RED" "$RESET"
        return 1
    fi
    rm -f "$tmp"
    run_root systemctl daemon-reload || true
    return 0
}

fw_autostart_on() {
    fw_unit_write || return 1
    run_root systemctl enable --now "$FW_UNIT_NAME"
}

fw_autostart_off() {
    if command -v systemctl >/dev/null 2>&1; then
        run_root systemctl disable --now "$FW_UNIT_NAME" 2>/dev/null || true
    fi
    run_root rm -f "$FW_UNIT_FILE"
    if command -v systemctl >/dev/null 2>&1; then
        run_root systemctl daemon-reload 2>/dev/null || true
    fi
    return 0
}

# ------------------------------------------------------------- firewall UI

fw_render_table() {
    if (( ${#FW_ACT[@]} == 0 )); then
        printf '%s  当前没有任何防火墙规则。%s\n' "$DIM" "$RESET"
        return 0
    fi

    local i row
    row="  $(pad '编号' 6) $(pad '动作' 8) $(pad '协议' 8) $(pad '端口' 18) 来源"
    printf '%s%s%s\n' "$DIM" "$row" "$RESET"

    for ((i = 0; i < ${#FW_ACT[@]}; i++)); do
        row="  $(pad "$((i + 1))" 6) $(pad "$(fw_action_label "${FW_ACT[i]}")" 8) $(pad "$(fw_proto_label "${FW_PROTO[i]}")" 8) $(pad "$(fw_ports_text "$i")" 18) ${FW_SRC[i]:-任意}"
        if [[ "${FW_ACT[i]}" == "allow" ]]; then
            printf '%s%s%s\n' "$GREEN" "$row" "$RESET"
        else
            printf '%s%s%s\n' "$RED" "$row" "$RESET"
        fi
    done
    return 0
}

fw_prompt_action() {
    local choice
    printf '%s请选择动作:%s\n' "$CYAN" "$RESET" >&2
    printf '%s1.%s 放行（allow）\n' "$GREEN" "$RESET" >&2
    printf '%s2.%s 封禁（deny）\n' "$GREEN" "$RESET" >&2
    printf '%s选择:%s ' "$CYAN" "$RESET" >&2
    read -r choice || return 1
    case "$choice" in
        ""|1) printf 'allow' ;;
        2) printf 'deny' ;;
        *) return 1 ;;
    esac
}

fw_prompt_proto() {
    local choice
    printf '%s请选择协议:%s\n' "$CYAN" "$RESET" >&2
    printf '%s1.%s tcp\n' "$GREEN" "$RESET" >&2
    printf '%s2.%s udp\n' "$GREEN" "$RESET" >&2
    printf '%s3.%s tcp + udp\n' "$GREEN" "$RESET" >&2
    printf '%s选择 [1]:%s ' "$CYAN" "$RESET" >&2
    read -r choice || return 1
    case "$choice" in
        ""|1) printf 'tcp' ;;
        2) printf 'udp' ;;
        3) printf 'all' ;;
        *) return 1 ;;
    esac
}

# Prints "<start> <end>"; "all all" means every port.
fw_prompt_ports() {
    local prompt="$1" allow_empty="${2:-no}" value start end
    while true; do
        printf '%s%s%s ' "$CYAN" "$prompt" "$RESET" >&2
        read -r value || return 1

        if [[ -z "$value" ]]; then
            if [[ "$allow_empty" == "yes" ]]; then
                printf 'all all'
                return 0
            fi
            printf '%s不能为空。%s\n' "$RED" "$RESET" >&2
            continue
        fi
        if [[ "$value" == "all" || "$value" == "*" ]]; then
            printf 'all all'
            return 0
        fi

        if [[ "$value" == *-* ]]; then
            start="${value%%-*}"
            end="${value#*-}"
        else
            start="$value"
            end="$value"
        fi

        if ! start="$(fw_norm_port "$start")" || ! end="$(fw_norm_port "$end")"; then
            printf '%s请输入单个端口或区间，例如 8080、10001-10200。%s\n' "$RED" "$RESET" >&2
            continue
        fi
        if (( start < 1 || end > 65535 || end < start )); then
            printf '%s端口必须在 1-65535 之间，且结束端口不小于起始端口。%s\n' "$RED" "$RESET" >&2
            continue
        fi

        printf '%s %s' "$start" "$end"
        return 0
    done
}

fw_prompt_ip() {
    local prompt="$1" value
    while true; do
        printf '%s%s%s ' "$CYAN" "$prompt" "$RESET" >&2
        read -r value || return 1
        if is_ip_or_cidr "$value"; then
            printf '%s' "$value"
            return 0
        fi
        printf '%s地址格式无效，例如 1.2.3.4、1.2.3.0/24、2001:db8::/32。%s\n' \
            "$RED" "$RESET" >&2
    done
}

fw_prompt_src_optional() {
    local value
    while true; do
        printf '%s来源 IP（留空表示任意来源）:%s ' "$CYAN" "$RESET" >&2
        read -r value || return 1
        if [[ -z "$value" ]]; then
            printf ''
            return 0
        fi
        if is_ip_or_cidr "$value"; then
            printf '%s' "$value"
            return 0
        fi
        printf '%s地址格式无效。%s\n' "$RED" "$RESET" >&2
    done
}

fw_apply_from_menu() {
    local risk_out answer extra="" ip
    fw_load

    if risk_out="$(fw_safety_check)"; then
        extra=""
    else
        printf '\n%s警告: 下面的规则可能会切断你的 SSH 登录%s\n' "$RED" "$RESET"
        printf '%s\n' "$risk_out"
        printf '\n%s规则只影响新建连接，当前会话不会掉线，但下次登录可能连不上。%s\n' \
            "$DIM" "$RESET"

        ip="$(fw_client_ip)"
        if [[ -n "$ip" && "$FW_SSH_PROTECT" == "yes" ]]; then
            printf '\n%s是否自动加一条「允许当前 IP %s 访问 SSH 端口」的保护规则？[Y/n]:%s ' \
                "$CYAN" "$ip" "$RESET"
            read -r answer
            if [[ -z "$answer" || "${answer,,}" == "y" || "${answer,,}" == "yes" ]]; then
                extra="$(fw_ssh_protect_rule)"
                printf '%s临时保护规则:%s\n%s\n' "$GREEN" "$RESET" "$extra"
            fi
        fi

        printf '\n%s确认下发请输入 FORCE，其他输入取消: %s' "$YELLOW" "$RESET"
        read -r answer
        if [[ "$answer" != "FORCE" ]]; then
            printf '%s已取消。%s\n' "$DIM" "$RESET"
            pause_screen
            return
        fi
    fi

    printf '\n'
    if run_root env FW_EXTRA_RULES="$extra" bash "$SELF_PATH" firewall-apply; then
        printf '\n%s规则已下发到系统防火墙。%s\n' "$GREEN" "$RESET"
    else
        printf '\n%s下发失败，请检查上面的错误输出。%s\n' "$RED" "$RESET"
    fi
    pause_screen
}

fw_apply_after_change() {
    local answer
    printf '\n%s现在立即下发到系统防火墙？[Y/n]:%s ' "$CYAN" "$RESET"
    read -r answer
    if [[ -z "$answer" || "${answer,,}" == "y" || "${answer,,}" == "yes" ]]; then
        printf '\n'
        fw_apply_from_menu
    else
        printf '%s已保存配置，之后可在菜单里选择「1. 立即应用当前配置」。%s\n' \
            "$DIM" "$RESET"
        pause_screen
    fi
}

fw_add_port_flow() {
    local action proto ports_pair start end src

    clear_screen
    draw_brand
    printf '\n%s[04-2] 添加端口规则%s\n\n' "$YELLOW" "$RESET"

    action="$(fw_prompt_action)" || {
        pause_screen
        return
    }
    proto="$(fw_prompt_proto)" || {
        pause_screen
        return
    }
    ports_pair="$(fw_prompt_ports '端口（单个或区间，例如 8080 或 10001-10200）:')" || {
        pause_screen
        return
    }
    read -r start end <<<"$ports_pair"
    src="$(fw_prompt_src_optional)" || {
        pause_screen
        return
    }

    fw_load
    FW_ACT+=("$action")
    FW_PROTO+=("$proto")
    FW_PSTART+=("$start")
    FW_PEND+=("$end")
    FW_SRC+=("$src")

    printf '\n%s新规则:%s %s\n' "$DIM" "$RESET" "$(fw_rule_display "$((${#FW_ACT[@]} - 1))")"
    if fw_save; then
        printf '%s已写入 %s%s\n' "$GREEN" "$FW_CONF_FILE" "$RESET"
        fw_apply_after_change
    else
        pause_screen
    fi
}

fw_add_ip_flow() {
    local action ip ports_pair start end

    clear_screen
    draw_brand
    printf '\n%s[04-3] 添加来源 IP 规则%s\n\n' "$YELLOW" "$RESET"

    action="$(fw_prompt_action)" || {
        pause_screen
        return
    }
    ip="$(fw_prompt_ip '来源 IP 或网段（例如 1.2.3.4 或 1.2.3.0/24）:')" || {
        pause_screen
        return
    }
    printf '%s端口留空表示该 IP 的所有端口。%s\n' "$DIM" "$RESET"
    ports_pair="$(fw_prompt_ports '端口（可留空）:' yes)" || {
        pause_screen
        return
    }
    read -r start end <<<"$ports_pair"

    fw_load
    FW_ACT+=("$action")
    FW_PROTO+=("all")
    FW_PSTART+=("$start")
    FW_PEND+=("$end")
    FW_SRC+=("$ip")

    printf '\n%s新规则:%s %s\n' "$DIM" "$RESET" "$(fw_rule_display "$((${#FW_ACT[@]} - 1))")"
    if fw_save; then
        printf '%s已写入 %s%s\n' "$GREEN" "$FW_CONF_FILE" "$RESET"
        fw_apply_after_change
    else
        pause_screen
    fi
}

fw_delete_flow() {
    local answer token found i skip
    local -a remove=()

    clear_screen
    draw_brand
    printf '\n%s[04-4] 删除规则%s\n\n' "$YELLOW" "$RESET"

    fw_load
    fw_render_table
    if (( ${#FW_ACT[@]} == 0 )); then
        pause_screen
        return
    fi

    printf '\n%s输入要删除的规则编号（多个用空格分隔，直接回车取消）:%s ' "$CYAN" "$RESET"
    read -r answer
    if [[ -z "$answer" ]]; then
        pause_screen
        return
    fi

    read -r -a remove <<<"$answer"
    for token in "${remove[@]}"; do
        if ! [[ "$token" =~ ^[0-9]+$ ]]; then
            printf '%s规则编号无效: %s%s\n' "$RED" "$token" "$RESET"
            pause_screen
            return
        fi
        if (( token < 1 || token > ${#FW_ACT[@]} )); then
            printf '%s没有编号为 %s 的规则。%s\n' "$RED" "$token" "$RESET"
            pause_screen
            return
        fi
    done

    local -a act=() proto=() pstart=() pend=() src=()
    for ((i = 0; i < ${#FW_ACT[@]}; i++)); do
        skip=0
        for token in "${remove[@]}"; do
            if (( token == i + 1 )); then
                skip=1
            fi
        done
        if (( skip )); then
            continue
        fi
        act+=("${FW_ACT[i]}")
        proto+=("${FW_PROTO[i]}")
        pstart+=("${FW_PSTART[i]}")
        pend+=("${FW_PEND[i]}")
        src+=("${FW_SRC[i]}")
    done

    FW_ACT=(${act[@]+"${act[@]}"})
    FW_PROTO=(${proto[@]+"${proto[@]}"})
    FW_PSTART=(${pstart[@]+"${pstart[@]}"})
    FW_PEND=(${pend[@]+"${pend[@]}"})
    FW_SRC=(${src[@]+"${src[@]}"})

    printf '\n%s删除后剩余规则:%s\n' "$DIM" "$RESET"
    fw_render_table
    if fw_save; then
        printf '%s已写入 %s%s\n' "$GREEN" "$FW_CONF_FILE" "$RESET"
        fw_apply_after_change
    else
        pause_screen
    fi
}

fw_clear_flow() {
    local answer
    clear_screen
    draw_brand
    printf '\n%s[04-5] 清空全部规则%s\n\n' "$YELLOW" "$RESET"

    fw_load
    fw_render_table
    printf '\n%s清空后不会立刻撤销系统里的规则，需要再选「1. 立即应用当前配置」才会移除链/表。%s\n' \
        "$DIM" "$RESET"
    printf '确认清空请输入 %sYES%s，其他输入取消: ' "$RED" "$RESET"
    read -r answer
    if [[ "$answer" != "YES" ]]; then
        printf '%s已取消。%s\n' "$DIM" "$RESET"
        pause_screen
        return
    fi

    FW_ACT=()
    FW_PROTO=()
    FW_PSTART=()
    FW_PEND=()
    FW_SRC=()
    if fw_save; then
        printf '%s已清空配置里的规则。%s\n' "$GREEN" "$RESET"
        fw_apply_after_change
    else
        pause_screen
    fi
}

fw_show_system_rules() {
    clear_screen
    draw_brand
    printf '\n%s[04-6] 系统实际规则%s\n\n' "$YELLOW" "$RESET"

    case "$(fw_backend)" in
        iptables)
            printf '%s--- iptables -S INPUT ---%s\n' "$DIM" "$RESET"
            run_root iptables -S INPUT 2>&1 || true
            printf '\n%s--- iptables -S %s ---%s\n' "$DIM" "$FW_IPT_CHAIN" "$RESET"
            run_root iptables -S "$FW_IPT_CHAIN" 2>&1 ||
                printf '%s链不存在（尚未下发）%s\n' "$DIM" "$RESET"
            printf '\n%s--- 命中计数 ---%s\n' "$DIM" "$RESET"
            run_root iptables -L "$FW_IPT_CHAIN" -n -v 2>&1 || true
            if command -v ip6tables >/dev/null 2>&1; then
                printf '\n%s--- ip6tables -S %s ---%s\n' "$DIM" "$FW_IPT_CHAIN" "$RESET"
                run_root ip6tables -S "$FW_IPT_CHAIN" 2>&1 || true
            fi
            ;;
        nft)
            run_root nft list table inet "$FW_NFT_TABLE" 2>&1 ||
                printf '%s表不存在（尚未下发）%s\n' "$DIM" "$RESET"
            ;;
        ufw)
            run_root ufw status numbered 2>&1 || true
            ;;
        *)
            printf '%s找不到可用的防火墙工具。%s\n' "$RED" "$RESET"
            ;;
    esac

    pause_screen
}

fw_settings_menu() {
    local choice
    clear_screen
    draw_brand
    printf '\n%s[04-7] 后端与开机自启%s\n\n' "$YELLOW" "$RESET"
    printf '%s自动探测结果:%s %s\n' "$DIM" "$RESET" "$(fw_backend_label "$(fw_detect_backend)")"
    printf '%s当前设置:%s %s → %s\n' \
        "$DIM" "$RESET" "$FW_BACKEND_CFG" "$(fw_backend_label "$(fw_backend)")"
    printf '%s开机自启:%s %s\n\n' "$DIM" "$RESET" "$(fw_autostart_label)"

    printf '%s1.%s 自动探测（auto）\n' "$GREEN" "$RESET"
    printf '%s2.%s 固定使用 iptables\n' "$GREEN" "$RESET"
    printf '%s3.%s 固定使用 nftables\n' "$GREEN" "$RESET"
    printf '%s4.%s 固定使用 ufw\n' "$GREEN" "$RESET"
    printf '%s5.%s 开启开机自动恢复\n' "$GREEN" "$RESET"
    printf '%s6.%s 关闭并删除开机自启单元\n' "$GREEN" "$RESET"
    printf '%s0.%s 返回\n\n' "$GREEN" "$RESET"
    printf '%s选择:%s ' "$CYAN" "$RESET"
    read -r choice

    case "$choice" in
        1|2|3|4)
            case "$choice" in
                1) FW_BACKEND_CFG="auto" ;;
                2) FW_BACKEND_CFG="iptables" ;;
                3) FW_BACKEND_CFG="nft" ;;
                4) FW_BACKEND_CFG="ufw" ;;
            esac
            if fw_save; then
                printf '%s后端已设置为: %s%s\n' "$GREEN" "$FW_BACKEND_CFG" "$RESET"
            fi
            pause_screen
            ;;
        5)
            if fw_autostart_on; then
                printf '%s已开启开机自动恢复。%s\n' "$GREEN" "$RESET"
            else
                printf '%s开启失败。%s\n' "$RED" "$RESET"
            fi
            pause_screen
            ;;
        6)
            fw_autostart_off
            printf '%s已关闭并删除 %s。%s\n' "$GREEN" "$FW_UNIT_FILE" "$RESET"
            pause_screen
            ;;
        0|"") return ;;
        *) printf '%s未知选项。%s\n' "$RED" "$RESET"; pause_screen ;;
    esac
}

show_firewall_menu() {
    local choice ip
    while true; do
        fw_load
        clear_screen
        draw_brand
        printf '\n%s[04] 防火墙规则%s\n' "$YELLOW" "$RESET"
        printf '%s后端:%s %s    %s开机自启:%s %s\n' \
            "$DIM" "$RESET" "$(fw_backend_label "$(fw_backend)")" \
            "$DIM" "$RESET" "$(fw_autostart_label)"
        printf '%sSSH 端口:%s %s' "$DIM" "$RESET" "$(fw_ssh_ports)"
        ip="$(fw_client_ip)"
        if [[ -n "$ip" ]]; then
            printf '    %s当前连接来源:%s %s' "$DIM" "$RESET" "$ip"
        fi
        printf '\n%s规则只影响新建连接，不会中断已建立的会话。%s\n' "$DIM" "$RESET"

        printf '\n%s当前规则（按顺序匹配，第一条命中生效）%s\n' "$CYAN" "$RESET"
        fw_render_table
        if [[ -n "$FW_NOTES" ]]; then
            printf '\n%s配置文件里有被忽略的行:%s\n%s' "$YELLOW" "$RESET" "$FW_NOTES"
        fi

        printf '\n%s1.%s 立即应用当前配置\n' "$GREEN" "$RESET"
        printf '%s2.%s 添加端口规则（放行 / 封禁）\n' "$GREEN" "$RESET"
        printf '%s3.%s 添加来源 IP 规则（放行 / 封禁）\n' "$GREEN" "$RESET"
        printf '%s4.%s 删除规则\n' "$GREEN" "$RESET"
        printf '%s5.%s 清空全部规则\n' "$GREEN" "$RESET"
        printf '%s6.%s 查看系统实际规则\n' "$GREEN" "$RESET"
        printf '%s7.%s 后端与开机自启设置\n' "$GREEN" "$RESET"
        printf '%s0.%s 返回主菜单\n' "$GREEN" "$RESET"
        printf '\n%s选择:%s ' "$CYAN" "$RESET"
        read -r choice

        case "$choice" in
            1) fw_apply_from_menu ;;
            2) fw_add_port_flow ;;
            3) fw_add_ip_flow ;;
            4) fw_delete_flow ;;
            5) fw_clear_flow ;;
            6) fw_show_system_rules ;;
            7) fw_settings_menu ;;
            0|"") return ;;
            *)
                printf '%s请输入 1-7 或 0。%s\n' "$RED" "$RESET"
                pause_screen
                ;;
        esac
    done
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

# ------------------------------------------------------------- log center

LOG_DIR="${LOG_DIR:-/var/log}"

log_backend() {
    if command -v journalctl >/dev/null 2>&1; then
        printf 'journald'
    elif [[ -e "$LOG_DIR/syslog" ]]; then
        printf 'syslog'
    elif [[ -e "$LOG_DIR/messages" ]]; then
        printf 'messages'
    else
        printf 'none'
    fi
}

log_persistent() {
    if [[ -d /var/log/journal ]]; then
        printf '是'
    else
        printf '否（只在内存，重启即丢）'
    fi
}

log_disk_usage() {
    local out
    if [[ "$(log_backend)" != "journald" ]]; then
        printf '—'
        return 0
    fi
    # 不加 sudo：避免菜单每次重绘都弹密码提示。
    out="$(journalctl --disk-usage 2>/dev/null | head -n 1 || true)"
    # journalctl 输出形如 "... take up 88.0M in the file system."
    if [[ "$out" =~ ([0-9.]+[KMGTP]i?B?) ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    else
        printf '未知'
    fi
}

log_prompt_lines() {
    local value count
    printf '%s显示条数 [40]:%s ' "$CYAN" "$RESET" >&2
    read -r value || return 1
    if [[ -z "$value" ]]; then
        printf '40'
        return 0
    fi
    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        printf '%s请输入数字，使用默认值 40。%s\n' "$RED" "$RESET" >&2
        printf '40'
        return 0
    fi
    count=$((10#$value))
    if (( count < 1 )); then
        count=1
    fi
    if (( count > 5000 )); then
        count=5000
    fi
    printf '%s' "$count"
    return 0
}

# log_emit <标题> <行数> <syslog 过滤模式或 -> [journalctl 参数...]
log_emit() {
    local title="$1" lines="$2" pattern="$3"
    shift 3

    clear_screen
    draw_brand
    printf '\n%s%s%s\n' "$YELLOW" "$title" "$RESET"
    printf '%s最近 %s 条 · %s%s\n\n' "$DIM" "$lines" "$(date '+%F %T')" "$RESET"

    case "$(log_backend)" in
        journald)
            run_root journalctl -n "$lines" --no-pager "$@" 2>&1 || true
            ;;
        syslog|messages)
            printf '%s系统没有 journald，下面显示 %s/%s 的内容。%s\n\n' \
                "$DIM" "$LOG_DIR" "$(log_backend)" "$RESET"
            if [[ -n "$pattern" && "$pattern" != "-" ]]; then
                run_root grep -iE "$pattern" "$LOG_DIR/$(log_backend)" 2>/dev/null |
                    tail -n "$lines" || true
            else
                run_root tail -n "$lines" "$LOG_DIR/$(log_backend)" 2>&1 || true
            fi
            ;;
        *)
            printf '%s找不到日志来源（没有 journalctl，也没有 /var/log/syslog 或 /var/log/messages）。%s\n' \
                "$RED" "$RESET"
            ;;
    esac

    pause_screen
}

log_ssh_unit() {
    if systemctl cat ssh.service >/dev/null 2>&1; then
        printf 'ssh'
    elif systemctl cat sshd.service >/dev/null 2>&1; then
        printf 'sshd'
    fi
}

log_view_login() {
    local lines unit
    lines="$(log_prompt_lines)" || return 0

    clear_screen
    draw_brand
    printf '\n%s登录记录%s\n' "$YELLOW" "$RESET"
    printf '%s最近 %s 条 · %s%s\n' "$DIM" "$lines" "$(date '+%F %T')" "$RESET"

    printf '\n%s--- 成功登录（last）---%s\n' "$CYAN" "$RESET"
    if command -v last >/dev/null 2>&1; then
        run_root last -n "$lines" -w 2>&1 || true
    else
        printf '%s系统没有 last 命令。%s\n' "$DIM" "$RESET"
    fi

    printf '\n%s--- 失败登录（lastb）---%s\n' "$CYAN" "$RESET"
    if command -v lastb >/dev/null 2>&1; then
        run_root lastb -n "$lines" -w 2>&1 || true
    else
        printf '%s系统没有 lastb 命令。%s\n' "$DIM" "$RESET"
    fi

    if [[ "$(log_backend)" == "journald" ]]; then
        if command -v systemctl >/dev/null 2>&1; then
            unit="$(log_ssh_unit)"
            if [[ -n "$unit" ]]; then
                printf '\n%s--- SSH 认证日志（%s）---%s\n' "$CYAN" "$unit" "$RESET"
                run_root journalctl -u "$unit" -n "$((lines * 4))" --no-pager 2>&1 |
                    grep -iE 'accepted|failed|invalid|refused|disconnect' || true
            fi
        fi
    fi

    pause_screen
}

log_follow() {
    local choice unit label
    clear_screen
    draw_brand
    printf '\n%s[05-7] 实时跟踪%s\n\n' "$YELLOW" "$RESET"
    printf '%s1.%s 限速服务\n' "$GREEN" "$RESET"
    printf '%s2.%s 防火墙服务\n' "$GREEN" "$RESET"
    printf '%s3.%s 全部系统日志\n' "$GREEN" "$RESET"
    printf '%s选择 [1]:%s ' "$CYAN" "$RESET"
    read -r choice

    case "$choice" in
        ""|1) unit="limit-ports.service"; label="限速服务" ;;
        2) unit="portctl-firewall.service"; label="防火墙服务" ;;
        3) unit=""; label="全部系统日志" ;;
        *) return ;;
    esac

    if [[ "$(log_backend)" != "journald" ]]; then
        printf '\n%s实时跟踪需要 journalctl。%s\n' "$RED" "$RESET"
        pause_screen
        return
    fi

    clear_screen
    draw_brand
    printf '\n%s实时跟踪 %s，按 Ctrl+C 返回菜单。%s\n\n' "$YELLOW" "$label" "$RESET"

    # 父进程忽略 SIGINT，只有子进程被 Ctrl+C 终止，这样不会连带退出菜单。
    trap '' INT
    if [[ -n "$unit" ]]; then
        ( trap - INT; run_root journalctl -u "$unit" -f -n 20 --no-pager ) || true
    else
        ( trap - INT; run_root journalctl -f -n 20 --no-pager ) || true
    fi
    trap - INT

    pause_screen
}

logs_export() {
    local lines="${1:-40}" target="${2:-/root/portctl-diag.txt}"
    local fw_conf="${FW_CONF_FILE:-/etc/default/portctl-firewall.conf}"

    [[ "$lines" =~ ^[0-9]+$ ]] || lines=40
    lines=$((10#$lines))

    {
        printf 'portctl 诊断日志\n'
        printf '导出时间: %s\n' "$(date '+%F %T %Z')"
        printf '主机: %s\n' "$(hostname 2>/dev/null || printf 'unknown')"
        printf '内核: %s\n' "$(uname -srmo 2>/dev/null || printf 'unknown')"
        printf '系统: %s\n' \
            "$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release 2>/dev/null | tr -d '"' | head -n 1)"
        printf '日志来源: %s\n' "$(log_backend)"

        printf '\n================ limit-ports.service ================\n'
        journalctl -u limit-ports.service -n "$lines" --no-pager 2>&1 || true
        printf '\n================ portctl-firewall.service ================\n'
        journalctl -u portctl-firewall.service -n "$lines" --no-pager 2>&1 || true
        printf '\n================ 系统错误日志 ================\n'
        journalctl -p err -n "$lines" --no-pager 2>&1 || true

        printf '\n================ tc qdisc ================\n'
        tc -s qdisc show 2>&1 || true
        printf '\n================ tc class ================\n'
        tc -s class show 2>&1 || true

        printf '\n================ 防火墙 ================\n'
        fw_load
        case "$(fw_backend)" in
            iptables)
                iptables -S 2>&1 || true
                ip6tables -S 2>&1 || true
                ;;
            nft) nft list ruleset 2>&1 || true ;;
            ufw) ufw status verbose 2>&1 || true ;;
            *) printf '找不到可用的防火墙工具。\n' ;;
        esac

        printf '\n================ 端口监听 ================\n'
        ss -tlnp 2>&1 || true

        printf '\n================ 本程序配置 ================\n'
        printf -- '--- %s ---\n' "${CONFIG_FILE:-/etc/default/limit-ports}"
        cat "${CONFIG_FILE:-/etc/default/limit-ports}" 2>&1 || true
        printf -- '\n--- %s ---\n' "$fw_conf"
        cat "$fw_conf" 2>&1 || true

        printf '\n================ 服务状态 ================\n'
        systemctl --no-pager --full status limit-ports.service 2>&1 || true
        systemctl --no-pager --full status portctl-firewall.service 2>&1 || true
    } >"$target" 2>&1

    [[ -s "$target" ]]
}

log_export_flow() {
    local lines target answer
    lines="$(log_prompt_lines)" || return 0

    target="/root/portctl-diag-$(date +%Y%m%d-%H%M%S).txt"
    printf '\n%s导出路径 [%s]:%s ' "$CYAN" "$target" "$RESET"
    read -r answer
    if [[ -n "$answer" ]]; then
        target="$answer"
    fi

    printf '\n%s正在收集日志与运行状态...%s\n' "$DIM" "$RESET"
    if run_root bash "$SELF_PATH" logs-export "$lines" "$target"; then
        printf '%s已导出到 %s%s\n' "$GREEN" "$target" "$RESET"
        printf '%s包含: 两个服务的日志、系统错误、tc 规则、防火墙规则、端口监听、配置和服务状态。%s\n' \
            "$DIM" "$RESET"
    else
        printf '%s导出失败，请检查路径是否可写。%s\n' "$RED" "$RESET"
    fi
    pause_screen
}

log_vacuum_run() {
    local arg="$1" label="$2" answer
    printf '\n%s将执行: journalctl %s（%s，不可恢复）%s\n' \
        "$YELLOW" "$arg" "$label" "$RESET"
    printf '确认请输入 YES: '
    read -r answer
    if [[ "$answer" != "YES" ]]; then
        printf '%s已取消。%s\n' "$DIM" "$RESET"
        pause_screen
        return
    fi
    run_root journalctl "$arg" 2>&1 || true
    printf '\n%s清理完成，当前占用: %s%s\n' "$GREEN" "$(log_disk_usage)" "$RESET"
    pause_screen
}

log_vacuum() {
    local choice
    clear_screen
    draw_brand
    printf '\n%s[05-9] 清理日志%s\n\n' "$YELLOW" "$RESET"

    if [[ "$(log_backend)" != "journald" ]]; then
        printf '%s只有 journald 才支持这里的清理功能。%s\n' "$RED" "$RESET"
        pause_screen
        return
    fi

    printf '%s当前占用: %s    持久化: %s%s\n' \
        "$DIM" "$(log_disk_usage)" "$(log_persistent)" "$RESET"
    if [[ ! -d /var/log/journal ]]; then
        printf '%s日志目前只存在内存里，清理意义不大。可在 /etc/systemd/journald.conf 里设置 Storage=persistent 让其持久化。%s\n' \
            "$DIM" "$RESET"
    fi

    printf '\n%s1.%s 只保留最近 7 天\n' "$GREEN" "$RESET"
    printf '%s2.%s 只保留最近 3 天\n' "$GREEN" "$RESET"
    printf '%s3.%s 限制总大小 200M\n' "$GREEN" "$RESET"
    printf '%s4.%s 限制总大小 500M\n' "$GREEN" "$RESET"
    printf '%s0.%s 取消\n\n' "$GREEN" "$RESET"
    printf '%s选择:%s ' "$CYAN" "$RESET"
    read -r choice

    case "$choice" in
        1) log_vacuum_run --vacuum-time=7d "保留 7 天" ;;
        2) log_vacuum_run --vacuum-time=3d "保留 3 天" ;;
        3) log_vacuum_run --vacuum-size=200M "限制 200M" ;;
        4) log_vacuum_run --vacuum-size=500M "限制 500M" ;;
        0|"") return ;;
        *) printf '%s未知选项。%s\n' "$RED" "$RESET"; pause_screen ;;
    esac
}

show_logs_menu() {
    local choice lines backend
    while true; do
        backend="$(log_backend)"
        clear_screen
        draw_brand
        printf '\n%s[05] 日志中心%s\n' "$YELLOW" "$RESET"
        case "$backend" in
            journald)
                printf '%s来源:%s journald    %s持久化:%s %s    %s占用:%s %s\n' \
                    "$DIM" "$RESET" "$DIM" "$RESET" "$(log_persistent)" \
                    "$DIM" "$RESET" "$(log_disk_usage)"
                ;;
            none)
                printf '%s来源:%s 未找到可用的日志系统\n' "$DIM" "$RESET"
                ;;
            *)
                printf '%s来源:%s %s/%s\n' "$DIM" "$RESET" "$LOG_DIR" "$backend"
                ;;
        esac

        printf '\n%s1.%s 限速服务日志\n' "$GREEN" "$RESET"
        printf '%s2.%s 防火墙服务日志\n' "$GREEN" "$RESET"
        printf '%s3.%s 系统错误日志\n' "$GREEN" "$RESET"
        printf '%s4.%s 登录记录（成功 / 失败）\n' "$GREEN" "$RESET"
        printf '%s5.%s 内核日志\n' "$GREEN" "$RESET"
        printf '%s6.%s 全部系统日志\n' "$GREEN" "$RESET"
        printf '%s7.%s 实时跟踪（Ctrl+C 返回）\n' "$GREEN" "$RESET"
        printf '%s8.%s 导出诊断日志到文件\n' "$GREEN" "$RESET"
        printf '%s9.%s 清理日志\n' "$GREEN" "$RESET"
        printf '%s0.%s 返回主菜单\n' "$GREEN" "$RESET"
        printf '\n%s选择:%s ' "$CYAN" "$RESET"
        read -r choice

        case "$choice" in
            1)
                lines="$(log_prompt_lines)" || continue
                log_emit "限速服务日志（limit-ports.service）" "$lines" 'limit-ports' \
                    -u limit-ports.service
                ;;
            2)
                lines="$(log_prompt_lines)" || continue
                log_emit "防火墙服务日志（portctl-firewall.service）" "$lines" 'portctl-firewall' \
                    -u portctl-firewall.service
                ;;
            3)
                lines="$(log_prompt_lines)" || continue
                log_emit "系统错误日志" "$lines" 'error|fail|critical|panic|denied' -p err
                ;;
            4) log_view_login ;;
            5)
                lines="$(log_prompt_lines)" || continue
                log_emit "内核日志" "$lines" 'kernel' -k
                ;;
            6)
                lines="$(log_prompt_lines)" || continue
                log_emit "全部系统日志" "$lines" -
                ;;
            7) log_follow ;;
            8) log_export_flow ;;
            9) log_vacuum ;;
            0|"") return ;;
            *) printf '%s请输入 1-9 或 0。%s\n' "$RED" "$RESET"; pause_screen ;;
        esac
    done
}

download_file() {
    local url="$1"
    local target="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 "$url" -o "$target"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$target" "$url"
    else
        printf '%s需要 curl 或 wget 才能联网。%s\n' "$RED" "$RESET"
        return 1
    fi
    [[ -s "$target" ]]
}

update_script() {
    clear_screen
    draw_brand
    printf '\n%s[06] 更新脚本%s\n\n' "$YELLOW" "$RESET"
    printf '%s正在从 GitHub 获取最新版本...%s\n' "$DIM" "$RESET"
    local tmp_dir installer
    tmp_dir="$(mktemp -d)"
    installer="$tmp_dir/install.sh"
    if download_file "$INSTALL_URL" "$installer"; then
        chmod 0755 "$installer"
        run_root bash "$installer" --no-menu
        printf '\n%s更新完成，现有配置已保留。%s\n' "$GREEN" "$RESET"
    else
        printf '%s更新失败，请检查网络或稍后重试。%s\n' "$RED" "$RESET"
    fi
    rm -rf "$tmp_dir"
    pause_screen
}

uninstall_program() {
    clear_screen
    draw_brand
    printf '\n%s[07] 卸载程序%s\n\n' "$YELLOW" "$RESET"
    printf '%s这将停止服务并删除 zc、portctl.sh 和 limit_ports.sh。%s\n' "$RED" "$RESET"
    printf '%s同时会移除 portctl-firewall.service（不会主动撤销已下发的防火墙规则）。%s\n' "$DIM" "$RESET"
    printf '%s默认保留 /etc/default/limit-ports 配置。%s\n\n' "$DIM" "$RESET"
    printf '确认卸载请输入 %sYES%s，其他输入取消: ' "$RED" "$RESET"
    read -r confirmation
    [[ "$confirmation" == "YES" ]] || {
        printf '%s已取消卸载。%s\n' "$DIM" "$RESET"
        pause_screen
        return
    }

    printf '\n是否同时删除配置 /etc/default/limit-ports？[y/N]: '
    read -r remove_config
    if command -v systemctl >/dev/null 2>&1; then
        run_root systemctl disable --now limit-ports.service 2>/dev/null || true
        run_root rm -f /etc/systemd/system/limit-ports.service
        run_root systemctl disable --now "$FW_UNIT_NAME" 2>/dev/null || true
        run_root rm -f "$FW_UNIT_FILE"
        run_root systemctl daemon-reload 2>/dev/null || true
    fi
    run_root rm -f /usr/local/bin/zc
    run_root rm -f /usr/local/sbin/portctl.sh
    run_root rm -f /usr/local/sbin/limit_ports.sh
    if [[ "${remove_config,,}" == "y" || "${remove_config,,}" == "yes" ]]; then
        run_root rm -f /etc/default/limit-ports
        run_root rm -f "$FW_CONF_FILE"
    fi
    printf '%s卸载完成。%s\n' "$GREEN" "$RESET"
    printf '%s当前菜单进程将在返回后退出。%s\n' "$DIM" "$RESET"
    pause_screen
    clear_screen
    exit 0
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
            4|04) show_firewall_menu ;;
            5|05) show_logs_menu ;;
            6|06) update_script ;;
            7|07) uninstall_program ;;
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
    firewall-apply)
        fw_load
        fw_apply_rules
        ;;
    firewall-clear)
        fw_load
        fw_clear_rules
        ;;
    logs-export)
        logs_export "${2:-40}" "${3:-/root/portctl-diag.txt}"
        ;;
    firewall-status)
        fw_load
        printf '后端: %s\n' "$(fw_backend_label "$(fw_backend)")"
        printf '配置文件: %s\n' "$FW_CONF_FILE"
        printf '规则: %s 条\n' "${#FW_ACT[@]}"
        fw_render_table
        if [[ -n "$FW_NOTES" ]]; then
            printf '\n配置文件里有被忽略的行:\n%s' "$FW_NOTES"
        fi
        ;;
    --help|-h)
        printf '用法: %s [menu|firewall-apply|firewall-clear|firewall-status|logs-export <条数> <路径>]\n' "$0"
        printf 'SSH 登录服务器后直接运行即可。默认进入交互式终端菜单。\n'
        ;;
    *)
        printf '未知参数: %s\n' "$1" >&2
        exit 2
        ;;
esac
