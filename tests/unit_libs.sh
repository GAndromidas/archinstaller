#!/usr/bin/env bash
# Unit tests for lib/* contracts: state locking/guards, config null
# filtering, dashboard plain-mode timing, package manager validation.
# All hermetic (temp STATE_FILE/INSTALL_LOG, no sudo, no hardware).
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib/core.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib/state.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib/config.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib/dashboard.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib/package.sh"
PASS=0; FAIL=0

assert_eq() {
  local name="${1:-}" got="${2:-}" want="${3:-}"
  if [[ "$got" == "$want" ]]; then PASS=$((PASS+1)); echo "PASS: $name";
  else FAIL=$((FAIL+1)); echo "FAIL: $name — got '$got', want '$want'"; fi
}
assert_rc() {
  local name="${1:-}" want="${2:-}"; shift 2
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" == "$want" ]]; then PASS=$((PASS+1)); echo "PASS: $name";
  else FAIL=$((FAIL+1)); echo "FAIL: $name — rc $rc, want $want"; fi
}

export STATE_FILE INSTALL_LOG
STATE_FILE=$(mktemp /tmp/archinstaller_unit_state.XXXXXX) || exit 1
INSTALL_LOG=$(mktemp /tmp/archinstaller_unit_log.XXXXXX) || exit 1
trap 'rm -f "$STATE_FILE" "$INSTALL_LOG" "$STATE_FILE".tmp.*' EXIT

# --- state: write + predicates -------------------------------------------
: > "$STATE_FILE"
state_write "COMPLETED: foo" || { echo "FAIL: state-write rc"; FAIL=$((FAIL+1)); }
grep -qFx "COMPLETED: foo" "$STATE_FILE" \
  && { PASS=$((PASS+1)); echo "PASS: state-write"; } \
  || { FAIL=$((FAIL+1)); echo "FAIL: state-write"; }
assert_rc "complete-true" 0 is_step_complete foo
assert_rc "complete-false" 1 is_step_complete bar
mark_step_complete_with_progress foo skipped
assert_rc "skipped-true" 0 is_step_skipped foo
assert_rc "done-either" 0 is_step_done foo
assert_rc "done-false" 1 is_step_done nope
assert_rc "empty-guard-complete" 1 is_step_complete
assert_rc "empty-guard-done" 1 is_step_done
assert_rc "empty-guard-write" 1 state_write ""
echo "FAILED: boom" >> "$STATE_FILE"
assert_rc "has-failure" 0 state_has_failure
state_clear_failures
if grep -q '^FAILED:' "$STATE_FILE"; then
  FAIL=$((FAIL+1)); echo "FAIL: clear-failures"
else
  PASS=$((PASS+1)); echo "PASS: clear-failures"
fi
if ls "$STATE_FILE".tmp.* >/dev/null 2>&1; then
  FAIL=$((FAIL+1)); echo "FAIL: clear-no-orphan"
else
  PASS=$((PASS+1)); echo "PASS: clear-no-orphan"
fi

# --- state: dry-run never mutates -----------------------------------------
: > "$STATE_FILE"
DRY_RUN=true mark_step_complete_with_progress dry_step completed
if grep -q 'dry_step' "$STATE_FILE"; then
  FAIL=$((FAIL+1)); echo "FAIL: dry-run-no-write"
else
  PASS=$((PASS+1)); echo "PASS: dry-run-no-write"
fi
DRY_RUN=false

# --- config: null never becomes a package ----------------------------------
printf 'pkgs:\n  - foo\n  - null\n  - bar\n' > /tmp/archinstaller_unit_pkgs.yaml
declare -a PKGS=()
read_yaml_packages /tmp/archinstaller_unit_pkgs.yaml '.pkgs' PKGS
assert_eq "null-filtered" "${PKGS[*]}" "foo bar"
rm -f /tmp/archinstaller_unit_pkgs.yaml
assert_rc "yaml-missing-file" 1 read_yaml_packages /nonexistent.yaml '.x' PKGS
assert_rc "yaml-empty-args" 1 read_yaml_packages

# --- package: unknown manager fails, empty names fail ----------------------
assert_rc "unknown-manager" 1 is_package_installed bogus foo
assert_rc "empty-pkg" 1 is_package_installed pacman ""
assert_rc "remove-unknown-manager" 1 remove_package foo bogus
assert_rc "generic-unknown-manager" 1 install_package_generic bogus foo

# --- dashboard plain-mode: TIMES always set (set -u regression) ------------
format_time() { echo "${1:-0}s"; }
DASHBOARD_PLAIN=true; TOTAL_STEPS=3
DASHBOARD_START_SEC=$(mono_now)
DASHBOARD_STEP_NAMES[1]="A"; DASHBOARD_CURRENT_STEP=1; DASHBOARD_STEP_SEC=$(mono_now)
dashboard_ok >/dev/null 2>&1
dashboard_step "B" 2 >/dev/null 2>&1; dashboard_skip "x" >/dev/null 2>&1
dashboard_step "C" 3 >/dev/null 2>&1; dashboard_fail >/dev/null 2>&1
[[ "${DASHBOARD_STEP_TIMES[2]:-unset}" != "unset" && "${DASHBOARD_STEP_TIMES[3]:-unset}" != "unset" ]] \
  && { PASS=$((PASS+1)); echo "PASS: dash-times-set"; } \
  || { FAIL=$((FAIL+1)); echo "FAIL: dash-times-set"; }
dashboard_finish >/dev/null 2>&1 \
  && { PASS=$((PASS+1)); echo "PASS: dash-finish-no-crash"; } \
  || { FAIL=$((FAIL+1)); echo "FAIL: dash-finish-no-crash"; }
grep -q 'STEP_TIMING' "$INSTALL_LOG" \
  && { PASS=$((PASS+1)); echo "PASS: step-timing-logged"; } \
  || { FAIL=$((FAIL+1)); echo "FAIL: step-timing-logged"; }
assert_rc "dash-run-empty" 1 dashboard_run ""
assert_rc "dash-run-missing" 1 dashboard_run /nonexistent

# --- install.sh static contracts --------------------------------------------
grep -q '3) dashboard_skip "No WoL hardware' "$ROOT_DIR/install.sh" \
  && ! grep '3) dashboard_skip "No WoL hardware' "$ROOT_DIR/install.sh" | grep -q 'mark_step_complete' \
  && { PASS=$((PASS+1)); echo "PASS: wol-retry-not-persisted"; } \
  || { FAIL=$((FAIL+1)); echo "FAIL: wol-retry-not-persisted"; }
grep -q 'Dry-run: skipping system requirements' "$ROOT_DIR/install.sh" \
  && { PASS=$((PASS+1)); echo "PASS: dry-run-skips-checks"; } \
  || { FAIL=$((FAIL+1)); echo "FAIL: dry-run-skips-checks"; }

echo "unit-libs: $PASS passed, $FAIL failed"
exit "$([ "$FAIL" -eq 0 ] && echo 0 || echo 1)"
