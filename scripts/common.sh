#!/bin/bash
set -uo pipefail

# ============================================================================
# SECTION 1: COLOR VARIABLES & BASIC FUNCTIONS
# ============================================================================

# Color variables for output formatting (only define if not already set by core.sh)
if [ -z "${RED:-}" ]; then
    if [ -t 1 ]; then
        RED='\033[0;31m'
        GREEN='\033[0;32m'
        YELLOW='\033[1;33m'
        CYAN='\033[0;36m'
        BLUE='\033[0;34m'
        RESET='\033[0m'
    else
        RED=''
        GREEN=''
        YELLOW=''
        CYAN=''
        BLUE=''
        RESET=''
    fi
fi

# Terminal formatting helpers
TERM_WIDTH=$(tput cols 2>/dev/null || echo 80)
TERM_HEIGHT=$(tput lines 2>/dev/null || echo 24)

# Global arrays and variables
ERRORS=()                   # Collects error messages for summary
CURRENT_STEP=1              # Tracks current step for progress display
INSTALLED_PACKAGES=()       # Tracks installed packages
REMOVED_PACKAGES=()         # Tracks removed packages
FAILED_PACKAGES=()          # Tracks packages that failed to install

# Timing and progress tracking
STEP_TIMES=()               # Tracks time for each step
STEP_START_TIME=0           # Start time of current step
INSTALLATION_START_TIME=0   # Overall installation start time

# UI/Flow configuration
TOTAL_STEPS=10
: "${VERBOSE:=false}"   # Can be overridden/exported by caller

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"  # Script directory
CONFIGS_DIR="$SCRIPT_DIR/../configs"                           # Config files directory
SCRIPTS_DIR="$SCRIPT_DIR"                                      # Scripts directory


# Distribution detection
IS_ARCH=false
FIREWALL_PREFERENCE="ufw"

# Check for EndeavourOS first using /etc/os-release (standard location)
if [[ -f /etc/os-release ]] && grep -q 'ID="endeavouros"' /etc/os-release 2>/dev/null; then
    FIREWALL_PREFERENCE="firewalld"
elif [[ -f /etc/arch-release ]]; then
    IS_ARCH=true
fi

# Dynamic helper utilities based on distribution
BASE_HELPER_UTILS=(base-devel bc bluez-utils cronie curl eza fastfetch flatpak fzf git openssh pacman-contrib rate-mirrors rsync usbutils yq zoxide)
FIREWALL_UTILS=(ufw)  # For Arch Linux

# Build final HELPER_UTILS array
HELPER_UTILS=("${BASE_HELPER_UTILS[@]}")

# Only add firewall utilities if not on EndeavourOS (which uses firewalld)
if [[ "$FIREWALL_PREFERENCE" != "firewalld" ]]; then
    HELPER_UTILS+=("${FIREWALL_UTILS[@]}")
else
    # Silent - no output needed
    :
fi

# Ensure critical variables are defined
: "${HOME:=/home/$USER}"
: "${USER:=$(whoami)}"
: "${XDG_CURRENT_DESKTOP:=}"
: "${INSTALL_LOG:=$HOME/.archinstaller.log}"

# Source library modules (provides log_*, ui_*, step, run_step, package, system functions)
for __lib_module in core ui system package config; do
    source "$SCRIPT_DIR/lib/$__lib_module.sh"
done
unset __lib_module

# Improved terminal output functions
# ============================================================================
# SECTION 2: LOGGING FUNCTIONS
# ============================================================================


# ============================================================================
# SECTION 3: CONFIGURATION VALIDATION FUNCTIONS
# ============================================================================

# Validate configuration file before modification
validate_config_file() {
    local config_file="$1"
    local backup_dir="${2:-/tmp/archinstaller_backups}"
    
    # Create backup directory if it doesn't exist
    sudo mkdir -p "$backup_dir" 2>/dev/null || true
    
    if [ -f "$config_file" ]; then
        # Check if file is readable and not empty
        if [ ! -r "$config_file" ] || [ ! -s "$config_file" ]; then
            log_warning "Configuration file $config_file is corrupted or empty"
            return 1
        fi
        
        # Create backup with timestamp
        local backup_file="$backup_dir/$(basename "$config_file").backup.$(date +%Y%m%d_%H%M%S)"
        sudo cp "$config_file" "$backup_file" 2>/dev/null || {
            log_warning "Failed to backup $config_file"
            return 1
        }
        log_info "Backed up $config_file to $backup_file"
    fi
    
    return 0
}

