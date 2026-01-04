#!/bin/bash
# Power management helper for LinuxInstaller
# - Detects CPU/GPU/RAM and exposes helper to show that info.
# - Installs/configures appropriate power management tooling:
#   Prefer: power-profiles-daemon (and configure default profile)
#   Fallback: cpupower (if cpufreq support) or tuned (legacy/older systems)
#
# Designed to be sourced by the main installer (install.sh).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Common helpers (log_* , step, install_pkg, supports_gum, etc.)
# These are present in the main install environment; sourcing here if available.
if [ -f "$SCRIPT_DIR/common.sh" ]; then
    source "$SCRIPT_DIR/common.sh"
fi
if [ -f "$SCRIPT_DIR/distro_check.sh" ]; then
    source "$SCRIPT_DIR/distro_check.sh"
fi

# -----------------------------------------------------------------------------
# System detection helpers
# -----------------------------------------------------------------------------

# System hardware detection variables
DETECTED_OS=""
DETECTED_CPU=""
DETECTED_CPU_VENDOR=""
DETECTED_CPU_MODEL=""
DETECTED_CPU_FAMILY=""
DETECTED_CPU_STEPPING=""
DETECTED_GPU=""
DETECTED_GPU_VENDOR=""
DETECTED_RAM=""

# Hardware-specific configuration
POWER_PROFILE_PREFERRED=""
MICROCODE_PACKAGE=""
GPU_DRIVER_PACKAGES=()
NEEDS_TDP_CONTROL=false
NEEDS_RYZEN_ADJUST=false
NEEDS_INTEL_PSTATE=false

# Comprehensive system hardware detection with power management optimization
detect_system_hardware() {
    log_info "Detecting system hardware for optimal power management configuration..."

    # Detect OS
    DETECTED_OS="${PRETTY_NAME:-$(uname -srv)}"

    # Detect CPU with detailed information
    if command -v lscpu >/dev/null 2>&1; then
        DETECTED_CPU=$(lscpu | grep "Model name:" | cut -d: -f2 | xargs)
        DETECTED_CPU_MODEL=$(lscpu | grep "Model:" | cut -d: -f2 | xargs)
        DETECTED_CPU_FAMILY=$(lscpu | grep "CPU family:" | cut -d: -f2 | xargs)
        DETECTED_CPU_STEPPING=$(lscpu | grep "Stepping:" | cut -d: -f2 | xargs)
    else
        DETECTED_CPU=$(awk -F: '/model name/{print $2; exit}' /proc/cpuinfo | xargs || true)
        DETECTED_CPU_MODEL=""
        DETECTED_CPU_FAMILY=""
        DETECTED_CPU_STEPPING=""
        [ -z "$DETECTED_CPU" ] && DETECTED_CPU=$(uname -m)
    fi

    # Detect CPU vendor and specific models
    if command -v lscpu >/dev/null 2>&1; then
        DETECTED_CPU_VENDOR=$(lscpu | grep "Vendor ID:" | cut -d: -f2 | xargs | tr '[:upper:]' '[:lower:]')
    else
        DETECTED_CPU_VENDOR=$(awk -F: '/^vendor_id/ {print $2; exit}' /proc/cpuinfo | xargs || true)
    fi
    DETECTED_CPU_VENDOR="${DETECTED_CPU_VENDOR:-Unknown}"

    # Detect GPU
    if command -v lspci >/dev/null 2>&1; then
        local gpu_info=$(lspci | grep -i vga | head -1)
        DETECTED_GPU=$(echo "$gpu_info" | cut -d: -f3- | xargs)
        
        if echo "$gpu_info" | grep -iq nvidia; then
            DETECTED_GPU_VENDOR="nvidia"
        elif echo "$gpu_info" | grep -iq amd\|radeon; then
            DETECTED_GPU_VENDOR="amd"
        elif echo "$gpu_info" | grep -iq intel; then
            DETECTED_GPU_VENDOR="intel"
        else
            DETECTED_GPU_VENDOR="unknown"
        fi
    else
        DETECTED_GPU="Unknown"
        DETECTED_GPU_VENDOR="unknown"
    fi

    # Detect RAM
    if command -v free >/dev/null 2>&1; then
        DETECTED_RAM=$(free -h | awk '/Mem:/ {print $2}')
    else
        memkb=$(awk '/MemTotal/ {print $2; exit}' /proc/meminfo || true)
        if [ -n "$memkb" ]; then
            DETECTED_RAM=$(awk -v kb="$memkb" 'BEGIN{ printf "%.0fM", kb/1024 }')
        else
            DETECTED_RAM="Unknown"
        fi
    fi

    # Analyze hardware for optimal power management tool selection
    analyze_hardware_for_power_management
    determine_microcode_and_drivers

    # Export all variables for use by other functions
    export DETECTED_OS DETECTED_CPU DETECTED_CPU_VENDOR DETECTED_CPU_MODEL DETECTED_CPU_FAMILY DETECTED_CPU_STEPPING DETECTED_GPU DETECTED_GPU_VENDOR DETECTED_RAM
    export POWER_PROFILE_PREFERRED MICROCODE_PACKAGE GPU_DRIVER_PACKAGES NEEDS_TDP_CONTROL NEEDS_RYZEN_ADJUST NEEDS_INTEL_PSTATE
}

