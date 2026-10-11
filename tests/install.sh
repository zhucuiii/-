#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export FIXTURE="$TMP/server" INSTALL_SHA=1111111111111111111111111111111111111111
export BIN_DIR="$TMP/sbin" CONFIG_DIR="$TMP/default" SYSTEMD_DIR="$TMP/systemd" ALIAS_DIR="$TMP/bin"
mkdir -p "$FIXTURE/config" "$FIXTURE/systemd"
cp "$ROOT/portctl.sh" "$ROOT/policy_engine.sh" "$ROOT/limit_ports.sh" "$FIXTURE/"
cp "$ROOT/config/limit-ports.example" "$FIXTURE/config/"
cp "$ROOT/systemd/limit-ports.service" "$FIXTURE/systemd/"
# Only bypass the privilege gate in this isolated, command-mocked fixture.
sed 's/^\[\[ "${EUID}" -eq 0 \]\]/true/' "$ROOT/install.sh" >"$TMP/installer.sh"
export CURL_TRACE="$TMP/downloads"
curl() {
    local url="" target=""
    while (( $# )); do
        case "$1" in
            -o) target="$2"; shift 2 ;;
            -H|--retry|--connect-timeout|--max-time) shift 2 ;;
            -*) shift ;;
            *) url="$1"; shift ;;
        esac
    done
    printf '%s\n' "$url" >>"$CURL_TRACE"
    if [[ "$url" == https://api.github.com/repos/zhucuiii/-/commits/main ]]; then
        printf '%s\n' "$INSTALL_SHA" >"$target"
        return
    fi
    local prefix="https://raw.githubusercontent.com/zhucuiii/-/$INSTALL_SHA/"
    [[ "$url" == "$prefix"* ]] || return 1
    cp "$FIXTURE/${url#"$prefix"}" "$target"
}
systemctl() { :; }
install() {
    if [[ "${INJECT_INSTALL_FAIL:-0}" == 1 && "${@: -2:1}" == */limit_ports.sh ]]; then
        return 1
    fi
    command install "$@"
}
export -f curl systemctl install
unset RAW_BASE INSTALL_REF REPOSITORY
passed=0
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { passed=$((passed + 1)); printf 'ok %s - %s\n' "$passed" "$1"; }

bash "$TMP/installer.sh" --no-menu >"$TMP/out" 2>"$TMP/err"
for file in portctl.sh policy_engine.sh limit_ports.sh; do
    cmp -s "$BIN_DIR/$file" "$ROOT/$file" || fail "component $file was not installed"
done
[[ "$(grep -c "/$INSTALL_SHA/" "$CURL_TRACE")" -eq 5 ]] || fail "components were not pinned to one commit"
[[ -L "$ALIAS_DIR/zc" || -f "$ALIAS_DIR/zc" ]] || fail "alias was not installed"
pass "installer resolves one commit and installs all matching components"

printf '# existing user config\nPORT_SPEC="8443=9mbit"\n' >"$CONFIG_DIR/limit-ports"
cp "$CONFIG_DIR/limit-ports" "$TMP/config.before"
cp "$BIN_DIR/portctl.sh" "$TMP/portctl.before"
printf '# upgrade marker\n' >>"$FIXTURE/portctl.sh"
export INJECT_INSTALL_FAIL=1
if bash "$TMP/installer.sh" --no-menu >"$TMP/out" 2>"$TMP/err"; then
    fail "injected installation failure was accepted"
fi
cmp -s "$BIN_DIR/portctl.sh" "$TMP/portctl.before" || fail "partial upgrade was not rolled back"
cmp -s "$CONFIG_DIR/limit-ports" "$TMP/config.before" || fail "rollback changed user config"
pass "partial upgrade restores previous components and preserves user config"

INJECT_INSTALL_FAIL=0
cp "$FIXTURE/portctl.sh" "$TMP/valid.script"
printf 'if then\n' >"$FIXTURE/portctl.sh"
if bash "$TMP/installer.sh" --no-menu >"$TMP/out" 2>"$TMP/err"; then fail "invalid Bash was installed"; fi
cmp -s "$BIN_DIR/portctl.sh" "$TMP/portctl.before" || fail "syntax failure touched installed files"
pass "syntax validation rejects malformed downloads before replacing components"

cp "$TMP/valid.script" "$FIXTURE/portctl.sh"
bash "$TMP/installer.sh" --no-menu >"$TMP/out" 2>"$TMP/err"
cmp -s "$BIN_DIR/portctl.sh" "$FIXTURE/portctl.sh" || fail "valid upgrade did not complete"
cmp -s "$CONFIG_DIR/limit-ports" "$TMP/config.before" || fail "upgrade changed user config"
pass "successful upgrades preserve existing configuration"

printf 'Passed %s installer tests.\n' "$passed"
