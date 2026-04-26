#!/bin/bash
set -uo pipefail

# ============================================================================
# Wake-on-LAN Configuration for ArchInstaller
# Smart detection and configuration for ethernet devices only
# ============================================================================

# Get scripts directory (handles both direct execution and sourcing)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Ensure color variables are available for standalone execution
if [[ -z "${BOLD:-}" ]]; then
    BOLD='\033[1m'
fi

# Function to detect if system is a laptop
is_laptop() {
    # Check for battery presence
    if [ -d /sys/class/power_supply/BAT0 ] || [ -d /sys/class/power_supply/BAT1 ]; then
        return 0
    fi
    
    # Check DMI product type for laptop/chassis
    if command -v dmidecode &>/dev/null; then
        local chassis_type=$(dmidecode -s chassis-type 2>/dev/null | tr '[:upper:]' '[:lower:]')
        case "$chassis_type" in
            "laptop"|"notebook"|"portable"|"sub notebook"|"convertible"|"detachable")
                return 0
                ;;
        esac
    fi
    
    # Check system product name for common laptop indicators
    if [ -f /sys/devices/virtual/dmi/id/product_name ]; then
        local product_name=$(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null | tr '[:upper:]' '[:lower:]')
        case "$product_name" in
            *laptop*|*notebook*|*book*|*ultrabook*|*macbook*|*thinkpad*|*latitude*|*precision*)
                return 0
                ;;
        esac
    fi
    
    return 1
}

# Function to test internet connectivity on interface
test_interface_connectivity() {
    local iface="$1"
    local timeout=5
    
    # Bring interface up if not already
    if ! ip link show "$iface" | grep -q "state UP"; then
        sudo ip link set "$iface" up 2>/dev/null || return 1
    fi
    
    # Test connectivity with multiple methods
    # Method 1: Try to ping 8.8.8.8
    if timeout "$timeout" ping -I "$iface" -c 1 -W 3 8.8.8.8 &>/dev/null; then
        return 0
    fi
    
    # Method 2: Try to ping 1.1.1.1
    if timeout "$timeout" ping -I "$iface" -c 1 -W 3 1.1.1.1 &>/dev/null; then
        return 0
    fi
    
    # Method 3: Check if interface has default route
    if ip route show dev "$iface" | grep -q "default"; then
        return 0
    fi
    
    return 1
}

# Function to get interface with internet connectivity
get_active_ethernet_interface() {
    local interfaces=($(get_ethernet_interfaces))
    
    for iface in "${interfaces[@]}"; do
        if test_interface_connectivity "$iface"; then
            echo "$iface"
            return 0
        fi
    done
    
    return 1
}

# Function to detect ethernet interfaces
get_ethernet_interfaces() {
    local interfaces=()
    
    # Get all network interfaces
    while IFS= read -r iface; do
        # Skip loopback and non-ethernet interfaces
        [[ "$iface" == "lo" ]] && continue
        
        # Check if interface is ethernet (not wireless)
        if [[ "$iface" =~ ^(enp|eth|ens|eno) ]]; then
            # Verify it's a physical interface
            if [ -d "/sys/class/net/$iface" ] && [ ! -L "/sys/class/net/$iface" ]; then
                # Check if interface supports carrier (physical connection)
                if [ -f "/sys/class/net/$iface/carrier" ] || [ -f "/sys/class/net/$iface/speed" ]; then
                    interfaces+=("$iface")
                fi
            fi
        fi
    done < <(ls /sys/class/net/ 2>/dev/null)
    
    printf '%s\n' "${interfaces[@]}"
}

# Function to check if interface supports Wake-on-LAN
supports_wol() {
    local iface="$1"
    
    # Check if ethtool is available
    if ! command -v ethtool &>/dev/null; then
        return 1
    fi
    
    # Check if interface supports WoL
    if sudo ethtool "$iface" &>/dev/null; then
        local wol_support=$(sudo ethtool "$iface" | awk '/Supports Wake-on:/ {print $4}')
        if [[ -n "$wol_support" && "$wol_support" != *"g"* ]]; then
            return 1
        fi
        return 0
    fi
    
    return 1
}

# Function to enable Wake-on-LAN on interface
enable_wol_interface() {
    local iface="$1"
    
    log_to_file "Enabling Wake-on-LAN on interface: $iface"
    
    # Enable WoL
    if sudo ethtool -s "$iface" wol g; then
        log_to_file "Wake-on-LAN enabled on $iface"
        ui_success "Wake-on-LAN enabled on $iface"
        
        # Create systemd service for persistence
        create_wol_service "$iface"
        return 0
    else
        log_to_file "Failed to enable Wake-on-LAN on $iface"
        ui_error "Failed to enable Wake-on-LAN on $iface"
        return 1
    fi
}

