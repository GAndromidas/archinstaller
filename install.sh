#!/bin/bash
set -uo pipefail

# Installation log file
INSTALL_LOG="$HOME/.archinstaller.log"

# Function to show help
show_help() {
  cat << EOF
Archinstaller - Comprehensive Arch Linux Post-Installation Script

USAGE:
    ./install.sh [OPTIONS]

OPTIONS:
    -h, --help      Show this help message and exit
    -v, --verbose   Enable verbose output (show all package installation details)
    -q, --quiet     Quiet mode (minimal output)
    -d, --dry-run   Preview what will be installed without making changes

DESCRIPTION:
    Archinstaller transforms a fresh Arch Linux installation into a fully
    configured, optimized system. It installs essential packages, configures
    desktop environment, sets up security features, and applies performance
    optimizations.

INSTALLATION MODES:
    Standard        Complete setup with all recommended packages
    Minimal         Essential tools only for lightweight installations
    Custom          Interactive selection of packages to install

FEATURES:
    - Desktop environment detection and optimization (KDE, GNOME, Cosmic)
    - Security hardening (Fail2ban, Firewall)
    - Performance tuning (Plymouth boot screen)
    - Optional gaming mode with performance optimizations
    - Btrfs snapshot support with automatic configuration

    - Automatic GPU driver detection and installation

REQUIREMENTS:
    - Fresh Arch Linux installation
    - Active internet connection
    - Regular user account with sudo privileges
    - Minimum 2GB free disk space

EXAMPLES:
    ./install.sh                Run installer with interactive prompts
    ./install.sh --verbose      Run with detailed package installation output
    ./install.sh --help         Show this help message

LOG FILE:
    Installation log saved to: ~/.archinstaller.log

MORE INFO:
    https://github.com/gandromidas/archinstaller

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

source "$SCRIPTS_DIR/common.sh"

# Install gum silently for enhanced UI experience
if ! command -v gum >/dev/null 2>&1; then
  log_to_file "Installing gum for enhanced UI experience..."
  if sudo pacman -S --noconfirm gum >/dev/null 2>&1; then
    log_to_file "Gum installed successfully"
  else
    log_to_file "Failed to install gum, falling back to basic UI"
  fi
fi

# Initialize log file
{
  echo "=========================================="
  echo "Archinstaller Installation Log"
  echo "Started: $(date)"
  echo "=========================================="
  echo ""
} > "$INSTALL_LOG"

# Function to log to both console and file
log_both() {
  echo "$1" | tee -a "$INSTALL_LOG"
}

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
    echo -e "${RED}Error: System compatibility check failed!${RESET}"
    echo -e "${YELLOW}   Please address the issues listed above before continuing.${RESET}"
    exit 1
  fi
  
  # Additional hardware-specific checks
  local hardware_issues=()
  
  # Check bootloader type and compatibility
  local bootloader=$(detect_bootloader 2>/dev/null || echo "unknown")
  case "$bootloader" in
    "grub"|"systemd-boot"|"limine")
      log_to_file "Detected bootloader: $bootloader"
      ;;
    "unknown")
      hardware_issues+=("Unsupported or unknown bootloader detected")
      ;;
  esac
  
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
    echo -e "${YELLOW}Warning: Hardware compatibility issues detected:${RESET}"
    for issue in "${hardware_issues[@]}"; do
      echo -e "${YELLOW}   - $issue${RESET}"
    done
    echo ""
    if ! gum_confirm "Continue despite hardware compatibility issues?" "Some features may not work optimally."; then
      ui_info "Installation cancelled by user"
      exit 0
    fi
  fi
  
  log_to_file "System requirements and hardware compatibility checks passed"
}

check_system_requirements
show_menu

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
      gum style --foreground 220 "Installation Progress Summary"
      echo ""
      for i in "${!completed_steps[@]}"; do
        local step="${completed_steps[$i]}"
        local status="${step_status[$i]}"
        local display_step="${step#*: }"
        
        case "$status" in
          "completed")
            gum style --foreground 10 "  [COMPLETED] $display_step" >/dev/null
            ;;
          "failed")
            gum style --foreground 196 "  [FAILED] $display_step" >/dev/null
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
            echo -e "${GREEN}[COMPLETED]${RESET} $display_step"
            ;;
          "failed")
            echo -e "${RED}[FAILED]${RESET} $display_step"
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
  echo ""
  echo -e "${YELLOW}========================================${RESET}"
  echo -e "${YELLOW}         DRY-RUN MODE ENABLED${RESET}"
  echo -e "${YELLOW}========================================${RESET}"
  echo -e "${CYAN}Preview mode: No changes will be made${RESET}"
  echo -e "${CYAN}Package installations will be simulated${RESET}"
  echo -e "${CYAN}System configurations will be previewed${RESET}"
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

