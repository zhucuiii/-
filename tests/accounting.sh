#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export CONFIG_FILE="$TMP/config"
export LIMIT_SCRIPT="$ROOT/limit_ports.sh"
export ACCT_DIR="$TMP"
export ACCT_FILE="$TMP/traffic.tsv"
export ACCT_TABLE="portctl_acct"
export ACCT_ERR_FILE="$TMP/acct.err"
export NFT_CALLS="$TMP/nft.calls"
export NFT_SCENARIO="missing"
export NFT_UP_BYTES=30 NFT_DOWN_BYTES=40 NFT_GENERATION="" NFT_SCOPE=""
printf 'PORT_SPEC="8080=12mbit"\n' >"$CONFIG_FILE"

# Load the functions without opening the interactive menu.
source "$ROOT/portctl.sh" --help >/dev/null
trap 'rm -rf "$TMP"' EXIT
load_rules

nft() {
    printf '%s\n' "$*" >>"$NFT_CALLS"
    case "$*" in
        "list tables inet")
            case "$NFT_SCENARIO" in
                denied|tables-error)
                    printf 'Operation not permitted\n' >&2
                    return 1
                    ;;
                read-error|ready|incomplete|wrong-port|malformed)
                    printf 'table inet portctl_acct\n'
                    ;;
                *)
                    printf 'table inet filter\ntable inet portctl_acct_backup\n'
                    ;;
            esac
            ;;
        "list counters table inet portctl_acct"|"reset counters table inet portctl_acct")
            case "$NFT_SCENARIO" in
                ready|wrong-port|malformed)
                    local port=8080 up="$NFT_UP_BYTES"
                    [[ "$NFT_SCENARIO" != wrong-port ]] || port=8443
                    [[ "$NFT_SCENARIO" != malformed ]] || up=invalid
                    printf 'table inet portctl_acct {\n'
                    if [[ -n "$NFT_SCOPE" ]]; then
                        printf '    counter scope_%s {\n        packets 0 bytes 0\n    }\n' "$NFT_SCOPE"
                    fi
                    if [[ -n "$NFT_GENERATION" ]]; then
                        printf '    counter generation_%s {\n        packets 0 bytes 0\n    }\n' "$NFT_GENERATION"
                    fi
                    printf '    counter up_%s {\n        packets 1 bytes %s\n    }\n' "$port" "$up"
                    printf '    counter down_%s {\n        packets 2 bytes %s\n    }\n}\n' "$port" "$NFT_DOWN_BYTES"
                    ;;
                incomplete)
                    printf 'table inet portctl_acct {\n'
                    printf '    counter up_8080 {\n        packets 1 bytes 30\n    }\n}\n'
                    ;;
                denied)
                    printf 'Operation not permitted\n' >&2
                    return 1
                    ;;
                read-error)
                    printf 'Counter read failed\n' >&2
                    return 1
                    ;;
                *)
                    printf 'Error: No such file or directory\n' >&2
                    return 1
                    ;;
            esac
            ;;
        "list table inet portctl_acct")
            [[ "$NFT_SCENARIO" == ready || "$NFT_SCENARIO" == read-error || "$NFT_SCENARIO" == incomplete ]]
            ;;
        *)
            printf 'Unexpected nft operation: %s\n' "$*" >&2
            return 99
            ;;
    esac
}
export -f nft

passed=0
pass() {
    passed=$((passed + 1))
    printf 'ok %s - %s\n' "$passed" "$1"
}
fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}
assert_output() {
    [[ "$(sed '/^#SCOPE/d' "$TMP/out")" == "$1" ]] || fail "unexpected output: $(cat "$TMP/out")"
}
assert_quiet() {
    [[ ! -s "$TMP/err" ]] || fail "unexpected stderr: $(cat "$TMP/err")"
}
assert_read_failure() {
    if acct_read_counters "${1:-read}" >"$TMP/out" 2>"$TMP/err"; then
        fail "counter read unexpectedly succeeded ($NFT_SCENARIO)"
    fi
    [[ ! -s "$TMP/out" ]] || fail "failed read returned partial data"
    grep -Fq '[acct]' "$TMP/err" || fail "missing failure diagnostic"
}

NFT_SCENARIO=missing
bash "$ROOT/portctl.sh" acct-show >"$TMP/out" 2>"$TMP/err"
assert_output $'0\t8080\t0\t0\t12mbit\n#TOTAL\t0\t0'
assert_quiet
pass "fresh setup has zero totals without a missing-table warning"

