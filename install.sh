#!/bin/bash
set -uo pipefail

# Installation log file
INSTALL_LOG="$HOME/.archinstaller.log"

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
    Gaming          Gaming-optimized setup with Steam, Heroic Games Launcher,
                    Faugus Launcher, and performance tools

FEATURES:
    - Hardware-aware CPU detection (Intel/AMD with microcode updates)
    - Automatic GPU driver detection and installation (NVIDIA/AMD/Intel)
    - Storage optimization (NVMe/SSD/HDD with I/O scheduling)
    - Desktop environment detection and optimization (KDE Plasma 6+, GNOME 46+, Cosmic)
    - Security hardening (UFW/Firewalld + Fail2ban with SSH protection)
    - Advanced performance tuning (CachyOS-inspired optimizations)
    - Smart AMD P-State system with gaming mode detection
    - Wake-on-LAN configuration for ethernet devices (desktops only)
    - Plymouth boot screen configuration
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
    ./install.sh --help         Show this help message

LOG FILES:
    Installation log: ~/.archinstaller.log
    Progress tracking: ~/.archinstaller.state

MORE INFO:
    https://github.com/GAndromidas/archinstaller

EOF
  exit 0
}


# Clear terminal for clean interface
clear

# Get's directory where this script is located (archinstaller root)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$SCRIPT_DIR/scripts"
CONFIGS_DIR="$SCRIPT_DIR/configs"

# State tracking for error recovery
STATE_FILE="$HOME/.archinstaller.state"
mkdir -p "$(dirname "$STATE_FILE")"

# Source new modular libraries
source "$SCRIPTS_DIR/lib/core.sh"
source "$SCRIPTS_DIR/lib/ui.sh"
source "$SCRIPTS_DIR/lib/system.sh"
source "$SCRIPTS_DIR/lib/package.sh"
source "$SCRIPTS_DIR/lib/config.sh"

# Source common.sh for backward compatibility with existing scripts
source "$SCRIPTS_DIR/common.sh"

# Source dashboard module for professional wizard-style display
source "$SCRIPTS_DIR/lib/dashboard.sh"

# Install gum silently for enhanced UI experience
if ! command -v gum >/dev/null 2>&1; then
  log_to_file "Installing gum for enhanced UI experience..."
  if sudo pacman -S --noconfirm gum >/dev/null 2>&1; then
    log_to_file "Gum installed successfully"
  else
    log_to_file "Failed to install gum, falling back to basic UI"
  fi
fi

# Initialize core library
init_core

START_TIME=$(date +%s)

# Parse flags
VERBOSE=false
DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    -h|--help)
      show_help
      ;;
    --verbose|-v)
      VERBOSE=true
      ;;
    --quiet|-q)
      VERBOSE=false
      ;;
    --dry-run|-d)
      DRY_RUN=true
      VERBOSE=true
      ;;
    *)
      echo "Unknown option: $arg"
      echo "Use --help for usage information"
      exit 1
      ;;
  esac
done
export VERBOSE
export DRY_RUN
export INSTALL_LOG
export START_TIME

arch_ascii