# Check if configuration value exists and is valid
validate_config_value() {
    local config_file="$1"
    local key="$2"
    local expected_pattern="${3:-.*}"
    
    if [ ! -f "$config_file" ]; then
        return 1
    fi
    
    # Check if key exists and matches expected pattern
    if grep -q "^${key}=" "$config_file" 2>/dev/null; then
        local value=$(grep "^${key}=" "$config_file" | cut -d'=' -f2-)
        if [[ "$value" =~ $expected_pattern ]]; then
            return 0
        fi
    fi
    
    return 1
}

# Atomic file write with validation
atomic_write() {
    local content="$1"
    local target_file="$2"
    local temp_file="${target_file}.tmp.$$"
    local backup_dir="/tmp/archinstaller_backups"
    
    # Validate target directory exists
    local target_dir=$(dirname "$target_file")
    if [ ! -d "$target_dir" ]; then
        log_error "Target directory $target_dir does not exist"
        return 1
    fi
    
    # Create backup if target exists
    if [ -f "$target_file" ]; then
        validate_config_file "$target_file" "$backup_dir"
    fi
    
    # Write to temporary file first
    if ! echo "$content" > "$temp_file"; then
        log_error "Failed to write to temporary file $temp_file"
        return 1
    fi
    
    # Validate temporary file
    if [ ! -s "$temp_file" ]; then
        log_error "Temporary file $temp_file is empty"
        rm -f "$temp_file"
        return 1
    fi
    
    # Atomic move to target
    if ! sudo mv "$temp_file" "$target_file"; then
        log_error "Failed to move $temp_file to $target_file"
        rm -f "$temp_file"
        return 1
    fi
    
    log_success "Successfully wrote configuration to $target_file"
    return 0
}

