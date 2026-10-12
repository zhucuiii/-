#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export CONFIG_FILE="$TMP/config" LIMIT_SCRIPT="$ROOT/limit_ports.sh"
export FW_LOCK_FILE="$TMP/firewall.lock"
export POLICY_DIR="$TMP/policy" POLICY_CONF="$TMP/policy.tsv"
printf 'PORT_SPEC="8080=20mbit"\n' >"$CONFIG_FILE"
source "$ROOT/portctl.sh" --help >/dev/null
trap 'rm -rf "$TMP"' EXIT
passed=0
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { passed=$((passed + 1)); printf 'ok %s - %s\n' "$passed" "$1"; }

(
    mkdir "$TMP/bin"
    MSYS=winsymlinks:nativestrict ln -s "$ROOT/portctl.sh" "$TMP/bin/zc"
    source "$TMP/bin/zc" --help >/dev/null
    [[ "$SELF_PATH" == "$ROOT/portctl.sh" ]] || fail "alias did not resolve its target"
    declare -F policy_tick >/dev/null || fail "alias did not load the policy module"
)
pass "zc resolves the installed target and loads policy functions"

(
    run_root() { printf '%s\n' "$*" >>"$TMP/services"; }
    systemctl() { :; }
    fw_autostart_off
    if grep -q 'portctl-policy' "$TMP/services"; then fail "firewall disabled policy services"; fi
    grep -q 'disable --now portctl-firewall.service' "$TMP/services" || fail "firewall was not disabled"
    pause_screen() { :; }
    acct_available() { return 1; }
    (uninstall_program <<<$'YES\nn') >"$TMP/uninstall.out"
    grep -q 'disable --now portctl-policy.timer' "$TMP/services" || fail "uninstall left the policy timer"
    grep -q 'stop portctl-policy.service' "$TMP/services" || fail "uninstall left an active policy service"
    grep -q 'rm -f /usr/local/sbin/policy_engine.sh' "$TMP/services" || fail "uninstall left the policy module"
)
pass "firewall lifecycle stays independent and uninstall removes policy components"

(
    source <(sed '$d' "$ROOT/limit_ports.sh")
    require_root() { :; }
    config_state() { printf 'applied\n'; }
    ip() { return 0; }
    tc() {
        case "$*" in
            "class show dev eth0") cat "$TMP/classes" ;;
            "-batch "*)
                cp "$2" "$TMP/batch"
                printf 'batch\n' >>"$TMP/tc.calls"
                ;;
            *) fail "unexpected tc command: $*" ;;
        esac
    }
    SPEC_STRING='10001-10003=12mbit 8080=20mbit 9000-9001=50mbit@shared'
    RATE_FILE="$TMP/rates"
    printf 'class htb 1:10 parent 1: rate 12Mbit ceil 12Mbit\nclass htb 1:11 parent 1: rate 12Mbit ceil 12Mbit\nclass htb 1:12 parent 1: rate 12Mbit ceil 12Mbit\nclass htb 1:13 parent 1: rate 20Mbit ceil 20Mbit\nclass htb 1:14 parent 1: rate 50Mbit ceil 50Mbit\n' >"$TMP/classes"
    printf '10001\t10003\t5mbit\n8080\t8080\t20mbit\n9000\t9001\t7mbit\n' >"$RATE_FILE"
    rate_set >"$TMP/rate.out"
    [[ "$(wc -l <"$TMP/batch")" -eq 4 ]] || fail "range policy did not update all expanded classes"
    for id in 10 11 12; do
        grep -q "classid 1:$id htb rate 5mbit ceil 5mbit" "$TMP/batch" || fail "missing range class $id"
    done
    grep -q 'classid 1:14 htb rate 7mbit' "$TMP/batch" || fail "shared class was not updated"
    if grep -q 'classid 1:13 ' "$TMP/batch"; then fail "unchanged class was rewritten"; fi
    sed -i 's/12Mbit/5Mbit/g;s/50Mbit/7Mbit/g' "$TMP/classes"
    rate_set >"$TMP/rate.out"
    [[ "$(wc -l <"$TMP/tc.calls")" -eq 1 ]] || fail "unchanged rates dispatched another batch"
    printf '8080\t8080\t10mbit\n10002\t10003\t5mbit\n' >"$RATE_FILE"
    if (rate_set) >"$TMP/rate.out" 2>&1; then fail "partial scope was accepted"; fi
    [[ "$(wc -l <"$TMP/tc.calls")" -eq 1 ]] || fail "invalid scope partially applied"
)
pass "independent and shared ranges update fully, unchanged rates skip tc, and invalid scopes fail before writes"

