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
    read -r || return 0
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
    printf '%sSSH 服务器端口控制台  v0.7.0%s\n' "$DIM" "$RESET"
}

draw_status() {
    local host
    host="$(hostname 2>/dev/null || printf 'unknown')"
    printf '\n%s主机:%s %s\n' "$DIM" "$RESET" "$host"
    printf '%s网卡:%s %s    %s默认速率:%s %s (%s)\n' \
        "$DIM" "$RESET" "$NIC" "$DIM" "$RESET" "$SPEED" "$(current_rate_mb "$SPEED")"
}

draw_menu() {
    printf '\n%s----------------------------------------%s\n' "$BLUE" "$RESET"
    printf '%s01.%s  %s端口限速%s\n' "$CYAN" "$RESET" "$GREEN" "$RESET"
    printf '%s02.%s  %s流量查看%s\n' "$CYAN" "$RESET" "$GREEN" "$RESET"
    printf '%s03.%s  %s防火墙规则%s\n' "$CYAN" "$RESET" "$GREEN" "$RESET"
    printf '%s04.%s  %s限速服务%s\n' "$CYAN" "$RESET" "$GREEN" "$RESET"
    printf '%s05.%s  %s日志中心%s\n' "$CYAN" "$RESET" "$GREEN" "$RESET"
    printf '%s06.%s  %s系统与维护%s\n' "$CYAN" "$RESET" "$GREEN" "$RESET"
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

prompt_rate() {
    local label="$1" value unit new_rate
    while true; do
        printf '%s输入%s速率数值（只输入数字，回车取消）:%s ' \
            "$CYAN" "$label" "$RESET" >&2
        read -r value || return 1
        [[ -n "$value" ]] || return 1
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
    read -r answer || return 0
    if [[ -z "$answer" || "${answer,,}" == "y" || "${answer,,}" == "yes" ]]; then
        printf '\n'
        limit_root apply || true
    else
        printf '%s已保存到配置，之后可在「端口限速 > 应用当前配置」生效。%s\n' \
            "$DIM" "$RESET"
    fi
    pause_screen
}

prompt_port_range() {
    local value start end
    while true; do
        printf '%s端口或区间（8080 / 10001-10200，回车取消）:%s ' "$CYAN" "$RESET" >&2
        read -r value || return 1
        [[ -n "$value" ]] || return 1
        if [[ "$value" =~ ^([0-9]{1,5})(-([0-9]{1,5}))?$ ]]; then
            start=$((10#${BASH_REMATCH[1]}))
            end=$((10#${BASH_REMATCH[3]:-${BASH_REMATCH[1]}}))
            if (( start >= 1 && end <= 65535 && end >= start )); then
                printf '%s\t%s' "$start" "$end"
                return 0
            fi
        fi
        printf '%s请输入 1-65535 内的端口或递增区间。%s\n' "$RED" "$RESET" >&2
    done
}

# One entry point accepts both a single port and a range.
add_rule_flow() {
    local start end rate mode mode_choice ports

    clear_screen
    draw_brand
    printf '\n%s端口限速 > 添加限速规则%s\n\n' "$YELLOW" "$RESET"
    ports="$(prompt_port_range)" || return 0
    IFS=$'\t' read -r start end <<<"$ports"

    rate="$(prompt_rate '限速')" || {
        pause_screen
        return
    }

    mode="per-port"
    if (( end > start )); then
        printf '\n%s请选择限速方式:%s\n' "$CYAN" "$RESET"
        printf '%s1.%s 每端口独立：区间内每个端口各自 %s\n' \
            "$GREEN" "$RESET" "$rate"
        printf '%s2.%s 区间共享：%s-%s 合计 %s\n' \
            "$GREEN" "$RESET" "$start" "$end" "$rate"
        printf '%s选择 [1]:%s ' "$CYAN" "$RESET"
        read -r mode_choice || return 0
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
        read -r answer || return 0
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

change_rule_rate() {
    local answer i selected=-1 rate spec="" piece
    clear_screen
    draw_brand
    printf '\n%s端口限速 > 修改单条规则速率%s\n\n' "$YELLOW" "$RESET"
    if ! load_rules; then
        printf '%s读取规则失败: %s%s\n' "$RED" "$RULES_ERROR" "$RESET"
        pause_screen
        return
    fi
    print_rules_table
    ((${#RULE_IDX[@]})) || { pause_screen; return; }
    printf '\n%s规则编号（回车取消）:%s ' "$CYAN" "$RESET"
    read -r answer || return 0
    [[ -n "$answer" ]] || return 0
    for ((i = 0; i < ${#RULE_IDX[@]}; i++)); do
        if [[ "${RULE_IDX[i]}" == "$answer" ]]; then
            selected="$i"
            break
        fi
    done
    if (( selected < 0 )); then
        printf '%s规则编号无效。%s\n' "$RED" "$RESET"
        pause_screen
        return
    fi
    rate="$(prompt_rate '新')" || { pause_screen; return; }
    for ((i = 0; i < ${#RULE_IDX[@]}; i++)); do
        if (( i == selected )); then
            piece="$(rule_to_spec "$i" "$rate")"
        else
            piece="$(rule_to_spec "$i")"
        fi
        spec+="${spec:+ }$piece"
    done
    if config_apply_edits "PORT_SPEC=$spec"; then
        printf '%s已保存规则 %s 的新速率: %s%s\n' "$GREEN" "$answer" "$rate" "$RESET"
        apply_after_change
    else
        pause_screen
    fi
}

show_rule_edit_menu() {
    local choice
    while true; do
        clear_screen
        draw_brand
        printf '\n%s端口限速 > 修改规则速率%s\n\n' "$YELLOW" "$RESET"
        printf '%s1.%s 修改单条规则速率\n' "$GREEN" "$RESET"
        printf '%s2.%s 统一修改全部规则速率\n' "$GREEN" "$RESET"
        printf '%s0.%s 返回端口限速\n' "$GREEN" "$RESET"
        printf '\n%s选择:%s ' "$CYAN" "$RESET"
        read -r choice || return 0
        case "$choice" in
            1) change_rule_rate ;;
            2) change_all_rates ;;
            0|"") return ;;
            *) printf '%s请输入 1-2 或 0。%s\n' "$RED" "$RESET"; pause_screen ;;
        esac
    done
}

# Rewrite every rule with one rate.
change_all_rates() {
    local i rate spec piece

    clear_screen
    draw_brand
    printf '\n%s端口限速 > 统一修改全部规则速率%s\n\n' "$YELLOW" "$RESET"

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

# Delete selected rules.
delete_rules() {
    local answer token found i skip spec

    clear_screen
    draw_brand
    printf '\n%s端口限速 > 删除限速规则%s\n\n' "$YELLOW" "$RESET"

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
    read -r answer || return 0
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

# Remove every rule, with explicit confirmation.
clear_rules() {
    local answer

    clear_screen
    draw_brand
    printf '\n%s端口限速 > 高级与排障 > 清空全部规则%s\n\n' "$YELLOW" "$RESET"

    if ! load_rules; then
        printf '%s读取规则失败:%s\n%s\n' "$RED" "$RESET" "$RULES_ERROR"
        pause_screen
        return
    fi
    print_rules_table

    printf '\n%s这会删除配置里的全部端口规则，应用后只剩默认队列。%s\n' \
        "$RED" "$RESET"
    printf '确认清空请输入 %sYES%s，其他输入取消: ' "$RED" "$RESET"
    read -r answer || return 0
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

# ------------------------------------------------- per-port traffic stats

human_bytes() {
    awk -v b="${1:-0}" 'BEGIN {
        if (b >= 1073741824) printf "%.2f GB", b / 1073741824;
        else if (b >= 1048576) printf "%.2f MB", b / 1048576;
        else if (b >= 1024) printf "%.1f KB", b / 1024;
        else printf "%.0f B", b;
    }'
}

format_speed() {
    awk -v d="${1:-0}" -v s="${2:-1}" 'BEGIN {
        if (s <= 0) s = 1;
        bps = d / s;
        if (bps >= 1048576) printf "%.2f MB/s", bps / 1048576;
        else if (bps >= 1024) printf "%.1f KB/s", bps / 1024;
        else printf "%.0f B/s", bps;
    }'
}

show_port_stats() {
    local interval="${1:-${STATS_INTERVAL:-3}}"
    local sample_a sample_b n rows total=0 active=0 idle=0

    clear_screen
    draw_brand
    printf '\n%s流量查看 > 限速端口实时流量%s\n\n' "$YELLOW" "$RESET"

    if ! sample_a="$(limit_local stats 2>&1)"; then
        printf '%s读取失败:%s\n%s\n' "$RED" "$RESET" "$sample_a"
        pause_screen
        return
    fi

    n="$(printf '%s\n' "$sample_a" | grep -c '^[0-9]' || true)"
    if [[ "${n:-0}" == "0" ]]; then
        printf '%s没有读到任何限速队列。%s\n' "$YELLOW" "$RESET"
        printf '%s请先在「端口限速」添加规则并应用当前配置。%s\n' "$DIM" "$RESET"
        pause_screen
        return
    fi

    printf '%s采样中，请稍候 %s 秒...%s\n' "$DIM" "$interval" "$RESET"
    sleep "$interval"
    if ! sample_b="$(limit_local stats 2>&1)"; then
        sample_b="$sample_a"
    fi

    local -A prev=()
    while IFS=$'\t' read -r cid port rate bytes pkts drop over; do
        [[ "$cid" =~ ^[0-9]+$ ]] || continue
        prev["$cid"]="$bytes"
    done <<<"$sample_a"

    rows=""
    while IFS=$'\t' read -r cid port rate bytes pkts drop over; do
        [[ "$cid" =~ ^[0-9]+$ ]] || continue
        local base="${prev[$cid]:-0}"
        local delta=$((bytes - base))
        if (( delta < 0 )); then
            delta=0
        fi
        total=$((total + delta))
        if (( delta > 0 )); then
            active=$((active + 1))
        fi
        if (( bytes == 0 )); then
            idle=$((idle + 1))
        fi
        rows+="$delta"$'\t'"$port"$'\t'"$rate"$'\t'"$(format_speed "$delta" "$interval")"$'\t'"$(human_bytes "$bytes")"$'\t'"$pkts"$'\n'
    done <<<"$sample_b"

    local head row
    head="  $(pad '端口' 16) $(pad '限速' 10) $(pad '当前速率' 12) $(pad '累计流量' 13) 包数"
    printf '\n%s%s%s\n' "$DIM" "$head" "$RESET"

    printf '%s' "$rows" | sort -rn -k1,1 | sed -n '1,25p' |
        while IFS=$'\t' read -r _delta port rate speed human pkts; do
            if [[ -n "$port" ]]; then
                row="  $(pad "$port" 16) $(pad "$rate" 10) $(pad "$speed" 12) $(pad "$human" 13) $pkts"
                printf '%s\n' "$row"
            fi
        done

    printf '\n%s  端口总数 %s   正在跑 %s   累计 0 字节 %s%s\n' \
        "$DIM" "$n" "$active" "$idle" "$RESET"
    printf '%s  合计速率: %s%s\n' "$DIM" \
        "$(awk -v d="$total" -v s="$interval" 'BEGIN { printf "%.2f Mbit/s", (s > 0 ? d * 8 / s / 1e6 : 0) }')" \
        "$RESET"
    if (( idle > 0 )); then
        printf '%s  提示: 累计 0 字节只说明该端口还没被用过；若某用户明明在跑却是 0，才说明没匹配上。%s\n' \
            "$DIM" "$RESET"
    fi
    if (( $(printf '%s\n' "$sample_b" | grep -c '^[0-9]' || true) > 25 )); then
        printf '%s  只显示速率最高的 25 个。%s\n' "$DIM" "$RESET"
    fi

    pause_screen
}

# ------------------------------------------- all-port live traffic monitor
#
# The tc counters only exist for ports we shape. To watch every port we read
# the kernel connection tracking table instead: it carries per-connection
# byte counters for both directions and needs no extra packages.
#
# Only connections where the ORIGINAL tuple targets one of our own addresses
# are counted, i.e. the host acting as a server. That also avoids counting
# the docker-proxy -> container leg twice.

CONNTRACK_FILE="${CONNTRACK_FILE:-/proc/net/nf_conntrack}"
TRAFFIC_INTERVAL="${TRAFFIC_INTERVAL:-2}"
TRAFFIC_TOP="${TRAFFIC_TOP:-25}"

local_ip_set() {
    ip -o addr show scope global 2>/dev/null |
        awk '{ split($4, a, "/"); print a[1] }' |
        tr '\n' ' '
}

conntrack_source() {
    if [[ -r "$CONNTRACK_FILE" ]]; then
        printf 'file'
    elif command -v conntrack >/dev/null 2>&1; then
        printf 'cmd'
    else
        printf 'none'
    fi
}

# 输出: proto<TAB>port<TAB>bytes<TAB>connections
conntrack_by_port() {
    local ips
    ips="$(local_ip_set)"
    local awk_prog='
        BEGIN {
            n = split(ips, a, " ")
            for (i = 1; i <= n; i++) {
                if (a[i] != "") { local[a[i]] = 1 }
            }
        }
        {
            c = 0
            proto = ""
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^(tcp|udp|sctp|icmp|icmpv6)$/ && proto == "") { proto = $i }
                else if ($i ~ /^src=/)        { c++; src[c]   = substr($i, 5) }
                else if ($i ~ /^dst=/)        { dst[c]   = substr($i, 5) }
                else if ($i ~ /^sport=/)      { sport[c] = substr($i, 7) }
                else if ($i ~ /^dport=/)      { dport[c] = substr($i, 7) }
                else if ($i ~ /^bytes=/)      { bytes[c] = substr($i, 7) + 0 }
            }
            if (c < 1 || proto == "") { next }
            # 本机作为服务端：原始方向的目的地址是本机
            if (!(dst[1] in local)) { next }
            p = dport[1]
            if (p == "") { next }
            key = proto "\t" p
            total[key] += bytes[1] + bytes[2]
            conns[key]++
        }
        END {
            for (k in total) { printf "%s\t%d\t%d\n", k, total[k], conns[k] }
        }
    '

    case "$(conntrack_source)" in
        file)
            awk -v ips="$ips" "$awk_prog" "$CONNTRACK_FILE" 2>/dev/null || true
            ;;
        cmd)
            conntrack -L -o extended 2>/dev/null |
                awk -v ips="$ips" "$awk_prog" 2>/dev/null || true
            ;;
        *)
            return 1
            ;;
    esac
    return 0
}

# 这个端口有没有被限速（读的是 [01] 里的规则）
limited_rate_of() {
    local port="$1" i
    for ((i = 0; i < ${#RULE_IDX[@]}; i++)); do
        if (( port >= RULE_START[i] && port <= RULE_END[i] )); then
            printf '%s' "${RULE_RATE[i]}"
            return 0
        fi
    done
    printf '—'
}

draw_traffic_screen() {
    local prev="$1" cur="$2" interval="$3"
    local -A prev_bytes=()
    local proto port bytes conns

    while IFS=$'\t' read -r proto port bytes conns; do
        if [[ -n "$port" ]]; then
            prev_bytes["$proto/$port"]="$bytes"
        fi
    done <<<"$prev"

    local rows="" active=0 total=0
    local delta base
    while IFS=$'\t' read -r proto port bytes conns; do
        if [[ -z "$port" ]]; then
            continue
        fi
        base="${prev_bytes["$proto/$port"]:-0}"
        delta=$((bytes - base))
        if (( delta < 0 )); then
            delta=0
        fi
        # 只显示这段时间里真的有流量经过的端口
        if (( delta == 0 )); then
            continue
        fi
        active=$((active + 1))
        total=$((total + delta))
        rows+="$delta"$'\t'"$port"$'\t'"$proto"$'\t'"$(format_speed "$delta" "$interval")"$'\t'"$conns"$'\t'"$(limited_rate_of "$port")"$'\n'
    done <<<"$cur"

    # 不整屏清，避免闪烁
    printf '%s[H' "$ESC"
    draw_brand
    printf '\n%s流量查看 > 全部端口实时流量%s   %s%s%s   %s每 %s 秒刷新，Ctrl+C 返回%s\n' \
        "$YELLOW" "$RESET" "$DIM" "$(date '+%H:%M:%S')" "$RESET" \
        "$DIM" "$interval" "$RESET"

    if (( active == 0 )); then
        printf '\n%s  这段时间里没有任何端口有流量经过。%s\n' "$DIM" "$RESET"
        printf '%s[J' "$ESC"
        return 0
    fi

    local head row
    head="  $(pad '端口' 12) $(pad '协议' 8) $(pad '当前速率' 14) $(pad '连接数' 10) 限速"
    printf '\n%s%s%s\n' "$DIM" "$head" "$RESET"

    printf '%s' "$rows" | sort -rn -k1,1 | sed -n "1,${TRAFFIC_TOP}p" |
        while IFS=$'\t' read -r _delta port proto speed conns limited; do
            if [[ -n "$port" ]]; then
                row="  $(pad "$port" 12) $(pad "$proto" 8) $(pad "$speed" 14) $(pad "$conns" 10) $limited"
                printf '%s\n' "$row"
            fi
        done

    printf '\n%s  活跃端口 %s   合计 %s%s\n' \
        "$DIM" "$active" "$(format_speed "$total" "$interval")" "$RESET"
    if (( active > TRAFFIC_TOP )); then
        printf '%s  只显示速率最高的 %s 个。%s\n' "$DIM" "$TRAFFIC_TOP" "$RESET"
    fi
    printf '%s[J' "$ESC"
    return 0
}

traffic_loop() {
    local interval="$1" prev cur n=0
    local max="${TRAFFIC_REFRESH:-0}"

    prev="$(conntrack_by_port)"
    draw_traffic_screen "$prev" "$prev" "$interval"
    while true; do
        sleep "$interval"
        cur="$(conntrack_by_port)"
        draw_traffic_screen "$prev" "$cur" "$interval"
        prev="$cur"
        n=$((n + 1))
        if (( max > 0 && n >= max )); then
            break
        fi
    done
}

show_all_port_traffic() {
    local interval="${1:-$TRAFFIC_INTERVAL}"

    if [[ "$(conntrack_source)" == "none" ]]; then
        clear_screen
        draw_brand
        printf '\n%s读不到连接跟踪表。%s\n' "$RED" "$RESET"
        printf '%s需要 root 权限读 %s，或者系统里没有 conntrack。%s\n' \
            "$DIM" "$CONNTRACK_FILE" "$RESET"
        pause_screen
        return
    fi

    # 规则用于标注"这个端口有没有被限速"
    load_rules || true

    # 父进程忽略 SIGINT，Ctrl+C 只结束刷新循环，回到菜单
    trap '' INT
    (
        trap - INT
        traffic_loop "$interval"
    ) || true
    trap - INT

    pause_screen
}

# ------------------------------------------------- traffic accounting
#
# tc counters only exist on egress, so they can only answer "how much did the
# server send to this user". For per-port totals in BOTH directions we let the
# kernel count itself with nftables named counters, referenced from two maps so
# the lookup stays a hash instead of a few hundred rules evaluated per packet.
#
#   ingress, user upload   : prerouting,  dport == the user's port
#   egress,  user download : postrouting, sport == the user's port
#
# `nft reset counters` both dumps and clears in one go, so folding the live
# counters into a file on disk never drops a packet, and the totals survive a
# reboot even though the nft rules themselves do not.

ACCT_TABLE="${ACCT_TABLE:-portctl_acct}"
ACCT_DIR="${ACCT_DIR:-/var/lib/portctl}"
ACCT_FILE="${ACCT_FILE:-$ACCT_DIR/traffic.tsv}"
ACCT_SERVICE_FILE="${ACCT_SERVICE_FILE:-/etc/systemd/system/portctl-accounting.service}"
ACCT_TIMER_FILE="${ACCT_TIMER_FILE:-/etc/systemd/system/portctl-accounting.timer}"
ACCT_TIMER_NAME="portctl-accounting.timer"
ACCT_MAX_PORTS="${ACCT_MAX_PORTS:-512}"
# 临时的 stderr 暂存文件，只用于把诊断信息和数据分开
ACCT_ERR_FILE="${ACCT_ERR_FILE:-${TMPDIR:-/tmp}/portctl-acct-err.$$}"

acct_available() {
    command -v nft >/dev/null 2>&1
}

acct_table_exists() {
    nft list table inet "$ACCT_TABLE" >/dev/null 2>&1
}

# 按当前端口规则展开成端口列表；超过上限则返回 1
acct_ports() {
    local i p
    local -a out=()
    for ((i = 0; i < ${#RULE_IDX[@]}; i++)); do
        for ((p = RULE_START[i]; p <= RULE_END[i]; p++)); do
            out+=("$p")
            if (( ${#out[@]} > ACCT_MAX_PORTS )); then
                return 1
            fi
        done
    done
    ((${#out[@]})) || return 1
    printf '%s\n' "${out[@]}"
    return 0
}

acct_build_script() {
    local -a ports=()
    local p els_up="" els_down=""
    readarray -t ports < <(acct_ports) || return 1
    ((${#ports[@]})) || return 1

    for p in "${ports[@]}"; do
        els_up+="${els_up:+, }$p : \"up_$p\""
        els_down+="${els_down:+, }$p : \"down_$p\""
    done

    printf 'table inet %s {\n' "$ACCT_TABLE"
    for p in "${ports[@]}"; do
        printf '    counter up_%s {\n    }\n' "$p"
        printf '    counter down_%s {\n    }\n' "$p"
    done
    printf '    map up {\n        type inet_service : counter\n        elements = { %s }\n    }\n' "$els_up"
    printf '    map down {\n        type inet_service : counter\n        elements = { %s }\n    }\n' "$els_down"
    printf '    chain pre {\n'
    printf '        type filter hook prerouting priority -150; policy accept;\n'
    printf '        counter name tcp dport map @up\n'
    printf '        counter name udp dport map @up\n'
    printf '    }\n'
    printf '    chain post {\n'
    printf '        type filter hook postrouting priority 150; policy accept;\n'
    printf '        counter name tcp sport map @down\n'
    printf '        counter name udp sport map @down\n'
    printf '    }\n'
    printf '}\n'
}

acct_setup() {
    acct_available || {
        printf '找不到 nft 命令，无法建立流量统计。\n' >&2
        return 1
    }
    load_rules || true
    if (( ${#RULE_IDX[@]} == 0 )); then
        printf '当前没有任何端口规则，请先在 [01] 里配置限速端口。\n' >&2
        return 1
    fi

    local script n
    script="$(mktemp)" || return 1
    if ! acct_build_script >"$script"; then
        rm -f "$script"
        printf '端口数量超过 ACCT_MAX_PORTS=%s，未建立统计。\n' "$ACCT_MAX_PORTS" >&2
        return 1
    fi
    n="$(acct_ports | wc -l)"

    # 先用 -c（check）让 nft 只解析不执行：语法/内核校验不过就直接放弃，
    # 已经存在的旧统计表原封不动，不会出现"删了旧表又装不上新表"。
    if ! nft -c -f "$script" 2>&1; then
        rm -f "$script"
        printf 'nft 校验未通过（上面是内核报错），未做任何修改。\n' >&2
        return 1
    fi

    nft delete table inet "$ACCT_TABLE" 2>/dev/null || true
    if ! nft -f "$script"; then
        rm -f "$script"
        printf 'nft 规则加载失败（上面是内核报错）。\n' >&2
        return 1
    fi
    rm -f "$script"

    if ! acct_table_exists; then
        printf 'nft 报告成功但表不存在，未建立统计。\n' >&2
        return 1
    fi

    printf '统计规则已建立: %s 个端口 × 2 个方向。\n' "$n"
    return 0
}

acct_remove() {
    if acct_table_exists; then
        nft delete table inet "$ACCT_TABLE" && printf '统计规则已移除（磁盘上的累计数据保留）。\n'
    else
        printf '统计规则本来就不存在。\n'
    fi
    return 0
}

# 输出: port<TAB>up<TAB>down
# $1 = reset（读取并清零，用于折叠）| 省略（只读）
#
# reset 会把内核计数器清零，所以只有在确认拿到了**完整**列表时才允许折叠：
# 任何一次 nft 调用失败或输出异常，都必须放弃本次折叠而不是把残缺数据当真。
acct_read_counters() {
    local mode="${1:-read}" out rc=0 expected seen tables

    if [[ "$mode" == "reset" ]]; then
        out="$(nft reset counters table inet "$ACCT_TABLE" 2>&1)" || rc=$?
    else
        out="$(nft list counters table inet "$ACCT_TABLE" 2>&1)" || rc=$?
    fi

    if (( rc != 0 )); then
        # An absent table is normal before setup, after removal or after reboot.
        # Only a successful table listing can distinguish it from access errors.
        if [[ "$mode" == "read" ]] &&
            tables="$(nft list tables inet 2>/dev/null)" &&
            ! grep -Fxq -- "table inet $ACCT_TABLE" <<<"$tables"; then
            return 0
        fi
        printf '[acct] nft 执行失败（退出码 %s）: %s\n' "$rc" "$out" >&2
        return 1
    fi
    if [[ -z "$out" ]]; then
        printf '[acct] nft 没有输出，放弃本次读取。\n' >&2
        return 1
    fi

    # 该有的计数器一个都不能少，少一个就意味着有字节会被漏掉。
    expected="$(acct_ports 2>/dev/null | wc -l)" || expected=0
    seen="$(printf '%s\n' "$out" | grep -cE '^[[:space:]]*counter (up|down)_[0-9]+' || true)"
    if (( expected > 0 )) && (( seen != expected * 2 )); then
        printf '[acct] 只读到 %s/%s 个计数器，放弃本次读取。\n' \
            "$seen" "$((expected * 2))" >&2
        if (( seen > 0 )); then
            printf '[acct] 端口规则和已建立的统计表不一致（改过端口规则？），\n' >&2
            printf '[acct] 请在「流量查看 > 上行 / 下行累计」里选「2. 建立 / 重建统计」。\n' >&2
        fi
        return 1
    fi

    printf '%s\n' "$out" | awk '
        /counter (up|down)_[0-9]+/ {
            name = $2
            next
        }
        /packets/ {
            if (name == "") { next }
            split(name, part, "_")
            p = part[2]
            if (part[1] == "up") { up[p] += $4 }
            else { down[p] += $4 }
            name = ""
        }
        END {
            for (p in up) { printf "%s\t%d\t%d\n", p, up[p], down[p] + 0 }
            for (p in down) { if (!(p in up)) { printf "%s\t0\t%d\n", p, down[p] } }
        }
    '
}

acct_load_totals() {
    [[ -f "$ACCT_FILE" ]] || return 0
    awk -F'\t' '$1 !~ /^#/ && NF >= 3 { printf "%s\t%s\t%s\n", $1, $2, $3 }' "$ACCT_FILE"
}

# 已有累计 + 尚未折叠的实时计数
acct_current() {
    local totals live rc=0
    totals="$(acct_load_totals)" || rc=$?
    live="$(acct_read_counters read)" || rc=$?
    printf '%s\n%s\n' "$totals" "$live" |
        awk -F'\t' '
            $1 ~ /^#/ { next }
            NF >= 3 { up[$1] += $2; down[$1] += $3 }
            END { for (p in up) { printf "%s\t%d\t%d\n", p, up[p], down[p] } }
        ' | sort -n || return $?
    return "$rc"
}

# 把实时计数原子地读走并清零，累加进磁盘
acct_sample() {
    acct_available || return 1

    # 重启后 nft 规则不存在，先自愈重建（新计数器从 0 开始，本次没有可折叠的数据）
    if ! acct_table_exists; then
        acct_setup || return 1
        return 0
    fi

    local live
    if ! live="$(acct_read_counters reset)"; then
        # 读取不完整时绝不能折叠：reset 可能已经清零，但我们手里的数据是残的。
        # 直接失败退出，让 systemd 记录一次失败的采样，而不是悄悄丢掉流量。
        printf '[acct] 本次采样放弃，未写入累计文件。\n' >&2
        return 1
    fi
    if [[ -z "$live" ]]; then
        return 0
    fi

    install -d -m 0755 "$ACCT_DIR" || return 1
    local tmp ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    tmp="$(mktemp)" || return 1

    {
        printf '# port\tup_bytes\tdown_bytes\tupdated\n'
        {
            acct_load_totals
            printf '%s\n' "$live"
        } | awk -F'\t' -v ts="$ts" '
            $1 ~ /^#/ { next }
            NF >= 3 { up[$1] += $2; down[$1] += $3 }
            END {
                for (p in up) { printf "%s\t%d\t%d\t%s\n", p, up[p], down[p], ts }
            }
        ' | sort -n
    } >"$tmp"

    if ! mv -f "$tmp" "$ACCT_FILE"; then
        rm -f "$tmp"
        return 1
    fi
    return 0
}

acct_reset() {
    acct_available || return 1
    nft reset counters table inet "$ACCT_TABLE" >/dev/null 2>&1 || true
    install -d -m 0755 "$ACCT_DIR" || return 1
    [[ -f "$ACCT_FILE" ]] && rm -f "$ACCT_FILE"
    printf '累计流量已清零。\n'
    return 0
}

acct_autostart_enabled() {
    command -v systemctl >/dev/null 2>&1 || return 1
    systemctl is-enabled "$ACCT_TIMER_NAME" >/dev/null 2>&1
}

acct_autostart_label() {
    if acct_autostart_enabled; then
        printf '已开启（每分钟）'
    else
        printf '未开启'
    fi
}

acct_autostart_on() {
    local self tmp
    self="$(fw_installed_self)"
    tmp="$(mktemp)" || return 1

    {
        printf '[Unit]\n'
        printf 'Description=portctl traffic accounting sample\n\n'
        printf '[Service]\n'
        printf 'Type=oneshot\n'
        printf 'ExecStart=%s acct-sample\n' "$self"
    } >"$tmp"
    if ! run_root install -m 0644 "$tmp" "$ACCT_SERVICE_FILE"; then
        rm -f "$tmp"
        return 1
    fi

    {
        printf '[Unit]\n'
        printf 'Description=portctl traffic accounting timer\n\n'
        printf '[Timer]\n'
        printf 'OnBootSec=2min\n'
        printf 'OnUnitActiveSec=1min\n\n'
        printf '[Install]\n'
        printf 'WantedBy=timers.target\n'
    } >"$tmp"
    if ! run_root install -m 0644 "$tmp" "$ACCT_TIMER_FILE"; then
        rm -f "$tmp"
        return 1
    fi
    rm -f "$tmp"

    run_root systemctl daemon-reload || true
    run_root systemctl enable --now "$ACCT_TIMER_NAME"
}

acct_autostart_off() {
    if command -v systemctl >/dev/null 2>&1; then
        run_root systemctl disable --now "$ACCT_TIMER_NAME" 2>/dev/null || true
    fi
    run_root rm -f "$ACCT_TIMER_FILE" "$ACCT_SERVICE_FILE"
    if command -v systemctl >/dev/null 2>&1; then
        run_root systemctl daemon-reload 2>/dev/null || true
    fi
    return 0
}

# 输出: 合计<TAB>端口<TAB>上行<TAB>下行<TAB>限速，最后一行是 #TOTAL<TAB>上行<TAB>下行
acct_rows_for_menu() {
    local data rc=0
    data="$(acct_current)" || rc=$?
    local -A up=() down=()
    local p u d

    while IFS=$'\t' read -r p u d; do
        if [[ -n "$p" ]]; then
            up["$p"]="${u:-0}"
            down["$p"]="${d:-0}"
        fi
    done <<<"$data"

    local i port tot_u=0 tot_d=0 rows=""
    for ((i = 0; i < ${#RULE_IDX[@]}; i++)); do
        for ((port = RULE_START[i]; port <= RULE_END[i]; port++)); do
            u="${up[$port]:-0}"
            d="${down[$port]:-0}"
            tot_u=$((tot_u + u))
            tot_d=$((tot_d + d))
            rows+="$((u + d))"$'\t'"$port"$'\t'"$u"$'\t'"$d"$'\t'"${RULE_RATE[i]}"$'\n'
        done
    done

    printf '%s' "$rows"
    printf '#TOTAL\t%s\t%s\n' "$tot_u" "$tot_d"
    return "$rc"
}

show_traffic_accounting() {
    local choice data rows total_line

    while true; do
        clear_screen
        draw_brand
        printf '\n%s流量查看 > 上行 / 下行累计%s\n' "$YELLOW" "$RESET"

        if ! acct_available; then
            printf '\n%s找不到 nft 命令，这个功能需要 nftables。%s\n' "$RED" "$RESET"
            pause_screen
            return
        fi

        # stdout 是数据、stderr 是诊断信息，必须分开：
        # 合并到一起的话，一条 [acct] 警告会被当成数据行混进表格。
        local err_file="$ACCT_ERR_FILE"
        : >"$err_file" 2>/dev/null || err_file=/dev/null
        local acct_rc=0
        data="$(run_root bash "$SELF_PATH" acct-show 2>"$err_file")" || acct_rc=$?
        local acct_err=""
        [[ -s "$err_file" ]] && acct_err="$(cat "$err_file")"

        rows="$(printf '%s\n' "$data" | grep '^[0-9]' || true)"
        total_line="$(printf '%s\n' "$data" | grep '^#TOTAL' || true)"

        if (( acct_rc != 0 )) || [[ -n "$acct_err" ]]; then
            printf '\n%s读取累计数据时有问题:%s\n%s\n' "$YELLOW" "$RESET" "$acct_err"
        fi

        local n_rows n_active
        n_rows="$(printf '%s\n' "$rows" | grep -c '^[0-9]' || true)"
        n_active="$(printf '%s\n' "$rows" | awk -F'\t' '$1 > 0' | grep -c '^[0-9]' || true)"
        n_rows="${n_rows:-0}"
        n_active="${n_active:-0}"

        # 只显示真的有过流量的端口
        if (( acct_rc != 0 && n_active == 0 )); then
            printf '\n%s  本次统计读取失败，不能确认当前流量。%s\n' "$YELLOW" "$RESET"
        elif (( n_rows == 0 )); then
            printf '\n%s  当前没有端口规则，请先在 [01] 里配置限速端口。%s\n' "$YELLOW" "$RESET"
        elif (( n_active == 0 )); then
            printf '\n%s  还没有任何一个端口产生过流量。%s\n' "$DIM" "$RESET"
        else
            local head row
            head="  $(pad '端口' 10) $(pad '上行（用户上传）' 18) $(pad '下行（用户下载）' 18) $(pad '合计' 12) 限速"
            printf '\n%s%s%s\n' "$DIM" "$head" "$RESET"
            printf '%s\n' "$rows" | awk -F'\t' '$1 > 0' | sort -rn -k1,1 | sed -n '1,30p' |
                while IFS=$'\t' read -r _t port u d rate; do
                    [[ -n "$port" ]] || continue
                    row="  $(pad "$port" 10) $(pad "$(human_bytes "$u")" 18) $(pad "$(human_bytes "$d")" 18) $(pad "$(human_bytes "$((u + d))")" 12) $rate"
                    printf '%s\n' "$row"
                done
            if (( n_active > 30 )); then
                printf '\n%s  有流量的端口共 %s 个，只显示合计最高的 30 个。%s\n' "$DIM" "$n_active" "$RESET"
            fi
        fi

        if [[ -n "$total_line" ]]; then
            IFS=$'\t' read -r _ tu td <<<"$total_line"
            printf '%s  端口总数 %s   有过流量 %s%s\n' "$DIM" "$n_rows" "$n_active" "$RESET"
            printf '%s  总计: 上行 %s   下行 %s   合计 %s%s\n' \
                "$DIM" "$(human_bytes "$tu")" "$(human_bytes "$td")" \
                "$(human_bytes "$((tu + td))")" "$RESET"
        fi

        if (( acct_rc != 0 )); then
            printf '%s  统计规则: 状态未知（读取失败）%s\n' "$YELLOW" "$RESET"
        elif acct_table_exists; then
            printf '%s  统计规则: 已建立    %s自动采样: %s%s\n' \
                "$DIM" "$DIM" "$(acct_autostart_label)" "$RESET"
        else
            printf '%s  统计规则: 未建立（选 2 建立）%s\n' "$YELLOW" "$RESET"
        fi

        printf '\n%s1.%s 刷新\n' "$GREEN" "$RESET"
        printf '%s2.%s 按当前端口规则建立 / 重建统计\n' "$GREEN" "$RESET"
        printf '%s3.%s 清零累计数据\n' "$GREEN" "$RESET"
        printf '%s4.%s 自动采样开关（systemd timer）\n' "$GREEN" "$RESET"
        printf '%s5.%s 移除统计规则（保留磁盘数据）\n' "$GREEN" "$RESET"
        printf '%s0.%s 返回\n' "$GREEN" "$RESET"
        printf '\n%s选择:%s ' "$CYAN" "$RESET"
        read -r choice || return 0

        case "$choice" in
            ""|1) continue ;;
            2)
                printf '\n'
                run_root bash "$SELF_PATH" acct-setup || true
                pause_screen
                ;;
            3)
                printf '\n%s这会清空所有端口的累计流量，不可恢复。确认请输入 YES: %s' "$YELLOW" "$RESET"
                read -r choice || return 0
                if [[ "$choice" == "YES" ]]; then
                    run_root bash "$SELF_PATH" acct-reset || true
                else
                    printf '%s已取消。%s\n' "$DIM" "$RESET"
                fi
                pause_screen
                ;;
            4)
                if acct_autostart_enabled; then
                    acct_autostart_off
                    printf '%s已关闭自动采样。%s\n' "$GREEN" "$RESET"
                else
                    if acct_autostart_on; then
                        printf '%s已开启自动采样（每分钟折叠一次，重启不丢）。%s\n' "$GREEN" "$RESET"
                    else
                        printf '%s开启失败。%s\n' "$RED" "$RESET"
                    fi
                fi
                pause_screen
                ;;
            5)
                printf '\n'
                run_root bash "$SELF_PATH" acct-remove || true
                pause_screen
                ;;
            0) return ;;
            *)
                printf '%s请输入 1-5 或 0。%s\n' "$RED" "$RESET"
                pause_screen
                ;;
        esac
    done
}

show_traffic_menu() {
    local choice
    while true; do
        clear_screen
        draw_brand
        printf '\n%s[02] 流量查看%s\n\n' "$YELLOW" "$RESET"
        printf '%s1.%s 限速端口实时流量\n' "$GREEN" "$RESET"
        printf '%s2.%s 上行 / 下行累计\n' "$GREEN" "$RESET"
        printf '%s3.%s 全部端口监控（排障）\n' "$GREEN" "$RESET"
        printf '%s0.%s 返回\n' "$GREEN" "$RESET"
        printf '\n%s选择:%s ' "$CYAN" "$RESET"
        read -r choice || return 0
        case "$choice" in
            1) show_port_stats ;;
            2) show_traffic_accounting ;;
            3) show_all_port_traffic ;;
            0|"") return ;;
            *) printf '%s请输入 1-3 或 0。%s\n' "$RED" "$RESET"; pause_screen ;;
        esac
    done
}

show_limit_advanced_menu() {
    local choice
    while true; do
        clear_screen
        draw_brand
        printf '\n%s端口限速 > 高级与排障%s\n\n' "$YELLOW" "$RESET"
        printf '%s1.%s 查看 tc 队列与统计\n' "$GREEN" "$RESET"
        printf '%s2.%s 查看配置执行计划\n' "$GREEN" "$RESET"
        printf '%s3.%s 清空全部限速规则\n' "$RED" "$RESET"
        printf '%s0.%s 返回端口限速\n' "$GREEN" "$RESET"
        printf '\n%s选择:%s ' "$CYAN" "$RESET"
        read -r choice || return 0
        case "$choice" in
            1)
                run_root tc -s qdisc show dev "$NIC" || true
                run_root tc -s class show dev "$NIC" || true
                pause_screen
                ;;
            2) limit_local plan -v || true; pause_screen ;;
            3) clear_rules ;;
            0|"") return ;;
            *) printf '%s请输入 1-3 或 0。%s\n' "$RED" "$RESET"; pause_screen ;;
        esac
    done
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

        printf '\n%s1.%s 添加限速规则\n' "$GREEN" "$RESET"
        printf '%s2.%s 修改规则速率\n' "$GREEN" "$RESET"
        printf '%s3.%s 删除限速规则\n' "$GREEN" "$RESET"
        printf '%s4.%s 应用当前配置\n' "$GREEN" "$RESET"
        printf '%s5.%s 流量查看\n' "$GREEN" "$RESET"
        printf '%s6.%s 高级与排障\n' "$GREEN" "$RESET"
        printf '%s0.%s 返回主菜单\n' "$GREEN" "$RESET"
        printf '\n%s选择:%s ' "$CYAN" "$RESET"
        read -r choice || return 0

        case "$choice" in
            1) add_rule_flow ;;
            2) show_rule_edit_menu ;;
            3) delete_rules ;;
            4)
                limit_root apply || true
                pause_screen
                ;;
            5) show_traffic_menu ;;
            6) show_limit_advanced_menu ;;
            0|"") return ;;
            *)
                printf '%s请输入 1-6 或 0。%s\n' "$RED" "$RESET"
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
        printf '# portctl 防火墙规则（由控制台防火墙菜单维护）\n'
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
        printf '%s已保存配置，之后可在「防火墙规则 > 应用当前配置」生效。%s\n' \
            "$DIM" "$RESET"
        pause_screen
    fi
}

fw_add_port_flow() {
    local action proto ports_pair start end src

    clear_screen
    draw_brand
    printf '\n%s防火墙规则 > 添加端口规则%s\n\n' "$YELLOW" "$RESET"

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
    printf '\n%s防火墙规则 > 添加来源 IP 规则%s\n\n' "$YELLOW" "$RESET"

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
    printf '\n%s防火墙规则 > 删除规则%s\n\n' "$YELLOW" "$RESET"

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
    printf '\n%s防火墙规则 > 高级与排障 > 清空全部规则%s\n\n' "$YELLOW" "$RESET"

    fw_load
    fw_render_table
    printf '\n%s清空后不会立刻撤销系统里的规则，需要再选「应用当前配置」才会移除链/表。%s\n' \
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
    printf '\n%s防火墙规则 > 系统实际规则%s\n\n' "$YELLOW" "$RESET"

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
    printf '\n%s防火墙规则 > 后端与开机自启%s\n\n' "$YELLOW" "$RESET"
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
    read -r choice || return 0

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

fw_add_menu() {
    local choice
    clear_screen
    draw_brand
    printf '\n%s防火墙规则 > 添加规则%s\n\n' "$YELLOW" "$RESET"
    printf '%s1.%s 端口规则（放行 / 封禁）\n' "$GREEN" "$RESET"
    printf '%s2.%s 来源 IP 规则（放行 / 封禁）\n' "$GREEN" "$RESET"
    printf '%s0.%s 返回防火墙规则\n' "$GREEN" "$RESET"
    printf '\n%s选择:%s ' "$CYAN" "$RESET"
    read -r choice || return 0
    case "$choice" in
        1) fw_add_port_flow ;;
        2) fw_add_ip_flow ;;
        0|"") return ;;
        *) printf '%s请输入 1-2 或 0。%s\n' "$RED" "$RESET"; pause_screen ;;
    esac
}

