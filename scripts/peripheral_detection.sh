#!/bin/bash
set -uo pipefail

# Smart Peripheral Detection for Archinstaller
# Automatically detects connected peripherals and installs appropriate packages

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Load peripheral configuration from YAML file
load_peripheral_config() {
    local config_file="$SCRIPT_DIR/../configs/peripherals.yaml"
    
    if [[ ! -f "$config_file" ]]; then
        ui_warn "Peripheral configuration file not found: $config_file"
        return 1
    fi
    
    # Add timeout for YAML loading to prevent hanging
    if ! timeout 10s bash -c "command -v yq >/dev/null 2>&1 && yq eval '.' '$config_file' >/dev/null 2>&1"; then
        ui_warn "Failed to load peripheral configuration or yq not available"
        log_error "YAML configuration loading failed or timed out"
        return 1
    fi
    
    ui_info "Peripheral configuration loaded successfully"
    return 0
}

# ===== Enhanced Detection Functions =====

# Detect Logitech devices (mice, keyboards, etc.)
detect_logitech_devices() {
    local logitech_devices=()
    
    # Check for Logitech USB devices (including wireless receivers) with timeout
    local usb_devices
    if ! usb_devices=$(timeout 5s lsusb 2>/dev/null); then
        ui_warn "USB device scan timed out - may be VM environment"
        printf '%s\n' "${logitech_devices[@]}"
        return 0
    fi
    
    # Parse lsusb output for Logitech devices with timeout protection
    while IFS= read -r line; do
        if [[ "$line" =~ Bus[[:space:]]+[0-9]+[[:space:]]+Device[[:space:]]+[0-9]+:[[:space:]]+ID[[:space:]]+([0-9a-f]+):([0-9a-f]+) ]]; then
            local vendor_id="${BASH_REMATCH[1]}"
            local product_id="${BASH_REMATCH[2]}"
            
            # Check for Logitech vendor ID (046d)
            if [[ "$vendor_id" == "046d" ]]; then
                local device_info=$(timeout 3s lsusb -d "$vendor_id:$product_id" -v 2>/dev/null || echo "Logitech device ($vendor_id:$product_id)")
                logitech_devices+=("$device_info")
            fi
        fi
    done <<< "$usb_devices" | grep -i "Logitech"
    
    # Check for Logitech wireless receivers specifically
    if lsusb | grep -i "Unifying" >/dev/null 2>&1; then
        while IFS= read -r line; do
            local device_name=$(echo "$line" | cut -d: -f3- | sed 's/^ *//')
            logitech_devices+=("USB Receiver: $device_name")
        done < <(lsusb | grep -i "Unifying")
    fi
    
    # Check for Logitech Lightspeed receivers
    if lsusb | grep -i "Lightspeed" >/dev/null 2>&1; then
        while IFS= read -r line; do
            local device_name=$(echo "$line" | cut -d: -f3- | sed 's/^ *//')
            logitech_devices+=("Lightspeed Receiver: $device_name")
        done < <(lsusb | grep -i "Lightspeed")
    fi
    
    # Enhanced Bluetooth device detection
    if command -v bluetoothctl >/dev/null 2>&1; then
        # Get all paired and connected devices
        local bt_devices=$(bluetoothctl devices 2>/dev/null || true)
        if [[ -n "$bt_devices" ]]; then
            while IFS= read -r line; do
                local device_mac=$(echo "$line" | awk '{print $2}')
                local device_name=$(echo "$line" | cut -d' ' -f3-)
                
                # Check if it's a Logitech device
                if echo "$device_name" | grep -i "Logitech" >/dev/null 2>&1; then
                    # Check if device is connected
                    local device_info=$(bluetoothctl info "$device_mac" 2>/dev/null || true)
                    local connected="No"
                    if echo "$device_info" | grep -q "Connected: yes"; then
                        connected="Yes"
                    fi
                    logitech_devices+=("Bluetooth: $device_name ($device_mac) - Connected: $connected")
                fi
            done <<< "$bt_devices"
        fi
        
        # Also check for currently connected devices
        local connected_bt=$(bluetoothctl devices Connected 2>/dev/null || true)
        if [[ -n "$connected_bt" ]]; then
            while IFS= read -r line; do
                local device_mac=$(echo "$line" | awk '{print $2}')
                local device_name=$(echo "$line" | cut -d' ' -f3-)
                if echo "$device_name" | grep -i "Logitech" >/dev/null 2>&1; then
                    logitech_devices+=("Bluetooth Connected: $device_name ($device_mac)")
                fi
            done <<< "$connected_bt"
        fi
    fi
    
    # Check for Logitech devices in /sys/bus/usb/devices/ (more thorough)
    for device in /sys/bus/usb/devices/*/idVendor; do
        if [[ -f "$device" ]]; then
            local vendor=$(cat "$device" 2>/dev/null || echo "")
            if [[ "$vendor" == "046d" ]]; then  # Logitech vendor ID
                local device_path=$(dirname "$device")
                local product_file="$device_path/idProduct"
                if [[ -f "$product_file" ]]; then
                    local product=$(cat "$product_file" 2>/dev/null || echo "")
                    # Check for specific Logitech device IDs
                    case "$product" in
                        "c086"|"c087"|"c088")
                            logitech_devices+=("System: Logitech G502 X Lightspeed (VID:046d PID:$product)")
                            ;;
                        "c52b"|"c52e"|"c532")
                            logitech_devices+=("System: Logitech Unifying Receiver (VID:046d PID:$product)")
                            ;;
                        *)
                            logitech_devices+=("System: Logitech device (VID:046d PID:$product)")
                            ;;
                    esac
                fi
            fi
        fi
    done
    
    # Check for input devices that might be Logitech
    for input_device in /sys/class/input/input*/device/id/vendor; do
        if [[ -f "$input_device" ]]; then
            local vendor=$(cat "$input_device" 2>/dev/null || echo "")
            if [[ "$vendor" == "046d" ]]; then
                local device_path=$(dirname "$input_device")
                local product_file="$device_path/../id/product"
                if [[ -f "$product_file" ]]; then
                    local product=$(cat "$product_file" 2>/dev/null || echo "")
                    logitech_devices+=("Input Device: Logitech $product")
                fi
            fi
        fi
    done
    
    printf '%s\n' "${logitech_devices[@]}"
}