(
    source <(sed '$d' "$ROOT/limit_ports.sh")
    require_root() { :; }
    config_state() { printf 'applied\n'; }
    ip() { return 0; }
    tc() {
        case "$*" in
            "class show dev eth0") printf 'class htb 1:10 parent 1: rate 12Mbit ceil 12Mbit\n' ;;
            "-batch "*)
                n=${TC_BATCH_COUNT:-0}; TC_BATCH_COUNT=$((n + 1))
                cp "$2" "$TMP/rate-batch-$TC_BATCH_COUNT"
                (( TC_BATCH_COUNT == 1 )) && return 1
                return 0
                ;;
            *) fail "unexpected tc command during rollback: $*" ;;
        esac
    }
    SPEC_STRING='8080=12mbit'
    parse_spec "$SPEC_STRING"; build_plan
    RATE_FILE="$TMP/rollback-rates"
    printf '8080\t8080\t5mbit\n' >"$RATE_FILE"
    if (rate_set) >"$TMP/rollback.out" 2>&1; then fail "failed rate update reported success"; fi
    grep -q 'classid 1:10 htb rate 12000000bit ceil 12000000bit' "$TMP/rate-batch-2" || fail "rollback did not restore old rate"
)
pass "failed rate updates replay the previous queue rates"

(
    source <(sed '$d' "$ROOT/limit_ports.sh")
    NIC=eth0 FILTER_KIND=u32 IPV6_MODE=yes IPV6_STRICT=yes
    ip() { printf '    inet6 2001:db8::1/64 scope global\n'; }
    if (validate_ipv6_coverage) >"$TMP/ipv6.out" 2>&1; then fail "strict IPv6 coverage accepted u32-only shaping"; fi
    grep -q 'IPV6_STRICT' "$TMP/ipv6.out" || fail "strict IPv6 diagnostic omitted remediation"
    IPV6_STRICT=no
    validate_ipv6_coverage >"$TMP/ipv6-warning" 2>&1
    grep -q '仅限速 IPv4' "$TMP/ipv6-warning" || fail "non-strict IPv6 downgrade was not reported"
)
pass "IPv6 coverage checks reject silent u32-only enforcement and report explicit downgrade"

(
    source <(sed '$d' "$ROOT/limit_ports.sh")
    FILTER_KIND=flower IPV6_MODE=no IPV6_STRICT=yes NIC=eth0
    flower_ok() { return 1; }
    if (validate_ipv6_coverage) >"$TMP/flower.out" 2>&1; then fail "explicit flower requirement was silently downgraded"; fi
    grep -q 'FILTER_KIND=flower' "$TMP/flower.out" || fail "missing explicit flower diagnostic"
)
pass "explicit flower selection fails when cls_flower is unavailable"

(
    source <(sed '$d' "$ROOT/limit_ports.sh")
    LIMIT_STATE_DIR="$TMP/restore-state"
    NIC=eth0 FILTER_KIND=u32 IPV6_MODE=no PRECHECK=no
    ip() { :; }
    tc() {
        case "$*" in
            'qdisc del '*) return 0 ;;
            'class show '*) printf 'class htb 1:1 root rate 1Mbit ceil 1000Mbit\nclass htb 1:10 parent 1: rate 5Mbit ceil 5Mbit\n' ;;
            '-batch '*)
                cp "$2" "$TMP/last-apply.batch"
                if [[ "${FAIL_APPLY:-0}" == 1 ]]; then FAIL_APPLY=0; return 1; fi
                [[ "${FAIL_RESTORE:-0}" != 1 ]]
                ;;
            *) fail "unexpected tc request: $*" ;;
        esac
    }
    SPEC_STRING='8080=12mbit'
    apply_rules >"$TMP/restore.out"
    cp "$(applied_batch_file)" "$TMP/saved.batch"
    SPEC_STRING='8443=20mbit'
    FAIL_APPLY=1
    if (apply_rules) >"$TMP/restore.out" 2>&1; then fail "failed apply returned success"; fi
    grep -q 'sport 8080' "$TMP/last-apply.batch" || fail "old port filters not restored"
    grep -q 'classid 1:10 htb rate 5000000bit ceil 5000000bit' "$TMP/last-apply.batch" || fail "old policy rate lost during rollback"
    cmp -s "$(applied_batch_file)" "$TMP/saved.batch" || fail "rollback changed old snapshot"
    parse_spec "$SPEC_STRING"; build_plan
    [[ "$(config_state)" == pending ]] || fail "failed new config marked applied"
    FAIL_RESTORE=1
    if (apply_rules) >"$TMP/restore.out" 2>&1; then fail "failed restore returned success"; fi
    [[ ! -f "$(applied_batch_file)" ]] || fail "failed restore kept a trusted snapshot"
    if (apply_rules) >"$TMP/restore.out" 2>&1; then fail "first apply failure returned success"; fi
    [[ "$(config_state)" == unknown ]] || fail "first apply failure marked applied"
)
pass "base apply failures restore old ports and live policy rates, and failed recovery invalidates state"

