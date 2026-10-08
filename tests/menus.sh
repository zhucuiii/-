#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export CONFIG_FILE="$TMP/config"
export LIMIT_SCRIPT="$ROOT/limit_ports.sh"
export FW_CONF_FILE="$TMP/firewall.conf"
export FW_STATE_FILE="$TMP/firewall.state"
export ACCT_FILE="$TMP/traffic.tsv"
export ACCT_ERR_FILE="$TMP/acct.err"
source "$ROOT/portctl.sh" --help >/dev/null
trap 'rm -rf "$TMP"' EXIT

passed=0
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { passed=$((passed + 1)); printf 'ok %s - %s\n' "$passed" "$1"; }
pause_screen() { :; }

check_route() (
    local input="$1" expected="$2"
    : >"$TMP/trace"
    record() { printf '%s\n' "$*" >>"$TMP/trace"; }
    add_rule_flow() { record add; }
    change_rule_rate() { record edit-one; }
    change_all_rates() { record edit-all; }
    delete_rules() { record delete; }
    clear_rules() { record clear; }
    show_port_stats() { record realtime; }
    show_traffic_accounting() { record accounting; }
    show_all_port_traffic() { record all-traffic; }
    fw_add_port_flow() { record fw-port; }
    fw_add_ip_flow() { record fw-ip; }
    fw_delete_flow() { record fw-delete; }
    fw_apply_from_menu() { record fw-apply; }
    fw_show_system_rules() { record fw-system; }
    fw_settings_menu() { record fw-settings; }
    fw_clear_flow() { record fw-clear; }
    fw_detect_backend() { printf 'iptables'; }
    fw_autostart_label() { printf 'disabled'; }
    fw_ssh_ports() { printf '22'; }
    fw_client_ip() { :; }
    log_backend() { printf 'none'; }
    log_prompt_lines() { printf '40'; }
    log_emit() { record "log:$1"; }
    log_view_login() { record login; }
    log_follow() { record follow; }
    log_export_flow() { record export; }
    log_vacuum() { record vacuum; }
    show_system_info() { record info; }
    update_script() { record update; }
    uninstall_program() { record uninstall; }
    limit_root() { record "limit:$*"; }
    limit_local() {
        case "$1" in
            rules) : ;;
            *) record "limit-local:$*" ;;
        esac
    }
    run_root() { record "root:$*"; }
    systemctl() {
        case "$1" in
            is-active) printf 'inactive\n'; return 3 ;;
            is-enabled) printf 'disabled\n'; return 1 ;;
            *) fail "unexpected unprivileged systemctl call" ;;
        esac
    }
    main_menu <<<"$input" >"$TMP/menu.out" 2>"$TMP/menu.err"
    [[ "$(cat "$TMP/trace")" == "$expected" ]] ||
        fail "route expected [$expected], got [$(cat "$TMP/trace")]"
    [[ ! -s "$TMP/menu.err" ]] || fail "menu stderr: $(cat "$TMP/menu.err")"
)

check_route $'1\n1\n0\n0' add
pass "limit menu routes to unified add"
check_route $'01\n2\n1\n2\n0\n3\n4\n0\n0' $'edit-one\nedit-all\ndelete\nlimit:apply'
pass "single and bulk rate edits, delete and apply retain their routes"
check_route $'1\n5\n1\n2\n3\n0\n0\n0' $'realtime\naccounting\nall-traffic'
pass "traffic is reachable from the limit menu"
check_route $'02\n1\n2\n3\n0\n0' $'realtime\naccounting\nall-traffic'
pass "traffic is reachable directly from the main menu"
check_route $'1\n6\n1\n2\n3\n0\n0\n0' $'root:tc -s qdisc show dev eth0\nroot:tc -s class show dev eth0\nlimit-local:plan -v\nclear'
pass "tc inspection, execution plan and clear live in advanced tools"
check_route $'03\n1\n1\n1\n2\n2\n3\n0\n0' $'fw-port\nfw-ip\nfw-delete\nfw-apply'
pass "firewall port and IP add flows retain their routes"
check_route $'3\n4\n1\n2\n3\n0\n0\n0' $'fw-system\nfw-settings\nfw-clear'
pass "firewall settings, actual rules and clear remain reachable"
check_route $'04\n1\n2\n3\n4\n5\n6\n0\n0' \
    $'root:systemctl start limit-ports.service\nroot:systemctl restart limit-ports.service\nroot:systemctl stop limit-ports.service\nroot:systemctl enable limit-ports.service\nroot:systemctl disable limit-ports.service\nroot:systemctl --no-pager --full status limit-ports.service'