# Detect Keychron keyboards
detect_keychron_keyboards() {
    local keychron_devices=()
    
    # Check for Keychron USB devices
    if lsusb | grep -i "Keychron" >/dev/null 2>&1; then
        while IFS= read -r line; do
            local device_id=$(echo "$line" | awk '{print $6}')
            local device_name=$(echo "$line" | cut -d: -f3- | sed 's/^ *//')
            keychron_devices+=("USB: $device_name ($device_id)")
        done < <(lsusb | grep -i "Keychron")
    fi
    
    # Enhanced Bluetooth detection for Keychron with timeout
    if command -v bluetoothctl >/dev/null 2>&1; then
        # Get all paired and connected devices with timeout
        local bt_devices
        if ! bt_devices=$(timeout 5s bluetoothctl devices 2>/dev/null || true); then
            ui_warn "Bluetooth device scan timed out - may be VM environment"
            printf '%s\n' "${keychron_devices[@]}"
            return 0
        fi
        
        if [[ -n "$bt_devices" ]]; then
            while IFS= read -r line; do
                local device_mac=$(echo "$line" | awk '{print $2}')
                local device_name=$(echo "$line" | cut -d' ' -f3-)
                
                # Check if it's a Keychron device
                if echo "$device_name" | grep -i "Keychron" >/dev/null 2>&1; then
                    # Check if device is connected with timeout
                    local device_info
                    if ! device_info=$(timeout 3s bluetoothctl info "$device_mac" 2>/dev/null || true); then
                        keychron_devices+=("Bluetooth: $device_name (timeout)")
                    else
                        keychron_devices+=("Bluetooth: $device_name")
                    fi
                fi
            done <<< "$bt_devices"
        fi
        
        # Also check for currently connected devices
        local connected_bt=$(bluetoothctl devices Connected 2>/dev/null || true)
        if [[ -n "$connected_bt" ]]; then
            while IFS= read -r line; do
                local device_mac=$(echo "$line" | awk '{print $2}')
                local device_name=$(echo "$line" | cut -d' ' -f3-)
                if echo "$device_name" | grep -i "Keychron" >/dev/null 2>&1; then
                    keychron_devices+=("Bluetooth Connected: $device_name ($device_mac)")
                fi
            done <<< "$connected_bt"
        fi
    fi
    
    # Check for Keychron devices in /sys/bus/usb/devices/ (more thorough)
    for device in /sys/bus/usb/devices/*/idVendor; do
        if [[ -f "$device" ]]; then
            local vendor=$(cat "$device" 2>/dev/null || echo "")
            # Keychron uses various vendor IDs, commonly 3496
            if [[ "$vendor" == "3496" ]] || [[ "$vendor" == "05ac" ]]; then  # Keychron or Apple (some Keychron use Apple IDs)
                local device_path=$(dirname "$device")
                local product_file="$device_path/idProduct"
                if [[ -f "$product_file" ]]; then
                    local product=$(cat "$product_file" 2>/dev/null || echo "")
                    # Check for specific Keychron K8 Pro model
                    case "$product" in
                        "6032"|"6034"|"6035")
                            keychron_devices+=("System: Keychron K8 Pro (VID:$vendor PID:$product)")
                            ;;
                        *)
                            keychron_devices+=("System: Keychron keyboard (VID:$vendor PID:$product)")
                            ;;
                    esac
                fi
            fi
        fi
    done
    
    # Check for input devices that might be Keychron
    for input_device in /sys/class/input/input*/device/id/vendor; do
        if [[ -f "$input_device" ]]; then
            local vendor=$(cat "$input_device" 2>/dev/null || echo "")
            if [[ "$vendor" == "3496" ]] || [[ "$vendor" == "05ac" ]]; then
                local device_path=$(dirname "$input_device")
                local product_file="$device_path/../id/product"
                if [[ -f "$product_file" ]]; then
                    local product=$(cat "$product_file" 2>/dev/null || echo "")
                    if echo "$product" | grep -i "Keychron" >/dev/null 2>&1; then
                        keychron_devices+=("Input Device: Keychron $product")
                    fi
                fi
            fi
        fi
    done
    
    # Check for Keychron in /proc/bus/input/devices (alternative detection)
    if [[ -f /proc/bus/input/devices ]]; then
        local keychron_input=$(grep -i "Keychron" /proc/bus/input/devices 2>/dev/null || true)
        if [[ -n "$keychron_input" ]]; then
            while IFS= read -r line; do
                if echo "$line" | grep -q "Name="; then
                    local device_name=$(echo "$line" | cut -d= -f2- | sed 's/^"//; s/"$//')
                    keychron_devices+=("Input System: $device_name")
                fi
            done <<< "$keychron_input"
        fi
    fi
    
    printf '%s\n' "${keychron_devices[@]}"
}

