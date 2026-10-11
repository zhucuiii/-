#!/usr/bin/env bash
# Run as root in a disposable network namespace, never the host namespace.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
[[ "$EUID" -eq 0 && "${PORTCTL_TEST_NETNS:-}" == 1 ]] || {
    printf 'Run with: sudo unshare -n env PORTCTL_TEST_NETNS=1 bash tests/integration.sh\n' >&2
    exit 1
}
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export CONFIG_FILE="$TMP/config" LIMIT_SCRIPT="$ROOT/limit_ports.sh" LIMIT_LOCK_DIR="$TMP/locks"
export ACCT_DIR="$TMP/accounting" ACCT_FILE="$TMP/accounting/traffic.tsv"
export FW_LOCK_FILE="$TMP/firewall.lock" FW_CONF_FILE="$TMP/firewall.conf"
cat >"$CONFIG_FILE" <<'EOF'
NIC="pctest0"
PORT_SPEC="10001-10003=12mbit 20000-20001=50mbit@shared"
FILTER_KIND="flower"
IPV6_MODE="yes"
PRECHECK="yes"
EOF
passed=0
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { passed=$((passed + 1)); printf 'ok %s - %s\n' "$passed" "$1"; }

ip link set lo up
ip link add pctest0 type dummy
ip link set pctest0 up
ip addr add 192.0.2.1/24 dev pctest0
ip -6 addr add fd00::1/64 dev pctest0
bash "$LIMIT_SCRIPT" apply
filters="$(tc filter show dev pctest0 parent 1:)"
grep -q 'protocol ip ' <<<"$filters" || fail "IPv4 filters missing"
grep -q 'protocol ipv6 ' <<<"$filters" || fail "IPv6 filters missing"
printf '10001\t10003\t5mbit\n20000\t20001\t7mbit\n' >"$TMP/rates"
bash "$LIMIT_SCRIPT" rate-set --rate-file "$TMP/rates"
classes="$(tc class show dev pctest0)"
for id in 10 11 12; do
    grep -Eq "class htb 1:$id .*rate 5Mbit ceil 5Mbit" <<<"$classes" || fail "independent class $id did not change"
done
grep -Eq 'class htb 1:13 .*rate 7Mbit ceil 7Mbit' <<<"$classes" || fail "shared class did not change"
bash "$LIMIT_SCRIPT" rate-set --rate-file "$TMP/rates" >"$TMP/unchanged"
grep -q '无需更新队列' "$TMP/unchanged" || fail "unchanged rates were rewritten"
pass "real tc installs IPv4/IPv6 filters and updates independent/shared policies"

source "$ROOT/portctl.sh" --help >/dev/null
trap 'rm -rf "$TMP"' EXIT
load_rules
acct_setup
printf 'sample\n' >/dev/udp/127.0.0.1/10001
printf 'sample6\n' >/dev/udp/::1/10002
before="$(acct_current)"
awk -F'\t' '$1==10001 && $2>0 {found=1} END {exit !found}' <<<"$before" || fail "IPv4 upload not counted"
awk -F'\t' '$1==10002 && $2>0 {found=1} END {exit !found}' <<<"$before" || fail "IPv6 upload not counted"
acct_sample
[[ "$(acct_current)" == "$before" ]] || fail "sampling changed real totals"
acct_sample
[[ "$(acct_current)" == "$before" ]] || fail "repeat sampling double-counted"
acct_setup
[[ "$(acct_current)" == "$before" ]] || fail "table rebuild lost persisted totals"
printf 'more\n' >/dev/udp/127.0.0.1/10001
after="$(acct_current)"
[[ "$after" != "$before" ]] || fail "new generation was not counted"
acct_reset
awk -F'\t' '$2!=0 || $3!=0 {bad=1} END {exit bad}' <<<"$(acct_current)" || fail "logical reset failed"
pass "real nft counters persist once, survive rebuilds, and reset logical totals"

FW_ACT=(deny) FW_PROTO=(tcp) FW_PSTART=(3306) FW_PEND=(3306) FW_SRC=("")
fw_nft_apply
nft list table inet portctl >"$TMP/nft.before"
FW_SRC=("invalid-address")
if fw_nft_apply >"$TMP/error" 2>&1; then fail "invalid nft replacement succeeded"; fi
nft list table inet portctl >"$TMP/nft.after"
cmp -s "$TMP/nft.before" "$TMP/nft.after" || fail "failed nft precheck changed the old table"
pass "real nft firewall replacement preserves the old table on validation failure"

FW_SRC=("")
iptables -N KEEP_ME
iptables -A KEEP_ME -j ACCEPT
ip6tables -N KEEP_ME
ip6tables -A KEEP_ME -j ACCEPT
fw_iptables_apply
iptables -C PORTCTL -m conntrack --ctstate NEW -p tcp --dport 3306 -j DROP
ip6tables -C PORTCTL -m conntrack --ctstate NEW -p tcp --dport 3306 -j DROP
FW_SRC=("invalid-address")
if fw_iptables_apply >"$TMP/error" 2>&1; then fail "invalid iptables replacement succeeded"; fi
iptables -C PORTCTL -m conntrack --ctstate NEW -p tcp --dport 3306 -j DROP
iptables -C KEEP_ME -j ACCEPT
ip6tables -C KEEP_ME -j ACCEPT
pass "real iptables restore updates both families and preserves existing chains on errors"

printf 'Passed %s Linux integration tests.\n' "$passed"