pass "service start, stop and autostart are independent operations"
check_route $'05\n1\n1\n2\n0\n2\n3\n4\n5\n0\n0' \
    $'log:限速服务日志（limit-ports.service）\nlog:防火墙服务日志（portctl-firewall.service）\nlog:系统错误日志\nlogin\nfollow\nexport'
pass "common logs and diagnostic export remain reachable"
check_route $'5\n6\n1\n2\n3\n0\n0\n0' $'log:内核日志\nlog:全部系统日志\nvacuum'
pass "kernel logs and cleanup move to advanced tools"
check_route $'06\n1\n2\n3\n0\n0' $'info\nupdate\nuninstall'
pass "maintenance contains system info, update and uninstall"
check_route $'00\n1\n0\n2\n0\n3\n0\n4\n0\n5\n0\n6\n0\n0' ""
pass "refresh and all top-level returns have no side effects"
if head -n 25 "$TMP/menu.out" | grep -q '卸载程序'; then
    fail "uninstall leaked back into the main menu"
fi
pass "uninstall is not a main-menu shortcut"
check_route $'1\n9\n0\n0' ""
pass "invalid input does not dispatch an unrelated action"

for menu in main_menu show_limit_menu show_traffic_menu show_rule_edit_menu \
    show_limit_advanced_menu show_firewall_menu show_firewall_advanced_menu \
    fw_add_menu fw_settings_menu show_service_menu show_logs_menu \
    show_service_logs_menu show_logs_advanced_menu show_maintenance_menu; do
    (
        fw_detect_backend() { printf 'iptables'; }
        fw_ssh_ports() { printf '22'; }
        fw_client_ip() { :; }
        "$menu" </dev/null >"$TMP/eof.out" 2>"$TMP/eof.err"
    )
done
pass "all reorganized menus handle end-of-input without looping"

[[ "$(prompt_port_range <<<8080 2>/dev/null)" == $'8080\t8080' ]] || fail "single port input"
[[ "$(prompt_port_range <<<10001-10200 2>/dev/null)" == $'10001\t10200' ]] || fail "range input"
[[ "$(prompt_port_range <<<00080-00081 2>/dev/null)" == $'80\t81' ]] || fail "decimal port normalization"
[[ "$(prompt_port_range <<<1-65535 2>/dev/null)" == $'1\t65535' ]] || fail "boundary ports"
pass "unified input handles single ports, ranges and decimal leading zeros"
for invalid in 0 65536 20-10 1-65536 -1 999999999999999999999 '1;echo bad' 0-0 foo; do
    if prompt_port_range <<<"$invalid" >"$TMP/out" 2>"$TMP/err"; then
        fail "invalid port range accepted: $invalid"
    fi
done
[[ "$(prompt_port_range <<<$'invalid\n8080' 2>/dev/null)" == $'8080\t8080' ]] || fail "invalid input retry"
if prompt_port_range <<<"" >/dev/null 2>&1; then fail "empty input should cancel"; fi
pass "invalid port input retries safely and blank input cancels"
(
    pause_screen() { :; }
    add_rule_flow <<<"" >/dev/null 2>/dev/null
    add_rule_flow <<<$'8080\n' >/dev/null 2>/dev/null
    change_rule_rate <<<"" >/dev/null
)
pass "cancelling add and rate input returns successfully under errexit"