# Enhanced system requirements checking with hardware compatibility
check_system_requirements() {
  local requirements_failed=false
  
  # Use the enhanced compatibility check from common.sh
  if ! check_system_compatibility; then
    ui_error "System compatibility check failed!"
    ui_info "Please address the issues listed above before continuing."
    exit 1
  fi
  
  # Additional hardware-specific checks
  local hardware_issues=()
  
  # Bootloader detection will happen during the bootloader config step
  log_to_file "Bootloader type will be detected during Step 6 (Bootloader & Plymouth)"
  
  # Check for UEFI vs BIOS mode
  if [ -d /sys/firmware/efi ]; then
    log_to_file "UEFI boot mode detected"
  else
    log_to_file "BIOS/Legacy boot mode detected"
    hardware_issues+=("Legacy BIOS mode detected - some features may not work optimally")
  fi
  
  # Check GPU drivers availability
  if lspci | grep -qi vga; then
    local gpu_vendor=$(lspci | grep -i vga | head -1 | awk '{print $1}' | cut -d: -f2)
    case "$gpu_vendor" in
      *"Intel"*)
        log_to_file "Intel GPU detected - mesa drivers will be configured"
        ;;
      *"NVIDIA"*)
        log_to_file "NVIDIA GPU detected - proprietary drivers will be configured"
        ;;
      *"AMD"*)
        log_to_file "AMD GPU detected - open-source drivers will be configured"
        ;;
      *)
        log_to_file "Unknown GPU detected - generic drivers will be used"
        ;;
    esac
  else
    hardware_issues+=("No GPU detected - this may be a headless system")
  fi
  
  # Check storage type for optimizations
  local root_device=$(findmnt -n -o SOURCE / | cut -d'[' -f1 | cut -d'/' -f3)
  if [ -n "$root_device" ]; then
    if echo "$root_device" | grep -q "nvme"; then
      log_to_file "NVMe storage detected - NVMe optimizations will be applied"
    elif [ -b "/dev/$root_device" ] && [ "$(cat /sys/block/${root_device}/queue/rotational 2>/dev/null)" = "0" ]; then
      log_to_file "SSD storage detected - SSD optimizations will be applied"
    else
      log_to_file "HDD storage detected - HDD optimizations will be applied"
    fi
  else
    hardware_issues+=("Could not determine root storage device")
  fi
  
  # Check system memory for optimizations
  local total_mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  local total_mem_gb=$((total_mem_kb / 1024 / 1024))
  if [ "$total_mem_gb" -lt 2 ]; then
    hardware_issues+=("Low memory detected (${total_mem_gb}GB) - at least 2GB recommended")
  else
    log_to_file "System memory: ${total_mem_gb}GB - appropriate optimizations will be applied"
  fi
  
  # Report hardware issues if any
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

check_system_requirements
show_menu

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

# Function to validate state file integrity
validate_state_file() {
  if [ ! -f "$STATE_FILE" ]; then
    return 0  # No file is valid
  fi
  
  # Check if file is readable and not empty
  if [ ! -r "$STATE_FILE" ] || [ ! -s "$STATE_FILE" ]; then
    log_warning "State file is corrupted or empty. Starting fresh installation."
    rm -f "$STATE_FILE" 2>/dev/null || true
    return 1
  fi
  
  return 0
}

# Enhanced resume functionality with partial failure handling and error recovery
show_resume_menu() {
  # Validate state file first
  if ! validate_state_file; then
    return 0
  fi
  
  if [ -f "$STATE_FILE" ] && [ -s "$STATE_FILE" ]; then
    echo ""
    ui_info "Previous installation detected. Checking installation status..."

    local completed_steps=()
    local step_status=()
    local has_failures=false
    local last_completed_step=""

    # Read and parse state file
    while IFS= read -r step; do
      completed_steps+=("$step")
      # Check if step was marked as completed
      if [[ "$step" =~ ^COMPLETED: ]]; then
        step_status+=("completed")
        last_completed_step="${step#*: }"
      elif [[ "$step" =~ ^FAILED: ]]; then
        step_status+=("failed")
        has_failures=true
      else
        # Legacy format - assume completed
        step_status+=("completed")
        last_completed_step="$step"
      fi
    done < "$STATE_FILE"

    if [ ${#completed_steps[@]} -eq 0 ]; then
      ui_info "No completed steps found in state file"
      return 0
    fi

    echo ""
    if supports_gum; then
      gum style --foreground "$GUM_HEADER" "Installation Progress Summary"
      echo ""
      for i in "${!completed_steps[@]}"; do
        local step="${completed_steps[$i]}"
        local status="${step_status[$i]}"
        local display_step="${step#*: }"
        
        case "$status" in
          "completed")
            gum style --foreground "$GUM_SUCCESS" "  [COMPLETED] $display_step" >/dev/null
            ;;
          "failed")
            gum style --foreground "$GUM_ERROR" "  [FAILED] $display_step" >/dev/null
            ;;
        esac
      done
      echo ""
      
      if [ "$has_failures" = true ]; then
        if gum confirm --default=true "Found failed steps. Retry failed steps first?"; then
          ui_info "Will retry failed steps during installation"
          return 0
        elif gum confirm --default=false "Resume from last completed step?"; then
          ui_success "Resuming installation from last completed step..."
          return 0
        else
          if gum confirm --default=false "Start fresh installation (this will clear previous progress)?"; then
            rm -f "$STATE_FILE" 2>/dev/null || true
            ui_info "Starting fresh installation..."
            return 0
          else
            ui_info "Installation cancelled by user"
            exit 0
          fi
        fi
      else
        if gum confirm --default=true "Resume installation from where you left off?"; then
          ui_success "Resuming installation..."
          return 0
        else
          if gum confirm --default=false "Start fresh installation (this will clear previous progress)?"; then
            rm -f "$STATE_FILE" 2>/dev/null || true
            ui_info "Starting fresh installation..."
            return 0
          else
            ui_info "Installation cancelled by user"
            exit 0
          fi
        fi
      fi
    else
      # Fallback for systems without gum
      echo ""
      for i in "${!completed_steps[@]}"; do
        local step="${completed_steps[$i]}"
        local status="${step_status[$i]}"
        local display_step="${step#*: }"
        
        case "$status" in
          "completed")
            echo -e "${THEME_SUCCESS}[COMPLETED]${RESET} $display_step"
            ;;
          "failed")
            echo -e "${THEME_ERROR}[FAILED]${RESET} $display_step"
            ;;
        esac
      done
      echo ""
      
      if [ "$has_failures" = true ]; then
        echo "Found failed steps. Options:"
        echo "1. Retry failed steps first"
        echo "2. Resume from last completed step"
        echo "3. Start fresh installation"
        echo "4. Cancel"
        echo ""
        read -p "Choose an option (1-4): " choice
        
        case "$choice" in
          1)
            ui_info "Will retry failed steps during installation"
            return 0
            ;;
          2)
            ui_success "Resuming installation from last completed step..."
            return 0
            ;;
          3)
            rm -f "$STATE_FILE" 2>/dev/null || true
            ui_info "Starting fresh installation..."
            return 0
            ;;
          4)
            ui_info "Installation cancelled by user"
            exit 0
            ;;
          *)
            ui_warn "Invalid option. Resuming installation..."
            return 0
            ;;
        esac
      else
        echo "Resume installation from where you left off? (y/n)"
        read -r response
        if [[ "$response" =~ ^[Yy]$ ]]; then
          ui_success "Resuming installation..."
          return 0
        else
          echo "Start fresh installation? (y/n)"
          read -r fresh_response
          if [[ "$fresh_response" =~ ^[Yy]$ ]]; then
            rm -f "$STATE_FILE" 2>/dev/null || true
            ui_info "Starting fresh installation..."
            return 0
          else
            ui_info "Installation cancelled by user"
            exit 0
          fi
        fi
      fi
    fi
  fi
}