show_firewall_advanced_menu() {
    local choice
    while true; do
        fw_load
        clear_screen
        draw_brand
        printf '\n%s防火墙规则 > 高级与排障%s\n\n' "$YELLOW" "$RESET"
        printf '%s1.%s 查看系统实际规则\n' "$GREEN" "$RESET"
        printf '%s2.%s 后端与开机自启设置\n' "$GREEN" "$RESET"
        printf '%s3.%s 清空全部防火墙规则\n' "$RED" "$RESET"
        printf '%s0.%s 返回防火墙规则\n' "$GREEN" "$RESET"
        printf '\n%s选择:%s ' "$CYAN" "$RESET"
        read -r choice || return 0
        case "$choice" in
            1) fw_show_system_rules ;;
            2) fw_settings_menu ;;
            3) fw_clear_flow ;;
            0|"") return ;;
            *) printf '%s请输入 1-3 或 0。%s\n' "$RED" "$RESET"; pause_screen ;;
        esac
    done
}

show_firewall_menu() {
    local choice ip
    while true; do
        fw_load
        clear_screen
        draw_brand
        printf '\n%s[03] 防火墙规则%s\n' "$YELLOW" "$RESET"
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

        printf '\n%s1.%s 添加防火墙规则\n' "$GREEN" "$RESET"
        printf '%s2.%s 删除防火墙规则\n' "$GREEN" "$RESET"
        printf '%s3.%s 应用当前配置\n' "$GREEN" "$RESET"
        printf '%s4.%s 高级与排障\n' "$GREEN" "$RESET"
        printf '%s0.%s 返回主菜单\n' "$GREEN" "$RESET"
        printf '\n%s选择:%s ' "$CYAN" "$RESET"
        read -r choice || return 0

        case "$choice" in
            1) fw_add_menu ;;
            2) fw_delete_flow ;;
            3) fw_apply_from_menu ;;
            4) show_firewall_advanced_menu ;;
            0|"") return ;;
            *)
                printf '%s请输入 1-4 或 0。%s\n' "$RED" "$RESET"
                pause_screen
                ;;
        esac
    done
}

