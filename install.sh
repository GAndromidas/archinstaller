#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# =============================================================================
# TESTING & VALIDATION FRAMEWORK
# =============================================================================

# Set up error handling
trap 'handle_error $LINENO' ERR
trap 'cleanup_on_exit' EXIT

# Check if running as root, re-exec with sudo if not
if [ "$(id -u)" -ne 0 ]; then
    exec sudo "$0" "$@"
fi


# Enhanced error handling functions
handle_error() {
    local line_no="$1"
    local exit_code="$?"

    log_error "Error occurred at line $line_no with exit code $exit_code"
    log_error "Command: $BASH_COMMAND"

    # Show installation state
    if [ -f "$INSTALL_STATE_FILE" ]; then
        log_info "Installation state:"
        cat "$INSTALL_STATE_FILE"
    fi

    # Suggest rollback steps
    suggest_rollback

    return $exit_code
}

suggest_rollback() {
    log_info "To rollback installation:"
    log_info "1. Restore backed up configurations from ~/.linuxinstaller-backup-*"
    log_info "2. Remove installed packages:"
    log_info "   - For Arch: sudo pacman -Rns \$(pacman -Qq | grep -E 'package1|package2')"
    log_info "   - For Debian/Ubuntu: sudo apt remove package1 package2"
    log_info "3. Disable services: sudo systemctl disable service1 service2"
}

# LinuxInstaller v1.0 - Main installation script