# Check system compatibility
check_system_compatibility() {
    local issues=()
    
    # Check if running as root (should not be)
    if [[ $EUID -eq 0 ]]; then
        issues+=("Script should not be run as root")
    fi
    
    # Check if on Arch Linux
    if [[ ! -f /etc/arch-release ]] && [[ ! -f /etc/endeavouros-release ]]; then
        issues+=("Not running on Arch Linux or EndeavourOS")
    fi
    
    # Check disk space
    local available_space=$(df / | awk 'NR==2 {print $4}')
    if [[ $available_space -lt 2097152 ]]; then
        issues+=("Insufficient disk space (need 2GB, have $((available_space / 1024 / 1024))GB)")
    fi
    
    # Check internet connection
    if ! ping -c 1 -W 5 archlinux.org &>/dev/null; then
        issues+=("No internet connection")
    fi
    
    # Check bootloader compatibility
    if [ ! -d "/boot" ]; then
        issues+=("Boot directory not found")
    fi
    
    # Report issues
    if [ ${#issues[@]} -gt 0 ]; then
        log_error "System compatibility issues found:"
        for issue in "${issues[@]}"; do
            log_error "  - $issue"
        done
        return 1
    fi
    
    return 0
}

# ============================================================================
# SECTION 4: TERMINAL OUTPUT & UI FUNCTIONS
# ============================================================================


# Format time display helper function
format_time() {
  local seconds=$1
  if [ "$seconds" -lt 60 ]; then
    echo "${seconds}s"
  elif [ "$seconds" -lt 3600 ]; then
    local minutes=$((seconds / 60))
    local remaining_seconds=$((seconds % 60))
    echo "${minutes}m ${remaining_seconds}s"
  else
    local hours=$((seconds / 3600))
    local minutes=$(((seconds % 3600) / 60))
    echo "${hours}h ${minutes}m"
  fi
}

# Timing functions for progress estimation
start_step_timer() {
  STEP_START_TIME=$(date +%s)
  if [ "$INSTALLATION_START_TIME" -eq 0 ]; then
    INSTALLATION_START_TIME=$STEP_START_TIME
  fi
}

end_step_timer() {
  local step_name="${1:-Step $CURRENT_STEP}"
  local end_time=$(date +%s)
  local duration=$((end_time - STEP_START_TIME))
  STEP_TIMES+=("$duration")

  # Calculate average time per step
  local total_time=0
  for time in "${STEP_TIMES[@]}"; do
    total_time=$((total_time + time))
  done

  local avg_time=$((total_time / ${#STEP_TIMES[@]}))
  local remaining_steps=$((TOTAL_STEPS - CURRENT_STEP))
  local estimated_remaining=$((remaining_steps * avg_time))

  if [ "$remaining_steps" -gt 0 ]; then
    ui_info "Step completed in $(format_time $duration). Estimated remaining time: $(format_time $estimated_remaining)"
  fi
}

# Enhanced step header with time estimation

# Unified styling functions for consistent UI across all scripts
print_unified_step_header() {
  local step_num="$1"
  local total="$2"
  local title="$3"
  local content="Step $step_num of $total: $title"

  if supports_gum; then
    echo ""
    gum style --margin "1 2" --border thick --padding "1 2" --foreground "$GUM_TEXT" "$content"
    echo ""
  else
    local w=$(tput cols 2>/dev/null || echo 80)
    echo ""
    echo -e "${THEME_BORDER}#$(printf '%*s' $((w - 2)) '' | tr ' ' '=')#${RESET}"
    local pad=$((w - ${#content} - 4))
    (( pad < 1 )) && pad=1
    echo -e "${THEME_BORDER}#${RESET} ${THEME_HEADER}${content}${RESET}$(printf '%*s' $pad '') ${THEME_BORDER}#${RESET}"
    echo -e "${THEME_BORDER}#$(printf '%*s' $((w - 2)) '' | tr ' ' '=')#${RESET}"
    echo ""
  fi
}

print_unified_substep() {
  local description="$1"

  if supports_gum; then
    gum style --margin "0 2" --foreground "$GUM_WARN" "> $description"
  else
    echo -e "${THEME_SECONDARY}> $description${RESET}"
  fi
}

print_unified_success() {
  local message="$1"

  if supports_gum; then
    gum style --margin "0 4" --foreground "$GUM_SUCCESS" "✓ $message"
  else
    echo -e "${THEME_SUCCESS}✓ $message${RESET}"
  fi
}

print_unified_error() {
  local message="$1"

  if supports_gum; then
    gum style --margin "0 4" --foreground "$GUM_ERROR" "✗ $message"
  else
    echo -e "${THEME_ERROR}✗ $message${RESET}"
  fi
}

# Utility/Helper Functions

# ============================================================================
# SECTION 4: PROGRESS & TIMING FUNCTIONS
# ============================================================================
# Utility/Helper Functions


# ============================================================================
# SECTION 5: UI STYLING FUNCTIONS (gum-based)
# ============================================================================
print_header() {
  local title="$1"; shift
  if supports_gum; then
    gum style --border double --margin "1 2" --padding "1 4" --foreground "$GUM_HEADER" --border-foreground "$GUM_BORDER" "$title"
    while (( "$#" )); do
      gum style --margin "1 0 0 0" --foreground "$GUM_WARN" "$1"
      shift
    done
  else
    echo -e "${THEME_HEADER}$title${RESET}"
    echo -e "${THEME_BORDER}----------------------------------------${RESET}"
    while (( "$#" )); do
      echo -e "${THEME_TEXT}$1${RESET}"
      shift
    done
  fi
}

print_step_header() {
  local step_num="$1"; local total="$2"; local title="$3"
  if supports_gum; then
    echo ""
    gum style --border normal --margin "1 0" --padding "0 2" --foreground "$GUM_HEADER" --border-foreground "$GUM_BORDER" "Step ${step_num}/${total}: ${title}"
  else
    echo -e "${THEME_BORDER}Step ${step_num}/${total}: ${title}${RESET}"
  fi
}
arch_ascii() {
  echo -e "${THEME_PRIMARY}"
  cat << "EOF"
      _             _     ___           _        _ _
     / \   _ __ ___| |__ |_ _|_ __  ___| |_ __ _| | | ___ _ __
    / _ \ | '__/ __| '_ \ | || '_ \/ __| __/ _` | | |/ _ \ '__|
   / ___ \| | | (__| | | || || | | \__ \ || (_| | | |  __/ |
  /_/   \_\_|  \___|_| |_|___|_| |_|___/\__\__,_|_|_|\___|_|

EOF
  echo -e "${RESET}"
}

# Enhanced resume functionality
# Function to check if running in VM environment

# ============================================================================
# SECTION 7: MENU & INSTALLATION MODE SELECTION
# ============================================================================


# Function to ensure a default mirrorlist exists before any pacman operation
generate_default_mirrorlist() {
  if [ -s "/etc/pacman.d/mirrorlist" ]; then
    return 0
  fi

  log_info "Mirrorlist empty or missing. Generating default..."

  if command -v reflector >/dev/null 2>&1; then
    sudo reflector --latest 10 --protocol https --sort rate --save /etc/pacman.d/mirrorlist >>"$INSTALL_LOG" 2>&1 && {
      log_success "Default mirrorlist generated with reflector."
      return 0
    }
  fi

  sudo tee /etc/pacman.d/mirrorlist >/dev/null <<'EOF'
## Default Arch Linux mirrorlist
Server = http://mirror.archlinux.de/sites/archlinux.org/$repo/os/$arch
EOF
  log_success "Basic mirrorlist created."
}

# Function to update mirrors using rate-mirrors (silent with confirmation)
update_system_mirrors() {
  # Check if rate-mirrors is available (silent check)
  if ! command -v rate-mirrors >/dev/null 2>&1; then
    return 0
  fi
  
  local mirror_repo="arch"
  
  # Detect mirror repo silently
  if [[ -f /etc/os-release ]] && grep -q 'ID="endeavouros"' /etc/os-release 2>/dev/null; then
    mirror_repo="endeavour"
  fi
  
  # Run mirror update silently in background
  # Redirect all output to /dev/null for silent operation
  nohup bash -c "sudo rate-mirrors --allow-root --save /etc/pacman.d/mirrorlist '$mirror_repo' >/dev/null 2>&1 && sudo pacman -Syy >/dev/null 2>&1" >>"$INSTALL_LOG" 2>&1 &
  
  # Give immediate feedback that mirrors are syncing
  ui_info "Syncing package mirrors..."
  ui_success "Mirrors are being updated in background"
  
  # Return immediately without blocking
  return 0
}

# Function to check if system is headless (no display manager or X server)
is_headless_system() {
  # Check for display manager
  if systemctl is-active --quiet gdm 2>/dev/null || \
     systemctl is-active --quiet sddm 2>/dev/null || \
     systemctl is-active --quiet lightdm 2>/dev/null || \
     systemctl is-active --quiet lxdm 2>/dev/null || \
     systemctl is-active --quiet slim 2>/dev/null; then
    return 1  # Not headless
  fi

  # Check for X server
  if pgrep -x X >/dev/null 2>&1 || pgrep -x Xorg >/dev/null 2>&1; then
    return 1  # Not headless
  fi

  # Check for Wayland
  if pgrep -x weston >/dev/null 2>&1 || pgrep -x gnome-shell >/dev/null 2>&1; then
    return 1  # Not headless
  fi

  # Check if XDG_CURRENT_DESKTOP is set
  if [[ -n "${XDG_CURRENT_DESKTOP:-}" ]]; then
    return 1  # Not headless
  fi

  return 0  # Headless
}


# ============================================================================
# SECTION 6: DISPLAY & BANNER FUNCTIONS
# ============================================================================
show_menu() {
  # Display detected OS information - use /etc/os-release for EndeavourOS
  local detected_os=""
  if [[ -f /etc/os-release ]] && grep -q 'ID="endeavouros"' /etc/os-release 2>/dev/null; then
    detected_os="EndeavourOS"
  elif [[ -f /etc/arch-release ]]; then
    detected_os="Arch Linux"
  else
    detected_os="Unknown"
  fi
  
  # Check if system is headless and only offer server mode
  if is_headless_system; then
    ui_warn "Headless system detected. Only Server mode is available."
    echo -e "${THEME_TEXT}Your OS is: $detected_os${RESET}"
    INSTALL_MODE="server"
    echo "Installation Mode: Server - Headless server setup"
    return
  fi

  # Check if gum is available, fallback to traditional menu if not
  if command -v gum >/dev/null 2>&1; then
    show_gum_menu
  else
    show_traditional_menu
  fi
}

# Function to validate INSTALL_MODE
validate_install_mode() {
  local mode="$1"

  case "$mode" in
    "default"|"minimal"|"server")
      return 0
      ;;
    *)
      log_error "Invalid INSTALL_MODE: '$mode'. Valid modes are: default, minimal, server"
      return 1
      ;;
  esac
}

show_gum_menu() {
  # Display detected OS information - use /etc/os-release for EndeavourOS
  local detected_os=""
  if [[ -f /etc/os-release ]] && grep -q 'ID="endeavouros"' /etc/os-release 2>/dev/null; then
    detected_os="EndeavourOS"
  elif [[ -f /etc/arch-release ]]; then
    detected_os="Arch Linux"
  else
    detected_os="Unknown"
  fi
  
  gum style --margin "1 0" --foreground "$GUM_WARN" "Your OS is: $detected_os"
  echo ""
  
  gum style --margin "1 0" --foreground "$GUM_WARN" "This script will transform your fresh Arch Linux installation into a"
  gum style --margin "0 0 1 0" --foreground "$GUM_WARN" "fully configured, optimized system with all the tools you need!"

  local choice=$(gum choose --cursor="-> " --selected.foreground "$GUM_PRIMARY" --cursor.foreground "$GUM_PRIMARY" \
    "Standard - Complete setup with all packages (intermediate users)" \
    "Minimal - Essential tools only (recommended for new users)" \
    "Server - Headless server setup (Docker, SSH, etc.)" \
    "Exit - Cancel installation")

  case "$choice" in
    "Standard"*)
      INSTALL_MODE="default"
      if validate_install_mode "$INSTALL_MODE"; then
        echo "Installation Mode: Standard - Complete setup with all packages (intermediate users)"
      else
        log_error "Failed to validate installation mode"
        exit 1
      fi
      ;;
    "Minimal"*)
      INSTALL_MODE="minimal"
      if validate_install_mode "$INSTALL_MODE"; then
        echo "Installation Mode: Minimal - Essential tools only (recommended for new users)"
      else
        log_error "Failed to validate installation mode"
        exit 1
      fi
      ;;
    "Server"*)
      INSTALL_MODE="server"
      if validate_install_mode "$INSTALL_MODE"; then
        echo "Installation Mode: Server - Headless server setup"
      else
        log_error "Failed to validate installation mode"
        exit 1
      fi
      ;;
    "Exit"*)
      gum style --foreground "$GUM_WARN" "Installation cancelled. You can run this script again anytime."
      exit 0
      ;;
  esac
}

show_traditional_menu() {
  # Display detected OS information - use /etc/os-release for EndeavourOS
  local detected_os=""
  if [[ -f /etc/os-release ]] && grep -q 'ID="endeavouros"' /etc/os-release 2>/dev/null; then
    detected_os="EndeavourOS"
  elif [[ -f /etc/arch-release ]]; then
    detected_os="Arch Linux"
  else
    detected_os="Unknown"
  fi
  
  echo "WELCOME TO ARCH INSTALLER"
  echo "----------------------------------------"
  echo "Your OS is: $detected_os"
  echo ""
  echo "This script will transform your fresh Arch Linux installation into a"
  echo "fully configured, optimized system with all the tools you need!"
  echo ""
  echo -e "${THEME_HEADER}Choose your installation mode:${RESET}"
  echo ""
  printf "  1) Standard%-12s - Complete setup with all packages (intermediate users)\n" ""
  printf "  2) Minimal%-13s - Essential tools only (recommended for new users)\n" ""
  printf "  3) Server%-13s - Headless server setup (Docker, SSH, etc.)\n" ""
  printf "  4) Exit%-16s - Cancel installation\n" ""
  echo ""

  while true; do
    read -r -p "$(echo -e "${THEME_SECONDARY}Enter your choice [1-4]: ${RESET}")" menu_choice
          case "$menu_choice" in
        1)
          INSTALL_MODE="default"
          if validate_install_mode "$INSTALL_MODE"; then
            echo "Installation Mode: Standard - Complete setup with all packages (intermediate users)"
            break
          else
            log_error "Failed to validate installation mode"
            exit 1
          fi
          ;;
        2)
          INSTALL_MODE="minimal"
          if validate_install_mode "$INSTALL_MODE"; then
            echo "Installation Mode: Minimal - Essential tools only (recommended for new users)"
            break
          else
            log_error "Failed to validate installation mode"
            exit 1
          fi
          ;;
        3)
          INSTALL_MODE="server"
          if validate_install_mode "$INSTALL_MODE"; then
            echo "Installation Mode: Server - Headless server setup"
            break
          else
            log_error "Failed to validate installation mode"
            exit 1
          fi
          ;;
      4)
        echo -e "\n${YELLOW}Installation cancelled. You can run this script again anytime.${RESET}"
        exit 0
        ;;
      *)
        echo -e "\n${RED}Invalid choice! Please enter 1, 2, 3, or 4.${RESET}\n"
        ;;
    esac
  done
}

