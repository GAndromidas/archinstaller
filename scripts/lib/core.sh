#!/bin/bash
set -uo pipefail

# Logging, error handling, and core utilities

# Color definitions (kept for backward compatibility — use THEME_* for new code)
if [ -z "${RED:-}" ]; then
  readonly RED='\033[0;31m'
  readonly GREEN='\033[0;32m'
  readonly YELLOW='\033[0;33m'
  readonly BLUE='\033[38;2;62;147;175m'
  readonly PURPLE='\033[0;35m'
  readonly CYAN='\033[38;2;62;147;175m'
  readonly WHITE='\033[38;2;205;214;244m'
  readonly DIM='\033[38;2;108;112;134m'
  readonly RESET='\033[0m'
fi

# Theme colors — single source of truth for all UI output
# Palette: accent #3E93AF, highlight #89B4FA,
# text #CDD6F4, muted #6C7086. Semantic red/yellow/green stay standard.
if [ -z "${THEME_PRIMARY:-}" ]; then
  readonly THEME_PRIMARY='\033[38;2;62;147;175m'
  readonly THEME_SECONDARY='\033[38;2;137;180;250m'
  readonly THEME_TEXT='\033[38;2;205;214;244m'
  readonly THEME_TEXT_BOLD='\033[1;38;2;205;214;244m'
  readonly THEME_SUCCESS='\033[0;32m'
  readonly THEME_WARN='\033[0;33m'
  readonly THEME_ERROR='\033[0;31m'
  readonly THEME_MUTED='\033[38;2;108;112;134m'
  readonly THEME_HIGHLIGHT='\033[38;2;137;180;250m'
  readonly THEME_BORDER='\033[38;2;62;147;175m'
  readonly THEME_HEADER='\033[38;2;137;180;250m'
fi

# Gum color mappings (hex supported by gum)
if [ -z "${GUM_PRIMARY:-}" ]; then
  readonly GUM_PRIMARY="#3E93AF"
  readonly GUM_SECONDARY="#89B4FA"
  readonly GUM_TEXT="#CDD6F4"
  readonly GUM_SUCCESS="46"
  readonly GUM_WARN="226"
  readonly GUM_ERROR="196"
  readonly GUM_MUTED="#6C7086"
  readonly GUM_HEADER="#89B4FA"
  readonly GUM_BORDER="#3E93AF"
fi

# Global variables (/var/tmp survives reboots so resume works; /tmp does not)
# NOTE: step/wall durations use mono_now() (dashboard.sh, install.sh) —
# never bare $SECONDS. Bash $SECONDS tracks wall-clock time since shell
# start, so an NTP/VM clock correction mid-install collapses every duration
# to ~0 (observed: all steps + total "<1s" on a Boxes run whose work
# demonstrably took minutes). /proc/uptime is monotonic and immune.
export INSTALL_LOG="${INSTALL_LOG:-/var/tmp/archinstaller.log}"
STATE_FILE="${STATE_FILE:-/var/tmp/archinstaller.state}"
# Do not wipe parent-shell tracking arrays on re-source (modules are sourced
# in subshells; core may be sourced twice in one process).
if ! declare -p ERRORS &>/dev/null; then ERRORS=(); fi
if ! declare -p INSTALLED_PACKAGES &>/dev/null; then INSTALLED_PACKAGES=(); fi
if ! declare -p FAILED_PACKAGES &>/dev/null; then FAILED_PACKAGES=(); fi

# Keep last 3 log backups
if ! declare -f rotate_logs >/dev/null 2>&1; then
rotate_logs() {
    local log="$INSTALL_LOG"
    for i in 3 2 1; do
        [ -f "${log}.$((i-1))" ] && mv -f "${log}.$((i-1))" "${log}.${i}" 2>/dev/null || true
    done
    [ -f "$log" ] && mv -f "$log" "${log}.1" 2>/dev/null || true
}
fi

if ! declare -f mono_now >/dev/null 2>&1; then
mono_now() {
    # Integer monotonic seconds since boot; falls back to $SECONDS where
    # /proc/uptime is unavailable.
    local up
    up=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo "")
    if [[ "$up" =~ ^[0-9]+$ ]]; then
        echo "$up"
    else
        echo "$SECONDS"
    fi
}
fi

