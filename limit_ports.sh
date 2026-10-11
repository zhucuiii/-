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
# Design notes:
#   * The default class (1:1, unmatched traffic) gets a SMALL guaranteed
#     rate (DEFAULT_GUARANTEE) and a LARGE ceiling (DEFAULT_RATE). HTB's
#     "rate" is a guarantee, so giving the default class the full link rate
#     would let it starve every limited port whenever unrelated traffic is
#     pumping.
#   * Filters use the flower classifier when available: one filter covers a
#     whole port range and both IPv4 and IPv6 are shaped. The u32 fallback
#     only covers IPv4 and needs one filter per port.
#   * Every shaped class gets an fq_codel child qdisc; otherwise the leaf
#     queue is a plain FIFO and latency collapses under load.
#   * Commands are applied through a single `tc -batch` call. On failure the
#     root qdisc is removed again: fail open, never half-configured.
#
# Rules are separated by spaces, commas, semicolons or newlines, and must
# not overlap.
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

LIMIT_PORTS_VERSION="0.7.0"

CONFIG_FILE="${CONFIG_FILE:-/etc/default/limit-ports}"
config_version() {
    if [[ -f "$CONFIG_FILE" ]]; then cksum <"$CONFIG_FILE"; else printf 'missing\n'; fi
}
LOADED_CONFIG_VERSION="$(config_version)"
if [[ -r "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi
[[ "$(config_version)" == "$LOADED_CONFIG_VERSION" ]] || {
    printf '[limit-ports] 配置读取期间发生变化，请重试。\n' >&2
    exit 1
}
LIMIT_SELF="$(readlink -f -- "${BASH_SOURCE[0]}")"
LIMIT_STATE_DIR="${LIMIT_STATE_DIR:-/var/lib/portctl/limits}"

NIC="${NIC:-eth0}"
SPEED="${SPEED:-12mbit}"
# Link capacity. Used as the ceiling of the default class.
DEFAULT_RATE="${DEFAULT_RATE:-1000mbit}"
# HTB "rate" is a guarantee, so unmatched traffic only guarantees this much
# and still bursts up to DEFAULT_RATE when the link is otherwise idle.
DEFAULT_GUARANTEE="${DEFAULT_GUARANTEE:-1mbit}"
PORT_START="${PORT_START:-10001}"
PORT_END="${PORT_END:-10200}"
CLASS_START="${CLASS_START:-10}"
R2Q="${R2Q:-100}"
MAX_CLASSES="${MAX_CLASSES:-4096}"
MAX_RULES="${MAX_RULES:-512}"
FILTER_PRIO="${FILTER_PRIO:-10}"
# IPv4 and IPv6 filters cannot share one prio on the same parent: the kernel
# answers "Filter with specified priority/protocol not found" (ENOENT).
FILTER_PRIO6="${FILTER_PRIO6:-$((FILTER_PRIO + 1))}"
# auto | yes | no  (try the whole batch on a throwaway dummy device first)
PRECHECK="${PRECHECK:-auto}"
# auto | flower | u32
FILTER_KIND="${FILTER_KIND:-auto}"
# auto | yes | no   (auto = shape IPv6 when the NIC has a global address)
IPV6_MODE="${IPV6_MODE:-auto}"
FQ_CODEL="${FQ_CODEL:-yes}"
FQ_CODEL_OPTS="${FQ_CODEL_OPTS:- flows 256 limit 1024}"
# empty = derive from the class rate
BURST="${BURST:-}"
CBURST="${CBURST:-}"

ACTION="apply"
ACTION_SPEC=""
RATE_FILE=""
CONFIG_SOURCE=""
EXPECTED_VERSION=""
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
PLAN_RULE=()
declare -A RATE_BPS=() RATE_BURST=() RATE_CBURST=()

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
  limit_ports.sh [apply|stop|status|rules|stats|plan|rate-set|config-state|effective-rates|capacity|check] [选项]

动作:
  apply        应用限速规则（默认动作）
  stop         删除 root qdisc，取消全部限速
  status       显示 tc qdisc/class 统计
  rules        打印解析后的限速规则（只读，不改动系统）
  stats        打印每个限速端口的字节/包计数（只读，供流量统计用）
  plan         打印将要执行的 tc 命令（只读，加 -v 输出完整 batch）
  config-state 显示当前配置是否已应用（只读）
  effective-rates 读取实际生效的队列速率（只读）
  capacity     显示端口数量、队列数量和统计容量（只读）
  check        校验配置与容量（只读）
  rate-set     更新已应用配置对应的队列速率

选项:
  --nic IFACE              网卡，默认 eth0
  --spec SPEC              直接指定端口规则，覆盖配置文件
  --speed RATE             默认速率，例如 12mbit、20mbit
  --default-rate RATE      链路容量，同时是默认 class 的上限
  --start-port PORT        起始端口（兼容旧配置）
  --end-port PORT          结束端口（兼容旧配置）
  --r2q NUMBER             HTB r2q 参数
  --rate-file FILE         速率覆盖 TSV
  --expected-version TEXT  拒绝与指定配置版本不一致的更新
  -v, --verbose            plan 时输出完整命令
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
  limit_ports.sh rate-set --rate-file /path/to/rates.tsv
  limit_ports.sh plan -v
USAGE
}

require_option_value() {
    [[ $# -ge 2 && -n "$2" ]] || die "选项 $1 缺少参数。"
}

parse_args() {
    while (($# > 0)); do
        case "$1" in
            apply|stop|status|rules|stats|plan|rate-set|config-save|config-state|check|effective-rates|capacity)
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
            --rate-file)
                require_option_value "$@"
                RATE_FILE="$2"
                shift 2
                ;;
            --config-source)
                require_option_value "$@"; CONFIG_SOURCE="$2"; shift 2 ;;
            --expected-version)
                require_option_value "$@"; EXPECTED_VERSION="$2"; shift 2 ;;
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

rate_to_bps() {
    local rate="${1,,}"
    if [[ -n "${RATE_BPS[$rate]:-}" ]]; then printf '%s' "${RATE_BPS[$rate]}"; return; fi
    case "$rate" in
        *tbit) awk "BEGIN { printf \"%.0f\", ${rate%tbit} * 1000000000000 }" ;;
        *gbit) awk "BEGIN { printf \"%.0f\", ${rate%gbit} * 1000000000 }" ;;
        *mbit) awk "BEGIN { printf \"%.0f\", ${rate%mbit} * 1000000 }" ;;
        *kbit) awk "BEGIN { printf \"%.0f\", ${rate%kbit} * 1000 }" ;;
        *bit) awk "BEGIN { printf \"%.0f\", ${rate%bit} }" ;;
        *) return 1 ;;
    esac
}

