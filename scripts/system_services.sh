#!/bin/bash
set -uo pipefail

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

setup_firewall_and_services() {
  step "Setting up firewall and services"

  # First handle firewall setup - prefer firewalld if available, otherwise use UFW
  if [[ "$FIREWALL_PREFERENCE" = "firewalld" ]] || command -v firewalld >/dev/null 2>&1; then
    run_step "Configuring Firewalld" configure_firewalld
  else
    run_step "Configuring UFW" configure_ufw
  fi

  # Configure user groups
  run_step "Configuring user groups" configure_user_groups

  # Then handle services
  run_step "Enabling system services" enable_services
}

configure_firewalld() {
  # Start and enable firewalld
  sudo systemctl start firewalld
  sudo systemctl enable firewalld

  # Set default policies
  sudo firewall-cmd --set-default-zone=drop
  log_success "Default policy set to deny all incoming connections."

  sudo firewall-cmd --set-default-zone=public
  log_success "Default policy set to allow all outgoing connections."

  # Allow SSH
  if ! sudo firewall-cmd --list-all | grep -q "22/tcp"; then
    sudo firewall-cmd --add-service=ssh --permanent
    sudo firewall-cmd --reload
    log_success "SSH allowed through Firewalld."
  else
    log_warning "SSH is already allowed. Skipping SSH service configuration."
  fi

  # Check if KDE Connect is installed
  if pacman -Q kdeconnect &>/dev/null; then
    # Allow specific ports for KDE Connect
    sudo firewall-cmd --add-port=1714-1764/udp --permanent
    sudo firewall-cmd --add-port=1714-1764/tcp --permanent
    sudo firewall-cmd --reload
    log_success "KDE Connect ports allowed through Firewalld."
  else
    log_warning "KDE Connect is not installed. Skipping KDE Connect service configuration."
  fi
}

configure_ufw() {
  # Install UFW if not present
  if ! command -v ufw >/dev/null 2>&1; then
    install_packages_quietly ufw
    log_success "UFW installed successfully."
  fi

  # Enable UFW
  sudo ufw enable
  sudo systemctl enable --now ufw

  # Set default policies
  sudo ufw default deny incoming
  log_success "Default policy set to deny all incoming connections."

  sudo ufw default allow outgoing
  log_success "Default policy set to allow all outgoing connections."

  # Allow SSH
  if ! sudo ufw status | grep -q "22/tcp"; then
    sudo ufw allow ssh
    log_success "SSH allowed through UFW."
  else
    log_warning "SSH is already allowed. Skipping SSH service configuration."
  fi

  # Check if KDE Connect is installed
  if pacman -Q kdeconnect &>/dev/null; then
    # Allow specific ports for KDE Connect
    sudo ufw allow 1714:1764/udp
    sudo ufw allow 1714:1764/tcp
    log_success "KDE Connect ports allowed through UFW."
  else
    log_warning "KDE Connect is not installed. Skipping KDE Connect service configuration."
  fi
}

# Function to provide instructions for virt-manager guest integration
configure_virt_manager_guest_integration() {
  step "Checking for Virt-Manager and providing guest integration instructions"
  if command -v virt-manager >/dev/null 2>&1; then
    ui_info "Virt-Manager detected. For optimal virtual machine experience (copy/paste, file sharing, display resizing), you need to install guest agents inside your VMs."
    echo ""
    gum style --foreground 226 "Recommended packages for Linux guest VMs:"
    gum style --margin "0 2" --foreground 15 "• spice-vdagent: Enables clipboard sharing (copy/paste), automatic display resizing, and cursor integration."
    gum style --margin "0 2" --foreground 15 "• qemu-guest-agent: Allows the host to send commands to the guest (e.g., graceful shutdown) and retrieve information."
    echo ""
    gum style --foreground 226 "Installation steps inside your Linux guest VM (e.g., for Arch Linux guests):"
    gum style --margin "0 2" --foreground 15 "1. Open a terminal in your guest VM."
    gum style --margin "0 2" --foreground 15 "2. Run: ${GREEN}sudo pacman -S spice-vdagent qemu-guest-agent${RESET}"
    gum style --margin "0 2" --foreground 15 "3. Enable the QEMU guest agent service: ${GREEN}sudo systemctl enable --now qemu-guest-agent${RESET}"
    echo ""
    gum style --foreground 226 "Ensure your VM configuration in Virt-Manager includes:"
    gum style --margin "0 2" --foreground 15 "• A 'Channel' device with 'Spice agent (qemu-ga)' type."
    gum style --margin "0 2" --foreground 15 "• A 'Video' device with 'QXL' or 'Virtio' model and a 'Spice server' display."
    echo ""
    log_success "Virt-Manager guest integration instructions provided."
  else
    log_info "Virt-Manager not installed. Skipping guest integration instructions."
  fi
}

configure_user_groups() {
  step "Configuring user groups"

  local groups=("wheel" "video" "storage" "optical" "scanner" "lp" "rfkill")

  for group in "${groups[@]}"; do
    if getent group "$group" >/dev/null; then
      if ! groups "$USER" | grep -q "\b$group\b"; then
        sudo usermod -aG "$group" "$USER"
        log_success "Added $USER to $group group"
      fi
    fi
  done
}