# Analyze hardware to determine optimal power management tools
analyze_hardware_for_power_management() {
    log_info "Analyzing hardware for optimal power management configuration..."

    # Determine CPU generation and capabilities
    local cpu_lower=$(echo "$DETECTED_CPU" | tr '[:upper:]' '[:lower:]')

    # AMD Ryzen detection and classification
    if [[ "$DETECTED_CPU_VENDOR" =~ [Aa]uthentic[Aa]MD ]] || [[ "$cpu_lower" =~ amd ]]; then
        if [[ "$cpu_lower" =~ ryzen ]]; then
            if [[ "$cpu_lower" =~ (1|2|3|4|5|6|7|8|9)000 ]]; then
                local gen="${BASH_REMATCH[1]}"
                if [[ $gen -ge 5 ]]; then
                    # Ryzen 5000+ (Zen 3+) - prefer power-profiles-daemon
                    POWER_PROFILE_PREFERRED="power-profiles-daemon"
                    NEEDS_RYZEN_ADJUST=false
                    NEEDS_TDP_CONTROL=false
                    log_info "Detected Ryzen $gen000 series (Zen 3+) - using power-profiles-daemon"
                elif [[ $gen -ge 3 ]]; then
                    # Ryzen 3000/4000 (Zen 2) - prefer tuned-ppd
                    POWER_PROFILE_PREFERRED="tuned-ppd"
                    NEEDS_RYZEN_ADJUST=true
                    NEEDS_TDP_CONTROL=true
                    log_info "Detected Ryzen $gen000 series (Zen 2) - using tuned-ppd with Ryzen adjustments"
                else
                    # Ryzen 1000/2000 (Zen/Zen+) - use tuned
                    POWER_PROFILE_PREFERRED="tuned"
                    NEEDS_RYZEN_ADJUST=true
                    NEEDS_TDP_CONTROL=true
                    log_info "Detected Ryzen $gen000 series (Zen/Zen+) - using tuned with Ryzen adjustments"
                fi
            else
                # Generic Ryzen detection
                POWER_PROFILE_PREFERRED="power-profiles-daemon"
                NEEDS_RYZEN_ADJUST=false
                NEEDS_TDP_CONTROL=false
                log_info "Detected AMD Ryzen - using power-profiles-daemon"
            fi
        else
            # Non-Ryzen AMD
            POWER_PROFILE_PREFERRED="tuned"
            NEEDS_RYZEN_ADJUST=false
            NEEDS_TDP_CONTROL=false
            log_info "Detected AMD CPU (non-Ryzen) - using tuned"
        fi
    # Intel detection and classification
    elif [[ "$DETECTED_CPU_VENDOR" =~ [Gg]enuine[Ii]ntel ]] || [[ "$cpu_lower" =~ intel ]]; then
        if [[ "$cpu_lower" =~ (i3|i5|i7|i9)-([0-9]+) ]]; then
            local model="${BASH_REMATCH[2]}"
            local gen="${model:0:1}"
            if [[ $gen -ge 8 ]]; then
                # Intel 8th gen+ - prefer power-profiles-daemon
                POWER_PROFILE_PREFERRED="power-profiles-daemon"
                NEEDS_INTEL_PSTATE=true
                log_info "Detected Intel $gen000 series (8th gen+) - using power-profiles-daemon"
            else
                # Intel older generations - use cpupower
                POWER_PROFILE_PREFERRED="cpupower"
                NEEDS_INTEL_PSTATE=false
                log_info "Detected Intel $gen000 series (older) - using cpupower"
            fi
        else
            # Generic Intel detection
            POWER_PROFILE_PREFERRED="cpupower"
            NEEDS_INTEL_PSTATE=false
            log_info "Detected Intel CPU - using cpupower"
        fi
    else
        # Unknown or other CPU
        POWER_PROFILE_PREFERRED="tuned"
        log_info "Detected unknown CPU vendor - using tuned as fallback"
    fi

    log_success "Power management tool selected: $POWER_PROFILE_PREFERRED"
}

