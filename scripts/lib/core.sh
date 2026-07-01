#!/bin/bash
set -uo pipefail

# ============================================================================
# Core Library - Logging, Error Handling, and Core Utilities
# ============================================================================

# Color definitions (kept for backward compatibility — use THEME_* for new code)
if [ -z "${RED:-}" ]; then
  readonly RED='\033[0;31m'
  readonly GREEN='\033[0;32m'
  readonly YELLOW='\033[0;33m'
  readonly BLUE='\033[0;34m'
  readonly PURPLE='\033[0;35m'
  readonly CYAN='\033[0;36m'
  readonly WHITE='\033[0;37m'
  readonly DIM='\033[0;2m'
  readonly RESET='\033[0m'
fi

# Theme colors — single source of truth for all UI output
if [ -z "${THEME_PRIMARY:-}" ]; then
  readonly THEME_PRIMARY='\033[0;34m'
  readonly THEME_SECONDARY='\033[1;34m'
  readonly THEME_TEXT='\033[0;37m'
  readonly THEME_TEXT_BOLD='\033[1;37m'
  readonly THEME_SUCCESS='\033[0;32m'
  readonly THEME_WARN='\033[0;33m'
  readonly THEME_ERROR='\033[0;31m'
  readonly THEME_MUTED='\033[0;2m'
  readonly THEME_HIGHLIGHT='\033[0;33m'
  readonly THEME_BORDER='\033[1;34m'
  readonly THEME_HEADER='\033[1;37m'
fi

# Gum color mappings for blue/white theme
if [ -z "${GUM_PRIMARY:-}" ]; then
  readonly GUM_PRIMARY="26"
  readonly GUM_SECONDARY="39"
  readonly GUM_TEXT="15"
  readonly GUM_SUCCESS="46"
  readonly GUM_WARN="226"
  readonly GUM_ERROR="196"
  readonly GUM_MUTED="8"
  readonly GUM_HEADER="26"
  readonly GUM_BORDER="26"
fi

# Global variables
export INSTALL_LOG="${INSTALL_LOG:-$HOME/.archinstaller.log}"
STATE_FILE="${STATE_FILE:-$HOME/.archinstaller.state}"
ERRORS=()
INSTALLED_PACKAGES=()
FAILED_PACKAGES=()
START_TIME=$(date +%s)

# Rotate old log files (keep last 3 backups)
if ! declare -f rotate_logs >/dev/null 2>&1; then
rotate_logs() {
    local log="$INSTALL_LOG"
    for i in 3 2 1; do
        [ -f "${log}.$((i-1))" ] && mv -f "${log}.$((i-1))" "${log}.${i}" 2>/dev/null || true
    done
    [ -f "$log" ] && mv -f "$log" "${log}.1" 2>/dev/null || true
}
fi

# Initialize logging
if ! declare -f init_logging >/dev/null 2>&1; then
init_logging() {
    mkdir -p "$(dirname "$INSTALL_LOG")" 2>/dev/null || true
    rotate_logs
    touch "$INSTALL_LOG" 2>/dev/null || true
    echo "=== Arch Installer Log - $(date) ===" >> "$INSTALL_LOG"
}
fi

# Log to file
if ! declare -f log_to_file >/dev/null 2>&1; then
log_to_file() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $message" >> "$INSTALL_LOG"
}
fi

# Log info message (console + file)
if ! declare -f log_info >/dev/null 2>&1; then
log_info() {
    local message="$1"
    local detail="${2:-}"
    echo -e "${THEME_TEXT}$message${RESET}"
    log_to_file "INFO: $message"
    if [ -n "$detail" ]; then
        log_to_file "  DETAIL: $detail"
    fi
}
fi

# Log success message (console + file)
if ! declare -f log_success >/dev/null 2>&1; then
log_success() {
    local message="$1"
    local detail="${2:-}"
    echo -e "${THEME_SUCCESS}$message${RESET}"
    log_to_file "SUCCESS: $message"
    if [ -n "$detail" ]; then
        echo -e "${THEME_MUTED}  Details: $detail${RESET}"
        log_to_file "  DETAIL: $detail"
    fi
}
fi

# Log warning message (console + file)
if ! declare -f log_warning >/dev/null 2>&1; then
log_warning() {
    local message="$1"
    local detail="${2:-}"
    echo -e "${THEME_WARN}⚠ $message${RESET}"
    log_to_file "WARNING: $message"
    if [ -n "$detail" ]; then
        echo -e "${THEME_MUTED}  Note: $detail${RESET}"
        log_to_file "  DETAIL: $detail"
    fi
}
fi

# Log error message (console + file)
if ! declare -f log_error >/dev/null 2>&1; then
log_error() {
    local message="$1"
    local hint="${2:-}"
    echo -e "${THEME_ERROR}✗ $message${RESET}"
    if [ -n "$hint" ]; then
        echo -e "${THEME_MUTED}  Tip: $hint${RESET}"
    fi
    ERRORS+=("$message")
    log_to_file "ERROR: $message"
}
fi

# Log debug message
if ! declare -f log_debug >/dev/null 2>&1; then
log_debug() {
    local message="$1"
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
    local description="$1"
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
    return $ret
}
fi

# Check if command exists
if ! declare -f command_exists >/dev/null 2>&1; then
command_exists() {
    command -v "$1" &>/dev/null
}
fi

# Validate file operation
if ! declare -f validate_file_operation >/dev/null 2>&1; then
validate_file_operation() {
    local operation="${1:?Operation type required}"
    local file="${2:?File path required}"
    local description="${3:-File operation}"

    if [[ "$operation" == "read" ]] && [ ! -f "$file" ]; then
        log_error "File $file does not exist. Cannot perform: $description"
        return 1
    fi

    if [[ "$operation" == "write" ]] && [ ! -d "$(dirname "$file")" ]; then
        log_error "Directory $(dirname "$file") does not exist. Cannot perform: $description"
        return 1
    fi

    if [[ "$operation" == "write" ]] && [ ! -w "$(dirname "$file")" ]; then
        log_error "No write permission for $(dirname "$file"). Cannot perform: $description"
        return 1
    fi

    return 0
}
fi

# Performance tracking
if ! declare -f log_performance >/dev/null 2>&1; then
log_performance() {
    local step_name="$1"
    local current_time=$(date +%s)
    local elapsed=$((current_time - START_TIME))
    local minutes=$((elapsed / 60))
    local seconds=$((elapsed % 60))
    log_info "$step_name completed in ${minutes}m ${seconds}s (${elapsed}s)"
}
fi

# Check if running as root
if ! declare -f check_root >/dev/null 2>&1; then
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "This operation requires root privileges"
        return 1
    fi
    return 0
}
fi

# Check if system is Arch Linux
if ! declare -f check_arch >/dev/null 2>&1; then
check_arch() {
    if [ ! -f /etc/arch-release ]; then
        log_error "This script is designed for Arch Linux only"
        return 1
    fi
    return 0
}
fi

# Initialize the core library
if ! declare -f init_core >/dev/null 2>&1; then
init_core() {
    init_logging
}
fi
