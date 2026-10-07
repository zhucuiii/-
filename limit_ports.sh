#!/usr/bin/env bash
#
# Per-port egress shaping with tc/HTB.
#
# Configuration is read from /etc/default/limit-ports or the environment.
# The script owns the root qdisc on NIC, so do not run it on an interface
# that is already managed by another tc service.
#
# Ports are described by PORT_SPEC. One rule looks like:
#
#     PORT[-END][=RATE][@per-port|@shared]
#
#     PORT          a single port, e.g. 8080
#     PORT-END      an inclusive range, e.g. 10001-10200
#     =RATE         per-rule rate, defaults to SPEED
#     @per-port     every port in the rule gets its own HTB class (default)
#     @shared       the whole rule shares a single HTB class
#
# Rules are separated by spaces, commas, semicolons or newlines.
# Rules must not overlap: every u32 filter lives in one priority chain and
# the classifier hashes on its selector, so overlapping rules would match
# unpredictably. Use @shared or a single rule instead.
#
# Examples:
#     PORT_SPEC="10001-10200=12mbit"
#     PORT_SPEC="10001-10200=12mbit 8080=20mbit"
#     PORT_SPEC="20000-20100=100mbit@shared 443"
#
#   ./limit_ports.sh apply
#   ./limit_ports.sh stop
#   ./limit_ports.sh status
#   ./limit_ports.sh rules
#   ./limit_ports.sh plan -v
#
set -Eeuo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/default/limit-ports}"
if [[ -r "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

NIC="${NIC:-eth0}"
SPEED="${SPEED:-12mbit}"
DEFAULT_RATE="${DEFAULT_RATE:-1000mbit}"
PORT_START="${PORT_START:-10001}"
PORT_END="${PORT_END:-10200}"
CLASS_START="${CLASS_START:-10}"
R2Q="${R2Q:-100}"
MAX_CLASSES="${MAX_CLASSES:-4096}"
MAX_RULES="${MAX_RULES:-512}"
FILTER_PRIO="${FILTER_PRIO:-10}"

ACTION="apply"
ACTION_SPEC=""
SPEC_STRING=""
SPEC_SOURCE="config"
START_PORT_GIVEN=0
END_PORT_GIVEN=0
VERBOSE=0

# Parsed PORT_SPEC rules, filled by parse_spec().
PARSE_START=()
PARSE_END=()
PARSE_RATE=()
PARSE_MODE=()

# Expanded HTB plan, filled by build_plan().
PLAN_ID=()
PLAN_RATE=()
PLAN_START=()
PLAN_END=()

log() {
    printf '[limit-ports] %s\n' "$*"
}

die() {
    printf '[limit-ports] 错误: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'USAGE'
用法:
  limit_ports.sh [apply|stop|status|rules|plan] [选项]

动作:
  apply        应用限速规则（默认动作）
  stop         删除 root qdisc，取消全部限速
  status       显示 tc qdisc/class 统计
  rules        打印解析后的限速规则（只读，不改动系统）
  plan         打印将要执行的 tc 命令（只读，加 -v 输出每一条）

选项:
  --nic IFACE              网卡，默认 eth0
  --spec SPEC              直接指定端口规则，覆盖配置文件
  --speed RATE             默认速率，例如 12mbit、20mbit
  --default-rate RATE      未匹配流量的速率
  --start-port PORT        起始端口（兼容旧配置）
  --end-port PORT          结束端口（兼容旧配置）
  --r2q NUMBER             HTB r2q 参数
  -v, --verbose            plan 时输出每一条 tc 命令
  -h, --help               显示帮助

端口规则语法:
  PORT[-END][=RATE][@per-port|@shared]

  8080                        单端口，默认速率，每端口独立队列
  8080=20mbit                 单端口，指定速率
  10001-10200=12mbit          端口区间，区间内每个端口各自限速
  20000-20100=100mbit@shared  端口区间共享一个 100mbit 队列
  443 8443                    多条规则用空格分隔

示例:
  limit_ports.sh apply --spec "10001-10200=12mbit 8080=20mbit"
  limit_ports.sh apply --speed 20mbit
  limit_ports.sh apply --start-port 10001 --end-port 10100 --speed 8mbit
  limit_ports.sh rules
  limit_ports.sh plan -v
USAGE
}

require_option_value() {
    [[ $# -ge 2 && -n "$2" ]] || die "选项 $1 缺少参数。"
}

parse_args() {
    while (($# > 0)); do
        case "$1" in
            apply|stop|status|rules|plan)
                ACTION="$1"
                shift
                ;;
            --nic)
                require_option_value "$@"
                NIC="$2"
                shift 2
                ;;
            --spec|--ports)
                require_option_value "$@"
                ACTION_SPEC="$2"
                shift 2
                ;;
            --speed)
                require_option_value "$@"
                SPEED="$2"
                shift 2
                ;;
            --default-rate)
                require_option_value "$@"
                DEFAULT_RATE="$2"
                shift 2
                ;;
            --start-port)
                require_option_value "$@"
                PORT_START="$2"
                START_PORT_GIVEN=1
                shift 2
                ;;
            --end-port)
                require_option_value "$@"
                PORT_END="$2"
                END_PORT_GIVEN=1
                shift 2
                ;;
            --r2q)
                require_option_value "$@"
                R2Q="$2"
                shift 2
                ;;
            -v|--verbose)
                VERBOSE=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "未知参数: $1。使用 --help 查看用法。"
                ;;
        esac
    done
}