# Determine appropriate microcode and GPU drivers
determine_microcode_and_drivers() {
    log_info "Determining appropriate microcode and GPU drivers..."

    # Determine microcode package
    case "$DETECTED_CPU_VENDOR" in
        *[Aa]uthentic[Aa]MD*)
            MICROCODE_PACKAGE="amd-ucode"
            log_info "AMD CPU detected - will install amd-ucode"
            ;;
        *[Gg]enuine[Ii]ntel*)
            MICROCODE_PACKAGE="intel-ucode"
            log_info "Intel CPU detected - will install intel-ucode"
            ;;
        *)
            MICROCODE_PACKAGE=""
            log_warn "Unknown CPU vendor - no microcode package selected"
            ;;
    esac

    # Determine GPU drivers
    case "$DETECTED_GPU_VENDOR" in
        "nvidia")
            if [ "$DISTRO_ID" = "arch" ]; then
                GPU_DRIVER_PACKAGES=("nvidia" "nvidia-utils" "nvidia-settings")
            elif [ "$DISTRO_ID" = "fedora" ]; then
                GPU_DRIVER_PACKAGES=("akmod-nvidia" "xorg-x11-drv-nvidia-cuda")
            else
                GPU_DRIVER_PACKAGES=("nvidia-driver" "nvidia-settings")
            fi
            log_info "NVIDIA GPU detected - will install proprietary drivers"
            ;;
        "amd")
            if [ "$DISTRO_ID" = "arch" ]; then
                GPU_DRIVER_PACKAGES=("mesa" "lib32-mesa" "vulkan-radeon" "lib32-vulkan-radeon")
            elif [ "$DISTRO_ID" = "fedora" ]; then
                GPU_DRIVER_PACKAGES=("mesa-libGL" "mesa-libGLU" "mesa-vulkan-drivers")
            else
                GPU_DRIVER_PACKAGES=("mesa-vulkan-drivers" "mesa-vulkan-drivers:i386")
            fi
            log_info "AMD GPU detected - will install open-source drivers"
            ;;
        "intel")
            if [ "$DISTRO_ID" = "arch" ]; then
                GPU_DRIVER_PACKAGES=("mesa" "lib32-mesa" "vulkan-intel" "lib32-vulkan-intel" "intel-media-driver")
            elif [ "$DISTRO_ID" = "fedora" ]; then
                GPU_DRIVER_PACKAGES=("mesa-libGL" "mesa-libGLU" "mesa-vulkan-drivers" "intel-media-driver")
            else
                GPU_DRIVER_PACKAGES=("mesa-vulkan-drivers" "mesa-vulkan-drivers:i386" "intel-media-va-driver:i386")
            fi
            log_info "Intel GPU detected - will install integrated graphics drivers"
            ;;
        *)
            GPU_DRIVER_PACKAGES=()
            log_warn "Unknown GPU vendor - no specific drivers selected"
            ;;
    esac
}