if ! declare -f init_logging >/dev/null 2>&1; then
init_logging() {
    mkdir -p "$(dirname "$INSTALL_LOG")" 2>/dev/null || true
    rotate_logs
    touch "$INSTALL_LOG" 2>/dev/null || true
    echo "=== Arch Installer Log - $(date) ===" >> "$INSTALL_LOG"
}
fi

if ! declare -f log_to_file >/dev/null 2>&1; then
log_to_file() {
    local message="${1:-}"
    [[ -n "$message" ]] || return 0
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $message" >> "$INSTALL_LOG"
}
fi

if ! declare -f log_info >/dev/null 2>&1; then
log_info() {
    local message="${1:-}"
    [[ -n "$message" ]] || return 0
    local detail="${2:-}"
    echo -e "${THEME_TEXT}$message${RESET}"
    log_to_file "INFO: $message"
    if [ -n "$detail" ]; then
        log_to_file "  DETAIL: $detail"
    fi
}
fi

if ! declare -f log_success >/dev/null 2>&1; then
log_success() {
    local message="${1:-}"
    [[ -n "$message" ]] || return 0
    local detail="${2:-}"
    echo -e "${THEME_SUCCESS}$message${RESET}"
    log_to_file "SUCCESS: $message"
    if [ -n "$detail" ]; then
        echo -e "${THEME_MUTED}  Details: $detail${RESET}"
        log_to_file "  DETAIL: $detail"
    fi
}
fi

if ! declare -f log_warning >/dev/null 2>&1; then
log_warning() {
    local message="${1:-}"
    [[ -n "$message" ]] || return 0
    local detail="${2:-}"
    echo -e "${THEME_WARN}⚠ $message${RESET}"
    log_to_file "WARNING: $message"
    if [ -n "$detail" ]; then
        echo -e "${THEME_MUTED}  Note: $detail${RESET}"
        log_to_file "  DETAIL: $detail"
    fi
}
fi

if ! declare -f log_error >/dev/null 2>&1; then
log_error() {
    local message="${1:-}"
    [[ -n "$message" ]] || return 0
    local hint="${2:-}"
    echo -e "${THEME_ERROR}✗ $message${RESET}"
    if [ -n "$hint" ]; then
        echo -e "${THEME_MUTED}  Tip: $hint${RESET}"
    fi
    ERRORS+=("$message")
    log_to_file "ERROR: $message"
}
fi

if ! declare -f log_debug >/dev/null 2>&1; then
log_debug() {
    local message="${1:-}"
    [[ -n "$message" ]] || return 0
    local detail="${2:-}"
    if [ "${VERBOSE:-false}" = true ]; then
        echo -e "${THEME_MUTED}[DEBUG] $message${RESET}"
        log_to_file "DEBUG: $message"
        if [ -n "$detail" ]; then
            log_to_file "  DETAIL: $detail"
        fi
    fi
}
fi

# Run a step with error handling
if ! declare -f run_step >/dev/null 2>&1; then
run_step() {
    [[ $# -ge 2 ]] || { log_error "run_step: usage: run_step <description> <cmd> [args...]"; return 1; }
    local description="${1:-}"
    shift

    step "$description"

    local ret
    "$@" 2>&1 | tee -a "$INSTALL_LOG" >/dev/null
    ret=${PIPESTATUS[0]}
    if [ "$ret" -eq 0 ]; then
        log_success "$description"
    else
        log_error "$description failed (exit code: $ret)"
    fi
    return "$ret"
}
fi

if ! declare -f command_exists >/dev/null 2>&1; then
command_exists() {
    [[ $# -ge 1 ]] || return 1
    command -v "$1" &>/dev/null
}
fi

if ! declare -f check_root >/dev/null 2>&1; then
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "This operation requires root privileges"
        return 1
    fi
    return 0
}
fi

if ! declare -f init_core >/dev/null 2>&1; then
init_core() {
    init_logging
}
fi