# Function to get all installed kernel types
get_installed_kernel_types() {
  local kernel_types=()
  command_exists pacman || { echo "Error: pacman not found." >&2; return 1; }
  pacman -Q linux &>/dev/null && kernel_types+=("linux")
  pacman -Q linux-lts &>/dev/null && kernel_types+=("linux-lts")
  pacman -Q linux-zen &>/dev/null && kernel_types+=("linux-zen")
  pacman -Q linux-hardened &>/dev/null && kernel_types+=("linux-hardened")
  echo "${kernel_types[@]}"
}

# Function: install_packages_quietly
# Description: Install packages via pacman (wrapper for generic installer)
# Parameters: $@ - Packages to install
install_packages_quietly() {
  install_package_generic "pacman" "$@"
}

# Batch install helper for multiple package groups
install_package_groups() {
  local groups=("$@")
  local all_packages=()

  for group in "${groups[@]}"; do
    case "$group" in
      "helpers")
        all_packages+=("${HELPER_UTILS[@]}")
        ;;
      "zsh")
        all_packages+=(zsh zsh-autosuggestions zsh-syntax-highlighting)
        ;;
      "starship")
        all_packages+=(starship)
        ;;
      # Add more groups as needed
    esac
  done

  # Remove duplicates before batch install
  if [ "${#all_packages[@]}" -gt 0 ]; then
    # Use associative array to filter duplicates
    declare -A pkg_map
    for pkg in "${all_packages[@]}"; do
      pkg_map["$pkg"]=1
    done
    local unique_pkgs=()
    for pkg in "${!pkg_map[@]}"; do
      unique_pkgs+=("$pkg")
    done
    install_packages_quietly "${unique_pkgs[@]}"
  fi
}

