#!/usr/bin/env bash
# Sourced by portctl.sh. Policies never rewrite the user's base rate config.

POLICY_CONF="${POLICY_CONF:-/etc/default/portctl-policy.tsv}"
POLICY_DIR="${POLICY_DIR:-/var/lib/portctl/policy}"
POLICY_STATE="${POLICY_STATE:-$POLICY_DIR/state.tsv}"
POLICY_TIMER_NAME="portctl-policy.timer"
POLICY_SERVICE_FILE="${POLICY_SERVICE_FILE:-/etc/systemd/system/portctl-policy.service}"
POLICY_TIMER_FILE="${POLICY_TIMER_FILE:-/etc/systemd/system/portctl-policy.timer}"

policy_error() { printf '[policy] %s\n' "$*" >&2; }
policy_now() { date +%s; }
policy_rate_value() {
    local rate="$1" number unit multiplier
    [[ "$rate" =~ ^([0-9]+([.][0-9]+)?)(bit|kbit|mbit|gbit|tbit)$ ]] || return 1
    number="${BASH_REMATCH[1]}" unit="${BASH_REMATCH[3]}"
    case "$unit" in
        bit) multiplier=1 ;; kbit) multiplier=1000 ;; mbit) multiplier=1000000 ;;
        gbit) multiplier=1000000000 ;; tbit) multiplier=1000000000000 ;;
    esac
    LC_ALL=C awk -v n="$number" -v m="$multiplier" 'BEGIN {
        v=n*m; if(v<1 || v>1e15) exit 1; printf "%.0f",v
    }'
}
policy_uint() { [[ "$1" =~ ^(0|[1-9][0-9]{0,14})$ ]]; }
policy_clock() {
    [[ "$1" =~ ^([01][0-9]|2[0-3]):([0-5][0-9])$ ]] || return 1
    printf '%s' "$((10#${BASH_REMATCH[1]} * 60 + 10#${BASH_REMATCH[2]}))"
}
policy_lock() {
    install -d -m 0700 "$POLICY_DIR" || return 1
    if command -v flock >/dev/null 2>&1; then
        exec {policy_lock_fd}>"$POLICY_DIR/lock" || return 1
        flock -w 30 "$policy_lock_fd" || { policy_error '策略正在执行，请稍后重试。'; return 1; }
        return 0
    fi
    local lockdir="$POLICY_DIR/lock.d" attempt=0
    while ! mkdir "$lockdir" 2>/dev/null; do
        attempt=$((attempt + 1))
        (( attempt < 300 )) || { policy_error '策略正在执行，请稍后重试。'; return 1; }
        sleep 0.1
    done
    POLICY_LOCK_DIR="$lockdir"
    trap 'rm -rf "$POLICY_LOCK_DIR"' EXIT
}
policy_load() {
    POLICY_IDS=() POLICY_TYPES=() POLICY_STARTS=() POLICY_ENDS=()
    POLICY_LIMITS=() POLICY_RATES=() POLICY_A=() POLICY_B=()
    [[ -f "$POLICY_CONF" ]] || return 0
    local id type start end amount rate a b extra line=0 i
    local -A seen=()
    while IFS=$'\t' read -r id type start end amount rate a b extra; do
        line=$((line + 1))
        [[ -n "$id" && "$id" != '#'* ]] || continue
        if ! policy_uint "$id" || (( id < 1 )) || [[ -n "${seen[$id]:-}" || -n "$extra" ]]; then
            policy_error "策略文件第 $line 行编号或列数无效。"; return 1
        fi
        if ! policy_uint "$start" || ! policy_uint "$end" ||
            (( start < 1 || end > 65535 || end < start )) ||
            ! policy_uint "$amount" || ! policy_rate_value "$rate" >/dev/null; then
            policy_error "策略 $id 的端口、额度或速率无效。"; return 1
        fi
        case "$type" in
            monthly)
                (( amount > 0 )) && [[ "$a" == month && "$b" == - ]] || return 1
                ;;
            usage)
                (( amount > 0 )) && policy_uint "$b" || return 1
                case "$a" in
                    duration|until) (( b > 0 )) || return 1 ;;
                    manual) [[ "$b" == 0 ]] || return 1 ;;
                    *) return 1 ;;
                esac
                ;;
            schedule)
                [[ "$amount" == 0 ]] && policy_clock "$a" >/dev/null &&
                    policy_clock "$b" >/dev/null && [[ "$a" != "$b" ]] || return 1
                ;;
            *) policy_error "未知策略类型: $type"; return 1 ;;
        esac
        # Each accounting scope has at most one policy of each usage type.
        for ((i=0; i<${#POLICY_IDS[@]}; i++)); do
            if [[ "$type" != schedule && "${POLICY_TYPES[i]}" == "$type" &&
                "${POLICY_STARTS[i]}" == "$start" && "${POLICY_ENDS[i]}" == "$end" ]]; then
                policy_error "同一端口范围不能重复设置 $type 策略。"; return 1
            fi
        done
        seen["$id"]=1
        POLICY_IDS+=("$id") POLICY_TYPES+=("$type") POLICY_STARTS+=("$start") POLICY_ENDS+=("$end")
        POLICY_LIMITS+=("$amount") POLICY_RATES+=("$rate") POLICY_A+=("$a") POLICY_B+=("$b")
    done <"$POLICY_CONF"
    return 0
}
policy_validate_scopes() {
    local i j matched
    load_rules || { policy_error "读取基础规则失败: $RULES_ERROR"; return 1; }
    for ((i=0; i<${#POLICY_IDS[@]}; i++)); do
        matched=0
        for ((j=0; j<${#RULE_IDX[@]}; j++)); do
            if [[ "${POLICY_STARTS[i]}" == "${RULE_START[j]}" &&
                "${POLICY_ENDS[i]}" == "${RULE_END[j]}" ]]; then matched=1; break; fi
        done
        (( matched )) || {
            policy_error "策略 ${POLICY_IDS[i]} 的端口范围已不对应基础规则，请删除或重新设置策略。"
            return 1
        }
    done
}
policy_load_state() {
    PS_PERIOD=() PS_LAST=() PS_USED=() PS_UNTIL=() PS_EXEMPT=()
    [[ -f "$POLICY_STATE" ]] || return 0
    local id period last used until exempt extra
    while IFS=$'\t' read -r id period last used until exempt extra; do
        [[ -n "$id" && "$id" != '#'* ]] || continue
        policy_uint "$id" && [[ "$period" =~ ^[0-9]{4}-[0-9]{2}$ ]] &&
            policy_uint "$last" && policy_uint "$used" && policy_uint "$until" &&
            [[ "$exempt" == 0 || "$exempt" == 1 ]] && [[ -z "$extra" ]] ||
            { policy_error '策略状态文件损坏，未修改限速。'; return 1; }
        PS_PERIOD["$id"]="$period" PS_LAST["$id"]="$last" PS_USED["$id"]="$used"
        PS_UNTIL["$id"]="$until" PS_EXEMPT["$id"]="$exempt"
    done <"$POLICY_STATE"
}
declare -A PS_PERIOD=() PS_LAST=() PS_USED=() PS_UNTIL=() PS_EXEMPT=()
policy_save_state() {
    local tmp id
    tmp="$(mktemp "$POLICY_DIR/state.XXXXXX")" || return 1
    for id in "${POLICY_IDS[@]}"; do
        [[ -n "${PS_PERIOD[$id]:-}" ]] || continue
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "${PS_PERIOD[$id]}" \
            "${PS_LAST[$id]}" "${PS_USED[$id]}" "${PS_UNTIL[$id]}" "${PS_EXEMPT[$id]}"
    done >"$tmp"
    chmod 0600 "$tmp"
    mv -f "$tmp" "$POLICY_STATE"
}
policy_totals() {
    # Read saved + live counters under the same lock as sampling/rebuild/reset.
    acct_table_exists || { policy_error '统计表未建立，请先建立统计。'; return 1; }
    acct_current
}
policy_total_scope() {
    LC_ALL=C awk -F'\t' -v s="$1" -v e="$2" '
        $1>=s && $1<=e { total+=$2+$3; seen++ }
        END { if(seen != e-s+1 || total<0 || total>9e15) exit 1; printf "%.0f",total }
    ' <<<"$POLICY_TOTALS"
}
policy_in_window() {
    local now="$1" a b
    a="$(policy_clock "$2")" && b="$(policy_clock "$3")" || return 1
    if (( a < b )); then (( now >= a && now < b ))
    else (( now >= a || now < b )); fi
}
policy_evaluate() {
    local now="$1" period minute i id type total delta used until exempt active rate value best j
    period="$(date -d "@$now" +%Y-%m)" || return 1
    minute="$(policy_clock "$(date -d "@$now" +%H:%M)")" || return 1
    POLICY_ROWS="" POLICY_EFFECTIVE=""
    local -A effective=() reasons=()
    for ((j=0; j<${#RULE_IDX[@]}; j++)); do effective["$j"]="${RULE_RATE[j]}"; done
    for ((i=0; i<${#POLICY_IDS[@]}; i++)); do
        id="${POLICY_IDS[i]}" type="${POLICY_TYPES[i]}" active=0 until=0 used=0 exempt=0
        if [[ "$type" == schedule ]]; then
            policy_in_window "$minute" "${POLICY_A[i]}" "${POLICY_B[i]}" && active=1
        else
            total="$(policy_total_scope "${POLICY_STARTS[i]}" "${POLICY_ENDS[i]}")" ||
                { policy_error "策略 $id 未读到完整计数。"; return 1; }
            if [[ -z "${PS_PERIOD[$id]:-}" ]]; then
                # Enrollment starts now; old traffic is not charged retroactively.
                PS_PERIOD["$id"]="$period" PS_LAST["$id"]="$total" PS_USED["$id"]=0
                PS_UNTIL["$id"]=0 PS_EXEMPT["$id"]=0
            fi
            delta=$((total - PS_LAST[$id]))
            # An explicit accounting reset starts a new counter generation.
            (( delta >= 0 )) || delta="$total"
            used=$((PS_USED[$id] + delta))
            until="${PS_UNTIL[$id]}" exempt="${PS_EXEMPT[$id]}"
            if [[ "$type" == monthly && "${PS_PERIOD[$id]}" != "$period" ]]; then
                used=0 until=0 exempt=0
            fi
            if [[ "$type" == usage ]]; then
                if (( until > 0 && until != 1 && now >= until )); then
                    used=0 until=0
                    # A fixed deadline is one-shot; duration policies rearm.
                    [[ "${POLICY_A[i]}" == until ]] && exempt=1
                fi
                if [[ "${POLICY_A[i]}" == until ]] && (( now >= POLICY_B[i] )); then
                    used=0 until=0 exempt=1
                fi
                if (( ! exempt && until == 0 && used >= POLICY_LIMITS[i] )); then
                    case "${POLICY_A[i]}" in
                        duration) until=$((now + POLICY_B[i])) ;;
                        until) until="${POLICY_B[i]}" ;;
                        manual) until=1 ;;
                    esac
                fi
                (( until > 0 && ! exempt )) && active=1
            else
                (( used >= POLICY_LIMITS[i] && ! exempt )) && active=1
            fi
            PS_PERIOD["$id"]="$period" PS_LAST["$id"]="$total" PS_USED["$id"]="$used"
            PS_UNTIL["$id"]="$until" PS_EXEMPT["$id"]="$exempt"
        fi
        if (( active )); then
            rate="${POLICY_RATES[i]}" value="$(policy_rate_value "$rate")" || return 1
            for ((j=0; j<${#RULE_IDX[@]}; j++)); do
                if [[ "${RULE_START[j]}" == "${POLICY_STARTS[i]}" &&
                    "${RULE_END[j]}" == "${POLICY_ENDS[i]}" ]]; then
                    best="$(policy_rate_value "${effective[$j]}")" || return 1
                    if (( value < best )); then effective["$j"]="$rate"; fi
                    reasons["$j"]="${reasons[$j]:-}${reasons[$j]:+,}$id"
                fi
            done
        fi
        POLICY_ROWS+="$id"$'\t'"$type"$'\t'"${POLICY_STARTS[i]}-${POLICY_ENDS[i]}"$'\t'"$used"$'\t'"${POLICY_LIMITS[i]}"$'\t'"$active"$'\t'"$until"$'\t'"$exempt"$'\n'
    done
    for ((j=0; j<${#RULE_IDX[@]}; j++)); do
        POLICY_EFFECTIVE+="${RULE_START[j]}"$'\t'"${RULE_END[j]}"$'\t'"${effective[$j]}"$'\n'
    done
}
policy_collect() {
    POLICY_TOTALS=""
    local type needs=0
    for type in "${POLICY_TYPES[@]}"; do [[ "$type" == schedule ]] || needs=1; done
    if (( needs )); then
        # Fail closed for evaluation, not for connectivity: leave current rates unchanged.
        POLICY_TOTALS="$(acct_with_lock policy_totals)" || return 1
    fi
}
policy_apply_effective() {
    local tmp
    tmp="$(mktemp "$POLICY_DIR/rates.XXXXXX")" || return 1
    printf '%s' "$POLICY_EFFECTIVE" >"$tmp"
    if ! limit_root rate-set --rate-file "$tmp"; then
        rm -f "$tmp"; policy_error '应用策略失败；状态已保存，下次执行会重试。'; return 1
    fi
    rm -f "$tmp"
}
policy_tick() (
    policy_lock || exit 1
    policy_load && policy_validate_scopes && policy_load_state && policy_collect || exit 1
    policy_evaluate "$(policy_now)" && policy_save_state || exit 1
    policy_apply_effective
)
policy_release() (
    local want="$1" now period i id found=0
    policy_uint "$want" || exit 1
    policy_lock || exit 1
    policy_load && policy_validate_scopes && policy_load_state && policy_collect || exit 1
    now="$(policy_now)" period="$(date -d "@$now" +%Y-%m)"
    policy_evaluate "$now" || exit 1
    for ((i=0; i<${#POLICY_IDS[@]}; i++)); do
        id="${POLICY_IDS[i]}"
        [[ "$id" == "$want" ]] || continue
        [[ "${POLICY_TYPES[i]}" != schedule ]] || { policy_error '时段规则请删除或修改，不支持用量解除。'; exit 1; }
        found=1
        PS_UNTIL["$id"]=0 PS_USED["$id"]=0
        if [[ "${POLICY_TYPES[i]}" == monthly ]]; then PS_EXEMPT["$id"]=1
        else
            PS_EXEMPT["$id"]=0
            # Fixed-deadline policies can be rearmed only before their deadline.
            if [[ "${POLICY_A[i]}" == until ]] && (( now >= POLICY_B[i] )); then PS_EXEMPT["$id"]=1; fi
        fi
    done
    (( found )) || { policy_error '策略编号不存在。'; exit 1; }
    policy_save_state && policy_evaluate "$now" && policy_save_state && policy_apply_effective || exit 1
    printf '已解除策略 %s；其他仍生效的策略不会被绕过。\n' "$want"
)
policy_write_config() {
    local content="$1" dir tmp
    dir="$(dirname -- "$POLICY_CONF")"
    install -d -m 0755 "$dir" || return 1
    tmp="$(mktemp "$dir/.portctl-policy.XXXXXX")" || return 1
    printf '%s' "$content" >"$tmp"
    # Validate before replacing; this is a TSV data file, never sourced.
    if ! POLICY_CONF="$tmp" policy_load; then rm -f "$tmp"; return 1; fi
    chmod 0600 "$tmp"
    mv -f "$tmp" "$POLICY_CONF"
}
policy_add() (
    local type="$1" start="$2" end="$3" amount="$4" rate="$5" a="$6" b="$7" content="" id next=1 now
    policy_lock || exit 1
    policy_load && policy_validate_scopes || exit 1
    for id in "${POLICY_IDS[@]}"; do (( id < next )) || next=$((id + 1)); done
    [[ ! -f "$POLICY_CONF" ]] || content="$(cat "$POLICY_CONF")"$'\n'
    content+="$next"$'\t'"$type"$'\t'"$start"$'\t'"$end"$'\t'"$amount"$'\t'"$rate"$'\t'"$a"$'\t'"$b"$'\n'
    local candidate
    candidate="$(mktemp "$POLICY_DIR/candidate.XXXXXX")" || exit 1
    printf '%s' "$content" >"$candidate"
    if ! POLICY_CONF="$candidate" policy_load || ! policy_validate_scopes; then rm -f "$candidate"; exit 1; fi
    rm -f "$candidate"
    now="$(policy_now)"
    if [[ "$type" == usage && "$a" == until ]] && (( b <= now )); then
        policy_error '解除时间必须在未来。'; exit 1
    fi
    # Initialize every existing state before adding a new baseline.
    policy_load_state && policy_collect && policy_evaluate "$now" || exit 1
    policy_save_state && policy_write_config "$content" || exit 1
    printf '已保存策略 %s。请开启自动执行，基础规则与统计表需已建立。\n' "$next"
)
policy_delete() (
    local want="$1" content i found=0
    policy_uint "$want" || exit 1
    policy_lock || exit 1
    policy_load || exit 1
    for i in "${POLICY_IDS[@]}"; do [[ "$i" != "$want" ]] || found=1; done
    (( found )) || { policy_error '策略编号不存在。'; exit 1; }
    content="$(awk -F'\t' -v id="$want" '$1 != id' "$POLICY_CONF")"
    policy_write_config "${content:+$content$'\n'}" || exit 1
    printf '策略已删除；正在恢复剩余策略对应的速率。\n'
    policy_load && policy_validate_scopes && policy_load_state && policy_collect &&
        policy_evaluate "$(policy_now)" && policy_save_state && policy_apply_effective
)
policy_status() (
    policy_lock || exit 1
    policy_load && policy_validate_scopes && policy_load_state && policy_collect || exit 1
    policy_evaluate "$(policy_now)" || exit 1
    printf '# id\ttype\tports\tused_bytes\tlimit_bytes\tactive\tuntil_epoch\texempt\n%s' "$POLICY_ROWS"
    printf '# Effective rates (start, end, rate)\n%s' "$POLICY_EFFECTIVE"
)
policy_enable() {
    local self tmp
    self="$(fw_installed_self)"
    # Validate and apply once before enabling unattended execution.
    run_root bash "$SELF_PATH" policy-tick || return 1
    tmp="$(mktemp)" || return 1
    {
        printf '[Unit]\nDescription=Portctl usage and schedule policies\nAfter=network-online.target limit-ports.service\n\n'
        printf '[Service]\nType=oneshot\nExecStart=%s policy-tick\n' "$self"
    } >"$tmp"
    run_root install -m 0644 "$tmp" "$POLICY_SERVICE_FILE" || { rm -f "$tmp"; return 1; }
    printf '[Unit]\nDescription=Evaluate portctl policies every minute\n\n[Timer]\nOnBootSec=30s\nOnUnitActiveSec=60s\nAccuracySec=1s\n\n[Install]\nWantedBy=timers.target\n' >"$tmp"
    run_root install -m 0644 "$tmp" "$POLICY_TIMER_FILE" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
    run_root systemctl daemon-reload && run_root systemctl enable --now "$POLICY_TIMER_NAME"
}
policy_disable() {
    run_root systemctl disable --now "$POLICY_TIMER_NAME" || return 1
    # Stop enforcement, then explicitly restore base rates without deleting policies.
    local tmp
    load_rules || return 1
    tmp="$(mktemp)" || return 1
    local i
    for ((i=0; i<${#RULE_IDX[@]}; i++)); do
        printf '%s\t%s\t%s\n' "${RULE_START[i]}" "${RULE_END[i]}" "${RULE_RATE[i]}"
    done >"$tmp"
    limit_root rate-set --rate-file "$tmp"
    local rc=$?
    rm -f "$tmp"
    return "$rc"
}

policy_prompt_amount() {
    local value
    printf '%s额度 / 阈值（GB，上传+下载，回车取消）:%s ' "$CYAN" "$RESET" >&2
    read -r value || return 1
    [[ "$value" =~ ^[0-9]{1,6}([.][0-9]{1,3})?$ ]] || return 1
    LC_ALL=C awk -v v="$value" 'BEGIN { n=v*1e9; if(n<1 || n>9e15) exit 1; printf "%.0f",n }'
}
policy_add_flow() {
    local type="$1" choice i selected=-1 start end amount=0 rate a=- b=- answer hours
    clear_screen
    draw_brand
    printf '\n%s用量与时段策略 > 添加 %s%s\n\n' "$YELLOW" "$type" "$RESET"
    load_rules || { printf '%s\n' "$RULES_ERROR"; pause_screen; return; }
    print_rules_table
    ((${#RULE_IDX[@]})) || { pause_screen; return; }
    printf '\n%s选择基础规则编号（区间合计计量，回车取消）:%s ' "$CYAN" "$RESET"
    read -r choice || return 0
    [[ -n "$choice" ]] || return 0
    for ((i=0; i<${#RULE_IDX[@]}; i++)); do [[ "${RULE_IDX[i]}" != "$choice" ]] || selected="$i"; done
    if (( selected < 0 )); then printf '规则编号无效。\n'; pause_screen; return; fi
    start="${RULE_START[selected]}" end="${RULE_END[selected]}"
    if [[ "$type" != schedule ]]; then amount="$(policy_prompt_amount)" || return 0; fi
    rate="$(prompt_rate '策略限速')" || return 0
    case "$type" in
        monthly) a=month b=- ;;
        usage)
            printf '\n1. 限速后持续指定小时\n2. 到指定日期时间解除\n3. 仅手动解除\n选择: '
            read -r answer || return 0
            case "$answer" in
                1)
                    printf '持续小时数（1-8760）: '
                    read -r hours || return 0
                    if ! [[ "$hours" =~ ^[0-9]{1,4}$ ]] || (( 10#$hours < 1 || 10#$hours > 8760 )); then
                        printf '小时数无效。\n'; pause_screen; return
                    fi
                    a=duration b=$((10#$hours * 3600))
                    ;;
                2)
                    printf '解除日期时间（服务器时区，YYYY-MM-DD HH:MM）: '
                    read -r answer || return 0
                    if ! [[ "$answer" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]] ||
                        ! b="$(date -d "$answer" +%s 2>/dev/null)"; then
                        printf '日期时间无效。\n'; pause_screen; return
                    fi
                    a=until
                    ;;
                3) a=manual b=0 ;;
                *) return 0 ;;
            esac
            ;;
        schedule)
            printf '每天开始时间（HH:MM，服务器时区）: '
            read -r a || return 0
            printf '每天结束时间（HH:MM，支持跨午夜）: '
            read -r b || return 0
            ;;
    esac
    run_root bash "$SELF_PATH" policy-add "$type" "$start" "$end" "$amount" "$rate" "$a" "$b" || true
    pause_screen
}
show_policy_menu() {
    local choice id data rc timer
    while true; do
        clear_screen
        draw_brand
        printf '\n%s用量与时段策略%s\n' "$YELLOW" "$RESET"
        timer="$(systemctl is-enabled "$POLICY_TIMER_NAME" 2>/dev/null)" || timer="${timer:-未开启}"
        printf '%s时区:%s %s    %s自动执行:%s %s\n\n' "$DIM" "$RESET" "$(date +%Z)" "$DIM" "$RESET" "$timer"
        rc=0
        data="$(run_root bash "$SELF_PATH" policy-status 2>&1)" || rc=$?
        if (( rc )); then printf '%s%s%s\n' "$YELLOW" "$data" "$RESET"
        else
            printf '%s\n' "$data" | while IFS=$'\t' read -r id type ports used amount active until exempt; do
                [[ "$id" != '#'* && -n "$id" ]] || continue
                [[ "$type" == monthly || "$type" == usage || "$type" == schedule ]] || continue
                local label status release="-"
                case "$type" in monthly) label="月额度" ;; usage) label="用量降速" ;; schedule) label="时段限速" ;; esac
                status="未触发"
                [[ "$exempt" != 1 ]] || status="已豁免"
                if [[ "$active" == 1 ]]; then status="策略命中"; fi
                if [[ "$type" == monthly ]]; then release="下月1日"
                elif [[ "$until" == 1 ]]; then release="手动解除"
                elif [[ "$until" =~ ^[0-9]+$ ]] && (( until > 1 )); then release="$(date -d "@$until" '+%m-%d %H:%M')"; fi
                printf '%s. %s  端口 %s  %s / %s  %s  解除:%s\n' \
                    "$id" "$label" "$ports" "$(human_bytes "$used")" "$(human_bytes "$amount")" "$status" "$release"
            done
        fi
        printf '\n1. 添加月度流量额度\n2. 添加用量触发降速\n3. 添加每日时段限速\n4. 手动解除用量降速\n5. 删除策略\n6. 开启自动执行\n7. 关闭自动执行并恢复基础速率\n8. 立即执行 / 刷新\n0. 返回\n选择: '
        read -r choice || return 0
        case "$choice" in
            1) policy_add_flow monthly ;;
            2) policy_add_flow usage ;;
            3) policy_add_flow schedule ;;
            4|5)
                printf '策略编号（回车取消）: '
                read -r id || return 0
                [[ -n "$id" ]] || continue
                if [[ "$choice" == 4 ]]; then run_root bash "$SELF_PATH" policy-release "$id" || true
                else run_root bash "$SELF_PATH" policy-delete "$id" || true; fi
                pause_screen
                ;;
            6) policy_enable || true; pause_screen ;;
            7) policy_disable || true; pause_screen ;;
            8) run_root bash "$SELF_PATH" policy-tick || true; pause_screen ;;
            0|"") return ;;
            *) printf '请输入 1-8 或 0。\n'; pause_screen ;;
        esac
    done
}