# Show LinuxInstaller ASCII art banner (distribution-specific colors)
show_linuxinstaller_ascii() {
    clear

    # Set color based on detected distribution
    local ascii_color="${CYAN}"  # Default cyan
    if [ "${DISTRO_ID:-}" = "fedora" ] || [ "${DISTRO_ID:-}" = "arch" ]; then
        ascii_color="${BLUE}"  # Blue for Fedora and Arch
    elif [ "${DISTRO_ID:-}" = "debian" ]; then
        ascii_color="${RED}"   # Red for Debian
    elif [ "${DISTRO_ID:-}" = "ubuntu" ]; then
        ascii_color="\033[38;5;208m"  # Orange for Ubuntu (ANSI 208)
    fi

    echo -e "${ascii_color}"
    cat << "EOF"

      _     _                  ___           _        _ _
     | |   (_)_ __  _   ___  _|_ _|_ __  ___| |_ __ _| | | ___ _ __
     | |   | | '_ \| | | \ \/ /| || '_ \/ __| __/ _` | | |/ _ \ '__|
     | |___| | | | | |_| |>  < | || | | \__ \ || (_| | | |  __/ |
     |_____|_|_| |_|\__,_/_/\_\___|_| |_|___/\__\__,_|_|_|\___|_|
EOF
    echo -e "${LIGHT_CYAN}           Cross-Distribution Linux Post-Installation Script${RESET}"
    echo ""
}

# Menu selection logic (always shown)
show_menu_selection() {
    # Update theme for current distro
    update_distro_theme

    display_info "Choose your preferred installation mode:"
    echo ""

    if supports_gum; then
        # Beautiful gum-based menu for fully interactive environments
        choice=$(gum choose \
            --cursor.foreground "$GUM_PRIMARY_FG" \
            --selected.foreground "$GUM_SUCCESS_FG" \
            "🚀 Standard - Complete setup with all recommended packages" \
            "⚡ Minimal - Essential tools only for lightweight installations" \
            "🖥️  Server - Headless server configuration" \
            "👋 Exit")

        case "$choice" in
            "🚀 Standard - Complete setup with all recommended packages")
                export INSTALL_MODE="standard"
                display_success "Standard mode selected - Full featured setup" ;;
            "⚡ Minimal - Essential tools only for lightweight installations")
                export INSTALL_MODE="minimal"
                display_success "Minimal mode selected - Lightweight setup" ;;
            "🖥️  Server - Headless server configuration")
                export INSTALL_MODE="server"
                display_success "Server mode selected - Headless configuration" ;;
            "👋 Exit")
                display_info "Goodbye! 👋"
                exit 0 ;;
        esac

        # Gaming option for desktop modes
        if [ "$INSTALL_MODE" = "standard" ] || [ "$INSTALL_MODE" = "minimal" ]; then
            echo ""
            if gum confirm "🎮 Include Gaming Package Suite? (Steam, Wine, optimizations)" --default=yes; then
                export INSTALL_GAMING=true
                display_success "Gaming packages will be installed"
            else
                export INSTALL_GAMING=false
                display_info "Skipping gaming packages"
            fi
        else
            export INSTALL_GAMING=false
        fi
    else
        # Fallback text menu for limited environments
        display_warning "Limited terminal capabilities detected. Using text-based menu."
        echo ""

        local attempts=0
        while [ $attempts -lt 3 ]; do
            attempts=$((attempts + 1))
            echo "Available options:"
            echo "1) 🚀 Standard - Complete setup"
            echo "2) ⚡ Minimal - Essential tools only"
            echo "3) 🖥️  Server - Headless configuration"
            echo "4) 👋 Exit"
            read -r -p "Select option [1-4]: " choice 2>/dev/null || {
                display_error "Input not available in this environment."
                display_info "Please run in an interactive terminal or use git clone for full menu."
                display_info "Defaulting to Standard mode for now."
                export INSTALL_MODE="standard"
                export INSTALL_GAMING=true
                return
            }

            choice=$(echo "$choice" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

            case "$choice" in
                1|"1"|"")
                    export INSTALL_MODE="standard"
                    display_success "Standard mode selected"
                    export INSTALL_GAMING=false
                    return ;;
                2|"2")
                    export INSTALL_MODE="minimal"
                    display_success "Minimal mode selected"
                    export INSTALL_GAMING=false
                    return ;;
                3|"3")
                    export INSTALL_MODE="server"
                    display_success "Server mode selected"
                    export INSTALL_GAMING=false
                    return ;;
                4|"4")
                    display_info "Goodbye! 👋"
                    exit 0 ;;
                *)
                    if [ $attempts -eq 3 ]; then
                        display_warning "Too many invalid attempts. Defaulting to Standard mode."
                        export INSTALL_MODE="standard"
                        export INSTALL_GAMING=false
                        return
                    else
                        display_warning "Please select a valid option (1-4)"
                    fi ;;
            esac
        done
    fi
}

# Enhanced Menu Function
show_menu() {
    show_linuxinstaller_ascii

    # Always show menu for user selection
    show_menu_selection

    friendly=""
    case "$INSTALL_MODE" in
        standard) friendly="🚀 Standard - Complete setup" ;;
        minimal)  friendly="⚡ Minimal - Essential tools" ;;
        server)   friendly="🖥️  Server - Headless config" ;;
        *)        friendly="$INSTALL_MODE" ;;
    esac

    display_success "Selected: $friendly"
    if [ "$INSTALL_GAMING" = "true" ]; then
        display_info "🎮 Gaming packages: Enabled"
    fi
    echo ""
}

# Color variables (cyan theme)
CYAN='\033[0;36m'
LIGHT_CYAN='\033[1;36m'
BLUE='\033[0;34m'
RESET='\033[0m'

# --- Configuration & Paths ---
# Determine script location and derive important directories
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" 2>/dev/null && pwd || echo "/tmp")"
CONFIGS_DIR="$SCRIPT_DIR/configs"    # Distribution-specific configuration files
SCRIPTS_DIR="$SCRIPT_DIR/scripts"    # Modular script components

# Enhanced Virtual Machine Detection
detect_virtual_machine() {
    if [ -f /proc/cpuinfo ]; then
        grep -qi "hypervisor\|vmware\|virtualbox\|kvm\|qemu\|xen" /proc/cpuinfo && return 0
    fi
    if [ -f /sys/class/dmi/id/product_name ]; then
        grep -qi "virtual\|vmware\|virtualbox\|kvm\|qemu\|xen" /sys/class/dmi/id/product_name && return 0
    fi
    if [ -f /sys/class/dmi/id/sys_vendor ]; then
        grep -qi "vmware\|virtualbox\|kvm\|qemu\|xen\|innotek" /sys/class/dmi/id/sys_vendor && return 0
    fi
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        systemd-detect-virt --quiet && return 0
    fi
    return 1
}

# Verify we have the required directory structure
if [ ! -d "$SCRIPTS_DIR" ]; then
    echo "FATAL ERROR: Scripts directory not found in $SCRIPT_DIR"
    echo "This indicates a corrupted or incomplete installation."
    echo "Please re-download LinuxInstaller from the official repository:"
    echo "  git clone https://github.com/GAndromidas/linuxinstaller.git"
    exit 1
fi

# --- Source Helpers ---
# We need distro detection and common utilities immediately
# Source required helper scripts with better error handling
if [ -f "$SCRIPTS_DIR/common.sh" ]; then
    source "$SCRIPTS_DIR/common.sh"
else
    echo "FATAL ERROR: Required file 'common.sh' not found in $SCRIPTS_DIR"
    echo "This indicates a corrupted or incomplete installation."
    echo "Please re-download LinuxInstaller from the official repository:"
    echo "  git clone https://github.com/GAndromidas/linuxinstaller.git"
    exit 1
fi

if [ -f "$SCRIPTS_DIR/package_manager.sh" ]; then
    source "$SCRIPTS_DIR/package_manager.sh"
else
    echo "FATAL ERROR: Required file 'package_manager.sh' not found in $SCRIPTS_DIR"
    echo "This indicates a corrupted or incomplete installation."
    echo "Please re-download LinuxInstaller from the official repository:"
    echo "  git clone https://github.com/GAndromidas/linuxinstaller.git"
    exit 1
fi

if [ -f "$SCRIPTS_DIR/distro_check.sh" ]; then
    source "$SCRIPTS_DIR/distro_check.sh"
else
    echo "FATAL ERROR: Required file 'distro_check.sh' not found in $SCRIPTS_DIR"
    echo "This indicates a corrupted or incomplete installation."
    echo "Please re-download LinuxInstaller from the official repository."
    exit 1
fi

# Optional Wake-on-LAN integration (sourced if present).
# The module integrates the wakeonlan helper so LinuxInstaller can auto-configure WoL.
if [ -f "$SCRIPTS_DIR/wakeonlan_config.sh" ]; then
  source "$SCRIPTS_DIR/wakeonlan_config.sh"
fi

# Optional power management helper (detection + configuration).
# This module provides `show_system_info` and `configure_power_management`
# to configure power-profiles-daemon / cpupower / tuned as appropriate.
if [ -f "$SCRIPTS_DIR/power_config.sh" ]; then
  source "$SCRIPTS_DIR/power_config.sh"
fi

# --- Global Variables ---
# Runtime flags and configuration
VERBOSE=false           # Enable detailed logging output
DRY_RUN=false          # Preview mode - show what would be done without changes
TOTAL_STEPS=0          # Total number of installation steps
CURRENT_STEP=0         # Current step counter for progress tracking
INSTALL_MODE="standard" # Installation mode: standard, minimal, or server
IS_VIRTUAL_MACHINE=false # Whether we're running in a virtual machine

# Helper tracking
GUM_INSTALLED_BY_SCRIPT=false  # Track if we installed gum to clean it up later

# --- State Management ---
# Track installation progress and state for rollback capabilities
declare -A INSTALL_STATE
INSTALL_STATE_FILE="/tmp/linuxinstaller.state"
LOG_FILE="/var/log/linuxinstaller.log"

# --- Progress Tracking ---
# Track installation progress with visual indicators
PROGRESS_TOTAL=13
PROGRESS_CURRENT=0

# --- Helper Functions ---
# Utility functions for script operation and user interaction

# Display help message and usage information
# Shows command-line options, installation modes, and examples
show_help() {
  cat << EOF
LinuxInstaller - Unified Post-Install Script

USAGE:
    ./install.sh [OPTIONS]

OPTIONS:
    -h, --help      Show this help message
    -v, --verbose   Enable verbose logging output
    -d, --dry-run   Preview mode - show what would be done without making changes

INSTALLATION MODES:
    Standard    Complete setup with all recommended packages
    Minimal     Essential tools only for lightweight installations  
    Server      Headless server configuration

EXAMPLES:
    ./install.sh                    # Interactive mode with menu
    ./install.sh --dry-run          # Preview what would be installed
    ./install.sh --verbose          # Show detailed output

For more information, visit: https://github.com/GAndromidas/linuxinstaller
EOF
}

# Bootstrap essential tools required for the installer
# Installs gum UI helper if not present, ensuring beautiful terminal output
bootstrap_tools() {
    log_info "Bootstrapping installer tools..."

    # Verify internet connectivity before attempting installations
    if ! ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1; then
        log_error "No internet connection detected!"
        log_error "Internet access is required for package installation."
        log_error "Please connect to the internet and try again."
        if [ "$DRY_RUN" = false ]; then
            exit 1
        fi
    fi

    # Install gum UI helper for enhanced terminal interface
    # Gum provides beautiful menus, progress bars, and styled output
    if ! supports_gum; then
        if [ "$DRY_RUN" = true ]; then
            log_info "DRY RUN: Would install gum UI helper"
            return
        fi

        log_info "Installing gum UI helper for enhanced terminal interface..."

        # Try package manager first (different for Arch vs others)
        if [ "$DISTRO_ID" = "arch" ]; then
            if pacman -S --noconfirm gum >/dev/null 2>&1; then
                GUM_INSTALLED_BY_SCRIPT=true
                supports_gum >/dev/null 2>&1 || true
                log_success "Gum UI helper installed successfully"
            else
                log_warn "Failed to install gum via pacman"
            fi
        else
            if install_pkg gum >/dev/null 2>&1; then
                GUM_INSTALLED_BY_SCRIPT=true
                supports_gum >/dev/null 2>&1 || true
                log_success "Gum UI helper installed successfully"
            else
                log_warn "Failed to install gum via package manager"
                log_info "Continuing with text-based interface"
            fi
        fi
    fi
}

# =============================================================================
# SIMPLIFIED PACKAGE INSTALLATION SYSTEM
# =============================================================================

# Determine available package types for current distribution
determine_package_types() {
    local requested_type="${1:-}"

    # If specific package type requested, only return that type
    if [ -n "$requested_type" ]; then
        echo "$requested_type"
        return
    fi

    # Determine package types available for this distro
    case "$DISTRO_ID" in
        "arch")   echo "native aur flatpak" ;;
        "ubuntu") echo "native snap flatpak" ;;
        *)        echo "native flatpak" ;; # fedora, debian
    esac
}

# Get packages for a specific section and package type from distro module
get_packages_for_type() {
    local section_path="$1"
    local pkg_type="$2"

    # Try distro-provided package function first (preferred)
    if declare -f distro_get_packages >/dev/null 2>&1; then
        # distro_get_packages should print one package per line; capture and normalize
        mapfile -t tmp < <(distro_get_packages "$section_path" "$pkg_type" 2>/dev/null || true)
        mapfile -t packages < <(printf "%s\n" "${tmp[@]}" | sed '/^[[:space:]]*null[[:space:]]*$/d' | sed '/^[[:space:]]*$/d')
        printf "%s\n" "${packages[@]}"
    fi
}

# Remove duplicate packages while preserving order
deduplicate_packages() {
    local -a packages=("$@")
    if [ ${#packages[@]} -gt 1 ]; then
        declare -A _seen_pkgs
        local _deduped=()
        for pkg in "${packages[@]}"; do
            if [ -n "$pkg" ] && [ -z "${_seen_pkgs[$pkg]:-}" ]; then
                _deduped+=("$pkg")
                _seen_pkgs[$pkg]=1
            fi
        done
        # Replace packages with deduplicated list
        printf "%s\n" "${_deduped[@]}"
        unset _seen_pkgs
    else
        printf "%s\n" "${packages[@]}"
    fi
}

# Install a group of packages based on mode and package type (native, aur, flatpak, snap)
install_package_group() {
    local group_name="$1"
    local description="$2"
    local package_type="$3"

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Would install $group_name ($package_type)"
        return 0
    fi

    log_info "Installing $description..."

    # Get packages for this group and type
    local packages
    mapfile -t packages < <(distro_get_packages "$group_name" "$package_type")

    if [ ${#packages[@]} -eq 0 ]; then
        log_info "No packages to install for $group_name ($package_type)"
        return 0
    fi

    # Deduplicate package list while preserving order
    packages_str=$(deduplicate_packages "${packages[@]}")
    mapfile -t packages <<< "$packages_str"

    # Install packages based on type
    case "$package_type" in
        "flatpak")
            install_flatpak_packages "${packages[@]}"
            ;;
        "aur")
            install_aur_packages "${packages[@]}"
            ;;
        "snap")
            install_snap_packages "${packages[@]}"
            ;;
        "native")
            install_packages_with_progress "${packages[@]}"
            ;;
        *)
            log_error "Unknown package type: $package_type"
            return 1
            ;;
    esac
}

# Install Flatpak packages with individual tracking
install_flatpak_packages() {
    local packages=("$@")
    local installed=() skipped=() failed=()

    # Ensure flatpak is installed
    if ! command -v flatpak >/dev/null 2>&1; then
        log_info "Installing Flatpak..."
        install_packages_with_progress "flatpak"
    fi

    # Add Flathub remote if not exists
    if ! flatpak remote-list 2>/dev/null | grep -q flathub; then
        log_info "Adding Flathub remote..."
        flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo >/dev/null 2>&1
    fi

    for pkg in "${packages[@]}"; do
        pkg="$(echo "$pkg" | xargs)"

        # Check if flatpak is already installed
        if flatpak list 2>/dev/null | grep -q "^${pkg}\s"; then
            skipped+=("$pkg")
            continue
        fi

        echo "• Installing $pkg"
        if flatpak install flathub -y "$pkg" >/dev/null 2>&1; then
            installed+=("$pkg")
        else
            failed+=("$pkg")
        fi
    done

    # Show installation summary
    if [ ${#installed[@]} -gt 0 ]; then
        log_success "Successfully installed Flatpak packages: ${installed[*]}"
    fi
    if [ ${#skipped[@]} -gt 0 ]; then
        log_info "Skipped (already installed): ${skipped[*]}"
    fi
    if [ ${#failed[@]} -gt 0 ]; then
        log_error "Failed to install Flatpak packages: ${failed[*]}"
    fi
}

# Install AUR packages with proper user context
install_aur_packages() {
    local packages=("$@")
    local installed=() skipped=() failed=()

    # Check if yay is available
    if ! command -v yay >/dev/null 2>&1; then
        log_warn "yay not found, skipping AUR packages: ${packages[*]}"
        return 0
    fi

    # Determine which user to run yay as (never as root)
    local yay_user=""
    if [ "$EUID" -eq 0 ]; then
        if [ -n "${SUDO_USER:-}" ]; then
            yay_user="$SUDO_USER"
        else
            # Fallback to first real user if SUDO_USER not set
            yay_user=$(getent passwd 1000 | cut -d: -f1)
        fi
        if [ -z "${yay_user:-}" ]; then
            log_error "Cannot determine user for AUR package installation"
            return 1
        fi
    else
        yay_user="$USER"
    fi

    for pkg in "${packages[@]}"; do
        pkg="$(echo "$pkg" | xargs)"

        echo "• Installing $pkg"
        if sudo -u "$yay_user" yay -S --noconfirm "$pkg" >/dev/null 2>&1; then
            installed+=("$pkg")
        else
            failed+=("$pkg")
        fi
    done

    # Show installation summary
    if [ ${#installed[@]} -gt 0 ]; then
        log_success "Successfully installed AUR packages: ${installed[*]}"
    fi
    if [ ${#failed[@]} -gt 0 ]; then
        log_error "Failed to install AUR packages: ${failed[*]}"
    fi
}

# Install Snap packages
install_snap_packages() {
    local packages=("$@")
    local installed=() skipped=() failed=()

    for pkg in "${packages[@]}"; do
        pkg="$(echo "$pkg" | xargs)"

        echo "• Installing $pkg"
        if snap install "$pkg" >/dev/null 2>&1; then
            installed+=("$pkg")
        else
            failed+=("$pkg")
        fi
    done

    # Show installation summary
    if [ ${#installed[@]} -gt 0 ]; then
        log_success "Successfully installed Snap packages: ${installed[*]}"
    fi
    if [ ${#failed[@]} -gt 0 ]; then
        log_error "Failed to install Snap packages: ${failed[*]}"
    fi
}

# =============================================================================
# MAIN EXECUTION FLOW
# =============================================================================

# The main installation workflow with clear phases

# Phase 1: Parse command-line arguments and validate environment
while [[ "$#" -gt 0 ]]; do
  case $1 in
    -h|--help) show_help ;;
    -v|--verbose) VERBOSE=true ;;
    -d|--dry-run) DRY_RUN=true ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
  shift
done

# Phase 2: Environment Setup
# We must detect distro first to know how to install prerequisites
# Detect distribution and desktop environment with error handling (silent)
if ! detect_distro >/dev/null 2>&1; then
    log_error "Failed to detect your Linux distribution!"
    log_error "LinuxInstaller supports: Arch Linux, Fedora, Debian, and Ubuntu."
    log_error "Please check that you're running a supported distribution."
    log_error "You can check your distribution with: cat /etc/os-release"
    exit 1
fi

# Desktop environment detection (always succeeds now, silent)
detect_de >/dev/null 2>&1 || true

# Detect if running in a virtual machine
if detect_virtual_machine; then
    IS_VIRTUAL_MACHINE=true
else
    IS_VIRTUAL_MACHINE=false
fi

# Source distro module early so it can provide package lists via `distro_get_packages()`
# Source distro-specific configuration with error handling
case "$DISTRO_ID" in
    "arch")
        if [ -f "$SCRIPTS_DIR/arch_config.sh" ]; then
            source "$SCRIPTS_DIR/arch_config.sh"
        else
            log_error "Arch Linux configuration module not found!"
            log_error "Please ensure all files are present in the scripts/ directory."
            exit 1
        fi
        ;;
    "fedora")
        if [ -f "$SCRIPTS_DIR/fedora_config.sh" ]; then
            source "$SCRIPTS_DIR/fedora_config.sh"
        else
            log_error "Fedora configuration module not found!"
            log_error "Please ensure all files are present in the scripts/ directory."
            exit 1
        fi
        ;;
    "debian"|"ubuntu")
        if [ -f "$SCRIPTS_DIR/debian_config.sh" ]; then
            source "$SCRIPTS_DIR/debian_config.sh"
        else
            log_error "Debian/Ubuntu configuration module not found!"
            log_error "Please ensure all files are present in the scripts/ directory."
            exit 1
        fi
        ;;
    *)
        log_error "Unsupported distribution: $DISTRO_ID"
        log_error "LinuxInstaller currently supports: Arch Linux, Fedora, Debian, Ubuntu."
        exit 1
        ;;
esac

# programs.yaml fallback removed; package lists are provided by distro modules (via distro_get_packages())

# Update display theme based on detected distro (silent)
update_distro_theme >/dev/null 2>&1

# Initialize state management (silent)
state_init >/dev/null 2>&1

# Bootstrap UI tools (silent)
bootstrap_tools >/dev/null 2>&1

# Phase 3: Installation Mode Selection
# Go directly to menu - skip all pre-installation checks
clear
if [ -t 1 ] && [ "$DRY_RUN" = false ]; then
    # Interactive terminal - always show menu for user selection
    show_menu
elif [ -t 1 ] && [ "$DRY_RUN" = true ]; then
    log_warn "Dry-Run Mode Active: No changes will be applied."
    log_info "Showing menu for preview purposes only."
    show_menu
else
    # Non-interactive mode (CI, scripts, pipes)
    # Only set a default mode if none exists to avoid overriding explicit settings
    if [ -z "${INSTALL_MODE:-}" ]; then
        export INSTALL_MODE="standard"
        log_info "Non-interactive: defaulting to install mode: $INSTALL_MODE"
    fi
    if [ -z "${INSTALL_GAMING:-}" ]; then
        export INSTALL_GAMING=false
        log_info "Non-interactive: gaming packages disabled by default"
    fi
fi

# Phase 4: Core Installation Execution
# Execute the main installation workflow in logical steps

# Initialize progress tracking (estimate total steps)
progress_init 15

# Step: System Update
step "Updating System Repositories"
if [ "$DRY_RUN" = false ]; then
    time_start "system_update"
    update_system
    time_end "system_update"
fi
progress_update "System update"

# Step: Enable password feedback for better UX
step "Enabling password feedback"
if [ "$DRY_RUN" = false ]; then
    enable_password_feedback
fi
progress_update "Password feedback setup"

# Step: Run Distro System Preparation (install essentials, etc.)
# Run distro-specific system preparation early so essential helpers are present
# before package installation and mark the step complete to avoid duplication.
# Note: For Arch, this includes pacman configuration via configure_pacman_arch
DSTR_PREP_FUNC="${DISTRO_ID}_system_preparation"
DSTR_PREP_STEP="${DSTR_PREP_FUNC}"
step "Running system preparation for $DISTRO_ID"
if [ "$DRY_RUN" = false ]; then
    source "$SCRIPTS_DIR/distro_check.sh"
    if declare -f "$DSTR_PREP_FUNC" >/dev/null 2>&1; then
        time_start "distro_prep"
        # Map ubuntu to debian config
        config_file="${DISTRO_ID}_config.sh"
        if [ "$DISTRO_ID" = "ubuntu" ]; then
            config_file="debian_config.sh"
        fi
        source "$SCRIPTS_DIR/$config_file"
        "$DSTR_PREP_FUNC"
        time_end "distro_prep"
    else
        log_error "System preparation function not found for $DISTRO_ID"
    fi
fi
progress_update "System preparation"

# Step: Install Packages based on Mode
display_step "📦" "Installing Packages ($INSTALL_MODE)"

# Setup Docker repo for server mode on Debian/Ubuntu
if [ "$INSTALL_MODE" = "server" ] && [[ "$DISTRO_ID" = "debian" || "$DISTRO_ID" = "ubuntu" ]]; then
    debian_setup_docker_repo
fi

# Install Base packages (native only) - Standard/Minimal/Server
install_package_group "$INSTALL_MODE" "Base System" "native"

# Install distro-provided 'essential' group (native only)
install_package_group "essential" "Essential Packages" "native"

# Install Desktop Environment Specific Packages (native only)
if [[ -n "${XDG_CURRENT_DESKTOP:-}" && "$INSTALL_MODE" != "server" ]]; then
    DE_KEY=$(echo "$XDG_CURRENT_DESKTOP" | tr '[:upper:]' '[:lower:]')
    if [[ "$DE_KEY" == *"kde"* ]]; then DE_KEY="kde"; fi
    if [[ "$DE_KEY" == *"gnome"* ]]; then DE_KEY="gnome"; fi

    step "Installing Desktop Environment Packages ($DE_KEY)"
    install_package_group "$DE_KEY" "$XDG_CURRENT_DESKTOP Environment" "native"
fi

# Install AUR packages for Arch Linux
if [ "$DISTRO_ID" = "arch" ]; then
    install_package_group "$INSTALL_MODE" "AUR Packages" "aur"
fi

# Install COPR/eza package for Fedora
if [ "$DISTRO_ID" = "fedora" ]; then
    step "Installing COPR/eza Package"
    if [ "$DRY_RUN" = false ]; then
        if command -v dnf >/dev/null; then
            # Install eza from COPR
            if dnf copr enable -y eza-community/eza >/dev/null 2>&1; then
                install_packages_with_progress "eza"
                log_success "Enabled eza COPR repository and installed eza"
            else
                log_warn "Failed to enable eza COPR repository"
            fi
        else
            log_warn "dnf not found, skipping eza installation"
        fi
    fi
fi

# Install Flatpak packages for all sections (Base, Desktop, Gaming)
install_package_group "$INSTALL_MODE" "Flatpak Packages" "flatpak"

if [[ -n "${XDG_CURRENT_DESKTOP:-}" && "$INSTALL_MODE" != "server" ]]; then
    install_package_group "$DE_KEY" "Flatpak Packages" "flatpak"
fi

# Handle Custom Addons if any (rudimentary handling)
if [[ "${CUSTOM_GROUPS:-}" == *"Gaming"* ]]; then
    install_package_group "gaming" "Gaming Suite" "native"
    install_package_group "gaming" "Gaming Suite" "flatpak"
fi

# Use to gaming decision made at menu time (if applicable)
if [ "$INSTALL_MODE" = "standard" ] || [ "$INSTALL_MODE" = "minimal" ] && [ -z "${CUSTOM_GROUPS:-}" ]; then
    if [ "${INSTALL_GAMING:-false}" = "true" ]; then
        # Gaming packages already installed above (native and flatpak)
        log_info "Gaming packages already installed in previous steps"
    fi
fi

time_end "package_installation"
progress_update "Package installation"
progress_update "Wake-on-LAN configuration"
progress_update "Distribution configuration"
progress_update "User configuration"
progress_update "Desktop configuration"
progress_update "Security configuration"
progress_update "Performance optimization"
progress_update "Gaming configuration"
progress_update "Maintenance setup"
progress_update "Finalization"

# ------------------------------------------------------------------
# Wake-on-LAN auto-configuration step
#
# If wakeonlan integration module was sourced above (wakeonlan_main_config),
# run it now (unless we're in DRY_RUN). In DRY_RUN show status instead.
# This keeps the step idempotent and consistent with the installer flow.
# ------------------------------------------------------------------
if [ "$INSTALL_MODE" != "server" ] && declare -f wakeonlan_main_config >/dev/null 2>&1; then
    step "Configuring Wake-on-LAN (Ethernet)"

    if [ "${DRY_RUN:-false}" = "true" ]; then
        log_info "[DRY-RUN] Would auto-configure Wake-on-LAN for wired interfaces"

        # Try to show what would be done by printing helper status output (if present)
        WOL_HELPER="$(cd "$SCRIPT_DIR/../.." && pwd)/Scripts/wakeonlan.sh"
        if [ -x "$WOL_HELPER" ]; then
            bash "$WOL_HELPER" --status 2>&1 | sed 's/^/  /'
        else
            log_warn "Wake-on-LAN helper not found at $WOL_HELPER"
        fi
    else
        # Non-dry run: call the integration entrypoint which handles enabling
        wakeonlan_main_config || log_warn "wakeonlan_main_config reported issues"
    fi
fi

# Step: Configure user shell and config files (universal)
display_step "🐚" "Configuring User Shell and Configuration Files"
if [ "$DRY_RUN" = false ]; then
    configure_user_shell_and_configs
fi

# Phase 5: Installation Finalization and Cleanup
display_step "🎉" "Finalizing Installation"

if [ "$DRY_RUN" = false ]; then
    # Enable services for installed packages
    enable_installed_services

    # Clean up temporary files and helpers
    final_cleanup

    # Generate performance report
    performance_report

    # Show final progress summary
    install_duration=$(( $(date +%s) - ${INSTALL_STATE["start_time"]:-$(date +%s)} ))
    progress_summary "$install_duration"
fi

# Installation completed
prompt_reboot