# Function for user confirmation with gum (or fallback)
# Usage: gum_confirm "Your question?" "Optional description."

# ============================================================================
# SECTION 11: PACKAGE INSTALLATION FUNCTIONS
# ============================================================================
gum_confirm() {
    local question="$1"
    local description="${2:-}" # Default to empty string if not provided

    if supports_gum; then
        # Use subshell to temporarily restore stdout/stderr to terminal for gum display
        # Cursor should be positioned below dashboard frame by dashboard_run
        (
            exec >/dev/tty 2>/dev/tty
            echo ""

            if [ -n "$description" ]; then
                gum style --foreground "$GUM_WARN" "$description"
            fi

            if gum confirm --default=true --prompt.foreground "$GUM_PRIMARY" --selected.background "$GUM_PRIMARY" "$question"; then
                exit 0
            else
                exit 1
            fi
        )
        local result=$?

        return $result
    else
        # Fallback to traditional read prompt
        echo ""
        if [ -n "$description" ]; then
            echo -e "${THEME_WARN}${description}${RESET}"
        fi

        local response
        while true; do
            read -r -p "$(echo -e "${THEME_SECONDARY}${question} [Y/n]: ${RESET}")" response
            response=${response,,} # tolower
            case "$response" in
                ""|y|yes)
                    return 0 # Yes
                    ;;
                n|no)
                    return 1 # No
                    ;;
                *)
                    echo -e "\n${THEME_ERROR}Please answer Y (yes) or N (no).${RESET}\n"
                    ;;
            esac
        done
    fi
}

