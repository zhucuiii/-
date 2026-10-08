#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export CONFIG_FILE="$TMP/config"
export POLICY_CONF="$TMP/policies.tsv"
export POLICY_DIR="$TMP/state"
export POLICY_STATE="$TMP/state/state.tsv"
export ACCT_DIR="$TMP/acct"
export ACCT_FILE="$TMP/acct/traffic.tsv"
export LIMIT_SCRIPT="$ROOT/limit_ports.sh"
printf 'PORT_SPEC="8080=100mbit 9000-9002=50mbit@shared"\n' >"$CONFIG_FILE"
source "$ROOT/portctl.sh" --help >/dev/null
source "$ROOT/policy_engine.sh"
load_rules

passed=0
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { passed=$((passed + 1)); printf 'ok %s - %s\n' "$passed" "$1"; }

policy_now() { printf '1764547200'; } # 2025-12-01 00:00:00 UTC
policy_lock() { mkdir -p "$POLICY_DIR"; }
policy_load_state() {
    PS_PERIOD=() PS_LAST=() PS_USED=() PS_UNTIL=() PS_EXEMPT=()
}
policy_save_state() { :; }
acct_table_exists() { return 0; }
acct_current() {
    printf '8080\t6000000000\t0\n'
    printf '9000\t1000000000\t0\n9001\t1000000000\t0\n9002\t1000000000\t0\n'
}
acct_with_lock() { "$@"; }
limit_root() {
    printf '%s\n' "$*" >>"$TMP/applied"
}

cat >"$POLICY_CONF" <<'EOF'
1	monthly	8080	8080	5000000000	10mbit	month	-
2	usage	9000	9002	2000000000	5mbit	manual	0
3	schedule	8080	8080	0	20mbit	00:00	06:00
EOF

policy_load
policy_validate_scopes
[[ "${#POLICY_IDS[@]}" == 3 ]] || fail "policy count"
pass "policy file loads and scopes match base rules"

PS_PERIOD[1]="2025-12" PS_LAST[1]=0 PS_USED[1]=0 PS_UNTIL[1]=0 PS_EXEMPT[1]=0
PS_PERIOD[2]="2025-12" PS_LAST[2]=0 PS_USED[2]=0 PS_UNTIL[2]=0 PS_EXEMPT[2]=0
policy_collect
policy_evaluate "$(policy_now)"
grep -q $'^1\tmonthly\t8080-8080\t6000000000\t5000000000\t1' <<<"$POLICY_ROWS" ||
    fail "monthly quota did not trigger"
grep -q $'^2\tusage\t9000-9002\t3000000000\t2000000000\t1' <<<"$POLICY_ROWS" ||
    fail "usage trigger did not trigger"
grep -q $'^8080\t8080\t10mbit' <<<"$POLICY_EFFECTIVE" ||
    fail "strictest effective rate missing for monthly rule"
grep -q $'^9000\t9002\t5mbit' <<<"$POLICY_EFFECTIVE" ||
    fail "usage effective rate missing"
pass "usage and monthly policies choose the strictest active rate"

cat >"$POLICY_CONF" <<'EOF'
1	schedule	8080	8080	0	20mbit	00:00	23:59
EOF
policy_load
policy_collect
policy_evaluate "$(policy_now)"
grep -q $'^8080\t8080\t20mbit' <<<"$POLICY_EFFECTIVE" ||
    fail "schedule policy did not activate"
pass "daily schedule activates inside its window"

cat >"$POLICY_CONF" <<'EOF'
1	usage	8080	8080	1000000000	5mbit	duration	3600
EOF
policy_load
policy_collect
policy_evaluate "$(policy_now)"
grep -q $'^1\tusage\t8080-8080\t6000000000\t1000000000\t1' <<<"$POLICY_ROWS" ||
    fail "duration policy did not trigger"
pass "temporary usage policy records its active deadline"

cat >"$POLICY_CONF" <<'EOF'
1	usage	8080	8080	1000000000	5mbit	manual	0
EOF
policy_load
PS_PERIOD[1]="2025-12" PS_LAST[1]=6000000000 PS_USED[1]=6000000000 PS_UNTIL[1]=1 PS_EXEMPT[1]=0
policy_collect
policy_release 1
policy_load
policy_load_state
policy_collect
policy_evaluate "$(policy_now)"
grep -q $'^8080\t8080\t100mbit' <<<"$POLICY_EFFECTIVE" ||
    fail "manual release did not restore base rate"
pass "manual release restores the base rate"

if policy_load <<<'' 2>/dev/null; then :; fi
cat >"$POLICY_CONF" <<'EOF'
1	schedule	8080	8080	0	20mbit	08:00	08:00
EOF
if policy_load 2>"$TMP/error"; then fail "invalid schedule accepted"; fi
pass "invalid schedule is rejected"

printf 'Passed %s policy tests.\n' "$passed"