# Display detected system information to user
show_system_info() {
    # Detect system information
    detect_system_hardware

    # Print system information in the same style as other headers
    if supports_gum; then
        display_info "Detected OS: $DETECTED_OS"
        display_info "Detected DE: ${XDG_CURRENT_DESKTOP:-None}"
        display_info "Detected CPU: ${DETECTED_CPU:-Unknown}"
        display_info "CPU Vendor: ${DETECTED_CPU_VENDOR:-Unknown}"
        display_info "Detected GPU: ${DETECTED_GPU:-Unknown}"
        display_info "GPU Vendor: ${DETECTED_GPU_VENDOR:-Unknown}"
        display_info "Detected RAM: ${DETECTED_RAM:-Unknown}"
        display_info "Power Tool: ${POWER_PROFILE_PREFERRED:-Unknown}"
        if [ -n "$MICROCODE_PACKAGE" ]; then
            display_info "Microcode: $MICROCODE_PACKAGE"
        fi
        if [ ${#GPU_DRIVER_PACKAGES[@]} -gt 0 ]; then
            display_info "GPU Drivers: ${GPU_DRIVER_PACKAGES[*]}"
        fi
    else
        display_info "System Detection Results:" "OS: ${DETECTED_OS:-Unknown}\nDE: ${XDG_CURRENT_DESKTOP:-None}\nCPU: ${DETECTED_CPU:-Unknown}\nCPU Vendor: ${DETECTED_CPU_VENDOR:-Unknown}\nGPU: ${DETECTED_GPU:-Unknown}\nGPU Vendor: ${DETECTED_GPU_VENDOR:-Unknown}\nRAM: ${DETECTED_RAM:-Unknown}\nPower Tool: ${POWER_PROFILE_PREFERRED:-Unknown}"
    fi
}

# -----------------------------------------------------------------------------
# Power management configuration
# -----------------------------------------------------------------------------

# Helper function to attempt package installation with fallbacks
_try_install() {
    # Args: package1 [package2 ...]
    for pkg in "$@"; do
        if [ -z "$pkg" ]; then
            continue
        fi
        if command -v install_pkg >/dev/null 2>&1; then
            install_packages_with_progress "$pkg" && return 0
        else
            # Fallback: try package manager generic installs (best-effort)
            if [ "${DRY_RUN:-false}" = "true" ]; then
                display_info "[DRY-RUN] Would install $pkg"
                return 0
            fi
            display_progress "installing" "$pkg"
            if command -v apt-get >/dev/null 2>&1; then
                apt-get install -y "$pkg" >/dev/null 2>&1 && display_success "✓ $pkg installed" && return 0
            elif command -v dnf >/dev/null 2>&1; then
                dnf install -y "$pkg" >/dev/null 2>&1 && display_success "✓ $pkg installed" && return 0
            elif command -v pacman >/dev/null 2>&1; then
                pacman -S --noconfirm "$pkg" >/dev/null 2>&1 && display_success "✓ $pkg installed" && return 0
            fi
            display_error "✗ Failed to install $pkg"
        fi
    done
    return 1
}

# Configure power management (power-profiles-daemon, cpupower, or tuned)
configure_power_management() {
    display_step "🔋" "Configuring Power Management"

    if [ "${DRY_RUN:-false}" = "true" ]; then
        log_info "[DRY-RUN] Would detect and configure power management utilities based on hardware"
        return 0
    fi

    # First, detect hardware to determine optimal configuration
    detect_system_hardware

    # Install microcode
    install_microcode

    # Install GPU drivers
    install_gpu_drivers

    # Install hardware-specific tools
    case "$DETECTED_CPU_VENDOR" in
        *[Aa]uthentic[Aa]MD*)
            install_ryzen_tools
            ;;
        *[Gg]enuine[Ii]ntel*)
            install_intel_tools
            ;;
    esac

    # Configure power management based on detected hardware
    case "$POWER_PROFILE_PREFERRED" in
        "power-profiles-daemon")
            configure_power_profiles_daemon
            ;;
        "tuned-ppd")
            configure_tuned_ppd
            ;;
        "cpupower")
            configure_cpupower
            ;;
        "tuned")
            configure_tuned
            ;;
        *)
            log_warn "Unknown power management tool: $POWER_PROFILE_PREFERRED"
            configure_fallback_power_management
            ;;
    esac
}