prompt_reboot() {
  simple_banner "Reboot System"
  echo -e "${THEME_TEXT}Congratulations! Your Arch Linux system is now fully configured!${RESET}"
  echo ""
  echo -e "${THEME_TEXT}What happens after reboot:${RESET}"
  echo "  - Boot screen will appear"
  echo "  - Performance optimizations will be enabled"
  echo "  - Gaming tools will be available (if installed)"
  echo ""
  echo -e "${THEME_WARN}It is strongly recommended to reboot now to apply all changes.${RESET}"
  echo ""

  # Use gum menu for reboot confirmation
  if command -v gum >/dev/null 2>&1; then
    echo ""
    gum style --foreground "$GUM_WARN" "Ready to reboot your system?"
    echo ""
    if gum confirm --default=true --prompt.foreground "$GUM_PRIMARY" --selected.background "$GUM_PRIMARY" "Reboot now?"; then
      echo ""
      echo -e "${THEME_TEXT}Rebooting your system...${RESET}"
      echo -e "${THEME_HEADER}Thank you for using Arch Installer!${RESET}"
      echo ""
      sleep 2
      sudo reboot
    else
      echo ""
      echo -e "${THEME_TEXT}Reboot skipped. You can reboot manually at any time using:${RESET}"
      echo -e "${THEME_SECONDARY}   sudo reboot${RESET}"
      echo -e "${THEME_TEXT}   Or simply restart your computer.${RESET}"
    fi
  else
    # Fallback to text prompt if gum is not available
    while true; do
      read -r -p "$(echo -e "${THEME_WARN}Reboot now? [Y/n]: ${RESET}")" reboot_ans
      reboot_ans=${reboot_ans,,}
      case "$reboot_ans" in
        ""|y|yes)
          echo ""
          echo -e "${THEME_TEXT}Rebooting your system...${RESET}"
          echo -e "${THEME_WARN}Thank you for using Arch Installer!${RESET}"
          echo ""
          sleep 2
          sudo reboot
          break
          ;;
        n|no)
          echo ""
          echo -e "${THEME_TEXT}Reboot skipped. You can reboot manually at any time using:${RESET}"
          echo -e "${THEME_SECONDARY}   sudo reboot${RESET}"
          echo -e "${THEME_TEXT}   Or simply restart your computer.${RESET}"
          break
          ;;
      esac
    done
  fi

  echo ""
  # Cleanup if no errors occurred
  if [ ${#ERRORS[@]} -eq 0 ]; then
    # Optional cleanup that doesn't destroy the repo
    if gum_confirm "Do you want to clean up temporary logs?" "This will remove the installation log and state file."; then
      echo -e "${THEME_TEXT}Cleaning up temporary files...${RESET}"
      rm -f "$STATE_FILE" "$INSTALL_LOG" 2>/dev/null || true
      echo -e "${THEME_SUCCESS}✓ Temporary files cleaned up${RESET}"
    else
      echo -e "${THEME_TEXT}Skipping cleanup.${RESET}"
    fi
  fi
}

# Pre-download package lists for faster installation

# ============================================================================
# SECTION 12: CONFIRMATION & USER INTERACTION
# ============================================================================
preload_package_lists() {
  step "Preloading package lists for faster installation"
  sudo pacman -Sy --noconfirm >>"$INSTALL_LOG" 2>&1
  if command -v yay >/dev/null; then
    yay -Sy --noconfirm >>"$INSTALL_LOG" 2>&1
  else
    log_warning "yay not available for AUR package list update"
  fi
}

# Optimized system update
fast_system_update() {
  step "Performing optimized system update"
  sudo pacman -Syu --noconfirm --overwrite="*"
  if command -v yay >/dev/null; then
    yay -Syu --noconfirm
  else
    log_warning "yay not available for AUR update"
  fi
}

# Function to collect errors from custom scripts
collect_custom_script_errors() {
  local script_name="$1"
  local script_errors=("$@")
  shift
  for error in "${script_errors[@]}"; do
    ERRORS+=("$script_name: $error")
  done
}

# Function: install_aur_quietly
# Description: Install packages via AUR helper (wrapper for generic installer)
# Parameters: $@ - Packages to install
# Returns: 0 on success, 1 on failure
install_aur_quietly() {
  if ! command -v yay &>/dev/null; then
    log_error "AUR helper (yay) not found. Cannot install AUR packages." "Install yay first with: git clone https://aur.archlinux.org/yay.git && cd yay && makepkg -si"
    return 1
  fi
  install_package_generic "aur" "$@"
}

# Function: install_flatpak_quietly
# Description: Install packages via Flatpak (wrapper for generic installer)
# Parameters: $@ - Packages to install
# Returns: 0 on success, 1 on failure
install_flatpak_quietly() {
  if ! command -v flatpak &>/dev/null; then
    log_error "Flatpak not found. Cannot install Flatpak packages." "Install flatpak first with: sudo pacman -S flatpak"
    return 1
  fi
  install_package_generic "flatpak" "$@"
}