enable_services() {
  # For server mode, we enable only a minimal set of services and then exit this script
  # to prevent any desktop-specific logic (like display manager setup) from running.
  if [[ "$INSTALL_MODE" == "server" ]]; then
    ui_info "Server mode: Enabling only essential services (cronie, sshd, etc.)."
    local services=(
      cronie.service
      fstrim.timer
      paccache.timer
      sshd.service
    )
    step "Enabling the following system services:"
    for svc in "${services[@]}"; do
      echo -e "  - $svc"
    done
    sudo systemctl enable --now "${services[@]}" >/dev/null 2>&1 || true
    log_success "Essential server services enabled."
    exit 0
  fi

  local services=(
    bluetooth.service
    cronie.service
    fstrim.timer
    paccache.timer
    sshd.service
  )

  # Check and configure virt-manager guest integration
  configure_virt_manager_guest_integration

  # Setup power profile management (power-profiles-daemon or tuned-ppd)
  setup_power_profile_daemon

  # Conditionally add rustdesk.service if installed
  if pacman -Q rustdesk-bin &>/dev/null || pacman -Q rustdesk &>/dev/null; then
    services+=(rustdesk.service)
    log_success "rustdesk.service will be enabled."
  else
    log_warning "rustdesk is not installed. Skipping rustdesk.service."
  fi

  # Check if Timeshift is already installed and install timeshift-autosnap if needed
  if pacman -Q timeshift &>/dev/null; then
    log_success "Timeshift detected - installing timeshift-autosnap for automatic snapshots..."
    if command -v yay >/dev/null 2>&1; then
      if yay -S --noconfirm --needed timeshift-autosnap >/dev/null 2>&1; then
        log_success "timeshift-autosnap installed successfully"
        services+=(timeshift-autosnap.timer)
        log_success "timeshift-autosnap.timer will be enabled for automatic snapshots."
      else
        log_error "Failed to install timeshift-autosnap from AUR"
      fi
    else
      log_warning "yay not available - cannot install timeshift-autosnap"
    fi
  else
    log_info "Timeshift not detected - skipping timeshift-autosnap installation"
  fi

  step "Enabling the following system services:"
  for svc in "${services[@]}"; do
    echo -e "  - $svc"
  done
  sudo systemctl enable --now "${services[@]}" 2>/dev/null || true

  # Verify services started correctly
  log_info "Verifying service status..."
  local failed_services=()
  for svc in "${services[@]}"; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      log_success "$svc is active"
    elif systemctl is-enabled --quiet "$svc" 2>/dev/null; then
      log_warning "$svc is enabled but not running (may require reboot)"
    else
      log_warning "$svc failed to start or enable"
      failed_services+=("$svc")
    fi
  done

  if [ ${#failed_services[@]} -eq 0 ]; then
    log_success "All services verified successfully"
  else
    log_warning "Some services may need attention: ${failed_services[*]}"
  fi
}

# Function to get total RAM in GB (rounded to common consumer sizes)
# Accounts for kernel memory reservation (e.g., 32GB shows as ~31GB, 8GB as ~7.5GB, etc.)
# Only returns: 2GB, 4GB, 8GB, 16GB, or 32GB
get_ram_gb() {
  local ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')

  # Convert to MB for better precision
  local ram_mb=$((ram_kb / 1024))

  # Calculate actual GB with decimal precision
  local ram_gb_precise=$(echo "scale=2; $ram_mb / 1024" | bc -l)

  # Round to common consumer RAM sizes: 2GB, 4GB, 8GB, 16GB, 32GB+
  local rounded_gb

  if (( $(echo "$ram_gb_precise < 3" | bc -l) )); then
    rounded_gb=2
  elif (( $(echo "$ram_gb_precise < 6" | bc -l) )); then
    rounded_gb=4
  elif (( $(echo "$ram_gb_precise < 12" | bc -l) )); then
    rounded_gb=8
  elif (( $(echo "$ram_gb_precise < 24" | bc -l) )); then
    rounded_gb=16
  else
    # Anything 24GB+ is treated as 32GB
    rounded_gb=32
  fi

  echo $rounded_gb
}

detect_and_install_gpu_drivers() {
  step "Detecting and installing graphics drivers"

  # VM detection function (from gamemode.sh)
  is_vm() {
    if grep -q -i 'hypervisor' /proc/cpuinfo; then
      return 0
    fi
    if systemd-detect-virt --quiet; then
      return 0
    fi
    if [ -d /proc/xen ]; then
      return 0
    fi
    return 1
  }

  if is_vm; then
    echo -e "${YELLOW}Virtual machine detected. Installing VM guest utilities and skipping physical GPU drivers.${RESET}"
    install_packages_quietly qemu-guest-agent spice-vdagent xf86-video-qxl
    log_success "VM guest utilities installed."
    return
  fi

  if lspci | grep -Eiq 'vga.*amd|3d.*amd|display.*amd'; then
    echo -e "${CYAN}AMD GPU detected. Installing AMD drivers and Vulkan support...${RESET}"
    install_packages_quietly mesa lib32-mesa xf86-video-amdgpu vulkan-radeon lib32-vulkan-radeon
    log_success "AMD drivers and Vulkan support installed"
    log_info "AMD GPU will use AMDGPU driver after reboot"
  elif lspci | grep -Eiq 'vga.*intel|3d.*intel|display.*intel'; then
    echo -e "${CYAN}Intel GPU detected. Installing Intel drivers and Vulkan support...${RESET}"
    install_packages_quietly mesa lib32-mesa vulkan-intel lib32-vulkan-intel
    log_success "Intel drivers and Vulkan support installed"
    log_info "Intel GPU will use i915 or xe driver after reboot"
  elif lspci | grep -qi nvidia; then
    echo -e "${YELLOW}NVIDIA GPU detected.${RESET}"

    # Get PCI ID and map to family
    nvidia_pciid=$(lspci -n -d ::0300 | grep -i nvidia | awk '{print $3}' | head -n1)
    nvidia_family=""
    nvidia_pkg=""
    nvidia_note=""

    # Map PCI ID to family (simplified, for full mapping see ArchWiki and Nouveau code names)
    if lspci | grep -Eiq 'TU|GA|AD|Turing|Ampere|Lovelace'; then
      nvidia_family="Turing or newer"
      nvidia_pkg="nvidia-open-dkms nvidia-utils lib32-nvidia-utils"
      nvidia_note="(open kernel modules, recommended for Turing/Ampere/Lovelace)"
    elif lspci | grep -Eiq 'GM|GP|Maxwell|Pascal'; then
      nvidia_family="Maxwell or newer"
      nvidia_pkg="nvidia nvidia-utils lib32-nvidia-utils"
      nvidia_note="(proprietary, recommended for Maxwell/Pascal)"
    elif lspci | grep -Eiq 'GK|Kepler'; then
      nvidia_family="Kepler"
      nvidia_pkg="nvidia-470xx-dkms"
      nvidia_note="(legacy, AUR, unsupported)"
    elif lspci | grep -Eiq 'GF|Fermi'; then
      nvidia_family="Fermi"
      nvidia_pkg="nvidia-390xx-dkms"
      nvidia_note="(legacy, AUR, unsupported)"
    elif lspci | grep -Eiq 'G8|Tesla'; then
      nvidia_family="Tesla"
      nvidia_pkg="nvidia-340xx-dkms"
      nvidia_note="(legacy, AUR, unsupported)"
    else
      nvidia_family="Unknown"
      nvidia_pkg="nvidia nvidia-utils lib32-nvidia-utils"
      nvidia_note="(defaulting to latest proprietary driver)"
    fi

    echo -e "${CYAN}Detected NVIDIA family: $nvidia_family $nvidia_note${RESET}"
    echo -e "${CYAN}Installing: $nvidia_pkg${RESET}"

    if [[ "$nvidia_family" == "Kepler" || "$nvidia_family" == "Fermi" || "$nvidia_family" == "Tesla" ]]; then
      echo -e "${YELLOW}Your NVIDIA GPU is legacy and may not be well supported by the proprietary driver, especially on Wayland.${RESET}"
      echo "For best Wayland support, it is recommended to use the open-source Nouveau driver."
      echo "Choose driver to install:"
      echo "  1) Nouveau (open source, best for Wayland, basic 3D support)"
      echo "  2) Proprietary legacy NVIDIA driver (AUR, may not work with Wayland, unsupported)"
      local legacy_choice
      while true; do
        read -r -p "Enter your choice [1-2]: " legacy_choice
        case "$legacy_choice" in
          1)
            echo -e "${CYAN}Installing Nouveau drivers...${RESET}"
            install_packages_quietly mesa xf86-video-nouveau vulkan-nouveau lib32-vulkan-nouveau
            log_success "Nouveau drivers installed."
            break
            ;;
          2)
            echo -e "${CYAN}Installing legacy proprietary NVIDIA drivers...${RESET}"
            if [[ "$nvidia_family" == "Kepler" ]]; then
              yay -S --noconfirm --needed nvidia-470xx-dkms
            elif [[ "$nvidia_family" == "Fermi" ]]; then
              yay -S --noconfirm --needed nvidia-390xx-dkms
            elif [[ "$nvidia_family" == "Tesla" ]]; then
              yay -S --noconfirm --needed nvidia-340xx-dkms
            fi
            log_success "Legacy proprietary NVIDIA drivers installed."
            break
            ;;
          *)
            echo -e "${RED}Invalid choice! Please enter 1 or 2.${RESET}"
            ;;
        esac
      done
      return
    fi

    # If AUR package, warn user
    if [[ "$nvidia_pkg" == *"dkms"* && "$nvidia_pkg" != *"nvidia-open-dkms"* ]]; then
      log_warning "This is a legacy/unsupported NVIDIA card. The driver will be installed from the AUR if yay is available."
      if ! command -v yay &>/dev/null; then
        log_error "yay (AUR helper) is not installed. Cannot install legacy NVIDIA driver."
        return 1
      fi
      yay -S --noconfirm --needed $nvidia_pkg
    else
      install_packages_quietly $nvidia_pkg
    fi

    log_success "NVIDIA drivers installed."
    return
  else
    echo -e "${YELLOW}No AMD, Intel, or NVIDIA GPU detected. Installing basic Mesa drivers only.${RESET}"
    install_packages_quietly mesa
  fi

  # Verify GPU driver is loaded
  verify_gpu_driver
}

# Function to verify GPU driver is loaded correctly
verify_gpu_driver() {
  step "Verifying GPU driver installation"

  # Check which driver is in use
  if lspci -k | grep -A 3 -iE 'vga|3d|display' | grep -iq 'Kernel driver in use'; then
    log_info "GPU driver status:"
    lspci -k | grep -A 3 -iE 'vga|3d|display' | grep -E 'VGA|3D|Display|Kernel driver'
    log_success "GPU driver is loaded and in use"
  else
    log_warning "Could not verify GPU driver status"
    log_info "Run 'lspci -k | grep -A 3 -iE \"vga|3d|display\"' after reboot to check driver"
  fi

  # Check for Vulkan support
  if command -v vulkaninfo >/dev/null 2>&1; then
    if vulkaninfo --summary &>/dev/null; then
      log_success "Vulkan support verified"
    else
      log_warning "Vulkan may not be properly configured"
    fi
  else
    log_info "Install vulkan-tools to verify Vulkan support: sudo pacman -S vulkan-tools"
  fi
}

# Function to detect if system is a laptop
is_laptop() {
  # Check multiple indicators for laptop detection
  if [ -d /sys/class/power_supply/BAT0 ] || [ -d /sys/class/power_supply/BAT1 ]; then
    return 0
  fi
  if command -v dmidecode >/dev/null 2>&1; then
    if sudo dmidecode -s chassis-type | grep -qiE 'Notebook|Laptop|Portable'; then
      return 0
    fi
  fi
  if [ -f /sys/class/dmi/id/chassis_type ]; then
    local chassis_type=$(cat /sys/class/dmi/id/chassis_type)
    # 8=Portable, 9=Laptop, 10=Notebook, 14=Sub Notebook
    if [[ "$chassis_type" =~ ^(8|9|10|14)$ ]]; then
      return 0
    fi
  fi
  return 1
}

