#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export CONFIG_FILE="$TMP/config" LIMIT_SCRIPT="$ROOT/limit_ports.sh"
export LIMIT_STATE_DIR="$TMP/limits" LIMIT_LOCK_DIR="$TMP/locks"
export POLICY_DIR="$TMP/policy" POLICY_STATE="$TMP/policy/state.tsv" POLICY_CONF="$TMP/policy.tsv"
export ACCT_DIR="$TMP/acct" FW_CONF_FILE="$TMP/firewall.conf" FW_LOCK_FILE="$TMP/firewall.lock"
export POLICY_SERVICE_FILE="$TMP/portctl-policy.service" POLICY_TIMER_FILE="$TMP/portctl-policy.timer"
export ACCT_SERVICE_FILE="$TMP/portctl-accounting.service" ACCT_TIMER_FILE="$TMP/portctl-accounting.timer"
printf 'NIC="eth0"\nPORT_SPEC="8080=20mbit"\n' >"$CONFIG_FILE"
source "$ROOT/portctl.sh" --help >/dev/null
trap 'rm -rf "$TMP"' EXIT
passed=0
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { passed=$((passed + 1)); printf 'ok %s - %s\n' "$passed" "$1"; }

limiter() (
    source <(sed '$d' "$LIMIT_SCRIPT")
    require_root() { :; }
    LIMIT_SELF="$LIMIT_SCRIPT"
    ip() { return 0; }
    tc() {
        case "$*" in
            "class show dev eth0") cat "$TMP/classes" ;;
            "-batch "*) cp "$2" "$TMP/latest.batch"; printf 'batch\n' >>"$TMP/tc.calls" ;;
            *) fail "unexpected tc mutation: $*" ;;
        esac
    }
    main "$@"
)

load_rules
old_version="$RULES_VERSION"
printf 'NIC="eth0"\nPORT_SPEC="8443=10mbit"\n' >"$TMP/candidate"
limiter config-save --config-source "$TMP/candidate" --expected-version "$old_version" >"$TMP/out"
cmp -s "$CONFIG_FILE" "$TMP/candidate" || fail "candidate was not committed"
if limiter config-save --config-source "$TMP/candidate" --expected-version "$old_version" >"$TMP/out" 2>&1; then
    fail "stale writer was accepted"
fi
pass "config saves commit atomically and reject stale versions"

load_rules
cp "$CONFIG_FILE" "$TMP/before"
printf 'NIC="eth0"\nPORT_SPEC="0=10mbit"\n' >"$TMP/invalid"
if limiter config-save --config-source "$TMP/invalid" --expected-version "$RULES_VERSION" >"$TMP/out" 2>&1; then
    fail "invalid configuration was saved"
fi
cmp -s "$CONFIG_FILE" "$TMP/before" || fail "invalid candidate changed the old configuration"
(
    mv() { return 1; }
    if limiter config-save --config-source "$TMP/candidate" --expected-version "$RULES_VERSION" >"$TMP/out" 2>&1; then
        fail "failed atomic replacement succeeded"
    fi
)
cmp -s "$CONFIG_FILE" "$TMP/before" || fail "failed atomic replacement changed the old file"
pass "invalid candidates and failed renames preserve the old configuration"

printf 'PORT_SPEC="8001=10mbit"\n' >"$TMP/first"
printf 'PORT_SPEC="8002=10mbit"\n' >"$TMP/second"
version="$(config_version)"
(
    if limiter config-save --config-source "$TMP/first" --expected-version "$version" >"$TMP/first.out" 2>&1; then
        printf 'saved\n'; else printf 'rejected\n'; fi
) >"$TMP/first.result" &
pid1=$!
(
    if limiter config-save --config-source "$TMP/second" --expected-version "$version" >"$TMP/second.out" 2>&1; then
        printf 'saved\n'; else printf 'rejected\n'; fi
) >"$TMP/second.result" &
pid2=$!
wait "$pid1"; wait "$pid2"
[[ "$(grep -h -c '^saved$' "$TMP/first.result" "$TMP/second.result" | awk '{s+=$1} END{print s}')" == 1 ]] ||
    fail "concurrent writers did not reject one stale edit"
pass "two concurrent edits cannot overwrite each other silently"

(
    source <(sed '$d' "$LIMIT_SCRIPT")
    mkdir -p "$LIMIT_STATE_DIR"
    SPEC_STRING='8080=20mbit'
    parse_spec "$SPEC_STRING"; build_plan
    base_signature >"$(applied_state_file)"
    [[ "$(config_state)" == applied ]] || fail "matching signature was not applied"
    SPEC_STRING='8443=20mbit'
    printf '8443\t8443\t5mbit\n' >"$TMP/rates"
    RATE_FILE="$TMP/rates"
    require_root() { :; }
    ip() { return 0; }
    tc() { fail "pending config touched tc"; }
    if (rate_set) >"$TMP/out" 2>&1; then fail "pending config changed an old class"; fi
    parse_spec "$SPEC_STRING"; build_plan
    [[ "$(config_state)" == pending ]] || fail "modified rule was not marked pending"
)
pass "applied signatures prevent new rules from changing old queues"

