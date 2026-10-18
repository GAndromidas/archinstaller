#!/usr/bin/env bash
# Hermetic unit tests for the SSH Include-repair logic in
# scripts/modules/system_services.sh (harden_sshd_restore_include).
#
# Regression incentive: the "Include already present and first" branch was
# once inverted, which caused (a) a false warning + pointless rewrite on
# every CLEAN rerun, and (b) a false "already repaired" no-op on genuinely
# DIRTY configs. These tests pin all four outcomes with a sudo shim.
#
# Needs no root: sudo is stubbed to run the same tools unprivileged, and
# the main sshd_config path is redirected into the fixture directory via
# SSHD_MAIN_CONFIG. Run with the suite: bash tests/integration.sh
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FX="$(mktemp -d /tmp/opencode/unit_ssh.XXXXXX)"
trap 'rm -rf "$FX"' EXIT
export INSTALL_LOG="$FX/test.log"
export SSHD_MAIN_CONFIG="$FX/sshd_config"
PASS=0; FAIL=0
assert_contains() {
  local name="${1:-}" hay="${2:-}" needle="${3:-}"
  if [[ "$hay" == *"$needle"* ]]; then PASS=$((PASS+1)); echo "PASS: $name";
  else FAIL=$((FAIL+1)); echo "FAIL: $name — '$needle' not in: ${hay:0:200}"; fi
}
assert_eq() {
  local name="${1:-}" got="${2:-}" want="${3:-}"
  if [[ "$got" == "$want" ]]; then PASS=$((PASS+1)); echo "PASS: $name";
  else FAIL=$((FAIL+1)); echo "FAIL: $name — got '$got', want '$want'"; fi
}

# --- sudo shim: drop -n, run the real tool unprivileged (fixtures are ours) ---
SSHD_T_RC="${SSHD_T_RC:-0}"
sudo() {
  [[ "${1:-}" == "-n" ]] && shift
  case "${1:-}" in
    grep) command grep "${@:2}" ;;
    awk)  command awk "${@:2}" ;;
    cp)   command cp "${@:2}" ;;
    sshd) [[ "${2:-}" == "-t" ]] && return "$SSHD_T_RC" || command sshd "${@:2}" ;;
    *) command "$@" ;;
  esac
}
export -f sudo

# Source the module: log_* come from core.sh; module has no top-level code.
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib/core.sh" >/dev/null 2>&1
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/modules/system_services.sh" >/dev/null 2>&1

# --- fixtures ---
cat > "$FX/clean.conf" <<EOF
# Added by archinstaller — enables sshd_config.d drop-ins (managed)
Include /etc/ssh/sshd_config.d/*.conf
PasswordAuthentication yes
EOF
cat > "$FX/dirty.conf" <<EOF
PermitRootLogin yes
# Added by archinstaller — enables sshd_config.d drop-ins (managed)
Include /etc/ssh/sshd_config.d/*.conf
PasswordAuthentication yes
EOF
cat > "$FX/noinclude.conf" <<EOF
# Managed by archinstaller test
PasswordAuthentication yes
EOF

# 1. CLEAN: Include already first → info, no rewrite, no backup
cp "$FX/clean.conf" "$SSHD_MAIN_CONFIG"
out=$(harden_sshd_restore_include 2>&1)
rc=$?
assert_contains "clean-info" "$out" "already present and first"
assert_eq "clean-rc" "$rc" "0"
assert_eq "clean-no-backups" "$(ls "$FX"/sshd_config.backup.* 2>/dev/null | wc -l)" "0"
assert_eq "clean-untouched" "$(head -1 "$SSHD_MAIN_CONFIG" | cut -c1-4)" "# Ad" || true

# 2. DIRTY: managed key above Include → warning + repair + backup
cp "$FX/dirty.conf" "$SSHD_MAIN_CONFIG"
out=$(harden_sshd_restore_include 2>&1)
rc=$?
assert_contains "dirty-warning" "$out" "Managed SSH setting precedes Include"
assert_contains "dirty-forensics" "$(cat "$INSTALL_LOG" 2>/dev/null)" "Managed keys above Include"
assert_contains "dirty-success" "$out" "Include in $SSHD_MAIN_CONFIG fixed"
assert_eq "dirty-rc" "$rc" "0"
assert_eq "dirty-repair" "$(grep -c '^Include /etc/ssh/sshd_config.d' "$SSHD_MAIN_CONFIG")" "1"
# The managed key must now be BELOW the Include (first-obtained goes to the
# drop-in); its exact line number depends on where we spliced it.
_prl_line=$(sudo awk '$1=="PermitRootLogin" {print NR}' "$SSHD_MAIN_CONFIG")
_prl_line=${_prl_line%%[^0-9]*}; [[ -n "$_prl_line" ]] || _prl_line=0
_inc_line=$(sudo awk '$1=="Include" {print NR}' "$SSHD_MAIN_CONFIG")
_inc_line=${_inc_line%%[^0-9]*}; [[ -n "$_inc_line" ]] || _inc_line=0
((_prl_line > _inc_line)); assert_eq "dirty-key-below-include" "$?" "0"
assert_contains "dirty-backup" "$(ls "$FX"/sshd_config.backup.* 2>/dev/null)" "sshd_config.backup."

# 3. NO INCLUDE: managed keys only in main → warning + Include added at top
cp "$FX/noinclude.conf" "$SSHD_MAIN_CONFIG"
out=$(harden_sshd_restore_include 2>&1)
assert_contains "noinclude-warning" "$out" "No Include for sshd_config.d"
assert_contains "noinclude-added" "$(head -2 "$SSHD_MAIN_CONFIG" | tail -1)" "Include /etc/ssh/sshd_config.d"

# 4. VALIDATION FAILURE: sshd -t fails after edit → rollback, rc 1
cp "$FX/dirty.conf" "$SSHD_MAIN_CONFIG"
SSHD_T_RC=3 out=$(harden_sshd_restore_include 2>&1)
rc=$?
assert_contains "rollback-warning" "$out" "rolling back"
assert_eq "rollback-rc" "$rc" "1"
assert_eq "rollback-restore" "$(head -1 "$SSHD_MAIN_CONFIG")" "PermitRootLogin yes"

echo ""; echo "unit-ssh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