# Detect other common peripherals that might need special packages
detect_other_peripherals() {
    local other_devices=()
    
    # Check for Razer devices
    if lsusb | grep -i "Razer" >/dev/null 2>&1; then
        other_devices+=("Razer gaming device detected")
    fi
    
    # Check for gaming mice (common gaming mouse vendors)
    local gaming_vendors=("1532" "046d" "1b1c" "1532" "045e")  # Razer, Logitech, Corsair, Razer, Microsoft
    for vendor_id in "${gaming_vendors[@]}"; do
        for device in /sys/bus/usb/devices/*/idVendor; do
            if [[ -f "$device" ]]; then
                local vendor=$(cat "$device" 2>/dev/null || echo "")
                if [[ "$vendor" == "$vendor_id" ]]; then
                    local device_path=$(dirname "$device")
                    local product_file="$device_path/idProduct"
                    if [[ -f "$product_file" ]]; then
                        local product=$(cat "$product_file" 2>/dev/null || echo "")
                        other_devices+=("Gaming device detected (VID:$vendor_id PID:$product)")
                    fi
                fi
            fi
        done
    done
    
    printf '%s\n' "${other_devices[@]}"
}

# ===== Package Installation Functions =====

# Function to check if a package is already installed
is_package_installed() {
    local package="$1"
    if pacman -Qi "$package" >/dev/null 2>&1; then
        return 0
    elif command -v yay >/dev/null 2>&1 && yay -Qi "$package" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Function to safely install a package without duplicates
safe_install_package() {
    local package="$1"
    local package_type="$2"  # "pacman" or "aur"
    
    if is_package_installed "$package"; then
        ui_info "$package is already installed, skipping..."
        log_info "$package already present on system"
        return 0
    fi
    
    case "$package_type" in
        "pacman")
            if pacman_install_single "$package" true; then
                log_success "Successfully installed $package"
                INSTALLED_PACKAGES+=("$package")
                return 0
            else
                log_error "Failed to install $package"
                return 1
            fi
            ;;
        "aur")
            if command -v yay >/dev/null 2>&1; then
                if yay -S --noconfirm --needed "$package" >/dev/null 2>&1; then
                    log_success "Successfully installed $package from AUR"
                    INSTALLED_PACKAGES+=("$package")
                    return 0
                else
                    log_error "Failed to install $package from AUR"
                    return 1
                fi
            else
                log_error "yay not available for AUR package installation"
                return 1
            fi
            ;;
        *)
            log_error "Unknown package type: $package_type"
            return 1
            ;;
    esac
}

# Install Logitech software (Solaar)
install_logitech_software() {
    ui_info "Logitech devices detected, installing Solaar for Logitech peripheral management..."
    
    local success=true
    
    # Install solaar using safe installation
    if ! safe_install_package "solaar" "pacman"; then
        success=false
    fi
    
    if [[ "$success" == true ]]; then
        ui_success "Logitech software installation completed"
        log_success "Logitech peripheral support installed"
        
        # Enable and start Solaar service if available
        if systemctl list-unit-files | grep -q "solaar.service"; then
            sudo systemctl enable --now solaar.service 2>/dev/null || true
            ui_info "Solaar service enabled"
        fi
        
        # Add user to plugdev group for device access
        if groups "$USER" | grep -q "plugdev"; then
            ui_info "User already in plugdev group"
        else
            sudo usermod -a -G plugdev "$USER" 2>/dev/null || true
            ui_info "Added user to plugdev group for device access"
        fi
    else
        ui_error "Solaar installation failed"
        log_error "Logitech software installation incomplete"
    fi
    
    return $([[ "$success" == true ]] && echo 0 || echo 1)
}

# Install Keychron keyboard software (via-bin from AUR)
install_keychron_software() {
    ui_info "Keychron keyboard detected, installing via-bin for keyboard management..."
    
    local success=true
    
    # Install via-bin using safe installation
    if ! safe_install_package "via-bin" "aur"; then
        success=false
    fi
    
    if [[ "$success" == true ]]; then
        ui_success "Keychron software installation completed"
        log_success "Keychron keyboard support installed"
        
        # Add user to input group for VIA access
        if groups "$USER" | grep -q "input"; then
            ui_info "User already in input group"
        else
            sudo usermod -a -G input "$USER" 2>/dev/null || true
            ui_info "Added user to input group for VIA access"
        fi
    else
        ui_error "via-bin installation failed"
        log_error "Keychron software installation incomplete"
    fi
    
    return $([[ "$success" == true ]] && echo 0 || echo 1)
}

# ===== Main Detection and Installation Function =====

smart_peripheral_detection() {
    ui_info "Starting smart peripheral detection..."
    
    # Check if running in VM and skip intensive detection
    if is_vm_environment; then
        ui_warn "Virtual machine detected - using simplified peripheral detection"
        ui_info "VM environments may not show all connected devices"
        return 0
    fi
    
    # Validate required commands are available
    local required_commands=("lsusb")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            ui_error "Required command '$cmd' not found. Cannot perform peripheral detection."
            log_error "Missing required command: $cmd"
            return 1
        fi
    done
    
    # Check if we have necessary permissions
    if [[ $EUID -eq 0 ]]; then
        ui_warn "Running as root - some detection methods may behave differently"
    fi
    
    local config_loaded=false
    if load_peripheral_config; then
        config_loaded=true
    fi
    
    local logitech_detected=false
    local keychron_detected=false
    local other_detected=false
    local installation_success=true
    
    # Detect Logitech devices
    local logitech_devices
    readarray -t logitech_devices < <(detect_logitech_devices)
    if [[ ${#logitech_devices[@]} -gt 0 ]]; then
        logitech_detected=true
        ui_info "Logitech devices detected:"
        for device in "${logitech_devices[@]}"; do
            ui_info "  • $device"
        done
    fi
    
    # Detect Keychron keyboards
    local keychron_devices
    readarray -t keychron_devices < <(detect_keychron_keyboards)
    if [[ ${#keychron_devices[@]} -gt 0 ]]; then
        keychron_detected=true
        ui_info "Keychron keyboards detected:"
        for device in "${keychron_devices[@]}"; do
            ui_info "  • $device"
        done
    fi
    
    # Detect other peripherals
    local other_devices
    readarray -t other_devices < <(detect_other_peripherals)
    if [[ ${#other_devices[@]} -gt 0 ]]; then
        other_detected=true
        ui_info "Other peripherals detected:"
        for device in "${other_devices[@]}"; do
            ui_info "  • $device"
        done
    fi
    
    # Install appropriate software based on detected devices
    if [[ "$logitech_detected" == true ]]; then
        ui_info "Installing Logitech software..."
        if ! install_logitech_software; then
            installation_success=false
            ui_warn "Logitech software installation encountered issues"
        fi
    fi
    
    if [[ "$keychron_detected" == true ]]; then
        ui_info "Installing Keychron software..."
        if ! install_keychron_software; then
            installation_success=false
            ui_warn "Keychron software installation encountered issues"
        fi
    fi
    
    # Summary
    echo ""
    ui_info "Smart Peripheral Detection Summary:"
    if [[ "$logitech_detected" == true ]]; then
        ui_info "  ✓ Logitech devices: Solaar management software"
    fi
    if [[ "$keychron_detected" == true ]]; then
        ui_info "  ✓ Keychron keyboards: VIA configuration tool"
    fi
    if [[ "$other_detected" == true ]]; then
        ui_info "  ✓ Other gaming/peripheral devices detected"
    fi
    if [[ "$logitech_detected" == false ]] && [[ "$keychron_detected" == false ]] && [[ "$other_detected" == false ]]; then
        ui_info "  ℹ No specific peripheral software needed"
    fi
    
    # Final validation
    if [[ "$installation_success" == true ]]; then
        ui_success "Smart peripheral detection completed successfully"
        log_success "Smart peripheral detection completed without errors"
        return 0
    else
        ui_warn "Smart peripheral detection completed with some issues"
        log_warning "Some peripheral software installation failed"
        return 1
    fi
}

# ===== Advanced Detection with YAML Config =====

detect_peripherals_from_config() {
    local config_file="$SCRIPT_DIR/../configs/peripherals.yaml"
    
    if [[ ! -f "$config_file" ]] || ! command -v yq >/dev/null 2>&1; then
        return 1
    fi
    
    ui_info "Using advanced peripheral detection with configuration..."
    
    local detected_peripherals=()
    
    # Parse YAML config and detect devices
    local peripheral_types
    readarray -t peripheral_types < <(yq 'keys | .[]' "$config_file" 2>/dev/null || true)
    
    for peripheral_type in "${peripheral_types[@]}"; do
        local vendor_ids
        readarray -t vendor_ids < <(yq ".${peripheral_type}.detection.vendor_ids.[]" "$config_file" 2>/dev/null || true)
        
        local name_patterns
        readarray -t name_patterns < <(yq ".${peripheral_type}.detection.name_patterns.[]" "$config_file" 2>/dev/null || true)
        
        local detected=false
        
        # Check USB devices
        for vendor_id in "${vendor_ids[@]}"; do
            if lsusb | grep -i "$vendor_id" >/dev/null 2>&1; then
                detected=true
                detected_peripherals+=("$peripheral_type (USB: $vendor_id)")
                break
            fi
        done
        
        # Check name patterns
        if [[ "$detected" == false ]]; then
            for pattern in "${name_patterns[@]}"; do
                if lsusb | grep -i "$pattern" >/dev/null 2>&1; then
                    detected=true
                    detected_peripherals+=("$peripheral_type (Name: $pattern)")
                    break
                fi
            done
        fi
        
        # Install packages if detected
        if [[ "$detected" == true ]]; then
            ui_info "$peripheral_type devices detected, installing packages..."
            install_peripheral_packages "$peripheral_type" "$config_file"
        fi
    done
    
    if [[ ${#detected_peripherals[@]} -gt 0 ]]; then
        ui_info "Advanced detection found:"
        for peripheral in "${detected_peripherals[@]}"; do
            ui_info "  • $peripheral"
        done
    fi
}

install_peripheral_packages() {
    local peripheral_type="$1"
    local config_file="$2"
    
    # Install pacman packages
    local pacman_packages
    readarray -t pacman_packages < <(yq ".${peripheral_type}.packages.pacman.[].name" "$config_file" 2>/dev/null || true)
    
    for pkg in "${pacman_packages[@]}"; do
        ui_info "Installing $pkg for $peripheral_type..."
        if pacman_install_single "$pkg" true; then
            log_success "Installed $pkg for $peripheral_type"
            INSTALLED_PACKAGES+=("$pkg")
        else
            log_error "Failed to install $pkg for $peripheral_type"
        fi
    done
    
    # Install AUR packages
    local aur_packages
    readarray -t aur_packages < <(yq ".${peripheral_type}.packages.aur.[].name" "$config_file" 2>/dev/null || true)
    
    for pkg in "${aur_packages[@]}"; do
        ui_info "Installing $pkg from AUR for $peripheral_type..."
        if command -v yay >/dev/null 2>&1 && yay -S --noconfirm --needed "$pkg" >/dev/null 2>&1; then
            log_success "Installed $pkg from AUR for $peripheral_type"
            INSTALLED_PACKAGES+=("$pkg")
        else
            log_error "Failed to install $pkg from AUR for $peripheral_type"
        fi
    done
    
    # Run post-install commands
    local post_install_commands
    readarray -t post_install_commands < <(yq ".${peripheral_type}.packages.pacman.[].post_install.[]" "$config_file" 2>/dev/null || true)
    
    for cmd in "${post_install_commands[@]}"; do
        ui_info "Running post-install command: $cmd"
        if eval "$cmd" 2>/dev/null; then
            log_success "Post-install command completed: $cmd"
        else
            log_warning "Post-install command failed: $cmd"
        fi
    done
    
    # Enable services
    local services
    readarray -t services < <(yq ".${peripheral_type}.packages.pacman.[].service" "$config_file" 2>/dev/null || true)
    
    for service in "${services[@]}"; do
        ui_info "Enabling service: $service"
        if sudo systemctl enable --now "$service" 2>/dev/null; then
            log_success "Service enabled: $service"
        else
            log_warning "Failed to enable service: $service"
        fi
    done
}

# ===== Standalone Execution =====
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    smart_peripheral_detection
fi