show_system_info() {
    clear_screen
    draw_brand
    printf '\n%s系统与维护 > 系统信息%s\n\n' "$YELLOW" "$RESET"
    printf '%s内核:%s %s\n' "$DIM" "$RESET" "$(uname -srmo 2>/dev/null || printf 'unknown')"
    printf '%s主机:%s %s\n' "$DIM" "$RESET" "$(hostname 2>/dev/null || printf 'unknown')"
    printf '%s时间:%s %s\n' "$DIM" "$RESET" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    printf '\n%s网卡状态%s\n' "$CYAN" "$RESET"
    ip -br addr show 2>/dev/null || true
    pause_screen
}

show_service_menu() {
    local choice active enabled
    while true; do
        clear_screen
        draw_brand
        printf '\n%s[04] 限速服务%s\n\n' "$YELLOW" "$RESET"
        if ! command -v systemctl >/dev/null 2>&1; then
            printf '%s当前系统没有 systemctl，无法管理限速服务。%s\n' "$YELLOW" "$RESET"
            pause_screen
            return
        fi
        active="$(systemctl is-active limit-ports.service 2>/dev/null)" || active="${active:-unknown}"
        enabled="$(systemctl is-enabled limit-ports.service 2>/dev/null)" || enabled="${enabled:-unknown}"
        printf '%s运行状态:%s %s    %s开机自启:%s %s\n\n' \
            "$DIM" "$RESET" "$active" "$DIM" "$RESET" "$enabled"
        printf '%s1.%s 启动限速服务\n' "$GREEN" "$RESET"
        printf '%s2.%s 重启限速服务\n' "$GREEN" "$RESET"
        printf '%s3.%s 停止限速服务\n' "$YELLOW" "$RESET"
        printf '%s4.%s 开启开机自启\n' "$GREEN" "$RESET"
        printf '%s5.%s 关闭开机自启\n' "$GREEN" "$RESET"
        printf '%s6.%s 查看详细状态\n' "$GREEN" "$RESET"
        printf '%s0.%s 返回主菜单\n' "$GREEN" "$RESET"
        printf '\n%s选择:%s ' "$CYAN" "$RESET"
        read -r choice || return 0
        case "$choice" in
            1) run_root systemctl start limit-ports.service || true ;;
            2) run_root systemctl restart limit-ports.service || true ;;
            3) run_root systemctl stop limit-ports.service || true ;;
            4) run_root systemctl enable limit-ports.service || true ;;
            5) run_root systemctl disable limit-ports.service || true ;;
            6) run_root systemctl --no-pager --full status limit-ports.service || true ;;
            0|b|B|"") return ;;
            *) printf '%s请输入 1-6 或 0。%s\n' "$RED" "$RESET" ;;
        esac
        pause_screen
    done
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
    printf '\n%s日志中心 > 实时跟踪%s\n\n' "$YELLOW" "$RESET"
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
    printf '\n%s日志中心 > 高级与清理 > 清理日志%s\n\n' "$YELLOW" "$RESET"

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

