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
                read-error|ready|incomplete)
                    printf 'table inet portctl_acct\n'
                    ;;
                *)
                    printf 'table inet filter\ntable inet portctl_acct_backup\n'
                    ;;
            esac
            ;;
        "list counters table inet portctl_acct"|"reset counters table inet portctl_acct")
            case "$NFT_SCENARIO" in
                ready)
                    printf 'table inet portctl_acct {\n'
                    printf '    counter up_8080 {\n        packets 1 bytes 30\n    }\n'
                    printf '    counter down_8080 {\n        packets 2 bytes 40\n    }\n}\n'
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
    [[ "$(cat "$TMP/out")" == "$1" ]] || fail "unexpected output: $(cat "$TMP/out")"
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

NFT_SCENARIO=missing
: >"$NFT_CALLS"
assert_read_failure reset
[[ "$(cat "$NFT_CALLS")" == "reset counters table inet portctl_acct" ]] ||
    fail "reset should not use the read-only fallback"
pass "missing-table reset remains a failure"

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

printf 'Passed %s accounting tests.\n' "$passed"