# Configure power-profiles-daemon (modern systems)
configure_power_profiles_daemon() {
    log_info "Configuring power-profiles-daemon..."

    # Install if not present
    if ! command -v powerprofilesctl >/dev/null 2>&1; then
        if _try_install power-profiles-daemon; then
            log_success "power-profiles-daemon installed"
        else
            log_warn "Failed to install power-profiles-daemon, falling back to cpupower"
            configure_cpupower
            return $?
        fi
    fi

    # Enable and start service
    if systemctl enable --now power-profiles-daemon >/dev/null 2>&1; then
        log_success "power-profiles-daemon enabled"
    else
        log_warn "Failed to enable power-profiles-daemon service"
    fi

    # Configure default profile based on system and gaming mode
    local profile="balanced"
    if [ "${INSTALL_GAMING:-false}" = "true" ]; then
        profile="performance"
    elif [ "$DETECTED_CPU_VENDOR" = "AuthenticAMD" ] && [ "$NEEDS_RYZEN_ADJUST" = true ]; then
        profile="balanced"
    fi

    if powerprofilesctl set "$profile" >/dev/null 2>&1; then
        log_success "power-profiles-daemon profile set to '$profile'"
    fi

    # Configure additional settings for gaming mode
    if [ "${INSTALL_GAMING:-false}" = "true" ]; then
        # Disable power saving features for gaming
        powerprofilesctl set performance >/dev/null 2>&1 || true
        log_info "Gaming mode: Performance profile enabled"
    fi
}

# Configure tuned-ppd (AMD Ryzen systems)
configure_tuned_ppd() {
    log_info "Configuring tuned-ppd for AMD Ryzen systems..."

    # Install tuned and tuned-ppd
    if ! _try_install tuned tuned-ppd; then
        log_warn "Failed to install tuned-ppd, falling back to standard tuned"
        configure_tuned
        return $?
    fi

    # Enable and start tuned
    if systemctl enable --now tuned >/dev/null 2>&1; then
        log_success "tuned enabled"
    else
        log_warn "Failed to enable tuned service"
    fi

    # Configure Ryzen-specific profile
    if command -v tuned-adm >/dev/null 2>&1; then
        if tuned-adm profile ryzen >/dev/null 2>&1; then
            tuned-adm profile ryzen
            log_success "Ryzen power profile activated"
        elif tuned-adm profile balanced >/dev/null 2>&1; then
            tuned-adm profile balanced
            log_success "Balanced power profile activated"
        fi

        # Configure additional Ryzen-specific settings
        if [ "$NEEDS_TDP_CONTROL" = true ] && command -v ryzenadj >/dev/null 2>&1; then
            # Set TDP limits for optimal performance
            ryzenadj --stapm-limit=65000 --fast-limit=88000 --slow-limit=54000 >/dev/null 2>&1 || true
            log_info "Ryzen TDP limits configured"
        fi
    fi
}