# Function to detect CPU generation and recommend power profile daemon
detect_power_profile_daemon() {
  local cpu_vendor=$(detect_cpu_vendor)
  local recommended_daemon="tuned-ppd"  # Default to safer choice
  local cpu_model=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | xargs)

  # Simple logic: Check kernel version and CPU family for modern support
  # power-profiles-daemon requires kernel 5.17+ and modern CPU (Zen 3+ or Skylake+)
  local kernel_major=$(uname -r | cut -d. -f1)
  local kernel_minor=$(uname -r | cut -d. -f2)

  if [ "$cpu_vendor" = "intel" ]; then
    # Budget Intel CPUs - always use tuned-ppd
    if echo "$cpu_model" | grep -qiE "Atom|Celeron|Pentium"; then
      recommended_daemon="tuned-ppd"
      log_info "Intel budget CPU detected - tuned-ppd recommended"
    # Modern kernel + Core i-series = likely 6th gen+ = power-profiles-daemon OK
    elif [ "$kernel_major" -ge 6 ] && echo "$cpu_model" | grep -qiE "Core.*i[3579]"; then
      recommended_daemon="power-profiles-daemon"
      log_info "Modern Intel CPU with recent kernel - power-profiles-daemon supported"
    else
      recommended_daemon="tuned-ppd"
      log_info "Older Intel CPU or kernel - tuned-ppd recommended"
    fi
  elif [ "$cpu_vendor" = "amd" ]; then
    # Check for modern AMD Ryzen CPUs (5000+ series) including Pro and mobile variants
    # Modern kernel required for proper AMD P-State support
    if [ "$kernel_major" -ge 6 ] && echo "$cpu_model" | grep -qiE "Ryzen.*(5[0-9]{3}|[6-9][0-9]{3})|Ryzen.*Pro.*[5-9][0-9]{3}"; then
      recommended_daemon="power-profiles-daemon"
      log_info "Modern AMD Ryzen (5000+ series including Pro/mobile) - power-profiles-daemon supported"
    else
      recommended_daemon="tuned-ppd"
      log_info "AMD CPU (Ryzen 1st-4th gen or older) - tuned-ppd recommended"
    fi
  else
    # Unknown CPU - default to tuned-ppd (safer choice)
    recommended_daemon="tuned-ppd"
    log_info "Unknown CPU vendor - tuned-ppd recommended (safer)"
  fi

  echo "$recommended_daemon"
}

# Function to install and configure power profile daemon
setup_power_profile_daemon() {
  step "Setting up power profile management"

  local daemon=$(detect_power_profile_daemon)

  if [ "$daemon" = "power-profiles-daemon" ]; then
    log_info "Installing power-profiles-daemon..."
    install_packages_quietly power-profiles-daemon

    sudo systemctl enable --now power-profiles-daemon.service 2>/dev/null

    if systemctl is-active --quiet power-profiles-daemon.service; then
      log_success "power-profiles-daemon is active"
      log_info "Use 'powerprofilesctl' to manage power profiles"
    else
      log_warning "power-profiles-daemon may require a reboot"
    fi
  else
    log_info "Installing tuned-ppd (power-profiles-daemon alternative)..."

    # Check if tuned-ppd is available in AUR
    if command -v yay >/dev/null 2>&1; then
      install_aur_quietly tuned-ppd

      sudo systemctl enable --now tuned.service 2>/dev/null

      if systemctl is-active --quiet tuned.service; then
        log_success "tuned-ppd is active"
        log_info "Use 'tuned-adm' to manage power profiles"
        log_info "Available profiles: balanced, powersave, performance"
      else
        log_warning "tuned-ppd may require a reboot"
      fi
    else
      log_warning "yay not available - cannot install tuned-ppd from AUR"
      log_info "Using kernel's built-in power management"
    fi
  fi
}

# Function to detect CPU vendor
detect_cpu_vendor() {
  if grep -qi "GenuineIntel" /proc/cpuinfo; then
    echo "intel"
  elif grep -qi "AuthenticAMD" /proc/cpuinfo; then
    echo "amd"
  else
    echo "unknown"
  fi
}

# Function to check if ACPI should be skipped due to compatibility issues
should_skip_acpi() {
  local cpu_vendor=$(detect_cpu_vendor)
  local manufacturer=$(detect_laptop_manufacturer)
  local cpu_model=""
  
  # Get CPU model for specific checks
  cpu_model=$(grep "model name" /proc/cpuinfo | head -1 | cut -d':' -f2 | xargs)
  
  # Skip ACPI for known problematic combinations
  case "$manufacturer" in
    hp)
      # HP laptops with AMD APUs (especially older Ryzen models)
      if [ "$cpu_vendor" = "amd" ]; then
        case "$cpu_model" in
          *"Ryzen 5 2500U"*|*"Ryzen 3 2200U"*|*"Ryzen 7 2700U"*|*"AMD A"*|*"AMD E"*)
            log_info "HP laptop with problematic AMD APU detected - skipping ACPI/acpid"
            echo "true"
            return 0
            ;;
        esac
      fi
      ;;
    lenovo)
      # Some older Lenovo ThinkPads with ACPI issues
      if [ "$cpu_vendor" = "amd" ] && echo "$cpu_model" | grep -q "AMD A[0-9]"; then
        log_info "Lenovo laptop with older AMD APU detected - skipping ACPI/acpid"
        echo "true"
        return 0
      fi
      ;;
    acer)
      # Acer laptops with specific AMD APUs
      if [ "$cpu_vendor" = "amd" ] && echo "$cpu_model" | grep -q "E[0-9]"; then
        log_info "Acer laptop with AMD E-series APU detected - skipping ACPI/acpid"
        echo "true"
        return 0
      fi
      ;;
  esac
  
  # Skip ACPI for very old CPUs (pre-2015)
  if [ "$cpu_vendor" = "amd" ]; then
    local cpu_family=$(grep "cpu family" /proc/cpuinfo | head -1 | cut -d':' -f2 | xargs)
    if [ "$cpu_family" -lt "21" ]; then  # Family 21+ is Zen architecture
      log_info "Old AMD CPU detected (family $cpu_family) - skipping ACPI/acpid"
      echo "true"
      return 0
    fi
  fi
  
  echo "false"
}

# Function to detect laptop manufacturer
detect_laptop_manufacturer() {
  local manufacturer="unknown"
  
  # Try DMI product name first
  if [ -f /sys/class/dmi/id/product_name ]; then
    local product_name=$(cat /sys/class/dmi/id/product_name 2>/dev/null | tr '[:upper:]' '[:lower:]')
    
    case "$product_name" in
      *lenovo*|*thinkpad*|*ideapad*|*legion*|*yoga*|*thinkbook*) manufacturer="lenovo" ;;
      *hp*|*hewlett*|*compaq*|*omen*|*pavilion*|*elitebook*|*spectre*|*envy*) manufacturer="hp" ;;
      *dell*|*latitude*|*precision*|*inspiron*|*xps*|*alienware*|*vostro*) manufacturer="dell" ;;
      *acer*|*aspire*|*predator*|*nitro*|*swift*|*spin*|*travelmate*) manufacturer="acer" ;;
      *asus*|*rog*|*zenbook*|*vivobook*|*tuf*|*proart*|*expertbook*) manufacturer="asus" ;;
      *msi*|*micro-star*|*ge*|*gt*|*gl*|*gf*|*creator*) manufacturer="msi" ;;
      *surface*|*microsoft*) manufacturer="microsoft" ;;
      *razer*|*blade*|*razer*) manufacturer="razer" ;;
      *lg*|*gram*) manufacturer="lg" ;;
      *samsung*|*galaxy*|*book*) manufacturer="samsung" ;;
      *huawei*|*matebook*) manufacturer="huawei" ;;
      *xiaomi*|*mi*|*redmibook*) manufacturer="xiaomi" ;;
      *framework*|*framework*) manufacturer="framework" ;;
      *system76*|*oryp*|*galago*|*lemur*) manufacturer="system76" ;;
    esac
  fi
  
  # Fallback to DMI sys_vendor if product_name didn't work
  if [ "$manufacturer" = "unknown" ] && [ -f /sys/class/dmi/id/sys_vendor ]; then
    local sys_vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null | tr '[:upper:]' '[:lower:]')
    
    case "$sys_vendor" in
      *lenovo*) manufacturer="lenovo" ;;
      *hp*|*hewlett*) manufacturer="hp" ;;
      *dell*) manufacturer="dell" ;;
      *acer*) manufacturer="acer" ;;
      *asus*|*asustek*) manufacturer="asus" ;;
      *msi*|*micro-star*) manufacturer="msi" ;;
      *microsoft*) manufacturer="microsoft" ;;
      *razer*) manufacturer="razer" ;;
      *lg*) manufacturer="lg" ;;
      *samsung*) manufacturer="samsung" ;;
      *huawei*) manufacturer="huawei" ;;
      *xiaomi*) manufacturer="xiaomi" ;;
      *framework*) manufacturer="framework" ;;
      *system76*) manufacturer="system76" ;;
    esac
  fi
  
  echo "$manufacturer"
}

# Function to detect if this is a gaming laptop
detect_gaming_laptop() {
  local manufacturer="$1"
  local is_gaming=false
  
  if [ -f /sys/class/dmi/id/product_name ]; then
    local product_name=$(cat /sys/class/dmi/id/product_name 2>/dev/null | tr '[:upper:]' '[:lower:]')
    
    case "$product_name" in
      *legion*|*omen*|*predator*|*nitro*|*rog*|*tuf*|*alienware*|*ge*|*gt*|*gl*|*razer*|*blade*) is_gaming=true ;;
    esac
  fi
  
  echo "$is_gaming"
}

# Function to get laptop model information
get_laptop_model() {
  local model="unknown"
  
  if [ -f /sys/class/dmi/id/product_name ]; then
    model=$(cat /sys/class/dmi/id/product_name 2>/dev/null)
  elif [ -f /sys/class/dmi/id/product_version ]; then
    model=$(cat /sys/class/dmi/id/product_version 2>/dev/null)
  fi
  
  echo "$model"
}