(
    source <(sed '$d' "$ROOT/limit_ports.sh")
    LIMIT_STATE_DIR="$TMP/ipv6-state"
    mkdir -p "$LIMIT_STATE_DIR"
    IPV6_MODE=auto
    nic_has_ipv6() { [[ "${HAS_IPV6:-0}" == 1 ]]; }
    SPEC_STRING='8080=12mbit'
    parse_spec "$SPEC_STRING"; build_plan
    base_signature >"$(applied_state_file)"
    [[ "$(config_state)" == applied ]] || fail "initial IPv4 config not applied"
    HAS_IPV6=1
    [[ "$(config_state)" == pending ]] || fail "IPv6 address appearance did not invalidate IPv4-only state"
)
pass "auto IPv6 address changes mark the previous rules pending"

(
    source <(sed '$d' "$ROOT/limit_ports.sh")
    LIMIT_STATE_DIR="$TMP/coverage-state"
    mkdir -p "$LIMIT_STATE_DIR"
    IPV6_MODE=yes FILTER_KIND=flower
    flower_ok() { return 0; }
    SPEC_STRING='8080=12mbit'
    parse_spec "$SPEC_STRING"; build_plan
    validate_ipv6_coverage
    base_signature >"$(applied_state_file)"
    tc() {
        printf 'filter parent 1: protocol ipv6 pref 11 flower handle 0x1\n  ip_proto tcp\n  classid 1:10\n'
        if [[ "${HAS_UDP:-0}" == 1 ]]; then
            printf 'filter parent 1: protocol ipv6 pref 11 flower handle 0x2\n  ip_proto udp\n  classid 1:10\n'
        fi
    }
    coverage_report >"$TMP/coverage"
    grep -Fxq $'ipv6\tuncovered' "$TMP/coverage" || fail "missing UDP filter presented as covered"
    HAS_UDP=1
    coverage_report >"$TMP/coverage"
    grep -Fxq $'ipv6\tfilters-present' "$TMP/coverage" || fail "installed TCP/UDP filters not recognized"
    IPV6_MODE=auto
    nic_has_ipv6() { return 1; }
    build_batch "$TMP/no-v6.batch"
    if grep -q 'protocol ipv6' "$TMP/no-v6.batch"; then fail "auto mode without IPv6 generated IPv6 filters"; fi
)
pass "IPv6 coverage inspects installed TCP/UDP filters and auto skips absent addresses"

(
    source <(sed '$d' "$ROOT/limit_ports.sh")
    LIMIT_LOCK_DIR="$TMP/locks"
    critical() {
        printf '%s-start\n' "$1" >>"$TMP/lock.trace"
        [[ "$1" != first ]] || touch "$TMP/started"
        sleep 0.2
        printf '%s-end\n' "$1" >>"$TMP/lock.trace"
    }
    with_nic_lock critical first &
    first_pid=$!
    for ((i=0;i<100;i++)); do [[ -f "$TMP/started" ]] && break; sleep 0.01; done
    [[ -f "$TMP/started" ]] || fail "first operation never acquired the lock"
    with_nic_lock critical second &
    second_pid=$!
    wait "$first_pid"
    wait "$second_pid"
    [[ "$(cat "$TMP/lock.trace")" == $'first-start\nfirst-end\nsecond-start\nsecond-end' ]] ||
        fail "concurrent tc operations interleaved"
)
pass "operations on the same NIC serialize through one lock"

