#!/bin/bash
set -uo pipefail

# Installation log file (/var/tmp persists across reboots so resume works)
INSTALL_LOG="${INSTALL_LOG:-/var/tmp/archinstaller.log}"
AUTO_MODE=false
UNATTENDED=false
AUTO_CONFIRM=false

# Function to show help
show_help() {
  cat << 'EOF'
ArchInstaller - Arch Linux Post-Installation Automation

USAGE:
    ./install.sh [OPTIONS]

OPTIONS:
    -h, --help      Show this help message and exit
    -v, --verbose   Enable verbose output (show all package installation details)
    -q, --quiet     Quiet mode (minimal output)
    -d, --dry-run   Preview what will be installed without making changes
    -a, --auto      Automatically select the recommended installation mode
    -y, --yes       Non-interactive mode: accept safe/default prompts automatically

DESCRIPTION:
    ArchInstaller transforms a fresh Arch Linux installation into a fully
    configured, optimized system with intelligent hardware detection and 
    tailored optimizations. It applies targeted optimizations rather than 
    one-size-fits-all settings, ensuring optimal performance for your 
    specific configuration.

INSTALLATION MODES:
    Standard        Complete setup with all recommended packages (intermediate users)
    Minimal         Essential tools only for lightweight installations (new users)
    Server          Headless configuration (Docker, SSH, server utilities)

    Gaming mode is offered as an optional step during Standard/Minimal installations.

FEATURES:
    - Hardware-aware CPU detection (Intel/AMD with microcode updates)
    - Automatic GPU driver detection and installation (AMD/Intel)
    - Storage optimization (NVMe/SSD/HDD with I/O scheduling)
    - Desktop environment detection and optimization (KDE Plasma 6+, GNOME 46+, Cosmic)
    - Security hardening (UFW/Firewalld + Fail2ban with SSH protection)
    - Advanced performance tuning
    - Smart AMD P-State system with gaming mode detection
    - Wake-on-LAN configuration for ethernet devices (desktops only)
    - Zsh shell with Oh-My-Zsh and Starship prompt
    - Resume functionality for interrupted installations

SYSTEM INTELLIGENCE:
    - Dynamic memory management (RAM-based swappiness)
    - Intelligent storage optimization (storage-type I/O scheduling)
    - Hardware-aware configuration (NVMe detection, zRAM monitoring)
    - Transparent hugepages optimization for desktop systems
    - Persistent settings via udev rules and systemd services

BOOTLOADER SUPPORT:
    - GRUB with timeout optimization and boot menu management
    - systemd-boot with LTS kernel fallback and EFI support
    - Limine with modern UEFI and fast boot support

REQUIREMENTS:
    - Fresh Arch Linux or EndeavourOS installation
    - Active internet connection
    - Regular user account with sudo privileges
    - Minimum 2GB free disk space
    - Supported bootloader (GRUB/systemd-boot/Limine)

EXAMPLES:
    ./install.sh                Run installer with interactive prompts
    ./install.sh --verbose      Run with detailed package installation output
    ./install.sh --dry-run      Preview changes without making them
    ./install.sh --auto          Automatically choose the recommended mode
    ./install.sh --yes           Run unattended with safe/default choices
    ./install.sh --help         Show this help message

LOG FILES:
    Installation log: /var/tmp/archinstaller.log
    Progress tracking: /var/tmp/archinstaller.state

MORE INFO:
    https://github.com/GAndromidas/archinstaller

EOF
  exit 0
}


# Get the directory where this script is located (archinstaller root)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$SCRIPT_DIR/scripts"
CONFIGS_DIR="$SCRIPT_DIR/configs"

# State tracking for error recovery (/var/tmp survives reboot; migrate legacy /tmp state)
STATE_FILE="/var/tmp/archinstaller.state"
if [[ ! -s "$STATE_FILE" && -s /tmp/archinstaller.state ]]; then
  cp -a /tmp/archinstaller.state "$STATE_FILE" 2>/dev/null || true