# Function to create systemd service for WoL persistence
create_wol_service() {
    local iface="$1"
    local service_file="/etc/systemd/system/wol-$iface.service"
    
    log_to_file "Creating systemd service for WoL on $iface"
    
    # Create systemd service file
    sudo tee "$service_file" > /dev/null <<EOF
[Unit]
Description=Enable Wake-on-LAN for $iface
After=network.target
Wants=network.target

[Service]
Type=oneshot
ExecStart=/sbin/ethtool -s $iface wol g
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    # Reload systemd and enable service
    sudo systemctl daemon-reload
    if sudo systemctl enable "wol-$iface.service"; then
        log_to_file "Systemd service enabled for WoL on $iface"
        ui_success "Persistent Wake-on-LAN service created for $iface"
    else
        log_to_file "Failed to enable systemd service for WoL on $iface"
        ui_error "Failed to create persistent WoL service for $iface"
    fi
}

# Function to get MAC address of interface
get_interface_mac() {
    local iface="$1"
    local mac_address=$(ip link show "$iface" 2>/dev/null | awk '/link\/ether/ {print $2}' | head -1)
    echo "$mac_address"
}

# Function to display WoL status
show_wol_status() {
    local interfaces=($(get_ethernet_interfaces))
    
    if [ ${#interfaces[@]} -eq 0 ]; then
        ui_info "No ethernet interfaces found"
        return 1
    fi
    
    echo -e "${CYAN}Wake-on-LAN Status:${RESET}"
    echo -e "${YELLOW}==================${RESET}"
    
    for iface in "${interfaces[@]}"; do
        local mac_addr=$(get_interface_mac "$iface")
        local wol_status="Unknown"
        
        if supports_wol "$iface"; then
            wol_status=$(sudo ethtool "$iface" 2>/dev/null | awk '/Wake-on:/ {print $2}')
            if [[ "$wol_status" == *"g"* ]]; then
                wol_status="${GREEN}Enabled${RESET}"
            else
                wol_status="${YELLOW}Disabled${RESET}"
            fi
        else
            wol_status="${RED}Not Supported${RESET}"
        fi
        
        echo -e "${CYAN}Interface: ${RESET}$iface"
        echo -e "${CYAN}MAC Address: ${RESET}${mac_addr:-N/A}"
        echo -e "${CYAN}WoL Status: ${RESET}$wol_status"
        echo -e "${YELLOW}------------------${RESET}"
    done
}

# Function to prompt user for interface selection
prompt_interface_selection() {
    local interfaces=("$@")
    local active_iface
    local choices=()
    
    # Find active interface (with internet)
    active_iface=$(get_active_ethernet_interface)
    
    ui_info "Multiple ethernet interfaces detected:"
    echo ""
    
    # Build choices array
    local i=1
    for iface in "${interfaces[@]}"; do
        local status=""
        local mac_addr=$(get_interface_mac "$iface")
        
        if [[ "$iface" == "$active_iface" ]]; then
            status="${GREEN}[ACTIVE - Internet]${RESET}"
        else
            status="${YELLOW}[No Internet]${RESET}"
        fi
        
        echo -e "${CYAN}$i)${RESET} $iface $status"
        echo -e "   MAC: ${mac_addr:-N/A}"
        echo ""
        choices+=("$iface")
        i=$((i + 1))
    done
    
    echo -e "${CYAN}a)${RESET} Configure ALL interfaces"
    echo -e "${CYAN}s)${RESET} Skip Wake-on-LAN configuration"
    echo ""
    
    while true; do
        echo -ne "${BOLD}Select option [1-${#interfaces[@]}, a, s]:${RESET} "
        read -r choice
        
        case "$choice" in
            [0-9]*|[0-9]*)
                if [[ "$choice" -ge 1 && "$choice" -le ${#interfaces[@]} ]]; then
                    local selected_iface="${choices[$((choice-1))]}"
                    echo ""
                    ui_info "Selected interface: $selected_iface"
                    echo "$selected_iface"
                    return 0
                else
                    ui_error "Invalid selection. Please try again."
                fi
                ;;
            a|A)
                echo ""
                ui_info "Configuring ALL ethernet interfaces"
                echo "ALL"
                return 0
                ;;
            s|S)
                echo ""
                ui_info "Wake-on-LAN configuration skipped"
                echo "SKIP"
                return 0
                ;;
            *)
                ui_error "Invalid option. Please try again."
                ;;
        esac
    done
}

# Main Wake-on-LAN configuration function
configure_wakeonlan() {
    ui_info "Configuring Wake-on-LAN..."
    
    # Check if system is a laptop
    if is_laptop; then
        ui_info "Laptop system detected - Wake-on-LAN configuration skipped"
        ui_info "Wake-on-LAN is typically not needed on laptops"
        log_to_file "Laptop detected - WoL configuration skipped"
        return 0
    fi
    
    # Install ethtool if not present
    if ! command -v ethtool &>/dev/null; then
        ui_info "Installing ethtool for Wake-on-LAN support..."
        if sudo pacman -S --noconfirm ethtool; then
            ui_success "ethtool installed successfully"
            log_to_file "ethtool installed for WoL support"
        else
            ui_error "Failed to install ethtool"
            return 1
        fi
    fi
    
    # Get ethernet interfaces
    local interfaces=($(get_ethernet_interfaces))
    
    if [ ${#interfaces[@]} -eq 0 ]; then
        ui_info "No ethernet interfaces found - Wake-on-LAN configuration skipped"
        log_to_file "No ethernet interfaces found - WoL configuration skipped"
        return 0
    fi
    
    ui_info "Found ${#interfaces[@]} ethernet interface(s): ${interfaces[*]}"
    
    # Check for internet connectivity on interfaces
    local active_iface=$(get_active_ethernet_interface)
    if [ -n "$active_iface" ]; then
        ui_success "Detected active internet connection on: $active_iface"
    else
        ui_warn "No ethernet interface has internet connectivity"
    fi
    
    local selection=""
    if [ ${#interfaces[@]} -eq 1 ]; then
        # Single interface - auto-select
        selection="${interfaces[0]}"
        ui_info "Auto-selecting single interface: $selection"
    else
        # Multiple interfaces - prompt user
        selection=$(prompt_interface_selection "${interfaces[@]}")
        
        if [[ "$selection" == "SKIP" ]]; then
            log_to_file "User chose to skip WoL configuration"
            return 0
        fi
    fi
    
    # Configure selected interfaces
    local success_count=0
    if [[ "$selection" == "ALL" ]]; then
        # Configure all interfaces
        for iface in "${interfaces[@]}"; do
            ui_info "Processing interface: $iface"
            
            if supports_wol "$iface"; then
                if enable_wol_interface "$iface"; then
                    success_count=$((success_count + 1))
                    
                    # Display MAC address for user reference
                    local mac_addr=$(get_interface_mac "$iface")
                    if [ -n "$mac_addr" ]; then
                        ui_info "MAC address for $iface: $mac_addr"
                        ui_info "Use this MAC address to send Wake-on-LAN packets"
                    fi
                fi
            else
                ui_warn "Interface $iface does not support Wake-on-LAN"
            fi
        done
    else
        # Configure single selected interface
        ui_info "Processing interface: $selection"
        
        if supports_wol "$selection"; then
            if enable_wol_interface "$selection"; then
                success_count=$((success_count + 1))
                
                # Display MAC address for user reference
                local mac_addr=$(get_interface_mac "$selection")
                if [ -n "$mac_addr" ]; then
                    ui_success "MAC address for $selection: $mac_addr"
                    ui_info "Use this MAC address to send Wake-on-LAN packets"
                fi
            fi
        else
            ui_warn "Interface $selection does not support Wake-on-LAN"
        fi
    fi
    
    if [ $success_count -gt 0 ]; then
        ui_success "Wake-on-LAN configured successfully on $success_count interface(s)"
        ui_info "Wake-on-LAN will persist after reboots"
        
        # Show final status
        echo ""
        show_wol_status
    else
        ui_warn "No interfaces were configured with Wake-on-LAN"
    fi
    
    return 0
}

# Function to disable Wake-on-LAN (for cleanup)
disable_wakeonlan() {
    ui_info "Disabling Wake-on-LAN..."
    
    local interfaces=($(get_ethernet_interfaces))
    
    for iface in "${interfaces[@]}"; do
        # Disable WoL
        if sudo ethtool -s "$iface" wol d 2>/dev/null; then
            ui_info "Wake-on-LAN disabled on $iface"
        fi
        
        # Remove systemd service
        local service_file="/etc/systemd/system/wol-$iface.service"
        if [ -f "$service_file" ]; then
            sudo systemctl disable "wol-$iface.service" 2>/dev/null
            sudo rm -f "$service_file"
            ui_info "Removed WoL service for $iface"
        fi
    done
    
    sudo systemctl daemon-reload
    ui_success "Wake-on-LAN disabled on all interfaces"
}

# Export functions for use in main installer
export -f configure_wakeonlan
export -f disable_wakeonlan
export -f show_wol_status