# Configure cpupower (Intel and older systems)
configure_cpupower() {
    log_info "Configuring cpupower..."

    # Install cpupower
    if ! _try_install cpupower linux-cpupower cpufrequtils; then
        log_warn "Failed to install cpupower, falling back to tuned"
        configure_tuned
        return $?
    fi

    # Enable and start cpupower
    if systemctl enable --now cpupower >/dev/null 2>&1 || systemctl enable --now cpupower.service >/dev/null 2>&1; then
        log_success "cpupower enabled"
    else
        log_warn "cpupower installed but enabling service failed"
    fi

    # Configure governor based on system and gaming mode
    local governor="ondemand"
    if [ "${INSTALL_GAMING:-false}" = "true" ]; then
        governor="performance"
    elif [ "$NEEDS_INTEL_PSTATE" = true ]; then
        governor="powersave"
    fi

    if command -v cpupower >/dev/null 2>&1; then
        cpupower frequency-set -g "$governor" >/dev/null 2>&1 || true
        log_info "CPU governor set to '$governor'"
    fi

    # Configure additional Intel-specific settings
    if [ "$NEEDS_INTEL_PSTATE" = true ] && [ "$DETECTED_CPU_VENDOR" = "GenuineIntel" ]; then
        # Enable Intel P-state
        if [ -f /etc/default/grub ]; then
            if ! grep -q "intel_pstate" /etc/default/grub; then
                sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="intel_pstate=enable /' /etc/default/grub
                log_info "Intel P-state enabled in GRUB configuration"
            fi
        fi
    fi
}

# Configure standard tuned (fallback)
configure_tuned() {
    log_info "Configuring standard tuned..."

    # Install tuned
    if ! _try_install tuned; then
        log_warn "Failed to install tuned, using basic cpupower"
        configure_cpupower
        return $?
    fi

    # Enable and start tuned
    if systemctl enable --now tuned >/dev/null 2>&1; then
        log_success "tuned enabled"
    else
        log_warn "Failed to enable tuned service"
    fi

    # Configure profile based on system type
    local profile="balanced"
    if [ "${INSTALL_GAMING:-false}" = "true" ]; then
        profile="throughput-performance"
    elif [ "$DETECTED_CPU_VENDOR" = "AuthenticAMD" ]; then
        profile="server"
    fi

    if command -v tuned-adm >/dev/null 2>&1; then
        if tuned-adm profile "$profile" >/dev/null 2>&1; then
            tuned-adm profile "$profile"
            log_success "Tuned profile set to '$profile'"
        fi
    fi
}

# Configure fallback power management
configure_fallback_power_management() {
    log_warn "Using fallback power management configuration..."

    # Try to install any available power management tool
    if _try_install power-profiles-daemon; then
        configure_power_profiles_daemon
    elif _try_install cpupower; then
        configure_cpupower
    elif _try_install tuned; then
        configure_tuned
    else
        log_error "No power management tools could be installed"
        return 1
    fi
}

# =============================================================================
# HARDWARE-SPECIFIC INSTALLATION FUNCTIONS
# =============================================================================

# Install appropriate microcode package
install_microcode() {
    log_info "Installing microcode package..."

    if [ -z "$MICROCODE_PACKAGE" ]; then
        log_warn "No microcode package selected for CPU vendor: $DETECTED_CPU_VENDOR"
        return 0
    fi

    if ! _try_install "$MICROCODE_PACKAGE"; then
        log_warn "Failed to install microcode package: $MICROCODE_PACKAGE"
        return 1
    fi

    log_success "Microcode package installed: $MICROCODE_PACKAGE"

    # Update bootloader configuration for microcode
    if [ -f /boot/grub/grub.cfg ]; then
        if command -v update-grub >/dev/null 2>&1; then
            update-grub >/dev/null 2>&1 || true
            log_info "GRUB configuration updated for microcode"
        fi
    fi
}

# Install appropriate GPU drivers based on detected hardware
install_gpu_drivers() {
    log_info "Installing GPU drivers..."

    if [ ${#GPU_DRIVER_PACKAGES[@]} -eq 0 ]; then
        log_info "No specific GPU drivers needed for vendor: $DETECTED_GPU_VENDOR"
        return 0
    fi

    if ! _try_install "${GPU_DRIVER_PACKAGES[@]}"; then
        log_warn "Failed to install some GPU drivers: ${GPU_DRIVER_PACKAGES[*]}"
        return 1
    fi

    log_success "GPU drivers installed: ${GPU_DRIVER_PACKAGES[*]}"

    # Configure GPU settings if needed
    case "$DETECTED_GPU_VENDOR" in
        "nvidia")
            configure_nvidia_settings
            ;;
        "amd")
            configure_amd_settings
            ;;
        "intel")
            configure_intel_settings
            ;;
    esac
}

