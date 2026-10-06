#!/usr/bin/env bash
#
# Per-port egress shaping with tc/HTB.
#
# Configuration can be supplied through /etc/default/limit-ports or
# environment variables. The script owns the root qdisc on NIC, so do not
# run it on an interface already managed by another tc service.
#
# Examples:
#   ./limit_ports.sh apply
#   ./limit_ports.sh stop
#   ./limit_ports.sh status
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
ACTION="apply"

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
  limit_ports.sh [apply|stop|status] [选项]

选项:
  --nic IFACE              网卡，默认 eth0
  --speed RATE             每端口限速，例如 12mbit、20mbit
  --default-rate RATE      未匹配流量的速率
  --start-port PORT        起始端口
  --end-port PORT          结束端口
  --r2q NUMBER             HTB r2q 参数
  -h, --help               显示帮助

示例:
  limit_ports.sh apply --speed 20mbit
  limit_ports.sh apply --nic ens3 --start-port 10001 --end-port 10200 --speed 12mbit
  limit_ports.sh status
USAGE
}

require_option_value() {
    [[ $# -ge 2 && -n "$2" ]] || die "选项 $1 缺少参数。"
}

parse_args() {
    while (($# > 0)); do
        case "$1" in
            apply|stop|status)
                ACTION="$1"
                shift
                ;;
            --nic)
                require_option_value "$@"
                NIC="$2"
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
                shift 2
                ;;
            --end-port)
                require_option_value "$@"
                PORT_END="$2"
                shift 2
                ;;
            --r2q)
                require_option_value "$@"
                R2Q="$2"
                shift 2
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

validate_config() {
    [[ -n "$NIC" ]] || die "NIC 不能为空。"
    is_uint "$PORT_START" || die "PORT_START 必须是整数。"
    is_uint "$PORT_END" || die "PORT_END 必须是整数。"
    is_uint "$CLASS_START" || die "CLASS_START 必须是整数。"
    is_uint "$R2Q" || die "R2Q 必须是整数。"
    (( PORT_START >= 1 && PORT_START <= 65535 )) || die "PORT_START 超出端口范围。"
    (( PORT_END >= PORT_START && PORT_END <= 65535 )) || die "PORT_END 超出端口范围。"
    (( CLASS_START >= 1 && CLASS_START <= 65535 )) || die "CLASS_START 超出 class 范围。"
    (( R2Q >= 1 )) || die "R2Q 必须大于 0。"

    local count=$((PORT_END - PORT_START + 1))
    (( CLASS_START + count - 1 <= 65535 )) ||
        die "端口数量超出 HTB class id 范围。"
    ip link show dev "$NIC" >/dev/null 2>&1 ||
        die "网卡不存在: $NIC"
}

delete_root_qdisc() {
    # This script intentionally manages the whole root qdisc. If another
    # service owns it, stop that service before running this script.
    tc qdisc del dev "$NIC" root 2>/dev/null || true
}

apply_rules() {
    validate_config

    log "清理 $NIC 上已有的 root qdisc..."
    delete_root_qdisc

    log "创建 HTB 根队列（r2q=$R2Q，默认 class=1:1）..."
    tc qdisc add dev "$NIC" root handle 1: htb default 1 r2q "$R2Q"

    # Unmatched traffic remains usable instead of being sent to a nonexistent
    # default class. Set DEFAULT_RATE to the real link rate when needed.
    tc class add dev "$NIC" parent 1: classid 1:1 htb \
        rate "$DEFAULT_RATE" ceil "$DEFAULT_RATE"

    local port id
    id="$CLASS_START"
    for ((port = PORT_START; port <= PORT_END; port++, id++)); do
        tc class add dev "$NIC" parent 1: classid "1:$id" htb \
            rate "$SPEED" ceil "$SPEED"

        # Egress packets sent by a listening TCP/UDP service have that
        # service port as their source port.
        tc filter add dev "$NIC" protocol ip parent 1: prio 10 u32 \
            match ip protocol 6 0xff \
            match ip sport "$port" 0xffff \
            flowid "1:$id"
        tc filter add dev "$NIC" protocol ip parent 1: prio 10 u32 \
            match ip protocol 17 0xff \
            match ip sport "$port" 0xffff \
            flowid "1:$id"
    done

    log "完成：端口 $PORT_START-$PORT_END，每端口独立限速 $SPEED（约 $(rate_to_mbps "$SPEED") MB/s）。"
    log "查看统计：tc -s class show dev $NIC"
}

rate_to_mbps() {
    # Human-readable hint only; tc itself remains the source of truth.
    case "$1" in
        *mbit) awk "BEGIN { printf \"%.2f\", ${1%mbit}/8 }" ;;
        *gbit) awk "BEGIN { printf \"%.2f\", ${1%gbit}*1000/8 }" ;;
        *) printf "按 tc 速率单位计算" ;;
    esac
}

stop_rules() {
    require_root
    require_command tc
    ip link show dev "$NIC" >/dev/null 2>&1 || die "网卡不存在: $NIC"
    log "删除 $NIC 的 root qdisc..."
    delete_root_qdisc
    log "已停止。"
}

status_rules() {
    require_root
    require_command tc
    ip link show dev "$NIC" >/dev/null 2>&1 || die "网卡不存在: $NIC"
    tc -s qdisc show dev "$NIC"
    tc -s class show dev "$NIC"
}

main() {
    require_root
    require_command tc
    require_command ip
    parse_args "$@"

    case "$ACTION" in
        apply) apply_rules ;;
        stop) stop_rules ;;
        status) status_rules ;;
        *)
            die "用法: $0 {apply|stop|status}"
            ;;
    esac
}

main "$@"