# Show resume menu if previous installation detected
if [ -f "$STATE_FILE" ] && [ -s "$STATE_FILE" ]; then
  show_resume_menu
fi

# Dry-run mode banner
if [ "$DRY_RUN" = true ]; then
  ui_header "DRY-RUN MODE ENABLED"
  ui_info "Preview mode: No changes will be made"
  ui_info "Package installations will be simulated"
  ui_info "System configurations will be previewed"
  echo ""
  sleep 2
fi

# Prompt for sudo using UI helpers
if [ "$DRY_RUN" = false ]; then
  ui_info "Please enter your sudo password to begin the installation:"
  sudo -v || { ui_error "Sudo required. Exiting."; exit 1; }
else
  ui_info "Dry-run mode: Skipping sudo authentication"
fi

# Keep sudo alive (skip in dry-run mode)
if [ "$DRY_RUN" = false ]; then
  while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &
  SUDO_KEEPALIVE_PID=$!
  # Enhanced trap with error handling
  trap 'cleanup_on_error $LINENO; save_log_on_exit' EXIT INT TERM ERR
else
  trap 'cleanup_on_error $LINENO; save_log_on_exit' EXIT INT TERM ERR
fi

# Function to mark step as completed with atomic append
mark_step_complete() {
  local step_name="$1"
  
  # Validate step name
  if [ -z "$step_name" ]; then
    log_error "mark_step_complete: step_name cannot be empty"
    return 1
  fi
  
  # Atomic append with file locking to prevent corruption
  (
    flock -x 200
    echo "$step_name" >> "$STATE_FILE"
  ) 200>>"$STATE_FILE" 2>/dev/null || {
    log_error "Failed to update state file for step: $step_name"
    return 1
  }
}

# Function to check if step was completed
is_step_complete() {
  [ -f "$STATE_FILE" ] && grep -q "^$1$" "$STATE_FILE"
}