# Install AMD Ryzen-specific tools
install_ryzen_tools() {
    log_info "Installing AMD Ryzen-specific tools..."

    local ryzen_packages=()

    # Add Ryzen-specific packages based on needs
    if [ "$NEEDS_RYZEN_ADJUST" = true ]; then
        ryzen_packages+=("ryzenadj")
    fi

    if [ "$NEEDS_TDP_CONTROL" = true ]; then
        ryzen_packages+=("ryzentune")
    fi

    if [ ${#ryzen_packages[@]} -gt 0 ]; then
        if ! _try_install "${ryzen_packages[@]}"; then
            log_warn "Failed to install some Ryzen tools: ${ryzen_packages[*]}"
            return 1
        fi
        log_success "Ryzen tools installed: ${ryzen_packages[*]}"
    fi

    # Configure Ryzen-specific settings
    if [ "$NEEDS_RYZEN_ADJUST" = true ] && command -v ryzenadj >/dev/null 2>&1; then
        configure_ryzen_performance
    fi
}

# Install Intel-specific tools
install_intel_tools() {
    log_info "Installing Intel-specific tools..."

    local intel_packages=()

    # Add Intel-specific packages
    if [ "$NEEDS_INTEL_PSTATE" = true ]; then
        intel_packages+=("intel-cmt-cat" "intel-gpu-tools")
    fi

    if [ ${#intel_packages[@]} -gt 0 ]; then
        if ! _try_install "${intel_packages[@]}"; then
            log_warn "Failed to install some Intel tools: ${intel_packages[*]}"
            return 1
        fi
        log_success "Intel tools installed: ${intel_packages[*]}"
    fi

    # Configure Intel-specific settings
    if [ "$NEEDS_INTEL_PSTATE" = true ]; then
        configure_intel_performance
    fi
}

# Configure NVIDIA-specific settings
configure_nvidia_settings() {
    log_info "Configuring NVIDIA GPU settings..."

    # Set NVIDIA power management
    if command -v nvidia-settings >/dev/null 2>&1; then
        nvidia-settings -a [gpu:0]/GPUFanControlState=0 >/dev/null 2>&1 || true
        nvidia-settings -a [gpu:0]/GPUPowerMizerMode=1 >/dev/null 2>&1 || true
        log_info "NVIDIA power management configured"
    fi
}

# Configure AMD GPU settings
configure_amd_settings() {
    log_info "Configuring AMD GPU settings..."

    # Set AMD power management
    if [ -d /sys/class/drm ]; then
        for card in /sys/class/drm/card*; do
            if [ -f "$card/device/power_dpm_force_performance_level" ]; then
                echo "auto" > "$card/device/power_dpm_force_performance_level" 2>/dev/null || true
            fi
        done
        log_info "AMD power management configured"
    fi
}

# Configure Intel GPU settings
configure_intel_settings() {
    log_info "Configuring Intel GPU settings..."

    # Set Intel power management
    if [ -d /sys/class/drm ]; then
        for card in /sys/class/drm/card*; do
            if [ -f "$card/device/power_dpm_force_performance_level" ]; then
                echo "normal" > "$card/device/power_dpm_force_performance_level" 2>/dev/null || true
            fi
        done
        log_info "Intel power management configured"
    fi
}

# Configure AMD Ryzen performance settings
configure_ryzen_performance() {
    log_info "Configuring AMD Ryzen performance settings..."

    if command -v ryzenadj >/dev/null 2>&1; then
        # Set optimal TDP and frequency limits
        ryzenadj --stapm-limit=65000 --fast-limit=88000 --slow-limit=54000 >/dev/null 2>&1 || true
        ryzenadj --tctl-limit=95 --vrm-current=90000 --vrmsoc-current=40000 >/dev/null 2>&1 || true
        log_info "Ryzen performance limits configured"
    fi
}

# Configure Intel performance settings
configure_intel_performance() {
    log_info "Configuring Intel performance settings..."

    # Enable Intel P-state if not already configured
    if [ -f /etc/default/grub ]; then
        if ! grep -q "intel_pstate=enable" /etc/default/grub; then
            sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="intel_pstate=enable /' /etc/default/grub
            log_info "Intel P-state enabled in GRUB configuration"
        fi
    fi

    # Configure CPU frequency scaling
    if [ -d /sys/devices/system/cpu/cpu0/cpufreq ]; then
        echo "performance" > /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || true
        log_info "Intel CPU governor set to performance"
    fi
}

# Test function to verify hardware detection works correctly
test_hardware_detection() {
    log_info "Testing hardware detection system..."

    # Call the detection function
    detect_system_hardware

    # Verify all variables are set
    local missing_vars=()

    [ -z "$DETECTED_OS" ] && missing_vars+=("DETECTED_OS")
    [ -z "$DETECTED_CPU" ] && missing_vars+=("DETECTED_CPU")
    [ -z "$DETECTED_CPU_VENDOR" ] && missing_vars+=("DETECTED_CPU_VENDOR")
    [ -z "$DETECTED_GPU" ] && missing_vars+=("DETECTED_GPU")
    [ -z "$DETECTED_GPU_VENDOR" ] && missing_vars+=("DETECTED_GPU_VENDOR")
    [ -z "$DETECTED_RAM" ] && missing_vars+=("DETECTED_RAM")
    [ -z "$POWER_PROFILE_PREFERRED" ] && missing_vars+=("POWER_PROFILE_PREFERRED")
    [ -z "$MICROCODE_PACKAGE" ] && missing_vars+=("MICROCODE_PACKAGE")

    if [ ${#missing_vars[@]} -gt 0 ]; then
        log_error "Missing variables: ${missing_vars[*]}"
        return 1
    fi

    # Display detected information
    log_success "Hardware detection successful:"
    log_info "  OS: $DETECTED_OS"
    log_info "  CPU: $DETECTED_CPU"
    log_info "  CPU Vendor: $DETECTED_CPU_VENDOR"
    log_info "  GPU: $DETECTED_GPU"
    log_info "  GPU Vendor: $DETECTED_GPU_VENDOR"
    log_info "  RAM: $DETECTED_RAM"
    log_info "  Power Tool: $POWER_PROFILE_PREFERRED"
    log_info "  Microcode: $MICROCODE_PACKAGE"

    if [ ${#GPU_DRIVER_PACKAGES[@]} -gt 0 ]; then
        log_info "  GPU Drivers: ${GPU_DRIVER_PACKAGES[*]}"
    fi

    # Test power management tool selection logic
    case "$POWER_PROFILE_PREFERRED" in
        "power-profiles-daemon")
            log_info "✓ Selected power-profiles-daemon (modern systems)"
            ;;
        "tuned-ppd")
            log_info "✓ Selected tuned-ppd (AMD Ryzen systems)"
            ;;
        "cpupower")
            log_info "✓ Selected cpupower (Intel systems)"
            ;;
        "tuned")
            log_info "✓ Selected tuned (legacy systems)"
            ;;
        *)
            log_warn "⚠ Unknown power management tool: $POWER_PROFILE_PREFERRED"
            ;;
    esac

    return 0
}

# Export the main helpers so the installer can call them if the file is sourced.
export -f detect_system_hardware
export -f show_system_info
export -f configure_power_management
export -f install_microcode
export -f install_gpu_drivers
export -f install_ryzen_tools
export -f install_intel_tools
export -f configure_nvidia_settings
export -f configure_amd_settings
export -f configure_intel_settings
export -f configure_ryzen_performance
export -f configure_intel_performance
export -f test_hardware_detection