(
    source <(sed '$d' "$LIMIT_SCRIPT")
    require_root() { :; }
    EXPECTED_VERSION="stale"
    tc() { fail "stale evaluation touched tc"; }
    RATE_FILE="$TMP/rates"
    if (rate_set) >"$TMP/out" 2>&1; then fail "stale policy version was accepted"; fi
)
pass "policy evaluations cannot apply rates after the source configuration changes"

(
    source <(sed '$d' "$LIMIT_SCRIPT")
    require_root() { :; }
    ip() { return 0; }
    awk() { printf 'call\n' >>"$TMP/awk.calls"; command awk "$@"; }
    tc() {
        [[ "$*" == "class show dev eth0" ]] || fail "unchanged rates dispatched tc"
        for ((id=10;id<210;id++)); do
            printf 'class htb 1:%s parent 1: rate 12Mbit ceil 12Mbit\n' "$id"
        done
    }
    SPEC_STRING='10001-10200=12mbit'
    parse_spec "$SPEC_STRING"; build_plan
    base_signature >"$(applied_state_file)"
    printf '10001\t10200\t12mbit\n' >"$TMP/rates"
    RATE_FILE="$TMP/rates"
    rate_set >"$TMP/out"
    [[ "$(wc -l <"$TMP/awk.calls")" -le 3 ]] || fail "rate checks still spawn per-class awk processes"
    [[ "$(compute_burst 12mbit)" == 30000 && "$(compute_cburst 12mbit)" == 15000 ]] ||
        fail "cached burst calculations changed values"
)
pass "200 unchanged queues use at most three awk calls with unchanged burst values"

(
    printf 'PORT_SPEC="8080=20mbit 9000-9001=50mbit@shared"\n' >"$CONFIG_FILE"
    source <(sed '$d' "$LIMIT_SCRIPT")
    SPEC_STRING='8080=20mbit 9000-9001=50mbit@shared'
    parse_spec "$SPEC_STRING"; build_plan
    base_signature >"$(applied_state_file)"
    tc() { printf 'class htb 1:10 parent 1: rate 5Mbit ceil 5Mbit\nclass htb 1:11 parent 1: rate 7Mbit ceil 7Mbit\n'; }
    [[ "$(effective_rates)" == $'8080\t8080\t5mbit\n9000\t9001\t7mbit' ]] || fail "actual rates came from base config"
)
pass "effective rate reports use live kernel ceilings"

