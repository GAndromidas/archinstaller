#!/bin/bash
set -uo pipefail

# Smart Peripheral Detection for Archinstaller
# Focused detection for Keychron keyboards and Logitech mice
# Only installs software when devices are actually detected

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# ===== Focused Device Detection =====

# Detect Logitech mice (specifically G502 X Lightspeed and other Logitech mice)
detect_logitech_mice() {
    local logitech_devices=()
    
    # Quick USB scan with timeout
    local usb_devices
    if ! usb_devices=$(timeout 2s lsusb 2>/dev/null); then
        return 0
    fi
    
    # Look specifically for Logitech vendor ID (046d) and mouse-related devices
    local logitech_mice=$(echo "$usb_devices" | grep -i "046d" | grep -i "mouse\|g502\|lightspeed\|g pro\|g703\|g903" | head -3)
    
    if [[ -n "$logitech_mice" ]]; then
        while IFS= read -r line; do
            if [[ -n "$line" ]]; then
                local device_name=$(echo "$line" | cut -d: -f3- | sed 's/^ *//')
                local device_id=$(echo "$line" | awk '{print $6}')
                
                # Enhanced detection for specific models
                if echo "$device_name" | grep -qi "g502.*lightspeed\|g502 x"; then
                    logitech_devices+=("Logitech G502 X Lightspeed: $device_name ($device_id)")
                elif echo "$device_name" | grep -qi "mouse\|g pro\|g703\|g903"; then
                    logitech_devices+=("Logitech Mouse: $device_name ($device_id)")
                fi
            fi
        done <<< "$logitech_mice"
    fi
    
    # Quick Bluetooth check for Logitech mice
    if command -v bluetoothctl >/dev/null 2>&1 && systemctl is-active --quiet bluetooth 2>/dev/null; then
        local bt_devices=$(timeout 2s bluetoothctl devices 2>/dev/null | grep -i "Logitech.*mouse\|Logitech.*g502" | head -2)
        if [[ -n "$bt_devices" ]]; then
            while IFS= read -r line; do
                if [[ -n "$line" ]]; then
                    local device_name=$(echo "$line" | cut -d' ' -f3-)
                    logitech_devices+=("Logitech Bluetooth Mouse: $device_name")
                fi
            done <<< "$bt_devices"
        fi
    fi
    
    printf '%s\n' "${logitech_devices[@]}"
}

# Detect Keychron keyboards (specifically K8 Pro and other Keychron models)
detect_keychron_keyboards() {
    local keychron_devices=()
    
    # Quick USB scan with timeout
    local usb_devices
    if ! usb_devices=$(timeout 2s lsusb 2>/dev/null); then
        return 0
    fi
    
    # Look specifically for Keychron vendor ID (3496) AND device name containing Keychron
    local keychron_keyboards=$(echo "$usb_devices" | grep -i "3496" | grep -i "Keychron" | head -3)
    
    if [[ -n "$keychron_keyboards" ]]; then
        while IFS= read -r line; do
            if [[ -n "$line" ]]; then
                local device_name=$(echo "$line" | cut -d: -f3- | sed 's/^ *//')
                local device_id=$(echo "$line" | awk '{print $6}')
                
                # Ultra-strict detection - must have vendor ID 3496 AND Keychron in name
                if echo "$line" | grep -qi "3496" && echo "$device_name" | grep -qi "Keychron"; then
                    # Enhanced detection for specific models
                    if echo "$device_name" | grep -qi "k8.*pro\|k8 pro"; then
                        keychron_devices+=("Keychron K8 Pro: $device_name ($device_id)")
                    elif echo "$device_name" | grep -qi "k6\|k2\|keyboard"; then
                        keychron_devices+=("Keychron Keyboard: $device_name ($device_id)")
                    fi
                fi
            fi
        done <<< "$keychron_keyboards"
    fi
    
    # Bluetooth detection for Keychron - very specific to avoid false positives
    if command -v bluetoothctl >/dev/null 2>&1 && systemctl is-active --quiet bluetooth 2>/dev/null; then
        local bt_devices=$(timeout 2s bluetoothctl devices 2>/dev/null | grep -i "Keychron.*K8.*Pro\|Keychron.*K8 Pro" | head -2)
        if [[ -n "$bt_devices" ]]; then
            while IFS= read -r line; do
                if [[ -n "$line" ]]; then
                    local device_name=$(echo "$line" | cut -d' ' -f3-)
                    # Only count if it's specifically K8 Pro
                    if echo "$device_name" | grep -qi "K8.*Pro\|K8 Pro"; then
                        keychron_devices+=("Keychron K8 Pro (Bluetooth): $device_name")
                    fi
                fi
            done <<< "$bt_devices"
        fi
    fi
    
    printf '%s\n' "${keychron_devices[@]}"
}