printf '8080\t100\t200\n' >"$ACCT_FILE"
bash "$ROOT/portctl.sh" acct-show >"$TMP/out" 2>"$TMP/err"
assert_output $'300\t8080\t100\t200\t12mbit\n#TOTAL\t100\t200'
assert_quiet
[[ "$(cat "$ACCT_FILE")" == $'8080\t100\t200' ]] || fail "saved totals were modified"
pass "absent table preserves saved totals, including with a similarly named table"

NFT_SCENARIO=ready
: >"$NFT_CALLS"
bash "$ROOT/portctl.sh" acct-show >"$TMP/out" 2>"$TMP/err"
assert_output $'370\t8080\t130\t240\t12mbit\n#TOTAL\t130\t240'
assert_quiet
[[ "$(cat "$NFT_CALLS")" == "list counters table inet portctl_acct" ]] ||
    fail "successful reads should not need a fallback table listing"
pass "live counters still merge with saved totals"

NFT_SCENARIO=denied
assert_read_failure
grep -Fq 'Operation not permitted' "$TMP/err" || fail "permission error was hidden"
pass "permission errors remain visible"

if bash "$ROOT/portctl.sh" acct-show >"$TMP/out" 2>"$TMP/err"; then
    fail "acct-show should return failure for permission errors"
fi
assert_output $'300\t8080\t100\t200\t12mbit\n#TOTAL\t100\t200'
grep -Fq 'Operation not permitted' "$TMP/err" || fail "CLI permission error was hidden"
pass "acct-show propagates failures while retaining saved totals"

NFT_SCENARIO=read-error
assert_read_failure
grep -Fq 'Counter read failed' "$TMP/err" || fail "counter error was hidden"
pass "an existing table with unreadable counters still fails"

NFT_SCENARIO=tables-error
assert_read_failure
pass "failed table enumeration is not treated as an absent table"

NFT_SCENARIO=incomplete
assert_read_failure
pass "incomplete counter sets are still rejected"

NFT_SCENARIO=wrong-port
assert_read_failure
pass "a different port with the same counter count is rejected"
NFT_SCENARIO=malformed
assert_read_failure
pass "non-numeric byte counts cannot corrupt totals"

NFT_SCENARIO=missing
CONFIG_FILE="$TMP/no-config" bash "$ROOT/portctl.sh" acct-show >"$TMP/out" 2>"$TMP/err"
assert_output $'#TOTAL\t0\t0'
assert_quiet
pass "no configured ports is a normal empty state"

# The menu must remain usable after a failed privileged child command.
run_root() {
    "$@"
}
NFT_SCENARIO=missing
CONFIG_FILE="$TMP/no-config" show_traffic_accounting <<<0 >"$TMP/out" 2>"$TMP/err"
grep -Fq '当前没有端口规则' "$TMP/out" || fail "menu omitted the setup hint"
if grep -Fq '[acct]' "$TMP/out"; then
    fail "menu displayed a missing-table diagnostic"
fi
assert_quiet
pass "fresh menu displays the setup hint without an error"

NFT_SCENARIO=denied
show_traffic_accounting <<<0 >"$TMP/out" 2>"$TMP/err"
grep -Fq 'Operation not permitted' "$TMP/out" || fail "menu hid the failure"
grep -Fq '0.' "$TMP/out" || fail "menu exited before rendering its controls"
assert_quiet
pass "menu survives a failed accounting read"

run_root() {
    printf 'Child command failed\n' >&2
    return 1
}
show_traffic_accounting <<<0 >"$TMP/out" 2>"$TMP/err"
grep -Fq 'Child command failed' "$TMP/out" || fail "menu hid the child failure"
if grep -Fq '当前没有端口规则' "$TMP/out"; then
    fail "menu mistook a failed read for missing port rules"
fi
if grep -Fq '还没有任何一个端口产生过流量' "$TMP/out"; then
    fail "menu mistook a failed read for zero traffic"
fi
pass "a failed child command is not presented as an empty configuration"

unset -f run_root
printf 'PORT_SPEC="not-a-port"\n' >"$CONFIG_FILE"
if bash "$ROOT/portctl.sh" acct-show >"$TMP/out" 2>"$TMP/err"; then
    fail "acct-show should reject invalid port rules"
fi
[[ ! -s "$TMP/out" && -s "$TMP/err" ]] || fail "invalid rules were presented as empty totals"
pass "invalid port rules are diagnosed instead of silently producing zero totals"