# Function to mark step as completed with atomic write
mark_step_complete() {
  local step_name="$1"
  
  # Validate step name
  if [ -z "$step_name" ]; then
    log_error "mark_step_complete: step_name cannot be empty"
    return 1
  fi
  
  # Atomic write with file locking to prevent corruption
  local temp_state_file="$STATE_FILE.tmp.$$"
  (
    flock -x 200
    echo "$step_name" >> "$temp_state_file"
  ) 200>"$temp_state_file" && mv "$temp_state_file" "$STATE_FILE" 2>/dev/null || {
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
    ui_info "Options:"
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

# Installation start header
print_header "Starting Arch Linux Installation" \
  "This process will take approximately 10-20 minutes depending on your internet speed." \
  "You can safely leave this running - it will handle everything automatically!"

# Step 1: System Preparation
# Check if step was previously completed successfully
if is_step_complete "system_preparation"; then
  ui_info "Step 1 (System Preparation) already completed - skipping"
else
  print_step_header_with_timing 1 "$TOTAL_STEPS" "System Preparation"
  ui_info "Installing system utilities..."
  if step "System Preparation" && source "$SCRIPTS_DIR/system_preparation.sh"; then
    mark_step_complete_with_progress "system_preparation" "completed"
  else
    mark_step_complete_with_progress "system_preparation" "failed"
    log_error "System preparation failed"
    # For critical steps, ask user if they want to continue
    if gum_confirm "System preparation failed. Continue with installation?" "This may cause issues with subsequent steps."; then
      ui_warn "Continuing installation despite system preparation failure"
    else
      ui_error "Installation stopped due to system preparation failure"
      exit 1
    fi
  fi
fi

# Step 2: Shell Setup
# Check if step was previously completed successfully
if is_step_complete "shell_setup"; then
  ui_info "Step 2 (Shell Setup) already completed - skipping"
else
  print_step_header_with_timing 2 "$TOTAL_STEPS" "Shell Setup"
  ui_info "Installing shell environment..."
  if step "Shell Setup" && source "$SCRIPTS_DIR/shell_setup.sh"; then
    mark_step_complete_with_progress "shell_setup" "completed"
  else
    mark_step_complete_with_progress "shell_setup" "failed"
    log_error "Shell setup failed"
    # Shell setup is important but not critical for system functionality
    ui_warn "Shell setup failed but continuing installation"
  fi
fi

# Step 3: Plymouth Setup
if [[ "$INSTALL_MODE" == "server" ]]; then
  ui_info "Server mode selected, skipping Plymouth (graphical boot) setup."
else
  # Check if step was previously completed successfully
  if is_step_complete "plymouth_setup"; then
    ui_info "Step 3 (Plymouth Setup) already completed - skipping"
  else
    print_step_header_with_timing 3 "$TOTAL_STEPS" "Plymouth Setup"
    ui_info "Configuring boot..."
    if step "Plymouth Setup" && source "$SCRIPTS_DIR/plymouth.sh"; then
      mark_step_complete_with_progress "plymouth_setup" "completed"
    else
      mark_step_complete_with_progress "plymouth_setup" "failed"
      log_error "Plymouth setup failed"
      ui_warn "Plymouth setup failed but continuing installation"
    fi
  fi
fi

# Step 4: Yay Installation
# Check if step was previously completed successfully
if is_step_complete "yay_installation"; then
  ui_info "Step 4 (Yay Installation) already completed - skipping"
else
  print_step_header_with_timing 4 "$TOTAL_STEPS" "Yay Installation"
  ui_info "Installing AUR helper..."
  if step "Yay Installation" && source "$SCRIPTS_DIR/yay.sh"; then
    mark_step_complete_with_progress "yay_installation" "completed"
  else
    mark_step_complete_with_progress "yay_installation" "failed"
    log_error "Yay installation failed"
    # AUR helper is optional for basic functionality
    ui_warn "Yay installation failed but continuing installation (AUR packages will not be available)"
  fi
fi

# Step 5: Programs Installation
# Check if step was previously completed successfully
if is_step_complete "programs_installation"; then
  ui_info "Step 5 (Programs Installation) already completed - skipping"
else
  print_step_header_with_timing 5 "$TOTAL_STEPS" "Programs Installation"
  ui_info "Installing applications..."
  if step "Programs Installation" && source "$SCRIPTS_DIR/programs.sh"; then
    mark_step_complete_with_progress "programs_installation" "completed"
  else
    mark_step_complete_with_progress "programs_installation" "failed"
    log_error "Programs installation failed"
    # Programs are optional for system functionality
    ui_warn "Programs installation failed but continuing installation"
  fi
fi

# Step 6: Smart Peripheral Detection
# Check if step was previously completed successfully
if is_step_complete "peripheral_detection"; then
  ui_info "Step 6 (Smart Peripheral Detection) already completed - skipping"
else
  print_step_header_with_timing 6 "$TOTAL_STEPS" "Smart Peripheral Detection"
  ui_info "Detecting peripherals..."
  if step "Smart Peripheral Detection" && source "$SCRIPTS_DIR/peripheral_detection.sh" && smart_peripheral_detection; then
    mark_step_complete_with_progress "peripheral_detection" "completed"
  else
    mark_step_complete_with_progress "peripheral_detection" "failed"
    log_error "Smart peripheral detection failed"
    # Peripheral detection is optional for system functionality
    ui_warn "Smart peripheral detection failed but continuing installation"
  fi
fi

# Step 7: Gaming Mode
if [[ "$INSTALL_MODE" == "server" ]]; then
  ui_info "Server mode selected, skipping Gaming Mode setup."
else
  # Check if step was previously completed successfully
  if is_step_complete "gaming_mode"; then
    ui_info "Step 7 (Gaming Mode) already completed - skipping"
  else
    print_step_header_with_timing 7 "$TOTAL_STEPS" "Gaming Mode"
    ui_info "Setting up gaming tools (optional)..."
    
    if step "Gaming Mode" && source "$SCRIPTS_DIR/gaming_mode.sh"; then
      mark_step_complete_with_progress "gaming_mode" "completed"
    else
      mark_step_complete_with_progress "gaming_mode" "failed"
      log_error "Gaming Mode failed"
      ui_warn "Gaming Mode failed but continuing installation (gaming optimizations not applied)"
    fi
  fi
fi

# Step 8: Bootloader and Kernel Configuration
# Check if step was previously completed successfully
if is_step_complete "bootloader_config"; then
  ui_info "Step 8 (Bootloader Configuration) already completed - skipping"
else
  print_step_header_with_timing 8 "$TOTAL_STEPS" "Bootloader and Kernel Configuration"
  ui_info "Configuring bootloader..."
  if step "Bootloader and Kernel Configuration" && source "$SCRIPTS_DIR/bootloader_config.sh"; then
    mark_step_complete_with_progress "bootloader_config" "completed"
  else
    mark_step_complete_with_progress "bootloader_config" "failed"
    log_error "Bootloader and kernel configuration failed"
    # Bootloader is critical for system boot
    if gum_confirm "Bootloader configuration failed. Continue with installation?" "This may prevent your system from booting properly."; then
      ui_warn "Continuing installation despite bootloader configuration failure"
    else
      ui_error "Installation stopped due to bootloader configuration failure"
      exit 1
    fi
  fi
fi

# Step 9: Fail2ban Setup
# Check if step was previously completed successfully
if is_step_complete "fail2ban_setup"; then
  ui_info "Step 9 (Fail2ban Setup) already completed - skipping"
else
  print_step_header_with_timing 9 "$TOTAL_STEPS" "Fail2ban Setup"
  ui_info "Setting up security protection for SSH..."
  if step "Fail2ban Setup" && source "$SCRIPTS_DIR/fail2ban.sh"; then
    mark_step_complete_with_progress "fail2ban_setup" "completed"
  else
    mark_step_complete_with_progress "fail2ban_setup" "failed"
    log_error "Fail2ban setup failed"
    ui_warn "Fail2ban setup failed but continuing installation (SSH security protection not applied)"
  fi
fi

# Step 10: System Services
# Check if step was previously completed successfully
if is_step_complete "system_services"; then
  ui_info "Step 10 (System Services) already completed - skipping"
else
  print_step_header_with_timing 10 "$TOTAL_STEPS" "System Services"
  ui_info "Configuring services..."
  if step "System Services" && source "$SCRIPTS_DIR/system_services.sh"; then
    mark_step_complete_with_progress "system_services" "completed"
  else
    mark_step_complete_with_progress "system_services" "failed"
    log_error "System services failed"
    # System services are important but not always critical
    ui_warn "System services failed but continuing installation"
  fi
fi

# Step 11: Maintenance
# Check if step was previously completed successfully
if is_step_complete "maintenance"; then
  ui_info "Step 11 (Maintenance) already completed - skipping"
else
  print_step_header_with_timing 11 "$TOTAL_STEPS" "Maintenance"
  ui_info "System optimization..."
  if step "Maintenance" && source "$SCRIPTS_DIR/maintenance.sh"; then
    mark_step_complete_with_progress "maintenance" "completed"
  else
    mark_step_complete_with_progress "maintenance" "failed"
    log_error "Maintenance failed"
    ui_warn "Maintenance failed but installation completed"
  fi
fi
if [ "$DRY_RUN" = true ]; then
  echo -e "${YELLOW}This was a preview run. No changes were made to your system.${RESET}"
  echo -e "${CYAN}To perform the actual installation, run:${RESET} ${GREEN}./install.sh${RESET}"
  echo ""
fi

log_performance "Total installation time"

prompt_reboot