# ===== Smart Installation Functions =====

# Install Solaar for Logitech mice with autostart configuration
install_solaar_for_logitech() {
    ui_info "Installing Solaar for Logitech mouse management..."
    
    local success=true
    
    # Check if Solaar is already installed
    if pacman -Qi solaar >/dev/null 2>&1; then
        ui_info "Solaar is already installed"
    else
        # Install Solaar with timeout
        if ! timeout 30s sudo pacman -S --noconfirm --needed solaar >/dev/null 2>&1; then
            ui_warn "Solaar installation failed or timed out"
            success=false
        fi
    fi
    
    if [[ "$success" == true ]]; then
        ui_success "Solaar installed successfully"
        
        # Enable and start Solaar service
        if systemctl list-unit-files | grep -q "solaar.service"; then
            timeout 5s sudo systemctl enable --now solaar.service 2>/dev/null || true
            ui_info "Solaar service enabled"
        fi
        
        # Add user to plugdev group for device access
        if timeout 3s groups "$USER" | grep -q "plugdev"; then
            ui_info "User already in plugdev group"
        else
            timeout 3s sudo usermod -a -G plugdev "$USER" 2>/dev/null || true
            ui_info "Added user to plugdev group for device access"
        fi
        
        # Create autostart configuration for system tray
        setup_solaar_autostart
        
        log_success "Logitech mouse support installed with system tray integration"
    else
        ui_error "Solaar installation failed"
        log_error "Logitech mouse setup incomplete"
    fi
    
    return $([[ "$success" == true ]] && echo 0 || echo 1)
}

# Setup Solaar autostart with system tray integration
setup_solaar_autostart() {
    local autostart_dir="$HOME/.config/autostart"
    local desktop_file="$autostart_dir/solaar.desktop"
    
    # Create autostart directory if it doesn't exist
    mkdir -p "$autostart_dir" 2>/dev/null || true
    
    # Create desktop file for autostart
    cat > "$desktop_file" << 'EOF'
[Desktop Entry]
Type=Application
Name=Solaar
Comment=Logitech Mouse and Keyboard Configuration
Exec=solaar --window=hide
Icon=solaar
Terminal=false
Categories=System;Settings;
StartupNotify=false
X-GNOME-Autostart-enabled=true
X-KDE-autostart-after-plasma
EOF
    
    if [[ -f "$desktop_file" ]]; then
        ui_success "Solaar autostart configured for system tray"
        ui_info "Solaar will start automatically with system tray icon"
    else
        ui_warn "Failed to create Solaar autostart configuration"
    fi
}

