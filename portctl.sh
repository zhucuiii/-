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

# Rules reported by `limit_ports.sh rules`, filled by load_rules().
RULE_IDX=()
RULE_START=()
RULE_END=()
RULE_RATE=()
RULE_MODE=()
RULE_PORTS=()
RULES_ERROR=""

cleanup() {
    printf '%s[?25h%s' "$ESC" "$RESET"
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
    printf '%sSSH 服务器端口控制台  v0.3.0%s\n' "$CYAN" "$RESET"
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
    printf '%s08.%s  %s网络诊断%s\n' "$CYAN" "$RESET" "$GREEN" "$RESET"
    printf '%s09.%s  %s进程查看%s\n' "$CYAN" "$RESET" "$GREEN" "$RESET"
    printf '%s10.%s  %s连接统计%s\n' "$CYAN" "$RESET" "$GREEN" "$RESET"
    printf '%s11.%s  %s系统资源%s\n' "$CYAN" "$RESET" "$GREEN" "$RESET"
    printf '%s12.%s  %s配置中心%s\n' "$CYAN" "$RESET" "$GREEN" "$RESET"
    printf '%s13.%s  %s扩展模块%s\n' "$CYAN" "$RESET" "$GREEN" "$RESET"
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
        run_root systemctl daemon-reload 2>/dev/null || true
    fi
    run_root rm -f /usr/local/bin/zc
    run_root rm -f /usr/local/sbin/portctl.sh
    run_root rm -f /usr/local/sbin/limit_ports.sh
    if [[ "${remove_config,,}" == "y" || "${remove_config,,}" == "yes" ]]; then
        run_root rm -f /etc/default/limit-ports
    fi
    printf '%s卸载完成。%s\n' "$GREEN" "$RESET"
    printf '%s当前菜单进程将在返回后退出。%s\n' "$DIM" "$RESET"
    pause_screen
    clear_screen
    exit 0
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
            7|07) uninstall_program ;;
            8|08) show_placeholder "[08] 网络诊断" ;;
            9|09) show_placeholder "[09] 进程查看" ;;
            10) show_placeholder "[10] 连接统计" ;;
            11) show_placeholder "[11] 系统资源" ;;
            12) show_placeholder "[12] 配置中心" ;;
            13) show_placeholder "[13] 扩展模块" ;;
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