fi
if [[ ! -s "$INSTALL_LOG" && -s /tmp/archinstaller.log ]]; then
  cp -a /tmp/archinstaller.log "$INSTALL_LOG" 2>/dev/null || true
fi

# Parse flags before any package installation or other system side effects.
VERBOSE=false
DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    -h|--help) show_help ;;
    --verbose|-v) VERBOSE=true ;;
    --quiet|-q) VERBOSE=false ;;
    --dry-run|-d) DRY_RUN=true; VERBOSE=true ;;
    --auto|-a) AUTO_MODE=true ;;
    --yes|-y) AUTO_MODE=true; UNATTENDED=true; AUTO_CONFIRM=true ;;
    *) echo "Unknown option: $arg"; echo "Use --help for usage information"; exit 1 ;;
  esac
done

# Source modular libraries once. common.sh remains a compatibility facade for
# older modules and third-party callers.
source "$SCRIPTS_DIR/lib/core.sh"
source "$SCRIPTS_DIR/lib/ui.sh"
source "$SCRIPTS_DIR/lib/system.sh"
source "$SCRIPTS_DIR/lib/package.sh"
source "$SCRIPTS_DIR/lib/config.sh"
source "$SCRIPTS_DIR/lib/state.sh"
source "$SCRIPTS_DIR/common.sh"
source "$SCRIPTS_DIR/lib/dashboard.sh"

export VERBOSE DRY_RUN INSTALL_LOG AUTO_MODE UNATTENDED AUTO_CONFIRM

# Sudo keep-alive: long runs (full -Syu + batch installs + mkinitcpio -P)
# outlive the default sudo timestamp. Refresh in the background so a hidden
# password prompt never hangs a step whose stdout is redirected to the log.
# Started once after the first authenticated sudo use; killed on exit via
# save_log_on_exit / cleanup_on_error.
start_sudo_keepalive() {
  [[ "${DRY_RUN:-false}" == true ]] && return 0
  if [[ -n "${SUDO_KEEPALIVE_PID:-}" ]] && kill -0 "$SUDO_KEEPALIVE_PID" 2>/dev/null; then
    return 0
  fi
  if ! sudo -n true 2>/dev/null; then
    return 1
  fi
  ( while true; do sudo -n true 2>/dev/null; sleep 50; kill -0 $$ 2>/dev/null || exit 0; done ) &
  SUDO_KEEPALIVE_PID=$!
  export SUDO_KEEPALIVE_PID
}

stop_sudo_keepalive() {
  if [[ -n "${SUDO_KEEPALIVE_PID:-}" ]]; then
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    unset SUDO_KEEPALIVE_PID
  fi
}

# Install gum only when we are actually going to modify the system. Dry-run is
# guaranteed not to install helpers or alter the target machine.
if [[ "$DRY_RUN" != true ]] && ! command -v gum >/dev/null 2>&1; then
  log_to_file "Installing gum for enhanced UI experience..."
  if sudo pacman -S --noconfirm --needed gum >>"$INSTALL_LOG" 2>&1; then
    log_to_file "Gum installed successfully"
  else
    log_to_file "Failed to install gum, falling back to basic UI"
  fi
fi

# Authenticate once up front so keep-alive can run non-interactively after.
if [[ "$DRY_RUN" != true ]]; then
  sudo -v || log_to_file "WARNING: sudo authentication failed; keep-alive disabled"
  start_sudo_keepalive || true
fi

init_core
START_TIME_SEC=$SECONDS
export START_TIME_SEC

# Clear the terminal only after options are parsed.
if [[ -t 1 ]] && [[ "${TERM:-dumb}" != dumb ]]; then clear; fi
arch_ascii