# Function to detect if we should apply automatic optimizations
should_auto_optimize() {
  # Auto-optimize if:
  # 1. AUTO_LAPTOP_OPTS environment variable is set to "true"
  # 2. We're running in non-interactive mode (no gum available)
  # 3. User has previously enabled optimizations
  
  if [ "${AUTO_LAPTOP_OPTS:-false}" = "true" ]; then
    echo "true"
    return
  fi
  
  if ! command -v gum >/dev/null 2>&1; then
    # In non-interactive mode, ask once and remember the choice
    local config_file="$HOME/.config/archinstaller-laptop-opts"
    if [ -f "$config_file" ]; then
      echo "$(cat "$config_file" 2>/dev/null)"
    else
      echo "false"  # Default to false in pure non-interactive mode
    fi
  else
    echo "false"  # Interactive mode - let user choose
  fi
}

# Function to get manufacturer-specific optimizations
get_manufacturer_optimizations() {
  local manufacturer="$1"
  local is_gaming=$(detect_gaming_laptop "$manufacturer")
  local optimizations=()
  
  case "$manufacturer" in
    lenovo)
      if [ "$is_gaming" = "true" ]; then
        optimizations+=("Lenovo Legion gaming optimizations")
        optimizations+=("Lenovo Vantage alternative (lenovo-legion-tool)")
      else
        optimizations+=("ThinkPad function keys support")
        optimizations+=("Lenovo power management tweaks")
      fi
      optimizations+=("Lenovo ACPI support")
      ;;
    hp)
      if [ "$is_gaming" = "true" ]; then
        optimizations+=("HP Omen gaming optimizations")
      else
        optimizations+=("HP Pavilion/EliteBook optimizations")
      fi
      optimizations+=("HP function keys and hotkeys")
      optimizations+=("HP power management")
      ;;
    dell)
      if [ "$is_gaming" = "true" ]; then
        optimizations+=("Dell Alienware gaming features")
      else
        optimizations+=("Dell XPS performance tweaks")
      fi
      optimizations+=("Dell function keys support")
      optimizations+=("Dell power management")
      ;;
    acer)
      if [ "$is_gaming" = "true" ]; then
        optimizations+=("Acer Predator/Nitro gaming optimizations")
      else
        optimizations+=("Acer Swift/Spin optimizations")
      fi
      optimizations+=("Acer function keys")
      optimizations+=("Acer power management")
      ;;
    asus)
      if [ "$is_gaming" = "true" ]; then
        optimizations+=("ASUS ROG/TUF gaming features")
      else
        optimizations+=("ASUS ZenBook/VivoBook optimizations")
      fi
      optimizations+=("ASUS function keys support")
      optimizations+=("ASUS power management")
      ;;
    msi)
      if [ "$is_gaming" = "true" ]; then
        optimizations+=("MSI GE/GT/GL gaming optimizations")
      else
        optimizations+=("MSI Creator series optimizations")
      fi
      optimizations+=("MSI function keys")
      optimizations+=("MSI Dragon Center alternative")
      ;;
    razer)
      optimizations+=("Razer Blade gaming optimizations")
      optimizations+=("Razer Synapse alternative")
      optimizations+=("Razer function keys")
      ;;
    lg)
      optimizations+=("LG Gram ultra-light optimizations")
      optimizations+=("LG function keys")
      optimizations+=("LG power management")
      ;;
    samsung)
      optimizations+=("Samsung Galaxy Book optimizations")
      optimizations+=("Samsung function keys")
      optimizations+=("Samsung power management")
      ;;
    huawei)
      optimizations+=("Huawei MateBook optimizations")
      optimizations+=("Huawei function keys")
      optimizations+=("Huawei power management")
      ;;
    xiaomi)
      optimizations+=("Xiaomi Mi/RedmiBook optimizations")
      optimizations+=("Xiaomi function keys")
      optimizations+=("Xiaomi power management")
      ;;
    framework)
      optimizations+=("Framework laptop modular optimizations")
      optimizations+=("Framework function keys")
      optimizations+=("Framework power management")
      ;;
    system76)
      optimizations+=("System76 firmware optimizations")
      optimizations+=("System76 function keys")
      optimizations+=("System76 power management")
      ;;
    microsoft)
      optimizations+=("Microsoft Surface optimizations")
      optimizations+=("Surface pen and touch support")
      optimizations+=("Surface power management")
      ;;
    *)
      optimizations+=("Generic laptop optimizations")
      optimizations+=("Standard ACPI support")
      optimizations+=("Universal power management")
      ;;
  esac
  
  printf '%s\n' "${optimizations[@]}"
}

# Function to detect RAM size and make adaptive decisions
detect_memory_size() {
  step "Detecting system memory and applying optimizations"

  # Get total RAM in GB
  local ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  local ram_gb=$((ram_kb / 1024 / 1024))

  log_info "Total system memory: ${ram_gb}GB"

  # Apply memory-based optimizations
  if [ $ram_gb -lt 4 ]; then
    log_warning "Low memory system detected (< 4GB)"
    log_info "Applying low-memory optimizations..."

    # Create or overwrite sysctl configuration based on RAM
    {
      echo "# Memory optimization settings generated by archinstaller"
      echo "# System RAM: ${ram_gb}GB detected on $(date)"
      echo ""
      echo "# Aggressive swappiness for low RAM"
      echo "vm.swappiness=60"
      echo ""
      echo "# Reduce cache pressure"
      echo "vm.vfs_cache_pressure=50"
    } | sudo tee /etc/sysctl.d/99-swappiness.conf >/dev/null
    log_success "Set swappiness to 60 (aggressive swap usage) and reduced cache pressure"

  elif [ $ram_gb -ge 4 ] && [ $ram_gb -lt 8 ]; then
    log_info "Standard memory system detected (4-8GB)"

    # Moderate swappiness
    {
      echo "# Memory optimization settings generated by archinstaller"
      echo "# System RAM: ${ram_gb}GB detected on $(date)"
      echo ""
      echo "# Moderate swappiness for standard systems"
      echo "vm.swappiness=30"
    } | sudo tee /etc/sysctl.d/99-swappiness.conf >/dev/null
    log_success "Set swappiness to 30 (moderate swap usage)"

  elif [ $ram_gb -ge 8 ] && [ $ram_gb -lt 16 ]; then
    log_info "High memory system detected (8-16GB)"

    # Low swappiness
    {
      echo "# Memory optimization settings generated by archinstaller"
      echo "# System RAM: ${ram_gb}GB detected on $(date)"
      echo ""
      echo "# Low swappiness for high memory systems"
      echo "vm.swappiness=10"
    } | sudo tee /etc/sysctl.d/99-swappiness.conf >/dev/null
    log_success "Set swappiness to 10 (low swap usage)"

  else
    log_success "Very high memory system detected (16GB+)"

    # Minimal swappiness
    {
      echo "# Memory optimization settings generated by archinstaller"
      echo "# System RAM: ${ram_gb}GB detected on $(date)"
      echo ""
      echo "# Minimal swappiness for very high memory systems"
      echo "vm.swappiness=1"
    } | sudo tee /etc/sysctl.d/99-swappiness.conf >/dev/null
    log_success "Set swappiness to 1 (minimal swap usage)"

    # Disable swap on very high memory systems
    if [ $ram_gb -ge 32 ]; then
      log_info "32GB+ RAM detected - swap can be fully disabled if desired"
    fi
  fi

  # Apply sysctl settings immediately
  sudo sysctl -p /etc/sysctl.d/99-swappiness.conf >/dev/null 2>&1

  log_success "Memory-based optimizations applied"
}

# Function to detect filesystem type and apply optimizations
detect_filesystem_type() {
  step "Detecting filesystem type and applying optimizations"

  local root_fs=$(findmnt -no FSTYPE /)
  log_info "Root filesystem: $root_fs"

  case "$root_fs" in
    ext4)
      log_info "ext4 detected - applying ext4 optimizations"
      # Set reserved blocks to 1% (default is 5%)
      local root_device=$(findmnt -no SOURCE /)
      if [ -n "$root_device" ]; then
        sudo tune2fs -m 1 "$root_device" 2>/dev/null && log_success "Reduced ext4 reserved blocks to 1%"
      fi
      ;;
    xfs)
      log_info "XFS detected - XFS is already well-optimized"
      log_success "XFS filesystem detected (no additional optimization needed)"
      ;;
    f2fs)
      log_info "F2FS detected - optimized for flash storage"
      log_success "F2FS filesystem detected (flash-optimized)"
      ;;
    btrfs)
      log_success "Btrfs detected - advanced filesystem features available"
      ;;
    *)
      log_info "Filesystem: $root_fs (using default optimizations)"
      ;;
  esac

  # Check for LUKS encryption
  if lsblk -o NAME,FSTYPE | grep -q crypto_LUKS; then
    log_info "LUKS encryption detected"
    # Check if SSD
    local encrypted_device=$(lsblk -o NAME,FSTYPE,TYPE | grep crypto_LUKS | head -1 | awk '{print $1}')
    if [ -n "$encrypted_device" ]; then
      log_success "Encrypted storage detected - TRIM support should be enabled in crypttab"
    fi
  fi
}