(
    pause_screen() { :; }
    for line in 'deny tcp 99999' 'deny tcp 22 garbage' 'deny tcp 22 form 1.2.3.4' 'backend typo' 'ssh-protect maybe'; do
        printf 'backend nft\nallow tcp 8080\n%s\n' "$line" >"$FW_CONF_FILE"
        if fw_load >"$TMP/out" 2>"$TMP/err"; then fail "invalid firewall line was accepted: $line"; fi
        [[ ${#FW_ACT[@]} == 0 ]] || fail "invalid config kept a partial ruleset"
    done
    FW_EXTRA_RULES='deny tcp 99999'
    FW_CONF_FILE="$TMP/missing-firewall"
    if fw_load >"$TMP/out" 2>"$TMP/err"; then fail "invalid temporary rules were accepted without a config file"; fi
)
pass "bad firewall rules and directives reject the entire file, including temporary rules"

(
    printf 'backend nft\nallow tcp 8080\n' >"$FW_CONF_FILE"
    fw_load
    old="$FW_CONFIG_VERSION"
    printf 'backend nft\nallow tcp 8443\n' >"$TMP/fw.candidate"
    fw_with_lock fw_save_config_locked "$TMP/fw.candidate" "$old"
    cmp -s "$FW_CONF_FILE" "$TMP/fw.candidate" || fail "firewall candidate was not saved"
    if fw_with_lock fw_save_config_locked "$TMP/fw.candidate" "$old" >"$TMP/out" 2>&1; then
        fail "stale firewall writer was accepted"
    fi
    FW_EXPECTED_VERSION="$old"
    fw_nft_apply() { fail "stale firewall confirmation touched the kernel"; }
    if fw_apply_rules >"$TMP/out" 2>&1; then fail "stale firewall confirmation was accepted"; fi
)
pass "firewall saves and menu confirmations reject concurrent configuration changes"

(
    fw_ssh_ports() { printf '22 2222'; }
    fw_client_ip() { printf '%s' "${CLIENT_IP:-}"; }
    fw_nft_apply() { printf 'applied\n' >>"$TMP/firewall.applied"; }
    printf 'backend nft\nssh-protect yes\ndeny tcp 22\n' >"$FW_CONF_FILE"
    CLIENT_IP=""
    if fw_apply_rules >"$TMP/out" 2>"$TMP/err"; then fail "boot-style apply blocked SSH without refusal"; fi
    [[ ! -f "$TMP/firewall.applied" ]] || fail "SSH guard ran after mutation"
    FW_FORCE=1
    fw_apply_rules >"$TMP/out"
    [[ "$(cat "$TMP/firewall.applied")" == applied ]] || fail "explicit override was ignored"
    FW_FORCE=0
    printf 'backend nft\nallow tcp 22\ndeny tcp 2222\n' >"$FW_CONF_FILE"
    if fw_apply_rules >"$TMP/out" 2>"$TMP/err"; then fail "allowing one SSH port protected a different port"; fi
    printf 'backend nft\ndeny udp 22\n' >"$FW_CONF_FILE"
    fw_apply_rules >"$TMP/out"
)
pass "CLI and boot applies protect each SSH TCP port and require explicit override for risky rules"

(
    printf 'PORT_SPEC="10000-10512=12mbit"\n' >"$CONFIG_FILE"
    load_rules
    if acct_capacity_check >"$TMP/out" 2>"$TMP/err"; then fail "513 ports passed the 512-port accounting limit"; fi
    [[ "$(limiter capacity | awk -F'\t' '$1=="ports"{print $2}')" == 513 ]] || fail "capacity report hid the port count"
    printf '1\tschedule\t10000\t10512\t0\t5mbit\t00:00\t23:59\n' >"$POLICY_CONF"
    policy_load; policy_validate_scopes; policy_collect
    printf '1\tmonthly\t10000\t10512\t1000000000\t5mbit\tmonth\t-\n' >"$POLICY_CONF"
    policy_load; policy_validate_scopes
    if policy_collect >"$TMP/out" 2>"$TMP/err"; then fail "usage policies bypassed the accounting capacity check"; fi
)
pass "large ranges remain available for shaping/schedules while usage policies enforce accounting capacity"

(
    printf 'PORT_SPEC="8080=20mbit"\n' >"$CONFIG_FILE"
    printf '1\tmonthly\t8080\t8080\t1000000000\t5mbit\tmonth\t-\n' >"$POLICY_CONF"
    run_root() {
        printf '%s\n' "$*" >>"$TMP/boot.calls"
        case "$1" in systemctl|bash) return 0 ;; *) "$@" ;; esac
    }
    systemctl() { :; }
    fw_installed_self() { printf '%s' "$SELF_PATH"; }
    limit_local() { if [[ "$1" == config-state ]]; then printf 'applied\n'; else bash "$LIMIT_SCRIPT" "$@"; fi; }
    policy_enable
    grep -Fxq 'Requires=limit-ports.service portctl-accounting.service' "$POLICY_SERVICE_FILE" ||
        fail "policy service does not start its dependencies"
    grep -Fxq 'After=network-online.target limit-ports.service portctl-accounting.service' "$POLICY_SERVICE_FILE" ||
        fail "policy ordering is incomplete"
    grep -Fxq 'After=network-online.target limit-ports.service' "$ACCT_SERVICE_FILE" || fail "accounting is not ordered after shaping"
    grep -q 'enable --now limit-ports.service' "$TMP/boot.calls" || fail "base service is not enabled"
    grep -q 'enable --now portctl-accounting.timer' "$TMP/boot.calls" || fail "accounting restore is not enabled"
    grep -q 'enable --now portctl-policy.timer' "$TMP/boot.calls" || fail "policy timer was not enabled"
)
pass "enabling quota policies installs and enables ordered boot dependencies"

(
    printf 'PORT_SPEC="8080=20mbit"\n' >"$CONFIG_FILE"
    printf '1\tmonthly\t8080\t8080\t1000000000\t5mbit\tmonth\t-\n' >"$POLICY_CONF"
    load_rules
    acct_table_exists() { [[ -f "$TMP/recovered" ]]; }
    policy_lock() { mkdir -p "$POLICY_DIR"; }
    acct_setup_locked() { touch "$TMP/recovered"; }
    acct_current() { printf '8080\t0\t0\n'; }
    limit_root() { return "${APPLY_RC:-0}"; }
    if policy_status >"$TMP/out" 2>"$TMP/err"; then fail "read-only status unexpectedly recovered a missing table"; fi
    [[ ! -f "$TMP/recovered" ]] || fail "status changed the kernel"
    policy_tick
    [[ -f "$TMP/recovered" ]] || fail "tick did not recover the missing accounting table"
    grep -q $'\tsuccess\t0' "$POLICY_DIR/last-run.tsv" || fail "successful run was not recorded"
    APPLY_RC=1
    if policy_tick >"$TMP/out" 2>"$TMP/err"; then fail "failed apply returned success"; fi
    grep -q $'\tfailed\t1' "$POLICY_DIR/last-run.tsv" || fail "failed run was not recorded"
    policy_last_run >"$TMP/out"
    grep -q '失败' "$TMP/out" || fail "status hid the failed run"
)
pass "ticks recover missing accounting tables and record outcomes while status stays read-only"

printf 'Passed %s optimization tests.\n' "$passed"