# Exercise actual config writes, isolated to the temporary directory.
run_root() { "$@"; }
printf '# preserved\nNIC="eth0"\nSPEED="12mbit"\nPORT_SPEC="8080=12mbit 9000-9002=30mbit@shared"\n' >"$CONFIG_FILE"
change_rule_rate <<<$'1\n25\n1\nn' >"$TMP/out" 2>"$TMP/err"
CONFIG_FILE="$CONFIG_FILE" bash "$LIMIT_SCRIPT" rules >"$TMP/rules"
grep -Fq $'8080\t8080\t25mbit\tper-port' "$TMP/rules" || fail "selected rate not saved"
grep -Fq $'9000\t9002\t30mbit\tshared' "$TMP/rules" || fail "unselected shared rule changed"
grep -Fxq '# preserved' "$CONFIG_FILE" || fail "config comments lost"
pass "single-rule editing preserves other rules, modes and config comments"
change_rule_rate <<<$'2\n40\n1\nn' >"$TMP/out" 2>"$TMP/err"
CONFIG_FILE="$CONFIG_FILE" bash "$LIMIT_SCRIPT" rules >"$TMP/rules"
grep -Fq $'9000\t9002\t40mbit\tshared' "$TMP/rules" || fail "selected shared mode lost"
pass "editing a shared rule preserves shared mode"
cp "$CONFIG_FILE" "$TMP/before"
change_rule_rate <<<99 >"$TMP/out" 2>"$TMP/err"
cmp -s "$CONFIG_FILE" "$TMP/before" || fail "invalid selection modified config"
pass "invalid rule selection cannot change config"
add_rule_flow <<<$'8443\n10\n1\nn' >"$TMP/out" 2>"$TMP/err"
grep -Fq '8443=10mbit' "$CONFIG_FILE" || fail "single-port add did not save"
add_rule_flow <<<$'10001-10003\n20\n1\n2\nn' >"$TMP/out" 2>"$TMP/err"
grep -Fq '10001-10003=20mbit@shared' "$CONFIG_FILE" || fail "shared-range add did not save"
pass "unified add saves single ports and shared ranges"
cp "$CONFIG_FILE" "$TMP/before"
add_rule_flow <<<$'9001\n10\n1\nn' >"$TMP/out" 2>"$TMP/err"
cmp -s "$CONFIG_FILE" "$TMP/before" || fail "declined conflict changed config"
pass "overlap replacement still requires confirmation"
clear_rules <<<NO >"$TMP/out" 2>"$TMP/err"
cmp -s "$CONFIG_FILE" "$TMP/before" || fail "declined clear changed config"
pass "clear still requires YES"
uninstall_program <<<NO >"$TMP/out" 2>"$TMP/err"
cmp -s "$CONFIG_FILE" "$TMP/before" || fail "declined uninstall changed config"
pass "uninstall still requires YES"

(
    download_file() { printf '#!/bin/bash\nexit 1\n' >"$2"; }
    update_script >"$TMP/out" 2>"$TMP/err"
    grep -Fq '安装失败' "$TMP/out" || fail "failed installer missing error"
    if grep -Fq '更新完成' "$TMP/out"; then fail "failed installer reported success"; fi
)
pass "failed updates do not report success or exit the menu"

(
    # Large output must not trigger SIGPIPE in the top-N rendering pipeline.
    acct_available() { return 0; }
    acct_table_exists() { return 0; }
    acct_autostart_label() { printf 'disabled'; }
    run_root() {
        local p
        for ((p = 10001; p <= 10400; p++)); do
            printf '300\t%s\t100\t200\t12mbit\n' "$p"
        done
        printf '#TOTAL\t40000\t80000\n'
    }
    show_traffic_accounting <<<0 >"$TMP/out" 2>"$TMP/err"
    grep -Fq '400 个，只显示合计最高的 30 个' "$TMP/out" ||
        fail "large accounting list did not render completely"
    [[ ! -s "$TMP/err" ]] || fail "large accounting render produced stderr"
)
pass "large accounting lists truncate display without terminating the menu"

printf 'Passed %s menu tests.\n' "$passed"
