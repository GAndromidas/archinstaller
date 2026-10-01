#!/usr/bin/env bash
set -uo pipefail

# Persistent installation state. Kept separate from orchestration so state
# handling can evolve without changing installation modules.
STATE_FILE="${STATE_FILE:-/var/tmp/archinstaller.state}"

validate_state_file() {
  if [[ ! -e "$STATE_FILE" ]]; then
    return 0
  fi
  if [[ ! -f "$STATE_FILE" || ! -r "$STATE_FILE" ]]; then
    log_warning "State file is not readable. Starting with a fresh state file."
    rm -f "$STATE_FILE" 2>/dev/null || true
    return 1
  fi
  if [[ ! -s "$STATE_FILE" ]]; then
    rm -f "$STATE_FILE" 2>/dev/null || true
    return 0
  fi
  return 0
}

state_write() {
  local line="${1:-}"
  [[ -n "$line" ]] || return 1
  mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || return 1
  touch "$STATE_FILE" 2>/dev/null || return 1
  (
    flock -x 200 || exit 1
    printf '%s\n' "$line" >&200
  ) 200>>"$STATE_FILE" 2>/dev/null || return 1
}

mark_step_complete_with_progress() {
  # Preview runs must never mutate persistent resume state.
  if [[ "${DRY_RUN:-false}" == true ]]; then
    log_debug "Dry-run: not writing state for step ${1:-unknown}"
    return 0
  fi
  local step_name="${1:-}"
  local status="${2:-completed}"
  [[ -n "$step_name" ]] || { log_error "Cannot update empty step name"; return 1; }
  case "$status" in
    completed|skipped|failed) state_write "${status^^}: $step_name" ;;
    *) log_error "Invalid state '$status' for step '$step_name'"; return 1 ;;
  esac
}

is_step_complete() {
  local _name="${1:-}"
  [[ -n "$_name" ]] || return 1
  [[ -f "$STATE_FILE" ]] && grep -qFx "COMPLETED: $_name" "$STATE_FILE"
}

is_step_skipped() {
  local _name="${1:-}"
  [[ -n "$_name" ]] || return 1
  [[ -f "$STATE_FILE" ]] && grep -qFx "SKIPPED: $_name" "$STATE_FILE"
}

# COMPLETED or SKIPPED both mean "don't re-run this step on resume".
# Use is_step_complete / is_step_skipped when the distinction matters
# (e.g. gaming re-offers when skipped, wake-on-lan does not).
is_step_done() {
  local _name="${1:-}"
  [[ -n "$_name" ]] || return 1
  is_step_complete "$_name" || is_step_skipped "$_name"
}

state_has_failure() {
  [[ -f "$STATE_FILE" ]] && grep -q '^FAILED:' "$STATE_FILE"
}

state_clear() {
  rm -f "$STATE_FILE" 2>/dev/null || true
}

# Strip FAILED: entries after a run reaches the end successfully — keeps
# COMPLETED/SKIPPED history but stops a stale failure from an earlier
# interrupted attempt confusing future summaries/resume decisions.
state_clear_failures() {
  [[ -f "$STATE_FILE" ]] || return 0
  local tmp
  tmp=$(mktemp "${STATE_FILE}.tmp.XXXXXX") || return 1
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" RETURN
  grep -v '^FAILED:' "$STATE_FILE" > "$tmp" || true
  if ! mv -f "$tmp" "$STATE_FILE"; then
    rm -f "$tmp"
    trap - RETURN
    return 1
  fi
  trap - RETURN
}