# Function to detect storage type and optimize I/O scheduler
detect_storage_type() {
  step "Detecting storage type and optimizing I/O scheduler"

  # Get all block devices (exclude loop, ram, etc.)
  local devices=$(lsblk -d -n -o NAME,TYPE | grep disk | awk '{print $1}')

  for device in $devices; do
    local rota=$(cat /sys/block/$device/queue/rotational 2>/dev/null || echo "1")
    local device_type=""
    local scheduler=""

    # Determine device type
    if [[ "$device" == nvme* ]]; then
      device_type="NVMe SSD"
      scheduler="none"
    elif [ "$rota" = "0" ]; then
      device_type="SATA SSD"
      scheduler="mq-deadline"
    else
      device_type="HDD"
      scheduler="bfq"
    fi

    log_info "Device /dev/$device: $device_type"

    # Set I/O scheduler
    if [ -f /sys/block/$device/queue/scheduler ]; then
      # Check if scheduler is available
      if grep -q "$scheduler" /sys/block/$device/queue/scheduler 2>/dev/null; then
        echo "$scheduler" | sudo tee /sys/block/$device/queue/scheduler >/dev/null
        log_success "Set I/O scheduler to '$scheduler' for /dev/$device"
      else
        log_warning "Scheduler '$scheduler' not available for /dev/$device"
      fi
    fi
  done

  # Make scheduler changes persistent via udev rule
  sudo tee /etc/udev/rules.d/60-ioschedulers.rules >/dev/null << 'EOF'
# Set I/O scheduler based on storage type
# NVMe devices - use none (multi-queue)
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/scheduler}="none"
# SSD devices - use mq-deadline
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"
# HDD devices - use bfq
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
EOF

  log_success "I/O scheduler optimizations applied and made persistent"
}

# Function to detect audio system
detect_audio_system() {
  step "Detecting audio system"

  if systemctl --user is-active --quiet pipewire 2>/dev/null || systemctl is-active --quiet pipewire 2>/dev/null; then
    log_success "PipeWire audio system detected"
    # Install PipeWire specific packages if not already installed
    install_packages_quietly pipewire-alsa pipewire-jack pipewire-pulse
    log_success "PipeWire compatibility packages installed"
  elif systemctl --user is-active --quiet pulseaudio 2>/dev/null || pgrep -x pulseaudio >/dev/null 2>&1; then
    log_success "PulseAudio audio system detected"
    # Ensure PulseAudio bluetooth support
    if pacman -Q bluez &>/dev/null; then
      install_packages_quietly pulseaudio-bluetooth
      log_success "PulseAudio Bluetooth support installed"
    fi
  else
    log_info "No audio system detected or not running yet"
    log_info "PipeWire is recommended for modern systems"
  fi
}

# Function to detect hybrid graphics
detect_hybrid_graphics() {
  step "Detecting hybrid graphics configuration"

  local gpu_count=$(lspci | grep -i vga | wc -l)

  if [ "$gpu_count" -gt 1 ]; then
    log_warning "Multiple GPUs detected - hybrid graphics system"
    lspci | grep -i vga

    # Check for NVIDIA + Intel/AMD combo
    if lspci | grep -qi nvidia && lspci | grep -qiE "intel|amd"; then
      log_warning "NVIDIA Optimus / Hybrid graphics detected"
      log_info "Consider installing optimus-manager or nvidia-prime for GPU switching"
      log_info "   AUR: yay -S optimus-manager optimus-manager-qt"
      log_info "Manual setup required after installation"
    fi
  else
    log_info "Single GPU system detected"
  fi
}

# Function to detect kernel type
detect_kernel_type() {
  step "Detecting installed kernel type"

  local kernel=$(uname -r)
  local kernel_type="linux"

  if [[ "$kernel" == *"-lts"* ]]; then
    kernel_type="linux-lts"
    log_success "Running linux-lts kernel (Long Term Support)"
    log_info "LTS kernel focuses on stability"
  elif [[ "$kernel" == *"-zen"* ]]; then
    kernel_type="Arch Linux (linux-zen)"
    log_success "Running linux-zen kernel (Performance)"
    log_info "Zen kernel optimized for desktop/gaming performance"
  elif [[ "$kernel" == *"-hardened"* ]]; then
    kernel_type="linux-hardened"
    log_success "Running linux-hardened kernel (Security)"
    log_info "Hardened kernel focuses on security"
  else
    log_success "Running standard linux kernel"
    log_info "Standard kernel provides balanced performance"
  fi

  # Apply kernel-specific optimizations
  case "$kernel_type" in
    "Arch Linux (linux-zen)")
      # Gaming/desktop optimizations already in place
      log_info "Arch Linux (linux-zen) already optimized for low latency"
      ;;
    linux-lts)
      # Stability focused
      log_info "LTS kernel - maximum stability"
      ;;
    linux-hardened)
      # Security-focused - minimal changes
      log_info "Hardened kernel - security optimizations active"
      ;;
    esac
}

# Function to detect VM hypervisor
detect_vm_hypervisor() {
  step "Detecting virtual machine environment"

  if command -v systemd-detect-virt >/dev/null 2>&1; then
    local virt_type=$(systemd-detect-virt)

    if [ "$virt_type" != "none" ]; then
      log_success "Virtual machine detected: $virt_type"

      case "$virt_type" in
        kvm|qemu)
          log_info "KVM/QEMU detected - qemu-guest-agent already installed"
          ;;
        vmware)
          log_info "VMware detected - consider installing open-vm-tools"
          if ! pacman -Q open-vm-tools &>/dev/null; then
            install_packages_quietly open-vm-tools
            sudo systemctl enable --now vmtoolsd.service
            log_success "VMware tools installed and enabled"
          fi
          ;;
        oracle)
          log_info "VirtualBox detected - consider installing virtualbox-guest-utils"
          if ! pacman -Q virtualbox-guest-utils &>/dev/null; then
            install_packages_quietly virtualbox-guest-utils
            sudo systemctl enable --now vboxservice.service
            log_success "VirtualBox guest utilities installed"
          fi
          ;;
        microsoft)
          log_info "Hyper-V detected"
          if ! pacman -Q hyperv &>/dev/null; then
            install_packages_quietly hyperv
            log_success "Hyper-V utilities installed"
          fi
          ;;
        *)
          log_info "Running in virtual machine: $virt_type"
          ;;
      esac
    else
      log_info "Running on bare metal (physical hardware)"
    fi
  else
    log_warning "systemd-detect-virt not available"
  fi
}

# Function to detect desktop environment version
detect_de_version() {
  step "Detecting desktop environment version"

  case "${XDG_CURRENT_DESKTOP:-}" in
    *GNOME*)
      if command -v gnome-shell >/dev/null 2>&1; then
        local gnome_version=$(gnome-shell --version | grep -oP '\d+' | head -1)
        log_success "GNOME version: $gnome_version"
        if [ "$gnome_version" -ge 45 ]; then
          log_info "Modern GNOME version detected (45+)"
        fi
      fi
      ;;
    *KDE*|*Plasma*)
      if command -v plasmashell >/dev/null 2>&1; then
        local plasma_version=$(plasmashell --version 2>/dev/null | grep -oP '\d+' | head -1)
        log_success "KDE Plasma version: $plasma_version"
        if [ "$plasma_version" -ge 6 ]; then
          log_info "KDE Plasma 6 detected (Qt6-based)"
        else
          log_error "KDE Plasma 5 detected - not supported. Please upgrade to Plasma 6"
          log_info "Arch Linux recommends using the latest Plasma 6 for bleeding edge support"
        fi
      fi
      ;;
    *COSMIC*)
      log_success "Cosmic Desktop detected (alpha/beta)"
      ;;
    *)
      log_info "Desktop environment: ${XDG_CURRENT_DESKTOP:-Unknown}"
      ;;
  esac
}

# Function to check battery status
check_battery_status() {
  step "Checking battery status"

  if [ -d /sys/class/power_supply/BAT0 ] || [ -d /sys/class/power_supply/BAT1 ]; then
    local battery_path="/sys/class/power_supply/BAT0"
    [ ! -d "$battery_path" ] && battery_path="/sys/class/power_supply/BAT1"

    if [ -d "$battery_path" ]; then
      local status=$(cat "$battery_path/status" 2>/dev/null || echo "Unknown")
      local capacity=$(cat "$battery_path/capacity" 2>/dev/null || echo "Unknown")

      log_info "Battery Status: $status"
      log_info "Battery Capacity: ${capacity}%"

      if [ "$status" = "Discharging" ] && [ "$capacity" -lt 30 ]; then
        log_warning "Battery level is low (${capacity}%)"
        log_warning "Consider plugging in AC adapter for installation"
        log_info "Installation may take 20-30 minutes"

        if command -v gum >/dev/null 2>&1; then
          if ! gum confirm --default=false "Continue on battery power?"; then
            log_error "Installation cancelled - please connect AC adapter"
            exit 1
          fi
        else
          read -r -p "Continue on battery power? [y/N]: " response
          response=${response,,}
          if [[ "$response" != "y" && "$response" != "yes" ]]; then
            log_error "Installation cancelled - please connect AC adapter"
            exit 1
          fi
        fi
      elif [ "$status" = "Charging" ] || [ "$status" = "Full" ]; then
        log_success "Battery is charging or full - safe to proceed"
      fi
    fi
  else
    log_info "No battery detected (desktop system or AC only)"
  fi
}