cache_rates() {
    local rate out bps burst cburst
    local -a missing=()
    for rate in "$@"; do
        rate="${rate,,}"
        [[ -n "${RATE_BPS[$rate]:-}" ]] || missing+=("$rate")
    done
    (( ${#missing[@]} )) || return 0
    out="$(printf '%s\n' "${missing[@]}" | LC_ALL=C awk '
        function bps(r, n,u) {
            n=r+0; u=r; sub(/^[0-9]+([.][0-9]+)?/,"",u)
            return n * (u=="tbit"?1e12:u=="gbit"?1e9:u=="mbit"?1e6:u=="kbit"?1e3:1)
        }
        !seen[$0]++ {
            n=bps($0); b=n/400; c=n/800
            printf "%s\t%.0f\t%.0f\t%.0f\n",$0,n,b<3000?3000:b,c<1500?1500:c
        }
    ')" || return 1
    while IFS=$'\t' read -r rate bps burst cburst; do
        RATE_BPS["$rate"]="$bps" RATE_BURST["$rate"]="$burst" RATE_CBURST["$rate"]="$cburst"
    done <<<"$out"
}

# HTB needs a burst large enough to cover one scheduling tick, otherwise the
# configured rate cannot actually be reached (see tc-htb(8) NOTES).
compute_burst() {
    if [[ -n "$BURST" ]]; then
        printf '%s' "$BURST"
        return 0
    fi
    if [[ -n "${RATE_BURST[$1]:-}" ]]; then printf '%s' "${RATE_BURST[$1]}"; return; fi
    local bps
    bps="$(rate_to_bps "$1")" || {
        printf '15000'
        return 0
    }
    awk -v bps="$bps" 'BEGIN {
        tick = bps / 8 / 100;
        b = tick * 2;
        if (b < 3000) b = 3000;
        printf "%.0f", b
    }'
}

compute_cburst() {
    if [[ -n "$CBURST" ]]; then
        printf '%s' "$CBURST"
        return 0
    fi
    if [[ -n "${RATE_CBURST[$1]:-}" ]]; then printf '%s' "${RATE_CBURST[$1]}"; return; fi
    local bps
    bps="$(rate_to_bps "$1")" || {
        printf '3000'
        return 0
    }
    awk -v bps="$bps" 'BEGIN {
        c = bps / 8 / 100;
        if (c < 1500) c = 1500;
        printf "%.0f", c
    }'
}

flower_ok() {
    case "$FILTER_KIND" in
        u32) return 1 ;;
        flower) return 0 ;;
    esac
    grep -qw cls_flower /proc/modules 2>/dev/null && return 0
    modinfo -F filename cls_flower >/dev/null 2>&1 && return 0
    return 1
}

