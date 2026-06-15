#!/bin/bash
set -uo pipefail

# ============================================================================
# Core Library - Logging, Error Handling, and Core Utilities
# ============================================================================

# Color definitions (kept for backward compatibility — use THEME_* for new code)
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly WHITE='\033[0;37m'
readonly DIM='\033[0;2m'
readonly RESET='\033[0m'

# Theme colors — single source of truth for all UI output
readonly THEME_PRIMARY='\033[0;34m'
readonly THEME_SECONDARY='\033[1;34m'
readonly THEME_TEXT='\033[0;37m'
readonly THEME_TEXT_BOLD='\033[1;37m'
readonly THEME_SUCCESS='\033[0;32m'
readonly THEME_WARN='\033[0;33m'
readonly THEME_ERROR='\033[0;31m'
readonly THEME_MUTED='\033[0;2m'
readonly THEME_BORDER='\033[1;34m'
readonly THEME_HEADER='\033[1;37m'

# Gum color mappings for blue/white theme
readonly GUM_PRIMARY="33"
readonly GUM_SECONDARY="39"
readonly GUM_TEXT="15"
readonly GUM_SUCCESS="46"
readonly GUM_WARN="226"
readonly GUM_ERROR="196"
readonly GUM_MUTED="8"
readonly GUM_HEADER="33"
readonly GUM_BORDER="33"

# Global variables
INSTALL_LOG="${INSTALL_LOG:-$HOME/.archinstaller.log}"
STATE_FILE="${STATE_FILE:-$HOME/.archinstaller.state}"
ERRORS=()
INSTALLED_PACKAGES=()
FAILED_PACKAGES=()
START_TIME=$(date +%s)

# Initialize logging
init_logging() {
    mkdir -p "$(dirname "$INSTALL_LOG")" 2>/dev/null || true
    echo "=== Arch Installer Log - $(date) ===" > "$INSTALL_LOG"
}

# Log to file
log_to_file() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $message" >> "$INSTALL_LOG"
}

# Log info message
log_info() {
    local message="$1"
    local detail="${2:-}"
    log_to_file "INFO: $message"
    if [ -n "$detail" ]; then
        log_to_file "  DETAIL: $detail"
    fi
}

# Log success message
log_success() {
    local message="$1"
    local detail="${2:-}"
    log_to_file "SUCCESS: $message"
    if [ -n "$detail" ]; then
        log_to_file "  DETAIL: $detail"
    fi
}

# Log warning message
log_warning() {
    local message="$1"
    local detail="${2:-}"
    log_to_file "WARNING: $message"
    if [ -n "$detail" ]; then
        log_to_file "  DETAIL: $detail"
    fi
}

# Log error message
log_error() {
    local message="$1"
    local detail="${2:-}"
    log_to_file "ERROR: $message"
    if [ -n "$detail" ]; then
        log_to_file "  DETAIL: $detail"
    fi
    ERRORS+=("$message")
}

# Log debug message
log_debug() {
    local message="$1"
    if [ "${VERBOSE:-false}" = true ]; then
        log_to_file "DEBUG: $message"
        echo -e "${DIM}[DEBUG] $message${RESET}"
    fi
}

# Run a step with error handling
run_step() {
    local description="$1"
    shift
    local command=("$@")
    
    step "$description"
    if "$@"; then
        log_success "$description"
        return 0
    else
        local exit_code=$?
        log_error "$description failed (exit code: $exit_code)"
        return $exit_code
    fi
}

# Check if command exists
command_exists() {
    command -v "$1" &>/dev/null
}

# Validate file operation
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

# Performance tracking
log_performance() {
    local step_name="$1"
    local current_time=$(date +%s)
    local elapsed=$((current_time - START_TIME))
    local minutes=$((elapsed / 60))
    local seconds=$((elapsed % 60))
    log_info "$step_name completed in ${minutes}m ${seconds}s (${elapsed}s)"
}

# Check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "This operation requires root privileges"
        return 1
    fi
    return 0
}

# Check if system is Arch Linux
check_arch() {
    if [ ! -f /etc/arch-release ]; then
        log_error "This script is designed for Arch Linux only"
        return 1
    fi
    return 0
}

# Initialize the core library
init_core() {
    init_logging
}