show_service_logs_menu() {
    local choice lines
    while true; do
        clear_screen
        draw_brand
        printf '\n%s日志中心 > 服务日志%s\n\n' "$YELLOW" "$RESET"
        printf '%s1.%s 限速服务日志\n' "$GREEN" "$RESET"
        printf '%s2.%s 防火墙服务日志\n' "$GREEN" "$RESET"
        printf '%s0.%s 返回日志中心\n' "$GREEN" "$RESET"
        printf '\n%s选择:%s ' "$CYAN" "$RESET"
        read -r choice || return 0
        case "$choice" in
            1|2)
                lines="$(log_prompt_lines)" || continue
                if [[ "$choice" == 1 ]]; then
                    log_emit "限速服务日志（limit-ports.service）" "$lines" 'limit-ports' -u limit-ports.service
                else
                    log_emit "防火墙服务日志（portctl-firewall.service）" "$lines" 'portctl-firewall' -u portctl-firewall.service
                fi
                ;;
            0|"") return ;;
            *) printf '%s请输入 1-2 或 0。%s\n' "$RED" "$RESET"; pause_screen ;;
        esac
    done
}

show_logs_advanced_menu() {
    local choice lines
    while true; do
        clear_screen
        draw_brand
        printf '\n%s日志中心 > 高级与清理%s\n\n' "$YELLOW" "$RESET"
        printf '%s1.%s 内核日志\n' "$GREEN" "$RESET"
        printf '%s2.%s 全部系统日志\n' "$GREEN" "$RESET"
        printf '%s3.%s 清理日志\n' "$RED" "$RESET"
        printf '%s0.%s 返回日志中心\n' "$GREEN" "$RESET"
        printf '\n%s选择:%s ' "$CYAN" "$RESET"
        read -r choice || return 0
        case "$choice" in
            1|2)
                lines="$(log_prompt_lines)" || continue
                if [[ "$choice" == 1 ]]; then
                    log_emit "内核日志" "$lines" 'kernel' -k
                else
                    log_emit "全部系统日志" "$lines" -
                fi
                ;;
            3) log_vacuum ;;
            0|"") return ;;
            *) printf '%s请输入 1-3 或 0。%s\n' "$RED" "$RESET"; pause_screen ;;
        esac
    done
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

        printf '\n%s1.%s 服务日志\n' "$GREEN" "$RESET"
        printf '%s2.%s 系统错误日志\n' "$GREEN" "$RESET"
        printf '%s3.%s 登录记录（成功 / 失败）\n' "$GREEN" "$RESET"
        printf '%s4.%s 实时跟踪\n' "$GREEN" "$RESET"
        printf '%s5.%s 导出诊断日志\n' "$GREEN" "$RESET"
        printf '%s6.%s 高级与清理\n' "$GREEN" "$RESET"
        printf '%s0.%s 返回主菜单\n' "$GREEN" "$RESET"
        printf '\n%s选择:%s ' "$CYAN" "$RESET"
        read -r choice || return 0

        case "$choice" in
            1) show_service_logs_menu ;;
            2)
                lines="$(log_prompt_lines)" || continue
                log_emit "系统错误日志" "$lines" 'error|fail|critical|panic|denied' -p err
                ;;
            3) log_view_login ;;
            4) log_follow ;;
            5) log_export_flow ;;
            6) show_logs_advanced_menu ;;
            0|"") return ;;
            *) printf '%s请输入 1-6 或 0。%s\n' "$RED" "$RESET"; pause_screen ;;
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
    printf '\n%s系统与维护 > 更新脚本%s\n\n' "$YELLOW" "$RESET"
    printf '%s正在从 GitHub 获取最新版本...%s\n' "$DIM" "$RESET"
    local tmp_dir installer
    tmp_dir="$(mktemp -d)" || return 1
    installer="$tmp_dir/install.sh"
    if download_file "$INSTALL_URL" "$installer"; then
        chmod 0755 "$installer"
        if run_root bash "$installer" --no-menu; then
            printf '\n%s更新完成，现有配置已保留。重新打开 zc 后使用新版本。%s\n' "$GREEN" "$RESET"
        else
            printf '%s安装失败，请检查上方错误信息。%s\n' "$RED" "$RESET"
        fi
    else
        printf '%s更新失败，请检查网络或稍后重试。%s\n' "$RED" "$RESET"
    fi
    rm -rf "$tmp_dir"
    pause_screen
}