# System checking function (defined before use)
check_system_requirements() {
  # Use the enhanced compatibility check from common.sh
  if ! check_system_compatibility; then
    ui_error "System compatibility check failed!"
    ui_info "Please address the issues listed above before continuing."
    exit 1
  fi

  # Additional hardware-specific checks
  local hardware_issues=()

  log_to_file "Bootloader type will be detected during Step 6 (Bootloader Configuration)"

  if [ -d /sys/firmware/efi ]; then
    log_to_file "UEFI boot mode detected"
  else
    log_to_file "BIOS/Legacy boot mode detected"
    hardware_issues+=("Legacy BIOS mode detected - some features may not work optimally")
  fi

  if lspci | grep -qi vga; then
    # Report EVERY GPU (not just head -1): hybrids (AMD iGPU + NVIDIA dGPU)
    # are common and head -1 hid the second vendor.
    local gpu_lines
    gpu_lines=$(lspci | grep -iE 'vga|3d controller|display controller' || true)
    log_to_file "GPU(s) detected:"
    while IFS= read -r gpu_info; do
      [[ -z "$gpu_info" ]] && continue
      case "$gpu_info" in
        *NVIDIA*)         log_to_file "  NVIDIA GPU: $gpu_info - proprietary drivers will be configured" ;;
        *"AMD"*|*Radeon*|*ATI*) log_to_file "  AMD GPU: $gpu_info - open-source drivers will be configured" ;;
        *Intel*)          log_to_file "  Intel GPU: $gpu_info - mesa drivers will be configured" ;;
        *)                log_to_file "  Unknown GPU: $gpu_info - generic drivers will be used" ;;
      esac
    done <<< "$gpu_lines"
  else
    hardware_issues+=("No GPU detected - this may be a headless system")
  fi

  local root_device=$(findmnt -n -o SOURCE / | cut -d'[' -f1 | cut -d'/' -f3)
  if [ -n "$root_device" ]; then
    if echo "$root_device" | grep -q "nvme"; then
      log_to_file "NVMe storage detected - NVMe optimizations will be applied"
    elif [ -b "/dev/$root_device" ] && [ "$(cat /sys/block/"${root_device}"/queue/rotational 2>/dev/null)" = "0" ]; then
      log_to_file "SSD storage detected - SSD optimizations will be applied"
    else
      log_to_file "HDD storage detected - HDD optimizations will be applied"
    fi
  else
    hardware_issues+=("Could not determine root storage device")
  fi

  local total_mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  local total_mem_gb=$((total_mem_kb / 1024 / 1024))
  if [ "$total_mem_gb" -lt 2 ]; then
    hardware_issues+=("Low memory detected (${total_mem_gb}GB) - at least 2GB recommended")
  else
    log_to_file "System memory: ${total_mem_gb}GB - appropriate optimizations will be applied"
  fi

  if [ ${#hardware_issues[@]} -gt 0 ]; then
    ui_warn "Hardware compatibility issues detected:"
    for issue in "${hardware_issues[@]}"; do
      ui_info "  - $issue"
    done
    echo ""
    if ! ui_confirm "Continue despite hardware compatibility issues?" "Some features may not work optimally."; then
      ui_info "Installation cancelled by user"
      exit 0
    fi
  fi

  log_to_file "System requirements and hardware compatibility checks passed"
}

# Run system checks — stdout goes to log, interactive prompts use /dev/tty
check_system_requirements >> "$INSTALL_LOG" 2>&1

if [[ "$AUTO_MODE" == true ]]; then
  if is_headless_system; then
    INSTALL_MODE="server"
  else
    INSTALL_MODE="default"
  fi
  ui_info "Automatic mode: selected $( [[ "$INSTALL_MODE" == server ]] && echo "Server" || echo "Standard" ) installation."
  [[ "$UNATTENDED" == true ]] && export AUTO_LAPTOP_OPTS=true
else
  show_menu
fi

# Check if INSTALL_MODE was set (user might have exited menu)
if [ -z "${INSTALL_MODE:-}" ]; then
  echo "Installation cancelled."
  exit 0
fi

# Validate INSTALL_MODE after menu selection
if ! validate_install_mode "$INSTALL_MODE"; then
  log_error "Invalid installation mode selected. Please run the script again."
  exit 1
fi

export INSTALL_MODE

# State-file validation and step bookkeeping live in lib/state.sh.

# Enhanced error handling and rollback functions
cleanup_on_error() {
  local exit_code="${1:-$?}"
  local context="${2:-}"

  if [ "$exit_code" -ne 0 ]; then
    if [ -n "$context" ]; then
      log_error "Installation ended: $context (exit code $exit_code)"
    else
      log_error "Installation failed with exit code $exit_code"
    fi
    log_error "Check the log file for details: $INSTALL_LOG"

    # Kill sudo keep-alive if running
    stop_sudo_keepalive || true

    # Check if steps actually failed — if all steps completed, don't mark as failure
    # Use state file as source of truth (more reliable than ERRORS array which runs in subshells)
    if [ -f "$STATE_FILE" ] && ! grep -q "^FAILED:" "$STATE_FILE" 2>/dev/null; then
      log_warning "All installation steps completed successfully despite external signal (exit code $exit_code)"
      return 0
    fi

    # Mark installation as failed
    INSTALLATION_SUCCESS=false

    # Offer recovery options
    echo ""
    ui_error "Installation encountered an error!"
    ui_header "Recovery Options"
    ui_info "1. Run the script again to resume from where it left off"
    ui_info "2. Check the log file: $INSTALL_LOG"
    ui_info "3. Start fresh installation: rm -f $STATE_FILE"

    # Save error state (no bogus line number — step-level FAILED lines are precise)
    echo "FAILED: Installation ended (exit code: $exit_code)${context:+ — $context}" >> "$STATE_FILE"
  fi
}

# Global installation success tracking
INSTALLATION_SUCCESS=true
INSTALLER_EXITING=false

save_log_on_exit() {
  stop_sudo_keepalive || true

  {
    echo ""
    echo "=========================================="
    echo "Installation ended: $(date)"
    echo "=========================================="

    # Determine actual installation status from state file (more reliable than
    # INSTALLATION_SUCCESS, which can be false due to external signals like
    # SIGTERM after all steps completed)
    if [ -f "$STATE_FILE" ] && grep -q "^FAILED:" "$STATE_FILE" 2>/dev/null; then
      echo "Installation completed with errors!"
      echo "Check the log above for details."
    else
      echo "Installation completed successfully!"
      local elapsed=$(( SECONDS - START_TIME_SEC ))
      (( elapsed < 0 )) && elapsed=0
      echo "Total installation time: $(format_time "$elapsed")"
    fi
  } >> "$INSTALL_LOG"
}

# cleanup_on_error() and save_log_on_exit() above were fully written but
# never actually wired to anything — no trap in the whole codebase called
# them, so neither ran on error, Ctrl+C, or normal exit. This wires them up.
handle_signal() {
  local sig="$1"
  log_warning "Received $sig; stopping ArchInstaller safely."
  INSTALLATION_SUCCESS=false
  exit 130
}
trap 'handle_signal INT' INT
trap 'handle_signal TERM' TERM

on_exit() {
  local rc=$?
  if [[ "$INSTALLER_EXITING" == true ]]; then return; fi
  INSTALLER_EXITING=true
  if (( rc != 0 )); then cleanup_on_error "$rc" || true; fi
  save_log_on_exit || true
}
trap on_exit EXIT

# Installation start — enter dashboard wizard mode
# Keep the order and failure policy of the original installer while using one
# runner for every normal step. This is intentionally data-driven so adding a
# future module does not require another large copy/paste block.
run_install_step() {
  local number="$1" id="$2" name="$3" script="$4" policy="${5:-continue}"
  dashboard_step "$name" "$number"

  if is_step_complete "$id"; then
    dashboard_skip
    return 0
  fi

  if dashboard_run "$script"; then
    mark_step_complete_with_progress "$id" completed
    dashboard_ok
    return 0
  fi

  mark_step_complete_with_progress "$id" failed
  dashboard_fail
  log_error "$name failed"

  case "$policy" in
    continue)
      ui_warn "$name failed but continuing installation"
      return 0
      ;;
    ask)
      if [[ "$AUTO_CONFIRM" == true ]] || ui_confirm "$name failed. Continue with installation?" "The installer will continue, but dependent features may not work correctly."; then
        ui_warn "Continuing despite $name failure"
        return 0
      fi
      ui_error "Installation stopped due to $name failure"
      return 1
      ;;
    stop)
      ui_error "Installation stopped due to $name failure"
      return 1
      ;;
  esac
}