# Function to detect bluetooth hardware using hardware detection methods only
detect_bluetooth_hardware() {
  step "Detecting Bluetooth hardware"

  local bluetooth_detected=false
  local detection_methods=()
  
  # Method 1: Check sysfs (kernel-level detection)
  if [ -d /sys/class/bluetooth ] && [ "$(ls /sys/class/bluetooth 2>/dev/null | wc -l)" -gt 0 ]; then
    bluetooth_detected=true
    detection_methods+=("kernel sysfs")
  fi
  
  # Method 2: USB devices (external dongles, built-in USB controllers)
  if command -v lsusb >/dev/null 2>&1; then
    if lsusb 2>/dev/null | grep -iE "(bluetooth|broadcom|intel|realtek).*bluetooth" >/dev/null 2>&1; then
      bluetooth_detected=true
      detection_methods+=("USB device")
    fi
  fi
  
  # Method 3: PCI devices (internal cards, PCIe adapters)
  if command -v lspci >/dev/null 2>&1; then
    if lspci 2>/dev/null | grep -iE "(bluetooth|broadcom|intel|realtek).*bluetooth" >/dev/null 2>&1; then
      bluetooth_detected=true
      detection_methods+=("PCI device")
    fi
  fi
  
  # Method 4: Check for bluetooth kernel modules
  if lsmod 2>/dev/null | grep -iE "(btusb|bluetooth)" >/dev/null 2>&1; then
    bluetooth_detected=true
    detection_methods+=("kernel module")
  fi
  
  # Method 5: Check for bluetooth adapters in /dev
  if [ -e /dev/rfkill ] || find /dev -name "*bluetooth*" 2>/dev/null | head -1 | grep -q .; then
    bluetooth_detected=true
    detection_methods+=("device node")
  fi

  if [ "$bluetooth_detected" = true ]; then
    local detection_info=$(IFS=', '; echo "${detection_methods[*]}")
    log_success "Bluetooth hardware detected (${detection_info})"
    
    # Check if bluetooth service is enabled
    if ! systemctl is-enabled bluetooth.service &>/dev/null; then
      log_info "Bluetooth hardware present - service will be enabled"
    else
      log_info "Bluetooth service already enabled"
    fi
  else
    # Professional red UI message for no Bluetooth
    if supports_gum; then
      echo ""
      gum style --foreground 196 --border thick --padding "1 2" \
        "  No Bluetooth hardware detected in your system" \
        "  Check if Bluetooth adapter is properly connected" \
        "  Bluetooth packages installed but service will not be started"
      echo ""
    else
      echo ""
      echo -e "${RED}  No Bluetooth hardware detected in your system${RESET}"
      echo -e "${RED}  Check if Bluetooth adapter is properly connected${RESET}"
      echo -e "${RED}  Bluetooth packages installed but service will not be started${RESET}"
      echo ""
    fi
    log_warning "No Bluetooth hardware detected - service will not be started"
  fi
}

# Function to setup Intel-specific laptop optimizations
setup_intel_laptop_optimizations() {
  step "Configuring Intel-specific laptop optimizations"

  # Install thermald for Intel thermal management
  log_info "Installing thermald for Intel thermal management..."
  install_packages_quietly thermald

  # Enable and start thermald
  sudo systemctl enable thermald.service 2>/dev/null
  sudo systemctl start thermald.service 2>/dev/null

  if systemctl is-active --quiet thermald.service; then
    log_success "thermald is active for thermal management"
  else
    log_warning "thermald may require a reboot"
  fi

  # Check if Intel P-State driver is available
  if [ -d /sys/devices/system/cpu/intel_pstate ]; then
    log_success "Intel P-State driver detected - kernel will manage CPU power"
  else
    log_info "Using ACPI CPUfreq driver for CPU power management"
  fi

  log_success "Intel-specific optimizations completed"
}

# Function to setup Lenovo-specific optimizations
setup_lenovo_optimizations() {
  step "Configuring Lenovo-specific optimizations"

  # Install Lenovo-specific tools
  if command -v yay >/dev/null 2>&1; then
    log_info "Installing lenovo-legion-tool for Lenovo laptops..."
    install_aur_quietly lenovo-legion-tool
    
    # Install ThinkPad firmware tools if detected
    if grep -qi "thinkpad" /sys/class/dmi/id/product_name 2>/dev/null; then
      log_info "Installing ThinkPad-specific tools..."
      install_packages_quietly acpi_call
      install_aur_quietly thinkfan
      install_aur_quietly tlp
    fi
  else
    # Check if ACPI should be skipped due to compatibility issues
    if [ "$(should_skip_acpi)" = "true" ]; then
      log_info "Skipping ACPI tools due to compatibility issues"
    else
      log_info "Installing basic ACPI tools for Lenovo..."
      install_packages_quietly acpi acpid
    fi
  fi

  # Configure Lenovo function keys
  log_info "Configuring Lenovo function keys..."
  if [ -f /sys/devices/platform/thinkpad_acpi/hotkey_all_mask ]; then
    sudo modprobe thinkpad_acpi 2>/dev/null
    log_success "ThinkPad ACPI driver loaded"
  fi

  # Enable services
  sudo systemctl enable acpid.service 2>/dev/null
  sudo systemctl start acpid.service 2>/dev/null

  log_success "Lenovo optimizations completed"
}

# Function to setup HP-specific optimizations
setup_hp_optimizations() {
  step "Configuring HP-specific optimizations"

  # Install HP-specific packages
  log_info "Installing HP-specific tools..."
  # Check if ACPI should be skipped due to compatibility issues
  if [ "$(should_skip_acpi)" = "true" ]; then
    log_info "Skipping ACPI tools due to compatibility issues"
  else
    install_packages_quietly acpi acpid
  fi
  
  if command -v yay >/dev/null 2>&1; then
    # Install HP Omen gaming tools if detected
    if grep -qi "omen" /sys/class/dmi/id/product_name 2>/dev/null; then
      log_info "Installing HP Omen gaming optimizations..."
      install_aur_quietly omen-monitors
    fi
  fi

  # Configure HP function keys
  sudo modprobe hp-wmi 2>/dev/null
  if lsmod | grep -q hp_wmi; then
    log_success "HP WMI module loaded for function key support"
  else
    log_warning "HP WMI module not available - function keys may not work properly"
  fi

  # Enable ACPI services
  sudo systemctl enable acpid.service 2>/dev/null
  sudo systemctl start acpid.service 2>/dev/null

  log_success "HP optimizations completed"
}

# Function to setup Dell-specific optimizations
setup_dell_optimizations() {
  step "Configuring Dell-specific optimizations"

  # Install Dell-specific packages
  log_info "Installing Dell-specific tools..."
  # Check if ACPI should be skipped due to compatibility issues
  if [ "$(should_skip_acpi)" = "true" ]; then
    log_info "Skipping ACPI tools due to compatibility issues"
  else
    install_packages_quietly acpi acpid
  fi
  
  if command -v yay >/dev/null 2>&1; then
    # Install Dell XPS tools if detected
    if grep -qi "xps" /sys/class/dmi/id/product_name 2>/dev/null; then
      log_info "Installing Dell XPS optimizations..."
      install_aur_quietly dell-xps-firmware
    fi
    
    # Install Dell Command Center alternative
    install_aur_quietly dell-command-center
  fi

  # Configure Dell function keys
  sudo modprobe dell-wmi 2>/dev/null
  if lsmod | grep -q dell_wmi; then
    log_success "Dell WMI module loaded for function key support"
  else
    log_warning "Dell WMI module not available - function keys may not work properly"
  fi

  # Enable ACPI services
  sudo systemctl enable acpid.service 2>/dev/null
  sudo systemctl start acpid.service 2>/dev/null

  log_success "Dell optimizations completed"
}

# Function to setup Acer-specific optimizations
setup_acer_optimizations() {
  step "Configuring Acer-specific optimizations"

  # Install Acer-specific packages
  log_info "Installing Acer-specific tools..."
  # Check if ACPI should be skipped due to compatibility issues
  if [ "$(should_skip_acpi)" = "true" ]; then
    log_info "Skipping ACPI tools due to compatibility issues"
  else
    install_packages_quietly acpi acpid
  fi
  
  if command -v yay >/dev/null 2>&1; then
    # Install Acer Nitro gaming tools if detected
    if grep -qi "nitro\|predator" /sys/class/dmi/id/product_name 2>/dev/null; then
      log_info "Installing Acer gaming optimizations..."
      install_aur_quietly acer-nitro-optimizer
    fi
  fi

  # Configure Acer function keys
  sudo modprobe acer-wmi 2>/dev/null
  if lsmod | grep -q acer_wmi; then
    log_success "Acer WMI module loaded for function key support"
  else
    log_warning "Acer WMI module not available - function keys may not work properly"
  fi

  # Enable ACPI services
  sudo systemctl enable acpid.service 2>/dev/null
  sudo systemctl start acpid.service 2>/dev/null

  log_success "Acer optimizations completed"
}