uninstall_program() {
    local confirmation remove_config
    clear_screen
    draw_brand
    printf '\n%s系统与维护 > 卸载程序%s\n\n' "$YELLOW" "$RESET"
    printf '%s这将停止服务并删除 zc、portctl.sh 和 limit_ports.sh。%s\n' "$RED" "$RESET"
    printf '%s同时会移除 portctl-firewall.service 与流量统计定时器（不会主动撤销已下发的防火墙规则）。%s\n' "$DIM" "$RESET"
    printf '%s默认保留 /etc/default/limit-ports 配置与流量统计累积数据。%s\n\n' "$DIM" "$RESET"
    printf '确认卸载请输入 %sYES%s，其他输入取消: ' "$RED" "$RESET"
    read -r confirmation || return 0
    [[ "$confirmation" == "YES" ]] || {
        printf '%s已取消卸载。%s\n' "$DIM" "$RESET"
        pause_screen
        return
    }

    printf '\n是否同时删除配置 /etc/default/limit-ports？[y/N]: '
    read -r remove_config || return 0
    if command -v systemctl >/dev/null 2>&1; then
        run_root systemctl disable --now limit-ports.service 2>/dev/null || true
        run_root rm -f /etc/systemd/system/limit-ports.service
        run_root systemctl disable --now "$FW_UNIT_NAME" 2>/dev/null || true
        run_root rm -f "$FW_UNIT_FILE"
        run_root systemctl disable --now "$ACCT_TIMER_NAME" 2>/dev/null || true
        run_root rm -f "$ACCT_TIMER_FILE" "$ACCT_SERVICE_FILE"
        run_root systemctl daemon-reload 2>/dev/null || true
    fi
    # 统计表由本程序创建，卸载时一并撤掉；累计数据文件保留，除非用户选择删配置。
    if acct_available && acct_table_exists; then
        run_root nft delete table inet "$ACCT_TABLE" 2>/dev/null || true
    fi
    run_root rm -f /usr/local/bin/zc
    run_root rm -f /usr/local/sbin/portctl.sh
    run_root rm -f /usr/local/sbin/limit_ports.sh
    if [[ "${remove_config,,}" == "y" || "${remove_config,,}" == "yes" ]]; then
        run_root rm -f /etc/default/limit-ports
        run_root rm -f "$FW_CONF_FILE"
        run_root rm -f "$ACCT_FILE"
    fi
    printf '%s卸载完成。%s\n' "$GREEN" "$RESET"
    printf '%s当前菜单进程将在返回后退出。%s\n' "$DIM" "$RESET"
    pause_screen
    clear_screen
    exit 0
}