filter_kind_label() {
    if flower_ok; then
        printf 'flower（支持端口区间与 IPv6）'
    else
        printf 'u32（仅 IPv4，逐端口）'
    fi
}

nic_has_ipv6() {
    ip -6 addr show dev "$NIC" scope global 2>/dev/null | grep -q 'inet6'
}

ipv6_enabled() {
    case "$IPV6_MODE" in
        yes) return 0 ;;
        no) return 1 ;;
    esac
    nic_has_ipv6
}

ipv6_label() {
    if ipv6_enabled; then
        printf '已启用'
    elif [[ "$IPV6_MODE" == "no" ]]; then
        printf '已关闭（IPV6_MODE=no）'
    else
        printf '未启用（网卡没有全局 IPv6 地址）'
    fi
}

fq_codel_enabled() {
    [[ "$FQ_CODEL" == "yes" ]]
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
    PLAN_RULE=()

    for ((i = 0; i < ${#PARSE_START[@]}; i++)); do
        if [[ "${PARSE_MODE[i]}" == "shared" ]]; then
            PLAN_ID+=("$id")
            PLAN_RATE+=("${PARSE_RATE[i]}")
            PLAN_START+=("${PARSE_START[i]}")
            PLAN_END+=("${PARSE_END[i]}")
            PLAN_RULE+=("$i")
            id=$((id + 1))
        else
            for ((p = PARSE_START[i]; p <= PARSE_END[i]; p++)); do
                PLAN_ID+=("$id")
                PLAN_RATE+=("${PARSE_RATE[i]}")
                PLAN_START+=("$p")
                PLAN_END+=("$p")
                PLAN_RULE+=("$i")
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
    cache_rates "$DEFAULT_RATE" "$DEFAULT_GUARANTEE" "${PARSE_RATE[@]}"
}

base_signature() {
    {
        printf '%s\n' "$NIC" "$CLASS_START" "$R2Q" "$DEFAULT_RATE" "$DEFAULT_GUARANTEE" \
            "$FILTER_KIND" "$IPV6_MODE" "$FILTER_PRIO" "$FILTER_PRIO6" "$FQ_CODEL" "$FQ_CODEL_OPTS" "$BURST" "$CBURST"
        cat /proc/sys/kernel/random/boot_id 2>/dev/null || printf 'unknown\n'
        local i
        for ((i=0;i<${#PARSE_START[@]};i++)); do
            printf '%s\t%s\t%s\t%s\n' "${PARSE_START[i]}" "${PARSE_END[i]}" "${PARSE_RATE[i]}" "${PARSE_MODE[i]}"
        done
    } | cksum
}

applied_state_file() { printf '%s/%s.applied' "$LIMIT_STATE_DIR" "${NIC//\//_}"; }

config_state() {
    local signature saved file
    signature="$(base_signature)" || return 1
    file="$(applied_state_file)"
    if [[ ! -r "$file" ]]; then printf 'unknown\n'; return; fi
    saved="$(cat "$file")" || return 1
    if [[ "$saved" == "$signature" ]]; then printf 'applied\n'; else printf 'pending\n'; fi
}

require_applied_config() {
    [[ "$(config_state)" == applied ]] ||
        die "配置尚未应用或生效版本无法确认，请先应用基础规则。"
}

class_rates() {
    local current
    current="$(LC_ALL=C tc class show dev "$NIC")" || return 1
    printf '%s\n' "$current" | LC_ALL=C awk '
        function bps(r,n,u) {
            r=tolower(r); n=r+0; u=r; sub(/^[0-9]+([.][0-9]+)?/,"",u)
            if(u!="bit" && u!="kbit" && u!="mbit" && u!="gbit" && u!="tbit") return -1
            return n * (u=="tbit"?1e12:u=="gbit"?1e9:u=="mbit"?1e6:u=="kbit"?1e3:1)
        }
        $1=="class" && $2=="htb" {
            r=""; c=""
            for(i=4;i<NF;i++) {if($i=="rate") r=$(i+1); if($i=="ceil") c=$(i+1)}
            if(r!="" && c!="") printf "%s\t%.0f\t%.0f\t%s\n",$3,bps(r),bps(c),tolower(c)
        }
    '
}

effective_rates() {
    local rows id rate ceil display i key
    require_command tc
    require_applied_config
    rows="$(class_rates)" || die "无法读取当前队列。"
    local -A actual=() value=()
    while IFS=$'\t' read -r id rate ceil display; do
        [[ -n "$id" ]] || continue
        actual["$id"]="$display" value["$id"]="$ceil"
    done <<<"$rows"
    local -A result=() numeric=()
    for ((i=0;i<${#PLAN_ID[@]};i++)); do
        key="${PLAN_RULE[i]}" id="1:${PLAN_ID[i]}"
        if [[ -z "${actual[$id]:-}" || "${value[$id]:--1}" == -1 ]]; then
            result["$key"]=missing; continue
        fi
        [[ "${result[$key]:-}" != missing ]] || continue
        if [[ -n "${numeric[$key]:-}" && "${numeric[$key]}" != "${value[$id]}" ]]; then
            result["$key"]=mixed
        elif [[ "${result[$key]:-}" != missing && "${result[$key]:-}" != mixed ]]; then
            result["$key"]="${actual[$id]}"
        fi
        numeric["$key"]="${value[$id]}"
    done
    for ((i=0;i<${#PARSE_START[@]};i++)); do
        printf '%s\t%s\t%s\n' "${PARSE_START[i]}" "${PARSE_END[i]}" "${result[$i]:-missing}"
    done
}

capacity_report() {
    printf 'ports\t%s\nclasses\t%s\nclass_limit\t%s\naccounting_limit\t%s\n' \
        "$(total_ports)" "${#PLAN_ID[@]}" "$MAX_CLASSES" "${ACCT_MAX_PORTS:-512}"
}

filter_count() {
    local i protos=2 families=1 per total=0
    if ipv6_enabled; then
        families=2
    fi
    if flower_ok; then
        printf '%s' "$(( ${#PLAN_ID[@]} * protos * families ))"
        return 0
    fi
    for ((i = 0; i < ${#PLAN_ID[@]}; i++)); do
        per=$((PLAN_END[i] - PLAN_START[i] + 1))
        total=$((total + per * protos))
    done
    printf '%s' "$total"
}

validate_config() {
    local check_nic="${1:-1}"

    [[ -n "$NIC" ]] || die "NIC 不能为空。"
    [[ "${ACCT_MAX_PORTS:-512}" =~ ^[1-9][0-9]{0,4}$ ]] &&
        (( ${ACCT_MAX_PORTS:-512} <= 65535 )) || die "ACCT_MAX_PORTS 必须是 1-65535。"
    is_uint "$CLASS_START" || die "CLASS_START 必须是整数。"
    is_uint "$R2Q" || die "R2Q 必须是整数。"
    is_uint "$MAX_CLASSES" || die "MAX_CLASSES 必须是整数。"
    is_uint "$MAX_RULES" || die "MAX_RULES 必须是整数。"
    is_uint "$FILTER_PRIO" || die "FILTER_PRIO 必须是整数。"
    is_uint "$FILTER_PRIO6" || die "FILTER_PRIO6 必须是整数。"
    (( FILTER_PRIO >= 1 && FILTER_PRIO6 >= 1 )) || die "FILTER_PRIO/FILTER_PRIO6 必须大于 0。"
    (( FILTER_PRIO != FILTER_PRIO6 )) ||
        die "FILTER_PRIO 与 FILTER_PRIO6 不能相同：同一个 parent 下 IPv4/IPv6 必须用不同 prio。"
    case "$PRECHECK" in
        auto|yes|no) ;;
        *) die "PRECHECK 只能是 auto / yes / no。" ;;
    esac
    (( CLASS_START >= 1 && CLASS_START <= 65535 )) || die "CLASS_START 超出 class 范围。"
    (( R2Q >= 1 )) || die "R2Q 必须大于 0。"
    is_rate "${DEFAULT_RATE,,}" || die "DEFAULT_RATE 速率格式无效: $DEFAULT_RATE"
    is_rate "${DEFAULT_GUARANTEE,,}" || die "DEFAULT_GUARANTEE 速率格式无效: $DEFAULT_GUARANTEE"
    case "$FILTER_KIND" in
        auto|flower|u32) ;;
        *) die "FILTER_KIND 只能是 auto / flower / u32。" ;;
    esac
    case "$IPV6_MODE" in
        auto|yes|no) ;;
        *) die "IPV6_MODE 只能是 auto / yes / no。" ;;
    esac

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

# The kernel picks ephemeral source ports for the server's OWN outbound
# connections. When that range overlaps the shaped ports, unrelated outbound
# traffic is throttled together with the service.
warn_local_port_conflict() {
    local lo hi i hits=""
    [[ -r /proc/sys/net/ipv4/ip_local_port_range ]] || return 0
    read -r lo hi </proc/sys/net/ipv4/ip_local_port_range
    is_uint "$lo" || return 0
    is_uint "$hi" || return 0

    for ((i = 0; i < ${#PARSE_START[@]}; i++)); do
        if (( PARSE_START[i] <= hi && lo <= PARSE_END[i] )); then
            hits="$hits $(port_range_label "${PARSE_START[i]}" "${PARSE_END[i]}")"
        fi
    done

    if [[ -n "$hits" ]]; then
        log "注意: 限速端口$hits 与内核临时端口范围 $lo-$hi 重叠。"
        log "      服务器自己的出站连接可能被误限速，建议改窄:"
        log "      sysctl -w net.ipv4.ip_local_port_range=\"32768 60999\""
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

port_match_range() {
    if [[ "$1" == "$2" ]]; then
        printf '%s' "$1"
    else
        printf '%s-%s' "$1" "$2"
    fi
}

proto_number() {
    if [[ "$1" == "tcp" ]]; then
        printf '6'
    else
        printf '17'
    fi
}

emit_filter_cmds() {
    local out="$1" id="$2" start="$3" end="$4"
    local proto family port prio
    local -a families=(ip)
    if ipv6_enabled; then
        families+=(ipv6)
    fi

    for proto in tcp udp; do
        for family in "${families[@]}"; do
            if flower_ok; then
                if [[ "$family" == "ipv6" ]]; then
                    prio="$FILTER_PRIO6"
                else
                    prio="$FILTER_PRIO"
                fi
                # flower matches a whole port range in a single filter and
                # works for both address families.
                printf 'filter add dev %s protocol %s parent 1: prio %s flower ip_proto %s src_port %s flowid 1:%s\n' \
                    "$NIC" "$family" "$prio" "$proto" \
                    "$(port_match_range "$start" "$end")" "$id" >>"$out"
            else
                # u32 cannot match IPv6 source ports and has no port ranges.
                [[ "$family" == "ipv6" ]] && continue
                for ((port = start; port <= end; port++)); do
                    printf 'filter add dev %s protocol ip parent 1: prio %s u32 match ip protocol %s 0xff match ip sport %s 0xffff flowid 1:%s\n' \
                        "$NIC" "$FILTER_PRIO" "$(proto_number "$proto")" "$port" "$id" >>"$out"
                done
            fi
        done
    done
}

build_batch() {
    local out="$1" i
    : >"$out"

    printf 'qdisc add dev %s root handle 1: htb default 1 r2q %s\n' \
        "$NIC" "$R2Q" >>"$out"

    # Guarantee only a little to unmatched traffic, but let it use the whole
    # link when nothing else needs bandwidth.
    printf 'class add dev %s parent 1: classid 1:1 htb rate %s ceil %s burst %s cburst %s\n' \
        "$NIC" "$DEFAULT_GUARANTEE" "$DEFAULT_RATE" \
        "$(compute_burst "$DEFAULT_RATE")" "$(compute_cburst "$DEFAULT_RATE")" >>"$out"

    for ((i = 0; i < ${#PLAN_ID[@]}; i++)); do
        printf 'class add dev %s parent 1: classid 1:%s htb rate %s ceil %s burst %s cburst %s\n' \
            "$NIC" "${PLAN_ID[i]}" "${PLAN_RATE[i]}" "${PLAN_RATE[i]}" \
            "$(compute_burst "${PLAN_RATE[i]}")" "$(compute_cburst "${PLAN_RATE[i]}")" >>"$out"

        if fq_codel_enabled; then
            printf 'qdisc add dev %s parent 1:%s handle %s: fq_codel%s\n' \
                "$NIC" "${PLAN_ID[i]}" "${PLAN_ID[i]}" "$FQ_CODEL_OPTS" >>"$out"
        fi

        emit_filter_cmds "$out" "${PLAN_ID[i]}" "${PLAN_START[i]}" "${PLAN_END[i]}"
    done
}

# Every generated command targets $NIC. Run the exact same batch against a
# throwaway dummy device first, so a syntax error (for example the kernel
# refusing two protocols on one filter prio) cannot take the live qdisc down.
precheck_enabled() {
    case "$PRECHECK" in
        no) return 1 ;;
        yes) return 0 ;;
    esac
    command -v ip >/dev/null 2>&1 || return 1
    modinfo -F filename dummy >/dev/null 2>&1
}

# 0 = ok, 1 = failed, 99 = cannot precheck
run_precheck() {
    local batch="$1" dev="lp${BASHPID}" testbatch rc=0
    if ip link show dev "$dev" >/dev/null 2>&1; then
        return 99
    fi
    if ! ip link add "$dev" type dummy 2>/dev/null; then
        return 99
    fi
    ip link set dev "$dev" up 2>/dev/null || true

    testbatch="$(mktemp "${TMPDIR:-/tmp}/limit-ports-pre.XXXXXX")" || {
        ip link del "$dev" 2>/dev/null || true
        return 99
    }
    sed "s/ dev $NIC / dev $dev /g" "$batch" >"$testbatch"

    if ! tc -batch "$testbatch"; then
        rc=1
    fi

    rm -f "$testbatch"
    tc qdisc del dev "$dev" root 2>/dev/null || true
    ip link del "$dev" 2>/dev/null || true
    return "$rc"
}

apply_rules() {
    validate_config 1
    parse_spec "$SPEC_STRING"
    build_plan

    log "规则来源: $SPEC_SOURCE（$(rules_summary)）"
    log_rule_list
    log "分类器: $(filter_kind_label)   IPv6: $(ipv6_label)   fq_codel: $FQ_CODEL"
    warn_local_port_conflict

    if (( ${#PLAN_ID[@]} == 0 )); then
        log "警告: 没有配置任何限速端口，本次只创建默认队列，等于不做端口限速。"
    fi

    local batch
    batch="$(mktemp "${TMPDIR:-/tmp}/limit-ports.XXXXXX")" ||
        die "无法创建临时文件。"
    build_batch "$batch"

    log "生成 $(wc -l <"$batch") 条 tc 命令，使用 tc -batch 一次性下发。"

    if precheck_enabled; then
        log "预检: 先在临时 dummy 网卡上试跑同一批命令（$NIC 完全不会被改动）..."
        local prc=0
        run_precheck "$batch" || prc=$?
        if (( prc == 1 )); then
            rm -f "$batch"
            die "预检未通过，已放弃下发，$NIC 保持原样。请根据上面的报错修正规则。"
        elif (( prc == 99 )); then
            log "预检跳过（无法创建 dummy 网卡）。"
        else
            log "预检通过。"
        fi
    fi

    local state pending
    state="$(applied_state_file)"
    install -d -m 0755 "$LIMIT_STATE_DIR" || die "无法创建生效状态目录。"
    pending="$(mktemp "$LIMIT_STATE_DIR/.applied.XXXXXX")" || die "无法创建生效状态文件。"
    base_signature >"$pending" || die "无法记录配置版本。"
    chmod 0644 "$pending"
    rm -f "$state"
    log "清理 $NIC 上已有的 root qdisc..."
    delete_root_qdisc

    if ! tc -batch "$batch"; then
        rm -f "$batch"
        rm -f "$pending"
        log "下发失败，回滚: 删除 root qdisc，回到不限速状态，避免留下半套规则..."
        delete_root_qdisc
        die "tc -batch 执行失败，已回滚。"
    fi
    rm -f "$batch"
    mv -f "$pending" "$state" || die "队列已应用，但生效状态保存失败，请重试。"

    log "完成：${#PLAN_ID[@]} 个 HTB class，$(filter_count) 条 filter。"
    log "查看统计：tc -s class show dev $NIC"
}

rate_set() {
    require_root
    require_command tc
    [[ -z "$EXPECTED_VERSION" || "$LOADED_CONFIG_VERSION" == "$EXPECTED_VERSION" ]] ||
        die "配置已被其他会话修改，未更新策略速率，请刷新后重试。"
    [[ -r "$RATE_FILE" ]] || die "找不到速率覆盖文件: $RATE_FILE"
    validate_config 1
    parse_spec "$SPEC_STRING"
    build_plan
    require_applied_config

    local -A override=() current_rate=() current_ceil=() desired_bps=()
    local start end rate key i batch extra rule matched current id ceil commands=0
    while IFS=$'\t' read -r start end rate extra; do
        [[ -n "$start" && "$start" != '#'* ]] || continue
        [[ -z "${extra:-}" ]] || die "速率覆盖文件格式无效。"
        is_uint "$start" && is_uint "$end" && (( start >= 1 && end <= 65535 && end >= start )) ||
            die "速率覆盖端口无效: $start-$end"
        rate="${rate,,}"
        is_rate "$rate" || die "速率覆盖格式无效: $rate"
        key="$start-$end"
        [[ -z "${override[$key]:-}" ]] || die "速率覆盖重复: $key"
        matched=0
        for ((i = 0; i < ${#PARSE_START[@]}; i++)); do
            if [[ "$start" == "${PARSE_START[i]}" && "$end" == "${PARSE_END[i]}" ]]; then
                matched=1
                break
            fi
        done
        (( matched )) || die "速率覆盖未匹配基础规则: $key"
        override["$key"]="$rate"
    done <"$RATE_FILE"
    cache_rates "${override[@]}"
    for key in "${!override[@]}"; do desired_bps["$key"]="${RATE_BPS[${override[$key]}]}"; done

    (( ${#override[@]} )) || die "速率覆盖文件没有匹配当前基础规则。"
    current="$(class_rates)" || die "无法读取当前限速队列。"
    local display
    while IFS=$'\t' read -r id rate ceil display; do
        [[ -n "$id" ]] || continue
        current_rate["$id"]="$rate" current_ceil["$id"]="$ceil"
    done <<<"$current"
    batch="$(mktemp "${TMPDIR:-/tmp}/limit-ports-rate.XXXXXX")" || die "无法创建临时文件。"
    : >"$batch"
    for ((i = 0; i < ${#PLAN_ID[@]}; i++)); do
        rule="${PLAN_RULE[i]}"
        key="${PARSE_START[rule]}-${PARSE_END[rule]}"
        if [[ -n "${override[$key]:-}" ]]; then
            rate="${override[$key]}"
            id="1:${PLAN_ID[i]}"
            if [[ -z "${current_rate[$id]:-}" ]]; then
                rm -f "$batch"
                die "缺少限速队列 $id，请先应用基础规则。"
            fi
            if [[ "${current_rate[$id]}" == "${desired_bps[$key]}" &&
                  "${current_ceil[$id]}" == "${desired_bps[$key]}" ]]; then
                continue
            fi
            printf 'class change dev %s parent 1: classid 1:%s htb rate %s ceil %s burst %s cburst %s\n' \
                "$NIC" "${PLAN_ID[i]}" "$rate" "$rate" \
                "$(compute_burst "$rate")" "$(compute_cburst "$rate")" >>"$batch"
            commands=$((commands + 1))
        fi
    done
    if [[ ! -s "$batch" ]]; then
        rm -f "$batch"
        log "策略速率未变化，无需更新队列。"
        return 0
    fi
    tc -batch "$batch" || {
        rm -f "$batch"
        die "速率覆盖应用失败，部分队列可能已更新；请重试或重新应用基础规则。"
    }
    rm -f "$batch"
    log "已更新 $commands 个队列（${#override[@]} 条策略速率覆盖）。"
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

# Machine-readable per-class counters, joined with the port each class serves.
# One port is normally one user, so this is effectively per-user accounting.
collect_stats() {
    local i
    local -A port_of=() rate_of=()

    for ((i = 0; i < ${#PLAN_ID[@]}; i++)); do
        port_of["${PLAN_ID[i]}"]="$(port_match_range "${PLAN_START[i]}" "${PLAN_END[i]}")"
        rate_of["${PLAN_ID[i]}"]="${PLAN_RATE[i]}"
    done

    printf '# class\tport\trate\tbytes\tpackets\tdropped\toverlimits\n'
    if (( ${#PLAN_ID[@]} == 0 )); then
        return 0
    fi

    tc -s class show dev "$NIC" 2>/dev/null | awk '
        /^class / {
            cid = $0
            sub(/^class [^ ]+ 1:/, "", cid)
            sub(/[^0-9].*$/, "", cid)
            next
        }
        /Sent/ {
            gsub(/,/, "", $7)
            print cid "\t" $2 "\t" $4 "\t" $7 "\t" $9
        }
    ' | while IFS=$'\t' read -r cid bytes pkts dropped over; do
        [[ -n "${port_of[$cid]:-}" ]] || continue
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$cid" "${port_of[$cid]}" "${rate_of[$cid]}" \
            "$bytes" "$pkts" "$dropped" "$over"
    done
}

plan_rules() {
    validate_config 0
    parse_spec "$SPEC_STRING"
    build_plan

    log "limit_ports.sh $LIMIT_PORTS_VERSION"
    log "网卡: $NIC   默认速率: $SPEED   默认 class: rate $DEFAULT_GUARANTEE / ceil $DEFAULT_RATE"
    log "规则来源: $SPEC_SOURCE（$(rules_summary)）"
    log "分类器: $(filter_kind_label)   IPv6: $(ipv6_label)   fq_codel: $FQ_CODEL"
    warn_local_port_conflict

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

    local batch
    batch="$(mktemp "${TMPDIR:-/tmp}/limit-ports.XXXXXX")" || die "无法创建临时文件。"
    build_batch "$batch"

    log "将创建 ${#PLAN_ID[@]} 个 HTB class、$(filter_count) 条 filter，共 $(wc -l <"$batch") 条 tc 命令。"

    if (( VERBOSE )); then
        printf '\n# 实际执行顺序: tc qdisc del dev %s root  (先清理)\n' "$NIC"
        cat "$batch"
    else
        log "加 -v/--verbose 输出完整命令。"
    fi

    rm -f "$batch"
}

stop_rules() {
    require_root
    require_command tc
    require_command ip
    ip link show dev "$NIC" >/dev/null 2>&1 || die "网卡不存在: $NIC"
    log "删除 $NIC 的 root qdisc..."
    delete_root_qdisc
    rm -f "$(applied_state_file)"
    log "已停止。"
}

status_rules() {
    require_root
    require_command tc
    require_command ip
    ip link show dev "$NIC" >/dev/null 2>&1 || die "网卡不存在: $NIC"
    printf 'limit_ports.sh %s\n' "$LIMIT_PORTS_VERSION"
    tc -s qdisc show dev "$NIC"
    tc -s class show dev "$NIC"
}

with_nic_lock() (
    local lock_dir="${LIMIT_LOCK_DIR:-/run/lock/limit-ports}" lock_file lockdir attempt=0
    install -d -m 0755 "$lock_dir" || exit 1
    lock_file="$lock_dir/${NIC//\//_}.lock"
    if command -v flock >/dev/null 2>&1; then
        exec {limit_lock_fd}>"$lock_file" || exit 1
        flock -w 30 "$limit_lock_fd" || die "网卡 $NIC 正在更新，请稍后重试。"
    else
        lockdir="${lock_file}.d"
        while ! mkdir "$lockdir" 2>/dev/null; do
            attempt=$((attempt + 1))
            (( attempt < 300 )) || die "网卡 $NIC 正在更新，请稍后重试。"
            sleep 0.1
        done
        trap 'rmdir "$lockdir"' EXIT
    fi
    "$@"
)

with_config_lock() (
    local dir="${CONFIG_FILE}.lock.d" attempt=0
    if command -v flock >/dev/null 2>&1; then
        exec {config_lock_fd}>"${CONFIG_FILE}.lock" || exit 1
        flock -w 30 "$config_lock_fd" || die "配置正在更新，请稍后重试。"
    else
        while ! mkdir "$dir" 2>/dev/null; do
            attempt=$((attempt + 1)); (( attempt < 300 )) || die "配置正在更新，请稍后重试。"
            sleep 0.1
        done
        trap 'rmdir "$dir"' EXIT
    fi
    [[ "$(config_version)" == "$LOADED_CONFIG_VERSION" ]] || die "配置已被其他会话修改，请刷新后重试。"
    [[ -z "$EXPECTED_VERSION" || "$LOADED_CONFIG_VERSION" == "$EXPECTED_VERSION" ]] ||
        die "配置已被其他会话修改，请刷新后重试。"
    "$@"
)

save_config() {
    [[ -r "$CONFIG_SOURCE" && -n "$EXPECTED_VERSION" ]] || die "需要候选配置和原配置版本。"
    [[ "$(config_version)" == "$EXPECTED_VERSION" ]] || die "配置已被其他会话修改，请刷新后重试。"
    bash -n "$CONFIG_SOURCE" || die "候选配置语法无效。"
    CONFIG_FILE="$CONFIG_SOURCE" bash "$LIMIT_SELF" check || die "候选配置校验失败。"
    local tmp
    tmp="$(mktemp "$(dirname -- "$CONFIG_FILE")/.limit-ports.XXXXXX")" || die "无法创建临时配置。"
    if ! install -m 0644 "$CONFIG_SOURCE" "$tmp" || ! mv -fT "$tmp" "$CONFIG_FILE"; then
        rm -f "$tmp"; die "保存配置失败，旧配置保留。"
    fi
}

main() {
    parse_args "$@"

    case "$ACTION" in
        apply)
            require_root
            require_command tc
            require_command ip
            resolve_spec
            with_config_lock with_nic_lock apply_rules
            ;;
        stop)
            require_root
            require_command tc
            require_command ip
            resolve_spec
            with_config_lock with_nic_lock stop_rules
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
        stats)
            resolve_spec
            validate_config 0
            parse_spec "$SPEC_STRING"
            build_plan
            collect_stats
            ;;
        plan)
            resolve_spec
            plan_rules
            ;;
        rate-set)
            require_root
            [[ -n "$RATE_FILE" ]] || die "rate-set 需要 --rate-file。"
            resolve_spec
            with_config_lock with_nic_lock rate_set
            ;;
        config-save)
            require_root
            with_config_lock save_config
            ;;
        config-state|effective-rates|capacity|check)
            resolve_spec
            validate_config 0
            parse_spec "$SPEC_STRING"
            build_plan
            case "$ACTION" in
                config-state) config_state ;;
                effective-rates) effective_rates ;;
                capacity) capacity_report ;;
                check)
                    local count
                    count="$(total_ports)"
                    if (( count > ${ACCT_MAX_PORTS:-512} )); then
                        log "当前 $count 个端口可限速，但超过流量统计上限 ${ACCT_MAX_PORTS:-512}；用量策略不可用。"
                    fi
                    ;;
            esac
            ;;
        *)
            die "用法: $0 {apply|stop|status|rules|stats|plan}"
            ;;
    esac
}

main "$@"