# Install VIA for Keychron keyboards
install_via_for_keychron() {
    ui_info "Installing VIA for Keychron keyboard management..."
    
    local success=true
    
    # Check if yay is available
    if ! command -v yay >/dev/null 2>&1; then
        ui_warn "yay not available - cannot install VIA from AUR"
        return 1
    fi
    
    # Check if via-bin is already installed
    if yay -Qi via-bin >/dev/null 2>&1; then
        ui_info "VIA is already installed"
    else
        # Install via-bin with timeout
        if ! timeout 60s yay -S --noconfirm --needed via-bin >/dev/null 2>&1; then
            ui_warn "VIA installation failed or timed out"
            success=false
        fi
    fi
    
    if [[ "$success" == true ]]; then
        ui_success "VIA installed successfully"
        
        # Add user to input group for VIA access
        if timeout 3s groups "$USER" | grep -q "input"; then
            ui_info "User already in input group"
        else
            timeout 3s sudo usermod -a -G input "$USER" 2>/dev/null || true
            ui_info "Added user to input group for VIA access"
        fi
        
        log_success "Keychron keyboard support installed"
    else
        ui_error "VIA installation failed"
        log_error "Keychron keyboard setup incomplete"
    fi
    
    return $([[ "$success" == true ]] && echo 0 || echo 1)
}

# ===== Main Smart Detection Function =====

smart_peripheral_detection() {
    ui_info "Starting smart peripheral detection..."
    
    # Check if running on laptop - skip peripheral detection on laptops
    if is_laptop; then
        ui_info "Laptop detected - using built-in touchpad and keyboard"
        ui_info "Skipping external peripheral detection"
        return 0
    fi
    
    # Validate lsusb is available
    if ! command -v lsusb >/dev/null 2>&1; then
        ui_warn "lsusb not available - skipping peripheral detection"
        return 0
    fi
    
    local logitech_detected=false
    local keychron_detected=false
    local installation_success=true
    
    # Detect Logitech mice
    ui_info "Scanning for Logitech mice..."
    local logitech_devices
    readarray -t logitech_devices < <(detect_logitech_mice)
    
    # Validate that we actually have Logitech devices (not empty strings)
    local has_logitech=false
    for device in "${logitech_devices[@]}"; do
        if [[ -n "$device" && "$device" != *"Logitech USB device: "* ]]; then
            has_logitech=true
            break
        fi
    done
    
    if [[ "$has_logitech" == true ]]; then
        logitech_detected=true
        ui_success "Logitech mice detected:"
        for device in "${logitech_devices[@]}"; do
            if [[ -n "$device" && "$device" != *"Logitech USB device: "* ]]; then
                ui_info "  • $device"
            fi
        done
        
        # Install Solaar only if Logitech mice detected
        if ! install_solaar_for_logitech; then
            installation_success=false
        fi
    else
        ui_info "No Logitech mice detected"
    fi
    
    # Detect Keychron keyboards
    ui_info "Scanning for Keychron keyboards..."
    local keychron_devices
    readarray -t keychron_devices < <(detect_keychron_keyboards)
    
    # Validate that we actually have Keychron devices (not empty strings)
    local has_keychron=false
    for device in "${keychron_devices[@]}"; do
        if [[ -n "$device" && "$device" == *"Keychron"* ]]; then
            has_keychron=true
            break
        fi
    done
    
    if [[ "$has_keychron" == true ]]; then
        keychron_detected=true
        ui_success "Keychron keyboards detected:"
        for device in "${keychron_devices[@]}"; do
            if [[ -n "$device" && "$device" == *"Keychron"* ]]; then
                ui_info "  • $device"
            fi
        done
        
        # Install VIA only if Keychron keyboards detected
        if ! install_via_for_keychron; then
            installation_success=false
        fi
    else
        ui_info "No Keychron keyboards detected"
    fi
    
    # Summary
    echo
    ui_info "Peripheral detection summary:"
    if [[ "$logitech_detected" == true ]]; then
        ui_success "✓ Logitech mice detected and configured"
    fi
    if [[ "$keychron_detected" == true ]]; then
        ui_success "✓ Keychron keyboards detected and configured"
    fi
    if [[ "$logitech_detected" == false && "$keychron_detected" == false ]]; then
        ui_info "No supported peripherals detected"
    fi
    
    if [[ "$installation_success" == false ]]; then
        ui_warn "Some peripheral software installations encountered issues"
    fi
    
    echo
    ui_info "Smart peripheral detection completed"
}

# Execute main function if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    smart_peripheral_detection
fi