show_maintenance_menu() {
    local choice
    while true; do
        clear_screen
        draw_brand
        printf '\n%s[06] 系统与维护%s\n\n' "$YELLOW" "$RESET"
        printf '%s1.%s 系统信息\n' "$GREEN" "$RESET"
        printf '%s2.%s 从 GitHub 更新脚本\n' "$GREEN" "$RESET"
        printf '%s3.%s 卸载程序\n' "$RED" "$RESET"
        printf '%s0.%s 返回主菜单\n' "$GREEN" "$RESET"
        printf '\n%s选择:%s ' "$CYAN" "$RESET"
        read -r choice || return 0
        case "$choice" in
            1) show_system_info ;;
            2) update_script ;;
            3) uninstall_program ;;
            0|"") return ;;
            *) printf '%s请输入 1-3 或 0。%s\n' "$RED" "$RESET"; pause_screen ;;
        esac
    done
}

main_menu() {
    local choice
    while true; do
        clear_screen
        draw_brand
        draw_status
        draw_menu
        printf '\n%s请输入你的选择:%s ' "$GREEN" "$RESET"
        read -r choice || return 0
        case "$choice" in
            1|01) show_limit_menu ;;
            2|02) show_traffic_menu ;;
            3|03) show_firewall_menu ;;
            4|04) show_service_menu ;;
            5|05) show_logs_menu ;;
            6|06) show_maintenance_menu ;;
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
    traffic)
        load_rules || true
        printf '# proto\tport\tbytes\tconnections\n'
        conntrack_by_port
        ;;
    acct-setup)
        load_rules || true
        acct_setup
        ;;
    acct-sample)
        # 采样要用 RULE_* 判断"该有几个计数器"，缺了它完整性校验形同虚设。
        load_rules || true
        acct_sample
        ;;
    acct-show)
        if ! load_rules; then
            printf '[acct] 无法读取端口规则: %s\n' "$RULES_ERROR" >&2
            exit 1
        fi
        acct_rows_for_menu
        ;;
    acct-reset)
        acct_reset
        ;;
    acct-remove)
        acct_remove
        ;;
    --help|-h)
        printf '用法: %s [menu|firewall-apply|firewall-clear|firewall-status|logs-export <条数> <路径>|traffic|acct-setup|acct-sample|acct-show|acct-reset|acct-remove]\n' "$0"
        printf 'SSH 登录服务器后直接运行即可。默认进入交互式终端菜单。\n'
        ;;
    *)
        printf '未知参数: %s\n' "$1" >&2
        exit 2
        ;;
esac