(
    FW_ACT=(deny) FW_PROTO=(tcp) FW_PSTART=(3306) FW_PEND=(3306) FW_SRC=("")
    nft() {
        printf '%s\n' "$*" >>"$TMP/nft.calls"
        case "$*" in
            "list tables inet") printf 'table inet portctl\n' ;;
            "-c -f "*) cp "$3" "$TMP/nft.checked"; [[ "${NFT_FAIL:-}" != check ]] ;;
            "-f "*) cp "$2" "$TMP/nft.applied"; [[ "${NFT_FAIL:-}" != apply ]] ;;
            *) fail "unexpected destructive nft command: $*" ;;
        esac
    }
    NFT_FAIL=check
    if fw_nft_apply >"$TMP/fw.out" 2>&1; then fail "invalid nft rules applied"; fi
    [[ ! -f "$TMP/nft.applied" ]] || fail "failed precheck touched nft"
    NFT_FAIL=apply
    if fw_nft_apply >"$TMP/fw.out" 2>&1; then fail "failed nft transaction reported success"; fi
    NFT_FAIL=""
    fw_nft_apply >"$TMP/fw.out"
    cmp -s "$TMP/nft.checked" "$TMP/nft.applied" || fail "applied a different nft batch than checked"
    grep -q '^delete table inet portctl$' "$TMP/nft.applied" || fail "old table was not replaced in the transaction"
    grep -q '^table inet portctl {' "$TMP/nft.applied" || fail "new table missing from transaction"
)
pass "nft firewall validates the entire replacement and deletes/recreates in one batch"

(
    FW_ACT=(deny) FW_PROTO=(tcp) FW_PSTART=(3306) FW_PEND=(3306) FW_SRC=("")
    iptables() {
        [[ "$*" == "-w 30 -S" ]] || fail "iptables was changed outside restore"
        printf '%s\n' '-P INPUT ACCEPT' '-N PORTCTL' '-A INPUT -j PORTCTL' '-A PORTCTL -p tcp --dport 8080 -j DROP' '-N OTHER' '-A OTHER -j ACCEPT'
    }
    ip6tables() { iptables "$@"; }
    restore() {
        local family="$1"; shift
        local text; text="$(cat)"
        printf '%s|%s\n' "$family" "$*" >>"$TMP/restore.calls"
        if [[ "$*" == *--test* ]]; then
            [[ "${RESTORE_FAIL:-}" != check ]]
        else
            printf '%s\n' "$text" >"$TMP/$family.applied"
            [[ "$family" != ip6tables || "${RESTORE_FAIL:-}" != apply ]]
        fi
    }
    iptables-restore() { restore iptables "$@"; }
    ip6tables-restore() { restore ip6tables "$@"; }
    RESTORE_FAIL=check
    if fw_iptables_apply >"$TMP/fw.out" 2>&1; then fail "failed iptables precheck reported success"; fi
    [[ ! -f "$TMP/iptables.applied" ]] || fail "failed precheck touched iptables"
    RESTORE_FAIL=apply
    if fw_iptables_apply >"$TMP/fw.out" 2>&1; then fail "failed IPv6 commit reported success"; fi
    grep -q -- '-A PORTCTL -p tcp --dport 8080 -j DROP' "$TMP/iptables.applied" || fail "IPv4 was not restored"
    if grep -q 'OTHER' "$TMP/iptables.applied"; then fail "rollback touched another chain"; fi
    RESTORE_FAIL=""
    fw_iptables_apply >"$TMP/fw.out"
    grep -q -- '-A PORTCTL -m conntrack --ctstate NEW -p tcp --dport 3306 -j DROP' "$TMP/iptables.applied" ||
        fail "new IPv4 rules missing"
    if grep -q 'OTHER' "$TMP/iptables.applied"; then fail "apply touched another chain"; fi
)
pass "iptables prechecks both families, preserves unrelated chains, and restores IPv4 if IPv6 fails"

printf 'Passed %s reliability tests.\n' "$passed"