on_error() {
    local code=$?
    printf '[limit-ports] 执行失败（退出码 %s）。可运行: tc -s qdisc show dev %s\n' \
        "$code" "$NIC" >&2
    exit "$code"
}
trap on_error ERR

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "必须以 root 运行。"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "找不到命令: $1（请安装 iproute2）。"
}

is_uint() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

is_rate() {
    [[ "$1" =~ ^[0-9]+([.][0-9]+)?(bit|kbit|mbit|gbit|tbit)$ ]]
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

# Decide which rule string to use. Precedence:
#   --spec  >  --start-port/--end-port  >  PORT_SPEC  >  PORT_START/PORT_END
resolve_spec() {
    if [[ -n "$ACTION_SPEC" ]]; then
        SPEC_STRING="$ACTION_SPEC"
        SPEC_SOURCE="命令行 --spec"
    elif (( START_PORT_GIVEN || END_PORT_GIVEN )); then
        SPEC_STRING="${PORT_START}-${PORT_END}=${SPEED}"
        SPEC_SOURCE="命令行 --start-port/--end-port"
    elif [[ -n "${PORT_SPEC+x}" ]]; then
        SPEC_STRING="$PORT_SPEC"
        SPEC_SOURCE="配置 PORT_SPEC"
    else
        SPEC_STRING="${PORT_START}-${PORT_END}=${SPEED}"
        SPEC_SOURCE="配置 PORT_START/PORT_END"
    fi
}

# Parse PORT_SPEC into the PARSE_* arrays.
parse_spec() {
    local raw="$1"
    local entry start end rate mode
    local -a entries=()
    PARSE_START=()
    PARSE_END=()
    PARSE_RATE=()
    PARSE_MODE=()

    raw="${raw//$'\n'/ }"
    raw="${raw//$'\r'/ }"
    raw="${raw//$'\t'/ }"
    raw="${raw//,/ }"
    raw="${raw//;/ }"

    read -r -a entries <<<"$raw"

    for entry in ${entries[@]+"${entries[@]}"}; do
        rate=""
        mode="per-port"

        if [[ "$entry" == *"@"* ]]; then
            mode="${entry##*@}"
            entry="${entry%@*}"
            case "${mode,,}" in
                shared) mode="shared" ;;
                per-port|perport) mode="per-port" ;;
                *) die "规则模式无效: @$mode（只支持 @shared 或 @per-port）。" ;;
            esac
        fi

        if [[ "$entry" == *"="* ]]; then
            rate="${entry#*=}"
            entry="${entry%%=*}"
        fi

        if [[ "$entry" == *-* ]]; then
            start="${entry%%-*}"
            end="${entry#*-}"
        else
            start="$entry"
            end="$entry"
        fi

        is_uint "$start" || die "端口格式无效: '$entry'（示例: 8080 或 10001-10200）。"
        is_uint "$end" || die "端口格式无效: '$entry'（示例: 8080 或 10001-10200）。"
        (( start >= 1 && start <= 65535 )) || die "端口超出范围: $start"
        (( end >= 1 && end <= 65535 )) || die "端口超出范围: $end"
        (( end >= start )) || die "端口区间无效: $start-$end"

        if [[ -n "$rate" ]]; then
            rate="${rate,,}"
            is_rate "$rate" ||
                die "速率格式无效: '$rate'（示例: 12mbit、1gbit、500kbit）。"
        else
            rate="${SPEED,,}"
            is_rate "$rate" || die "默认速率格式无效: '$SPEED'（示例: 12mbit）。"
        fi

        PARSE_START+=("$start")
        PARSE_END+=("$end")
        PARSE_RATE+=("$rate")
        PARSE_MODE+=("$mode")
    done

    ((${#PARSE_START[@]} > 0)) || return 0
    ((${#PARSE_START[@]} <= MAX_RULES)) ||
        die "规则数量超过 MAX_RULES=$MAX_RULES，请合并端口区间。"

    check_overlaps
}

check_overlaps() {
    local i j
    for ((i = 0; i < ${#PARSE_START[@]}; i++)); do
        for ((j = i + 1; j < ${#PARSE_START[@]}; j++)); do
            if (( PARSE_START[i] <= PARSE_END[j] && PARSE_START[j] <= PARSE_END[i] )); then
                die "端口规则冲突: 规则 $((i + 1)) ($(port_range_label "${PARSE_START[i]}" "${PARSE_END[i]}")) 与规则 $((j + 1)) ($(port_range_label "${PARSE_START[j]}" "${PARSE_END[j]}")) 重叠，请合并或删除其中一条。"
            fi
        done
    done
}

total_ports() {
    local i total=0
    for ((i = 0; i < ${#PARSE_START[@]}; i++)); do
        total=$((total + PARSE_END[i] - PARSE_START[i] + 1))
    done
    printf '%s' "$total"
}

rules_summary() {
    printf '%s 条规则 / %s 个端口' "${#PARSE_START[@]}" "$(total_ports)"
}

log_rule_list() {
    local i
    for ((i = 0; i < ${#PARSE_START[@]}; i++)); do
        log "  规则 $((i + 1)): 端口 $(port_range_label "${PARSE_START[i]}" "${PARSE_END[i]}")  速率 ${PARSE_RATE[i]}（约 $(rate_to_mbps "${PARSE_RATE[i]}") MB/s）  $(mode_label "${PARSE_MODE[i]}")"
    done
}

# Expand the rules into concrete HTB classes: one class per port for
# @per-port rules, one class for the whole span for @shared rules.
build_plan() {
    local i p id="$CLASS_START"
    PLAN_ID=()
    PLAN_RATE=()
    PLAN_START=()
    PLAN_END=()

    for ((i = 0; i < ${#PARSE_START[@]}; i++)); do
        if [[ "${PARSE_MODE[i]}" == "shared" ]]; then
            PLAN_ID+=("$id")
            PLAN_RATE+=("${PARSE_RATE[i]}")
            PLAN_START+=("${PARSE_START[i]}")
            PLAN_END+=("${PARSE_END[i]}")
            id=$((id + 1))
        else
            for ((p = PARSE_START[i]; p <= PARSE_END[i]; p++)); do
                PLAN_ID+=("$id")
                PLAN_RATE+=("${PARSE_RATE[i]}")
                PLAN_START+=("$p")
                PLAN_END+=("$p")
                id=$((id + 1))
            done
        fi
    done

    local classes=${#PLAN_ID[@]}
    if (( classes > 0 )); then
        (( id - 1 <= 65535 )) || die "class id 超出范围（最后一个是 $((id - 1))）。"
        (( classes <= MAX_CLASSES )) ||
            die "需要创建 $classes 个 HTB class，超过 MAX_CLASSES=$MAX_CLASSES。请改用区间共享限速（@shared）或缩小端口区间。"
    fi
}

filter_count() {
    local i total=0
    for ((i = 0; i < ${#PLAN_ID[@]}; i++)); do
        total=$((total + (PLAN_END[i] - PLAN_START[i] + 1) * 2))
    done
    printf '%s' "$total"
}

validate_config() {
    local check_nic="${1:-1}"

    [[ -n "$NIC" ]] || die "NIC 不能为空。"
    is_uint "$CLASS_START" || die "CLASS_START 必须是整数。"
    is_uint "$R2Q" || die "R2Q 必须是整数。"
    is_uint "$MAX_CLASSES" || die "MAX_CLASSES 必须是整数。"
    is_uint "$MAX_RULES" || die "MAX_RULES 必须是整数。"
    is_uint "$FILTER_PRIO" || die "FILTER_PRIO 必须是整数。"
    (( CLASS_START >= 1 && CLASS_START <= 65535 )) || die "CLASS_START 超出 class 范围。"
    (( R2Q >= 1 )) || die "R2Q 必须大于 0。"

    if [[ "$SPEC_SOURCE" == "配置 PORT_START/PORT_END" ]]; then
        is_uint "$PORT_START" || die "PORT_START 必须是整数。"
        is_uint "$PORT_END" || die "PORT_END 必须是整数。"
        (( PORT_START >= 1 && PORT_START <= 65535 )) || die "PORT_START 超出端口范围。"
        (( PORT_END >= PORT_START && PORT_END <= 65535 )) || die "PORT_END 超出端口范围。"
    fi

    if (( check_nic )); then
        ip link show dev "$NIC" >/dev/null 2>&1 || die "网卡不存在: $NIC"
    fi
}

delete_root_qdisc() {
    # This script intentionally manages the whole root qdisc. If another
    # service owns it, stop that service before running this script.
    tc qdisc del dev "$NIC" root 2>/dev/null || true
}

rate_to_mbps() {
    # Human-readable hint only; tc itself remains the source of truth.
    case "$1" in
        *mbit) awk "BEGIN { printf \"%.2f\", ${1%mbit}/8 }" ;;
        *gbit) awk "BEGIN { printf \"%.2f\", ${1%gbit}*1000/8 }" ;;
        *kbit) awk "BEGIN { printf \"%.4f\", ${1%kbit}/8000 }" ;;
        *) printf "按 tc 速率单位计算" ;;
    esac
}

apply_rules() {
    validate_config 1
    parse_spec "$SPEC_STRING"
    build_plan

    log "规则来源: $SPEC_SOURCE（$(rules_summary)）"
    log_rule_list

    if (( ${#PLAN_ID[@]} == 0 )); then
        log "警告: 没有配置任何限速端口，本次只创建默认队列，等于不做端口限速。"
    fi

    log "清理 $NIC 上已有的 root qdisc..."
    delete_root_qdisc

    log "创建 HTB 根队列（r2q=$R2Q，默认 class=1:1）..."
    tc qdisc add dev "$NIC" root handle 1: htb default 1 r2q "$R2Q"

    # Unmatched traffic remains usable instead of being sent to a nonexistent
    # default class. Set DEFAULT_RATE to the real link rate when needed.
    tc class add dev "$NIC" parent 1: classid 1:1 htb \
        rate "$DEFAULT_RATE" ceil "$DEFAULT_RATE"

    local i p
    for ((i = 0; i < ${#PLAN_ID[@]}; i++)); do
        tc class add dev "$NIC" parent 1: classid "1:${PLAN_ID[i]}" htb \
            rate "${PLAN_RATE[i]}" ceil "${PLAN_RATE[i]}"

        # Ranges are rejected when they overlap, so every filter can share one
        # priority chain: cls_u32 hashes on the selector and each source port
        # lands in its own bucket, which keeps the classification cheap.
        for ((p = PLAN_START[i]; p <= PLAN_END[i]; p++)); do
            # Egress packets sent by a listening TCP/UDP service have that
            # service port as their source port.
            tc filter add dev "$NIC" protocol ip parent 1: prio "$FILTER_PRIO" u32 \
                match ip protocol 6 0xff \
                match ip sport "$p" 0xffff \
                flowid "1:${PLAN_ID[i]}"
            tc filter add dev "$NIC" protocol ip parent 1: prio "$FILTER_PRIO" u32 \
                match ip protocol 17 0xff \
                match ip sport "$p" 0xffff \
                flowid "1:${PLAN_ID[i]}"
        done
    done

    log "完成：${#PLAN_ID[@]} 个 HTB class，$(filter_count) 条 filter。"
    log "查看统计：tc -s class show dev $NIC"
}

list_rules() {
    parse_spec "$SPEC_STRING"
    printf '# idx\tstart\tend\trate\tmode\tports\n'
    local i
    for ((i = 0; i < ${#PARSE_START[@]}; i++)); do
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$((i + 1))" \
            "${PARSE_START[i]}" \
            "${PARSE_END[i]}" \
            "${PARSE_RATE[i]}" \
            "${PARSE_MODE[i]}" \
            "$((PARSE_END[i] - PARSE_START[i] + 1))"
    done
}

print_plan_commands() {
    printf 'tc qdisc del dev %s root\n' "$NIC"
    printf 'tc qdisc add dev %s root handle 1: htb default 1 r2q %s\n' "$NIC" "$R2Q"
    printf 'tc class add dev %s parent 1: classid 1:1 htb rate %s ceil %s\n' \
        "$NIC" "$DEFAULT_RATE" "$DEFAULT_RATE"

    local i p
    for ((i = 0; i < ${#PLAN_ID[@]}; i++)); do
        printf 'tc class add dev %s parent 1: classid 1:%s htb rate %s ceil %s\n' \
            "$NIC" "${PLAN_ID[i]}" "${PLAN_RATE[i]}" "${PLAN_RATE[i]}"
        for ((p = PLAN_START[i]; p <= PLAN_END[i]; p++)); do
            printf 'tc filter add dev %s protocol ip parent 1: prio %s u32 match ip protocol 6 0xff match ip sport %s 0xffff flowid 1:%s\n' \
                "$NIC" "$FILTER_PRIO" "$p" "${PLAN_ID[i]}"
            printf 'tc filter add dev %s protocol ip parent 1: prio %s u32 match ip protocol 17 0xff match ip sport %s 0xffff flowid 1:%s\n' \
                "$NIC" "$FILTER_PRIO" "$p" "${PLAN_ID[i]}"
        done
    done
}

plan_rules() {
    validate_config 0
    parse_spec "$SPEC_STRING"
    build_plan

    log "网卡: $NIC   默认速率: $SPEED   默认 class 速率: $DEFAULT_RATE"
    log "规则来源: $SPEC_SOURCE（$(rules_summary)）"

    if (( ${#PLAN_ID[@]} == 0 )); then
        log "当前没有任何限速端口规则。"
    else
        log_rule_list
        printf '\n# idx  start      end        rate        mode      ports\n'
        local i
        for ((i = 0; i < ${#PARSE_START[@]}; i++)); do
            printf '  %-4s %-10s %-10s %-11s %-9s %s\n' \
                "$((i + 1))" \
                "${PARSE_START[i]}" \
                "${PARSE_END[i]}" \
                "${PARSE_RATE[i]}" \
                "${PARSE_MODE[i]}" \
                "$((PARSE_END[i] - PARSE_START[i] + 1))"
        done
    fi

    log "将创建 ${#PLAN_ID[@]} 个 HTB class，$(filter_count) 条 filter。"

    if (( VERBOSE )); then
        printf '\n'
        print_plan_commands
    else
        log "加 -v/--verbose 可输出每一条 tc 命令。"
    fi
}

stop_rules() {
    require_root
    require_command tc
    require_command ip
    ip link show dev "$NIC" >/dev/null 2>&1 || die "网卡不存在: $NIC"
    log "删除 $NIC 的 root qdisc..."
    delete_root_qdisc
    log "已停止。"
}

status_rules() {
    require_root
    require_command tc
    require_command ip
    ip link show dev "$NIC" >/dev/null 2>&1 || die "网卡不存在: $NIC"
    tc -s qdisc show dev "$NIC"
    tc -s class show dev "$NIC"
}

main() {
    parse_args "$@"

    case "$ACTION" in
        apply)
            require_root
            require_command tc
            require_command ip
            resolve_spec
            apply_rules
            ;;
        stop)
            require_root
            require_command tc
            require_command ip
            resolve_spec
            stop_rules
            ;;
        status)
            require_root
            require_command tc
            require_command ip
            resolve_spec
            status_rules
            ;;
        rules)
            resolve_spec
            list_rules
            ;;
        plan)
            resolve_spec
            plan_rules
            ;;
        *)
            die "用法: $0 {apply|stop|status|rules|plan}"
            ;;
    esac
}

main "$@"