# Function to setup ASUS-specific optimizations
setup_asus_optimizations() {
  step "Configuring ASUS-specific optimizations"

  # Install ASUS-specific packages
  log_info "Installing ASUS-specific tools..."
  # Check if ACPI should be skipped due to compatibility issues
  if [ "$(should_skip_acpi)" = "true" ]; then
    log_info "Skipping ACPI tools due to compatibility issues"
  else
    install_packages_quietly acpi acpid
  fi
  
  if command -v yay >/dev/null 2>&1; then
    # Install ASUS ROG gaming tools if detected
    if grep -qi "rog\|zenbook" /sys/class/dmi/id/product_name 2>/dev/null; then
      log_info "Installing ASUS ROG/ZenBook optimizations..."
      install_aur_quietly asusctl
      install_aur_quietly supergfxctl
    fi
  fi

  # Configure ASUS function keys
  sudo modprobe asus-wmi 2>/dev/null
  if lsmod | grep -q asus_wmi; then
    log_success "ASUS WMI module loaded for function key support"
  else
    log_warning "ASUS WMI module not available - function keys may not work properly"
  fi

  # Enable ACPI services
  sudo systemctl enable acpid.service 2>/dev/null
  sudo systemctl start acpid.service 2>/dev/null

  log_success "ASUS optimizations completed"
}

# Function to setup MSI-specific optimizations
setup_msi_optimizations() {
  step "Configuring MSI-specific optimizations"

  # Install MSI-specific packages
  log_info "Installing MSI-specific tools..."
  # Check if ACPI should be skipped due to compatibility issues
  if [ "$(should_skip_acpi)" = "true" ]; then
    log_info "Skipping ACPI tools due to compatibility issues"
  else
    install_packages_quietly acpi acpid
  fi
  
  if command -v yay >/dev/null 2>&1; then
    # Install MSI gaming tools
    log_info "Installing MSI gaming optimizations..."
    install_aur_quietly msi-ec
    install_aur_quietly msi-per-keyboard
  fi

  # Configure MSI function keys
  sudo modprobe msi-wmi 2>/dev/null
  if lsmod | grep -q msi_wmi; then
    log_success "MSI WMI module loaded for function key support"
  else
    log_warning "MSI WMI module not available - function keys may not work properly"
  fi

  # Enable ACPI services
  sudo systemctl enable acpid.service 2>/dev/null
  sudo systemctl start acpid.service 2>/dev/null

  log_success "MSI optimizations completed"
}

# Function to setup AMD-specific laptop optimizations
setup_amd_laptop_optimizations() {
  step "Configuring AMD-specific laptop optimizations"

  # Configure smart AMD P-State based on gaming mode presence
  configure_smart_amd_pstate

  log_success "AMD-specific optimizations completed"
}

# Function to configure smart AMD P-State with robust detection and validation
configure_smart_amd_pstate() {
  local cpu_vendor=$(grep -m1 'vendor_id' /proc/cpuinfo | awk '{print $3}')
  
  if [[ "$cpu_vendor" != "AuthenticAMD" ]]; then
    log_info "Non-AMD CPU detected - skipping AMD P-State configuration"
    return 0
  fi

  # Validate AMD P-State support
  if ! validate_amd_pstate_support; then
    log_warning "AMD CPU detected but P-State not supported - using ACPI CPUfreq"
    return 1
  fi

  # Robust gaming mode detection
  local gaming_mode_detected=false
  gaming_mode_detected=$(detect_gaming_mode_presence)
  
  log_info "AMD CPU detected with P-State support - configuring driver"
  
  # Apply configuration with error handling
  if [ "$gaming_mode_detected" = true ]; then
    log_info "Gaming mode detected - applying gaming P-State configuration"
    if configure_amd_pstate_gaming; then
      log_success "AMD P-State gaming configuration applied successfully"
    else
      log_warning "Gaming P-State failed - falling back to system configuration"
      configure_amd_pstate_system
    fi
  else
    log_info "Standard system detected - applying balanced P-State configuration"
    configure_amd_pstate_system
  fi
}

# Validate AMD P-State support with multiple checks
validate_amd_pstate_support() {
  local support_detected=false
  
  # Method 1: Check for AMD P-State driver in sysfs
  if [ -d /sys/devices/system/cpu/amd_pstate ]; then
    support_detected=true
    log_info "AMD P-State driver found in sysfs"
  fi
  
  # Method 2: Check for P-State in CPU capabilities
  if grep -q "amd_pstate" /proc/cpuinfo 2>/dev/null; then
    support_detected=true
    log_info "AMD P-State capability found in /proc/cpuinfo"
  fi
  
  # Method 3: Check kernel version (5.19+ has better support)
  local kernel_version=$(uname -r | cut -d. -f1-2)
  if [ "$(printf '%s\n' "5.19" "$kernel_version" | sort -V | head -n1)" = "5.19" ]; then
    support_detected=true
    log_info "Modern kernel ($kernel_version) with AMD P-State support"
  fi
  
  if [ "$support_detected" = true ]; then
    return 0  # P-State supported
  else
    return 1  # P-State not supported
  fi
}

# Robust gaming mode detection with multiple indicators
detect_gaming_mode_presence() {
  local gaming_indicators=0
  local total_checks=0
  
  # Check 1: Gaming-specific services
  ((total_checks++))
  if [ -f /etc/systemd/system/gaming-mode.service ] || [ -f /etc/systemd/user/gaming-mode.service ]; then
    ((gaming_indicators++))
    log_info "Found gaming-mode service"
  fi
  
  # Check 2: Gaming packages (more specific than just Steam)
  ((total_checks++))
  if pacman -Q "linux-zen" >/dev/null 2>&1; then
    ((gaming_indicators++))
    log_info "Found Zen kernel (gaming optimization)"
  fi
  
  # Check 3: Gaming tools (not just Steam)
  ((total_checks++))
  if pacman -Q "mangohud" "gamemode" >/dev/null 2>&1; then
    ((gaming_indicators++))
    log_info "Found gaming tools (MangoHud/GameMode)"
  fi
  
  # Check 4: Gaming desktop entries
  ((total_checks++))
  if [ -f /usr/share/applications/steam.desktop ] || [ -f /usr/share/applications/lutris.desktop ] || [ -f /usr/share/applications/heroic.desktop ]; then
    ((gaming_indicators++))
    log_info "Found gaming applications"
  fi
  
  # Check 5: Gaming configuration files
  ((total_checks++))
  if [ -d /etc/gaming-mode ] || [ -f /etc/default/gaming-mode ]; then
    ((gaming_indicators++))
    log_info "Found gaming mode configuration"
  fi
  
  # Determine if gaming mode is present (50% threshold)
  local threshold=$((total_checks / 2))
  if [ $gaming_indicators -ge $threshold ]; then
    log_info "Gaming mode detected ($gaming_indicators/$total_checks indicators)"
    return 0  # Gaming mode detected
  else
    log_info "Standard system detected ($gaming_indicators/$total_checks gaming indicators)"
    return 1  # Standard system
  fi
}

# Configure AMD P-State for gaming performance
configure_amd_pstate_gaming() {
  local pstate_conf="/etc/modprobe.d/amd-pstate.conf"
  local pstate_service="/etc/systemd/system/amd-pstate-gaming.service"
  
  # Create gaming P-State configuration
  sudo tee "$pstate_conf" > /dev/null << EOF
# AMD P-state configuration for optimal gaming performance
# Modern kernels (5.19+) handle pstate=active automatically in boot loaders
# This ensures compatibility with systemd-boot and GRUB
options amd_pstate=active
EOF
  
  # Create gaming-specific systemd service
  sudo tee "$pstate_service" > /dev/null << EOF
[Unit]
Description=Set AMD P-state gaming performance governor
Wants=systemd-udev-settle.service
After=amd-pstate-setup.service

[Service]
Type=oneshot
ExecStart=/usr/bin/cpupower frequency-set -g performance
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  
  # Enable the gaming service
  if sudo systemctl daemon-reload && sudo systemctl enable amd-pstate-gaming.service; then
    log_success "AMD P-state gaming performance service enabled"
  else
    log_warning "Failed to enable AMD P-state gaming performance service"
  fi
  
  # Update initramfs if needed
  if command -v mkinitcpio >/dev/null 2>&1; then
    sudo mkinitcpio -P linux-zen linux-lts 2>/dev/null && log_success "Initramfs updated for gaming P-State"
  fi
  
  log_success "AMD P-State gaming configuration applied"
}