printf 'PORT_SPEC="8080=12mbit"\n' >"$CONFIG_FILE"
load_rules
NFT_SCENARIO=ready
printf '8080\t100\t200\n' >"$ACCT_FILE"
: >"$NFT_CALLS"
acct_sample >"$TMP/out" 2>"$TMP/err"
[[ "$(acct_current)" == $'8080\t130\t240' ]] || fail "sample double-counted the live counters"
acct_sample >"$TMP/out" 2>"$TMP/err"
[[ "$(acct_current)" == $'8080\t130\t240' ]] || fail "repeated sample changed unchanged totals"
if grep -q '^reset ' "$NFT_CALLS"; then fail "sampling reset kernel counters"; fi
pass "sampling persists raw baselines without resetting or double-counting counters"

NFT_UP_BYTES=50 NFT_DOWN_BYTES=60
cp "$ACCT_FILE" "$TMP/before"
(
    mv() { return 1; }
    if acct_sample >"$TMP/out" 2>"$TMP/err"; then fail "failed disk commit succeeded"; fi
)
cmp -s "$ACCT_FILE" "$TMP/before" || fail "failed commit changed saved totals"
[[ "$(acct_current)" == $'8080\t150\t260' ]] || fail "failed commit lost live traffic"
acct_sample >"$TMP/out" 2>"$TMP/err"
[[ "$(acct_current)" == $'8080\t150\t260' ]] || fail "retry did not recover the unsaved delta"
pass "failed disk commits retain live bytes and retries save exactly once"

NFT_GENERATION=second NFT_UP_BYTES=300 NFT_DOWN_BYTES=400
acct_sample >"$TMP/out" 2>"$TMP/err"
[[ "$(acct_current)" == $'8080\t450\t660' ]] || fail "new counter generation reused the old baseline"
pass "replaced tables count new traffic even when counters overtake the old snapshot"

acct_reset >"$TMP/out" 2>"$TMP/err"
[[ "$(acct_current)" == $'8080\t0\t0' ]] || fail "reset did not zero logical totals"
NFT_UP_BYTES=330 NFT_DOWN_BYTES=410
[[ "$(acct_current)" == $'8080\t30\t10' ]] || fail "post-reset traffic used the wrong baseline"
if grep -q '^reset ' "$NFT_CALLS"; then fail "logical reset cleared kernel counters"; fi
pass "logical reset preserves counter baselines and counts subsequent traffic"

for scope in all local forward; do
    ACCT_SCOPE="$scope"
    acct_build_script >"$TMP/rules.nft"
    grep -q "counter scope_$scope" "$TMP/rules.nft" || fail "missing scope metadata"
    case "$scope" in
        all) grep -q 'hook prerouting priority -150' "$TMP/rules.nft" || fail "legacy hook changed" ;;
        local) grep -q 'hook input priority -150' "$TMP/rules.nft" || fail "local ingress not input"
               grep -q 'hook output priority -150' "$TMP/rules.nft" || fail "local egress not output" ;;
        forward) [[ "$(grep -c 'hook forward priority -150' "$TMP/rules.nft")" == 2 ]] || fail "forward traffic not isolated" ;;
    esac
done
pass "accounting scopes generate explicit metadata and routing hooks"

ACCT_SCOPE=local NFT_SCOPE=all
assert_read_failure
ACCT_SCOPE=local NFT_SCOPE=local
acct_read_counters >"$TMP/out"
grep -Fxq $'#SCOPE\tlocal' "$TMP/out" || fail "live scope missing"
acct_sample
grep -Fxq $'#SCOPE\tmixed' "$ACCT_FILE" || fail "scope switch hid historical accounting range"
acct_reset
grep -Fxq $'#SCOPE\tlocal' "$ACCT_FILE" || fail "reset did not start a new scope history"
NFT_SCOPE=forward
assert_read_failure
ACCT_SKIP_EXPECTED=1 acct_read_counters >"$TMP/out"
grep -Fxq $'#SCOPE\tforward' "$TMP/out" || fail "migration cannot sample old scope"
ACCT_SCOPE=invalid
if acct_build_script >"$TMP/out" 2>"$TMP/err"; then fail "invalid accounting scope accepted"; fi
pass "scope mismatches refuse sampling while explicit migrations retain labeled history"

printf 'Passed %s accounting tests.\n' "$passed"