# Draw the wizard frame once before the first step. Every dashboard_step/
# dashboard_ok/dashboard_fail call below assumes the frame (and the
# per-step row lookup table) already exists — without this call the very
# first dashboard_step invocation crashes under `set -u` (DASHBOARD_STEP_ROWS
# is never populated) and the dashboard box is never drawn at all.
dashboard_init

run_install_step 1 system_preparation "System Preparation" "$SCRIPTS_DIR/modules/system_preparation.sh" ask || exit 1
run_install_step 2 shell_setup "Shell Setup" "$SCRIPTS_DIR/modules/shell_setup.sh"
run_install_step 3 yay_installation "Yay Installation" "$SCRIPTS_DIR/modules/yay.sh"
run_install_step 4 programs_installation "Programs Installation" "$SCRIPTS_DIR/modules/programs.sh"

# Gaming mode has a meaningful exit code 2: user declined it. Preserve that
# behavior rather than treating a decline as a failure.
dashboard_step "Gaming Mode" 5
if [[ "$INSTALL_MODE" == "server" ]]; then
  mark_step_complete_with_progress gaming_mode skipped
  dashboard_skip "Skipped — server mode"
elif is_step_complete gaming_mode; then
  dashboard_skip
else
  dashboard_run "$SCRIPTS_DIR/modules/gaming_mode.sh"
  gaming_ret=$?
  case "$gaming_ret" in
    0) mark_step_complete_with_progress gaming_mode completed; dashboard_ok ;;
    2) mark_step_complete_with_progress gaming_mode skipped; dashboard_skip "Skipped by user" ;;
    *) mark_step_complete_with_progress gaming_mode failed; dashboard_fail; log_error "Gaming Mode failed"; ui_warn "Gaming Mode failed but continuing installation (gaming optimizations not applied)" ;;
  esac