# Enhanced step completion with status tracking and error recovery
# Tracks both completed and failed steps with detailed progress reporting
mark_step_complete_with_progress() {
  local step_name="$1"
  local status="${2:-completed}"

  # Validate step name
  if [ -z "$step_name" ]; then
    log_error "mark_step_complete_with_progress: step_name cannot be empty"
    return 1
  fi

  # Write status to state file with consistent format for parsing
  if [ "$status" = "completed" ]; then
    echo "COMPLETED: $step_name" >> "$STATE_FILE"
  else
    echo "FAILED: $step_name" >> "$STATE_FILE"
  fi
}

# Enhanced error handling and rollback functions
cleanup_on_error() {
  local exit_code=${1:-$?}
  local error_line=${2:-$LINENO}
  
  if [ $exit_code -ne 0 ]; then
    # Mark installation as failed
    INSTALLATION_SUCCESS=false
    
    log_error "Installation failed with exit code $exit_code at line $error_line"
    log_error "Check the log file for details: $INSTALL_LOG"
    
    # Kill sudo keep-alive if running
    if [ -n "${SUDO_KEEPALIVE_PID+x}" ]; then
      kill $SUDO_KEEPALIVE_PID 2>/dev/null || true
    fi
    
    # Offer recovery options
    echo ""
    ui_error "Installation encountered an error!"
    ui_header "Recovery Options"
    ui_info "1. Run the script again to resume from where it left off"
    ui_info "2. Check the log file: $INSTALL_LOG"
    ui_info "3. Start fresh installation: rm -f $STATE_FILE"
    
    # Save error state
    echo "FAILED: Installation failed at line $error_line (exit code: $exit_code)" >> "$STATE_FILE"
  fi
}

# Global installation success tracking
INSTALLATION_SUCCESS=true

# Function to save log on exit
save_log_on_exit() {
  # Kill sudo keep-alive if running
  if [ -n "${SUDO_KEEPALIVE_PID+x}" ]; then
    kill $SUDO_KEEPALIVE_PID 2>/dev/null || true
  fi
  
  {
    echo ""
    echo "=========================================="
    echo "Installation ended: $(date)"
    echo "=========================================="
    
    # Add summary if installation completed successfully
    if [ "$INSTALLATION_SUCCESS" = "true" ]; then
      echo "Installation completed successfully!"
      echo "Total installation time: $(($(date +%s) - START_TIME)) seconds"
    else
      echo "Installation completed with errors!"
      echo "Check the log above for details."
    fi
  } >> "$INSTALL_LOG"
}

# Installation start — enter dashboard wizard mode
dashboard_init

# Step 1: System Preparation
dashboard_step "System Preparation" 1
if is_step_complete "system_preparation"; then
  dashboard_skip
else
  if dashboard_run "$SCRIPTS_DIR/system_preparation.sh"; then
    mark_step_complete_with_progress "system_preparation" "completed"
    dashboard_ok
  else
    mark_step_complete_with_progress "system_preparation" "failed"
    dashboard_fail
    log_error "System preparation failed"
    if gum_confirm "System preparation failed. Continue with installation?" "This may cause issues with subsequent steps."; then
      ui_warn "Continuing installation despite system preparation failure"
    else
      ui_error "Installation stopped due to system preparation failure"
      exit 1
    fi
  fi
fi

# Step 2: Shell Setup
dashboard_step "Shell Setup" 2
if is_step_complete "shell_setup"; then
  dashboard_skip
else
  if dashboard_run "$SCRIPTS_DIR/shell_setup.sh"; then
    mark_step_complete_with_progress "shell_setup" "completed"
    dashboard_ok
  else
    mark_step_complete_with_progress "shell_setup" "failed"
    dashboard_fail
    log_error "Shell setup failed"
    ui_warn "Shell setup failed but continuing installation"
  fi
fi

# Step 3: Yay Installation
dashboard_step "Yay Installation" 3
if is_step_complete "yay_installation"; then
  dashboard_skip
else
  if dashboard_run "$SCRIPTS_DIR/yay.sh"; then
    mark_step_complete_with_progress "yay_installation" "completed"
    dashboard_ok
  else
    mark_step_complete_with_progress "yay_installation" "failed"
    dashboard_fail
    log_error "Yay installation failed"
    ui_warn "Yay installation failed but continuing installation (AUR packages will not be available)"
  fi
fi

# Step 4: Programs Installation
dashboard_step "Programs Installation" 4
if is_step_complete "programs_installation"; then
  dashboard_skip