# Configure AMD P-State for balanced system performance
configure_amd_pstate_system() {
  local pstate_conf="/etc/modprobe.d/amd-pstate.conf"
  
  # Create balanced P-State configuration
  sudo tee "$pstate_conf" > /dev/null << EOF
# AMD P-state configuration for balanced system performance
# Modern kernels (5.19+) handle pstate=active automatically in boot loaders
# This ensures compatibility with systemd-boot and GRUB
options amd_pstate=active
EOF
  
  # Enable AMD P-State driver for better power management
  if ! grep -q "amd_pstate" /etc/modules-load.d/*.conf 2>/dev/null; then
    echo "amd_pstate" | sudo tee -a /etc/modules-load.d/amd-pstate.conf >/dev/null
    log_success "AMD P-State driver enabled for next boot"
  fi
  
  # Update initramfs if needed
  if command -v mkinitcpio >/dev/null 2>&1; then
    sudo mkinitcpio -P linux linux-lts 2>/dev/null && log_success "Initramfs updated for system P-State"
  fi
  
  log_success "AMD P-State system configuration applied"
}

# Function to setup laptop optimizations
setup_laptop_optimizations() {
  if ! is_laptop; then
    log_info "Desktop system detected. Skipping laptop optimizations."
    return 0
  fi

  step "Laptop detected - Configuring laptop optimizations"
  log_success "Laptop hardware detected"

  # Enhanced detection
  local cpu_vendor=$(detect_cpu_vendor)
  local manufacturer=$(detect_laptop_manufacturer)
  local laptop_model=$(get_laptop_model)
  local is_gaming=$(detect_gaming_laptop "$manufacturer")
  local should_auto=$(should_auto_optimize)
  
  log_info "CPU Vendor: $(echo $cpu_vendor | tr '[:lower:]' '[:upper:]')"
  log_info "Laptop Manufacturer: $(echo $manufacturer | tr '[:lower:]' '[:upper:]')"
  log_info "Laptop Model: $laptop_model"
  
  if [ "$is_gaming" = "true" ]; then
    log_info "Gaming laptop detected - will apply gaming-specific optimizations"
  fi

  # Get manufacturer-specific optimizations
  local manufacturer_opts=($(get_manufacturer_optimizations "$manufacturer"))

  # Determine if we should enable optimizations
  local enable_laptop_opts=false
  
  if [ "$should_auto" = "true" ]; then
    # Automatic mode - enable optimizations without prompting
    enable_laptop_opts=true
    log_info "Auto-optimization mode enabled - applying laptop optimizations"
  elif command -v gum >/dev/null 2>&1; then
    # Interactive mode with gum
    echo ""
    gum style --foreground 226 "Laptop-specific optimizations available for $(echo $manufacturer | tr '[:lower:]' '[:upper]') $laptop_model:"
    gum style --margin "0 2" --foreground 15 "Power profile management (tuned-ppd or power-profiles-daemon)"
    gum style --margin "0 2" --foreground 15 "CPU-specific optimizations ($(echo $cpu_vendor | tr '[:lower:]' '[:upper]'))"
    
    # Show manufacturer-specific optimizations
    for opt in "${manufacturer_opts[@]}"; do
      gum style --margin "0 2" --foreground 15 "$opt"
    done
    
    echo ""
    gum style --foreground 11 "Tip: Set AUTO_LAPTOP_OPTS=true to skip this prompt in future"
    if gum confirm --default=true "Enable laptop optimizations?"; then
      enable_laptop_opts=true
    fi
  else
    # Non-interactive mode
    echo ""
    echo -e "${YELLOW}Laptop-specific optimizations available for $(echo $manufacturer | tr '[:lower:]' '[:upper]') $laptop_model:${RESET}"
    echo -e "  \u2022 Power profile management (tuned-ppd or power-profiles-daemon)"
    echo -e "  \u2022 CPU-specific optimizations ($(echo $cpu_vendor | tr '[:lower:]' '[:upper]'))"
    
    # Show manufacturer-specific optimizations
    for opt in "${manufacturer_opts[@]}"; do
      echo -e "  \u2022 $opt"
    done
    
    echo ""
    echo -e "${CYAN}Tip: Set AUTO_LAPTOP_OPTS=true to enable optimizations automatically${RESET}"
    read -r -p "Enable laptop optimizations? [Y/n]: " response
    response=${response,,}
    if [[ "$response" != "n" && "$response" != "no" ]]; then
      enable_laptop_opts=true
      # Remember the choice for future runs
      mkdir -p "$HOME/.config"
      echo "true" > "$HOME/.config/archinstaller-laptop-opts"
    else
      mkdir -p "$HOME/.config"
      echo "false" > "$HOME/.config/archinstaller-laptop-opts"
    fi
  fi

  if [ "$enable_laptop_opts" = false ]; then
    log_info "Laptop optimizations skipped by user"
    return 0
  fi

  # Setup power profile management (kernel + power-profiles-daemon/tuned-ppd)
  step "Setting up power profile management"
  log_info "Modern kernels handle power management well"
  log_info "Adding user-friendly profile switching via power-profiles-daemon or tuned-ppd"

  setup_power_profile_daemon

  # Apply CPU-specific optimizations
  case "$cpu_vendor" in
    intel)
      setup_intel_laptop_optimizations
      ;;
    amd)
      setup_amd_laptop_optimizations
      ;;
    *)
      log_info "Unknown CPU vendor - using kernel defaults for power management"
      ;;
  esac

  # Apply manufacturer-specific optimizations
  case "$manufacturer" in
    lenovo)
      setup_lenovo_optimizations
      ;;
    hp)
      setup_hp_optimizations
      ;;
    dell)
      setup_dell_optimizations
      ;;
    acer)
      setup_acer_optimizations
      ;;
    asus)
      setup_asus_optimizations
      ;;
    msi)
      setup_msi_optimizations
      ;;
    *)
      log_info "Unknown or unsupported manufacturer - applying generic optimizations"
      # Check if ACPI should be skipped due to compatibility issues
      if [ "$(should_skip_acpi)" = "true" ]; then
        log_info "Skipping ACPI tools due to compatibility issues"
      else
        install_packages_quietly acpi acpid
        sudo systemctl enable acpid.service 2>/dev/null
        sudo systemctl start acpid.service 2>/dev/null
      fi
      ;;
  esac

  # Show summary
  show_laptop_summary
}

# Apply advanced system optimizations (CachyOS-style)
setup_advanced_optimizations() {
  setup_advanced_optimizations
}

# Continue setup_laptop_optimizations function
show_laptop_summary() {
  # Display battery information
  step "Battery information"
  if [ -d /sys/class/power_supply/BAT0 ]; then
    local battery_status=$(cat /sys/class/power_supply/BAT0/status 2>/dev/null || echo "Unknown")
    local battery_capacity=$(cat /sys/class/power_supply/BAT0/capacity 2>/dev/null || echo "Unknown")
    log_info "Battery Status: $battery_status"
    log_info "Battery Capacity: ${battery_capacity}%"
  fi

  # Show power management info
  if command -v tuned-adm >/dev/null 2>&1; then
    log_info "Power profiles managed by tuned-ppd. Use: tuned-adm list"
  elif command -v powerprofilesctl >/dev/null 2>&1; then
    log_info "Power profiles managed by power-profiles-daemon. Use: powerprofilesctl"
  fi

  echo ""
  log_success "Laptop optimizations completed successfully"
  echo ""
  echo -e "${CYAN}Laptop features configured:${RESET}"
  echo -e "  • Kernel-based power management (automatic)"
  if command -v tuned-adm >/dev/null 2>&1; then
    echo -e "  • tuned-ppd for power profile switching"
  elif command -v powerprofilesctl >/dev/null 2>&1; then
    echo -e "  • power-profiles-daemon for power profile switching"
  fi
  case "$cpu_vendor" in
    intel)
      echo -e "  • Intel thermald (thermal management)"
      if [ -d /sys/devices/system/cpu/intel_pstate ]; then
        echo -e "  • Intel P-State driver (efficient CPU scaling)"
      fi
      ;;
    amd)
      if [ -d /sys/devices/system/cpu/amd_pstate ]; then
        echo -e "  • AMD P-State driver (Ryzen 5000+ efficient scaling)"
      else
        echo -e "  • ACPI CPUfreq driver (Ryzen 1st-4th gen)"
      fi
      ;;
  esac
  echo ""
  echo -e "${YELLOW}Tips:${RESET}"
  if command -v tuned-adm >/dev/null 2>&1; then
    echo -e "  • List power profiles: ${CYAN}tuned-adm list${RESET}"
    echo -e "  • Switch to powersave: ${CYAN}tuned-adm profile powersave${RESET}"
    echo -e "  • Switch to performance: ${CYAN}tuned-adm profile performance${RESET}"
    echo -e "  • Check active profile: ${CYAN}tuned-adm active${RESET}"
  elif command -v powerprofilesctl >/dev/null 2>&1; then
    echo -e "  • List power profiles: ${CYAN}powerprofilesctl list${RESET}"
    echo -e "  • Switch profile: ${CYAN}powerprofilesctl set performance${RESET}"
  fi
  if [ "$cpu_vendor" = "intel" ]; then
    echo -e "  • Thermal status: ${CYAN}sudo systemctl status thermald${RESET}"
  fi
  echo ""
}

# Execute all service and maintenance steps
setup_firewall_and_services
check_battery_status
detect_memory_size
detect_filesystem_type
detect_storage_type
detect_audio_system
detect_kernel_type
detect_vm_hypervisor
detect_de_version
detect_bluetooth_hardware
detect_and_install_gpu_drivers
detect_hybrid_graphics
setup_laptop_optimizations