fi

run_install_step 6 bootloader_config "Bootloader and Kernel Configuration" "$SCRIPTS_DIR/modules/bootloader_config.sh" ask || exit 1
run_install_step 7 system_services "System Services" "$SCRIPTS_DIR/modules/system_services.sh"
run_install_step 8 fail2ban_setup "Fail2ban Setup" "$SCRIPTS_DIR/modules/fail2ban.sh"

dashboard_step "Wake-on-LAN Configuration" 9
if is_step_done wakeonlan_config; then
  dashboard_skip
else
  dashboard_run "$SCRIPTS_DIR/modules/wakeonlan_config.sh"
  wol_exit=$?
  case "$wol_exit" in
    0) mark_step_complete_with_progress wakeonlan_config completed; dashboard_ok ;;
    2) mark_step_complete_with_progress wakeonlan_config skipped; dashboard_warn "Skipped — no WoL-capable NIC" ;;
    *) mark_step_complete_with_progress wakeonlan_config failed; dashboard_fail; log_error "Wake-on-LAN configuration failed"; ui_warn "Wake-on-LAN configuration failed but continuing installation" ;;
  esac
fi

run_install_step 10 maintenance "Maintenance" "$SCRIPTS_DIR/modules/maintenance.sh"

dashboard_finish

if [ "$DRY_RUN" = true ]; then
  echo ""
  ui_info "This was a preview run. No changes were made to your system."
  ui_info "To perform the actual installation, run: ./install.sh"
  echo ""
  exit 0
fi

state_clear_failures || log_warning "Could not clear stale failure markers from state file"

prompt_reboot