else
  if dashboard_run "$SCRIPTS_DIR/programs.sh"; then
    mark_step_complete_with_progress "programs_installation" "completed"
    dashboard_ok
  else
    mark_step_complete_with_progress "programs_installation" "failed"
    dashboard_fail
    log_error "Programs installation failed"
    ui_warn "Programs installation failed but continuing installation"
  fi
fi

# Step 5: Gaming Mode
dashboard_step "Gaming Mode" 5
if [[ "$INSTALL_MODE" == "server" ]]; then
  dashboard_skip "Skipped — server mode"
elif is_step_complete "gaming_mode"; then
  dashboard_skip
else
  if dashboard_run "$SCRIPTS_DIR/gaming_mode.sh"; then
    mark_step_complete_with_progress "gaming_mode" "completed"
    dashboard_ok
  else
    mark_step_complete_with_progress "gaming_mode" "failed"
    dashboard_fail
    log_error "Gaming Mode failed"
    ui_warn "Gaming Mode failed but continuing installation (gaming optimizations not applied)"
  fi
fi

# Step 6: Bootloader and Kernel Configuration
dashboard_step "Bootloader and Kernel Configuration" 6
if is_step_complete "bootloader_config"; then
  dashboard_skip
else
  if dashboard_run "$SCRIPTS_DIR/bootloader_config.sh"; then
    mark_step_complete_with_progress "bootloader_config" "completed"
    dashboard_ok
  else
    mark_step_complete_with_progress "bootloader_config" "failed"
    dashboard_fail
    log_error "Bootloader and kernel configuration failed"
    if gum_confirm "Bootloader configuration failed. Continue with installation?" "This may prevent your system from booting properly."; then
      ui_warn "Continuing installation despite bootloader configuration failure"
    else
      ui_error "Installation stopped due to bootloader configuration failure"
      exit 1
    fi
  fi
fi

# Step 7: Fail2ban Setup
dashboard_step "Fail2ban Setup" 7
if is_step_complete "fail2ban_setup"; then
  dashboard_skip
else
  if dashboard_run "$SCRIPTS_DIR/fail2ban.sh"; then
    mark_step_complete_with_progress "fail2ban_setup" "completed"
    dashboard_ok
  else
    mark_step_complete_with_progress "fail2ban_setup" "failed"
    dashboard_fail
    log_error "Fail2ban setup failed"
    ui_warn "Fail2ban setup failed but continuing installation (SSH security protection not applied)"
  fi
fi

# Step 8: System Services
dashboard_step "System Services" 8
if is_step_complete "system_services"; then
  dashboard_skip
else
  if dashboard_run "$SCRIPTS_DIR/system_services.sh"; then
    mark_step_complete_with_progress "system_services" "completed"
    dashboard_ok
  else
    mark_step_complete_with_progress "system_services" "failed"
    dashboard_fail
    log_error "System services failed"
    ui_warn "System services failed but continuing installation"
  fi
fi

# Step 9: Wake-on-LAN Configuration
dashboard_step "Wake-on-LAN Configuration" 9
if is_step_complete "wakeonlan_config"; then
  dashboard_skip
else
  # Source first to define configure_wakeonlan, then call it
  source "$SCRIPTS_DIR/wakeonlan_config.sh" >> "$INSTALL_LOG"
  if configure_wakeonlan >> "$INSTALL_LOG"; then
    mark_step_complete_with_progress "wakeonlan_config" "completed"
    dashboard_ok
  else
    mark_step_complete_with_progress "wakeonlan_config" "failed"
    dashboard_fail
    log_error "Wake-on-LAN configuration failed"
    ui_warn "Wake-on-LAN configuration failed but continuing installation"
  fi
fi

# Step 10: Maintenance
dashboard_step "Maintenance" 10
if is_step_complete "maintenance"; then
  dashboard_skip
else
  if dashboard_run "$SCRIPTS_DIR/maintenance.sh"; then
    mark_step_complete_with_progress "maintenance" "completed"
    dashboard_ok
  else
    mark_step_complete_with_progress "maintenance" "failed"
    dashboard_fail
    log_error "Maintenance failed"
    ui_warn "Maintenance failed but installation completed"
  fi
fi

dashboard_finish

if [ "$DRY_RUN" = true ]; then
  echo ""
  ui_info "This was a preview run. No changes were made to your system."
  ui_info "To perform the actual installation, run: ./install.sh"
  echo ""
fi

log_performance "Total installation time"

prompt_reboot
