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

  # Configure Plymouth boot splash
  run_step "Configuring Plymouth boot splash" configure_plymouth
}

configure_firewalld() {
  # Start and enable firewalld
  sudo systemctl start firewalld
  sudo systemctl enable firewalld

  # Set default zone to drop — deny incoming, allow outgoing, explicit allow for services
  sudo firewall-cmd --set-default-zone=drop
  log_success "Default zone set to drop (incoming denied, outgoing allowed)"

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
    log_success "KDE Connect ports opened in firewall"
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
  # Ensure openssh is installed before trying to enable sshd
  if ! pacman -Q openssh &>/dev/null; then
    log_info "openssh not found — installing..."
    sudo pacman -S --noconfirm --needed openssh >>"$INSTALL_LOG" 2>&1 || log_warning "Failed to install openssh"
  fi

  # Server mode enables a minimal set of services, desktop mode adds extras.
  # Both paths continue to shared optimizations (memory, filesystem, storage, audio, kernel).
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
    # Enable each service individually to prevent one failure from blocking all others
    local server_failed=()
    for svc in "${services[@]}"; do
      if sudo systemctl enable --now "$svc" >>"$INSTALL_LOG" 2>&1; then
        log_success "$svc enabled successfully"
      else
        log_warning "Failed to enable $svc"
        server_failed+=("$svc")
      fi
    done
    if [ ${#server_failed[@]} -eq 0 ]; then
      log_success "All essential services enabled successfully."
    else
      log_warning "Some services failed to enable: ${server_failed[*]}"
    fi
    
    # Continue to shared optimizations (memory, filesystem, storage, audio, kernel)
  else

  local services=(
    bluetooth.service
    cronie.service
    fstrim.timer
    paccache.timer
    sshd.service
  )

  # Check and configure virtualization guest integration (libvirt is used by virt-manager and gnome-boxes)
  if command -v virsh &>/dev/null || pacman -Q libvirt-daemon &>/dev/null 2>&1 || pacman -Q virt-manager &>/dev/null 2>&1 || pacman -Q gnome-boxes &>/dev/null 2>&1; then
    # Add user to libvirt group and enable service
    if groups "$USER" | grep -qE '\blibvirt\b'; then
      log_info "User already in libvirt group"
    else
      sudo usermod -aG libvirt "$USER" 2>/dev/null && log_success "Added user to libvirt group" || log_warning "Failed to add user to libvirt group"
    fi
    if systemctl is-enabled libvirtd &>/dev/null 2>&1; then
      log_info "libvirtd service already enabled"
    else
      sudo systemctl enable --now libvirtd 2>/dev/null && log_success "libvirtd service enabled" || log_warning "Failed to enable libvirtd service"
    fi
  fi

  # Conditionally add rustdesk.service if installed
  if pacman -Qi rustdesk-bin &>/dev/null || pacman -Qi rustdesk &>/dev/null || systemctl list-unit-files rustdesk.service &>/dev/null; then
    services+=(rustdesk.service)
    log_success "rustdesk.service will be enabled."
  else
    log_warning "rustdesk is not installed. Skipping rustdesk.service."
  fi

  # Conditionally add power-profiles-daemon.service if installed
  if pacman -Qi power-profiles-daemon &>/dev/null && ! pacman -Qi tlp &>/dev/null && ! pacman -Qi auto-cpufreq &>/dev/null; then
    services+=(power-profiles-daemon.service)
    log_success "power-profiles-daemon.service will be enabled."
  elif pacman -Qi power-profiles-daemon &>/dev/null; then
    log_warning "power-profiles-daemon installed but conflicting power manager (tlp/auto-cpufreq) detected. Skipping."
  fi

  # Check if Timeshift is already installed and install timeshift-autosnap if needed
  if pacman -Q timeshift &>/dev/null; then
    log_success "Timeshift detected - installing timeshift-autosnap for automatic snapshots..."
    if command -v yay >/dev/null 2>&1; then
      if yay -S --noconfirm --needed timeshift-autosnap >>"$INSTALL_LOG" 2>&1; then
        log_success "timeshift-autosnap installed successfully"
        sudo systemctl daemon-reload
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
  # Enable each service individually to prevent one failure from blocking all others
  local failed_services=()
  for svc in "${services[@]}"; do
    if sudo systemctl enable --now "$svc" >>"$INSTALL_LOG" 2>&1; then
      log_success "$svc enabled successfully"
    else
      log_warning "Failed to enable $svc"
      failed_services+=("$svc")
    fi
  done
  if [ ${#failed_services[@]} -eq 0 ]; then
    log_success "All services enabled successfully."
  else
    log_warning "Some services failed to enable: ${failed_services[*]}"
  fi

  # Verify services started correctly
  log_info "Verifying service status..."
  local verify_failed=()
  for svc in "${services[@]}"; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      log_success "$svc is active"
    elif systemctl is-enabled --quiet "$svc" 2>/dev/null; then
      log_warning "$svc is enabled but not running (may require reboot)"
    else
      log_warning "$svc failed to start or enable"
      verify_failed+=("$svc")
    fi
  done

  if [ ${#verify_failed[@]} -eq 0 ]; then
    log_success "All services verified successfully"
  else
    log_warning "Some services may need attention: ${verify_failed[*]}"
  fi
  fi
}

# Configure Plymouth boot splash
# Hook ordering per ArchWiki:
#   systemd: base → systemd → plymouth → (encrypt/sd-encrypt)
#   base:    base → udev → plymouth → (encrypt)
configure_plymouth() {
  # Skip for server mode (no graphical boot needed)
  if [[ "$INSTALL_MODE" == "server" ]]; then
    log_info "Server mode — skipping Plymouth configuration"
    return 0
  fi

  # Check if Plymouth is installed
  if ! pacman -Qi plymouth &>/dev/null 2>&1; then
    log_info "Plymouth not installed — skipping configuration"
    return 0
  fi

  ui_info "Configuring Plymouth boot splash..."

  # Set theme: prefer bgrt (UEFI), fallback to spinner
  local theme="spinner"
  if pacman -Qi plymouth-theme-bgrt &>/dev/null 2>&1; then
    theme="bgrt"
  elif pacman -Qi xora &>/dev/null 2>&1; then
    theme="xora"
  fi

  # Set the Plymouth theme (also creates initramfs hook directory entries)
  if command -v plymouth-set-default-theme &>/dev/null; then
    sudo plymouth-set-default-theme -R "$theme" >>"$INSTALL_LOG" 2>&1 && \
      log_success "Plymouth theme set to: $theme" || \
      log_warning "Failed to set Plymouth theme"
  fi

  # Add plymouth hook to mkinitcpio if not present
  local mkinitcpio_conf="/etc/mkinitcpio.conf"
  if [[ -f "$mkinitcpio_conf" ]]; then
    if ! grep -q "plymouth" "$mkinitcpio_conf"; then
      if grep -q "^HOOKS=.*systemd" "$mkinitcpio_conf"; then
        # systemd hook: add plymouth after systemd
        sudo sed -i 's/\(HOOKS=.*systemd\)/\1 plymouth/' "$mkinitcpio_conf"
        log_success "Added plymouth hook after systemd in mkinitcpio"
      elif grep -q "^HOOKS=.*udev" "$mkinitcpio_conf"; then
        # base hook: add plymouth after udev (udev MUST come before plymouth)
        sudo sed -i 's/\(HOOKS=.*udev\)/\1 plymouth/' "$mkinitcpio_conf"
        log_success "Added plymouth hook after udev in mkinitcpio"
      fi
    else
      log_info "Plymouth hook already present in mkinitcpio"
    fi

    # Verify plymouth is positioned correctly (after udev/systemd, before encrypt)
    if grep -q "plymouth" "$mkinitcpio_conf"; then
      local hooks_line
      hooks_line=$(grep "^HOOKS=" "$mkinitcpio_conf")
      local plymouth_pos=0 udev_pos=0 systemd_pos=0 encrypt_pos=0 sdencrypt_pos=0
      local pos=0
      for hook in $hooks_line; do
        ((pos++))
        case "$hook" in
          udev)       udev_pos=$pos ;;
          systemd)    systemd_pos=$pos ;;
          plymouth)   plymouth_pos=$pos ;;
          encrypt)    encrypt_pos=$pos ;;
          sd-encrypt) sdencrypt_pos=$pos ;;
        esac
      done
      # Fix ordering: plymouth must be after udev/systemd and before encrypt/sd-encrypt
      if [[ "$udev_pos" -gt 0 && "$plymouth_pos" -lt "$udev_pos" ]]; then
        log_warning "Plymouth is before udev in mkinitcpio — rearranging hooks"
        sudo sed -i 's/plymouth //' "$mkinitcpio_conf"
        sudo sed -i 's/\(HOOKS=.*udev\)/\1 plymouth/' "$mkinitcpio_conf"
      elif [[ "$systemd_pos" -gt 0 && "$plymouth_pos" -lt "$systemd_pos" ]]; then
        log_warning "Plymouth is before systemd in mkinitcpio — rearranging hooks"
        sudo sed -i 's/plymouth //' "$mkinitcpio_conf"
        sudo sed -i 's/\(HOOKS=.*systemd\)/\1 plymouth/' "$mkinitcpio_conf"
      fi
      # Ensure plymouth comes before encrypt/sd-encrypt if present
      if [[ "$encrypt_pos" -gt 0 && "$plymouth_pos" -gt "$encrypt_pos" ]]; then
        log_warning "Plymouth is after encrypt — rearranging hooks"
        sudo sed -i 's/plymouth //' "$mkinitcpio_conf"
        sudo sed -i 's/\(HOOKS=.*encrypt\)/\1 plymouth/' "$mkinitcpio_conf"
      elif [[ "$sdencrypt_pos" -gt 0 && "$plymouth_pos" -gt "$sdencrypt_pos" ]]; then
        log_warning "Plymouth is after sd-encrypt — rearranging hooks"
        sudo sed -i 's/plymouth //' "$mkinitcpio_conf"
        sudo sed -i 's/\(HOOKS=.*sd-encrypt\)/\1 plymouth/' "$mkinitcpio_conf"
      fi
    fi

    # Regenerate initramfs
    ui_info "Regenerating initramfs with Plymouth hooks..."
    if sudo mkinitcpio -P >>"$INSTALL_LOG" 2>&1; then
      log_success "Initramfs regenerated with Plymouth support"
    else
      log_warning "Initramfs regeneration had issues"
    fi
  fi

  log_success "Plymouth boot splash configured"
}

detect_and_install_gpu_drivers() {
  step "Detecting and installing graphics drivers"
  
  # Install base Mesa first (needed for all GPU types)
  install_packages_quietly mesa lib32-mesa

  if lspci | grep -Eiq 'vga.*amd|3d.*amd|display.*amd'; then
    echo -e "${THEME_TEXT}AMD GPU detected. Installing AMD drivers and Vulkan support...${RESET}"
    install_packages_quietly xf86-video-amdgpu vulkan-radeon lib32-vulkan-radeon
    log_success "AMD drivers and Vulkan support installed"
    log_info "AMD GPU will use AMDGPU driver after reboot"
  elif lspci | grep -Eiq 'vga.*nvidia|3d.*nvidia|display.*nvidia'; then
    echo -e "${THEME_TEXT}NVIDIA GPU detected. Installing NVIDIA drivers and Vulkan support...${RESET}"
    # Determine correct NVIDIA package set based on installed kernels
    local nvidia_packages=(nvidia-dkms nvidia-utils lib32-nvidia-utils vulkan-icd-loader lib32-vulkan-icd-loader)
    # Add nvidia-settings for GUI configuration
    nvidia_packages+=(nvidia-settings)
    install_packages_quietly "${nvidia_packages[@]}"
    log_success "NVIDIA drivers and Vulkan support installed"
    log_info "NVIDIA GPU will use proprietary driver after reboot"
    log_info "Ensure 'nvidia-dkms' is in your mkinitcpio MODULES array if using custom kernel"
  elif lspci | grep -Eiq 'vga.*intel|3d.*intel|display.*intel'; then
    echo -e "${THEME_TEXT}Intel GPU detected. Installing Intel drivers and Vulkan support...${RESET}"
    install_packages_quietly vulkan-intel lib32-vulkan-intel
    log_success "Intel drivers and Vulkan support installed"
    log_info "Intel GPU will use i915 or xe driver after reboot"
  else
    echo -e "${THEME_WARN}No AMD, Intel, or NVIDIA GPU detected. Using basic Mesa drivers already installed.${RESET}"
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

# NOTE: is_laptop() uses the cached version from system.sh (sourced via common.sh)

# NOTE: detect_cpu_vendor() uses the cached version from system.sh (sourced via common.sh)

# Function to install ACPI with smart compatibility handling
install_smart_acpi() {
  local acpi_mode=$(should_skip_acpi)
  
  case "$acpi_mode" in
    "minimal")
      log_info "Installing minimal ACPI support for legacy hardware"
      install_packages_quietly acpi
      # Only enable acpid service, don't start it automatically on legacy systems
      sudo systemctl enable acpid.service 2>/dev/null || true
      ;;
    "false")
      log_info "Installing full ACPI support for modern hardware"
      install_packages_quietly acpi acpid
      sudo systemctl enable acpid.service 2>/dev/null
      sudo systemctl start acpid.service 2>/dev/null
      ;;
    *)
      log_info "Skipping ACPI tools due to compatibility issues"
      ;;
  esac
}

# Function to check if ACPI should be skipped due to compatibility issues
should_skip_acpi() {
  local cpu_vendor=$(detect_cpu_vendor)
  local manufacturer=$(detect_laptop_manufacturer)
  local cpu_model=""
  local cpu_family=""
  
  # Get CPU model for specific checks
  cpu_model=$(grep "model name" /proc/cpuinfo | head -1 | cut -d':' -f2 | xargs)
  
  # Get CPU family for architecture detection
  cpu_family=$(grep "cpu family" /proc/cpuinfo | head -1 | cut -d':' -f2 | xargs)
  
  # Modern ACPI compatibility check - only skip truly problematic hardware
  
  # 1. Skip only for very old pre-Zen AMD CPUs (pre-2017)
  if [ "$cpu_vendor" = "amd" ]; then
    if [ "$cpu_family" -lt "23" ]; then  # Family 23+ is Zen 2 and newer
      log_info "Legacy AMD CPU detected (family $cpu_family) - using minimal ACPI"
      echo "minimal"
      return 0
    fi
  fi
  
  # 2. Skip for very old Intel CPUs (pre-2015)
  if [ "$cpu_vendor" = "intel" ]; then
    local cpu_model_num=$(echo "$cpu_model" | grep -o '[0-9]\{3,4\}' | head -1)
    if [ -n "$cpu_model_num" ] && [ "$cpu_model_num" -lt "4000" ]; then
      log_info "Legacy Intel CPU detected (model $cpu_model_num) - using minimal ACPI"
      echo "minimal"
      return 0
    fi
  fi
  
  # 3. Check for known problematic legacy hardware (only very old models)
  case "$manufacturer" in
    hp)
      # Only skip for very old HP models with legacy APUs
      if [ "$cpu_vendor" = "amd" ]; then
        case "$cpu_model" in
          *"AMD A4"*|*"AMD A6"*|*"AMD A8"*|*"AMD A10"*|*"AMD E1"*|*"AMD E2"*|*"AMD A[4-6]"*)
            log_info "HP laptop with legacy AMD APU detected - using minimal ACPI"
            echo "minimal"
            return 0
            ;;
        esac
      fi
      ;;
    lenovo)
      # Only skip for very old ThinkPads with legacy hardware
      if [ "$cpu_vendor" = "amd" ] && echo "$cpu_model" | grep -q "AMD A[4-6]"; then
        log_info "Lenovo laptop with legacy AMD APU detected - using minimal ACPI"
        echo "minimal"
        return 0
      fi
      ;;
  esac
  
  # Default: ACPI is safe for modern hardware
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
  if [ "$ram_gb" -lt 4 ]; then
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

  elif [ "$ram_gb" -ge 4 ] && [ "$ram_gb" -lt 8 ]; then
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

  elif [ "$ram_gb" -ge 8 ] && [ "$ram_gb" -lt 16 ]; then
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
    if [ "$ram_gb" -ge 32 ]; then
      log_info "32GB+ RAM detected - swap can be fully disabled if desired"
    fi
  fi

  # Apply sysctl settings immediately
  sudo sysctl -p /etc/sysctl.d/99-swappiness.conf >>"$INSTALL_LOG" 2>&1

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
  local devices=()
  while IFS= read -r device; do
    devices+=("$device")
  done < <(lsblk -d -n -o NAME,TYPE | grep disk | awk '{print $1}')

  for device in "${devices[@]}"; do
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
    *)
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
    # Install ACPI with smart compatibility handling
    install_smart_acpi
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
  # Install ACPI with smart compatibility handling
  install_smart_acpi
  
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
  # Install ACPI with smart compatibility handling
  install_smart_acpi
  
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
  # Install ACPI with smart compatibility handling
  install_smart_acpi
  
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
  # Install ACPI with smart compatibility handling
  install_smart_acpi
  
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
  # Install ACPI with smart compatibility handling
  install_smart_acpi
  
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
  detect_gaming_mode_presence && gaming_mode_detected=true
  
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
  if [ "$gaming_indicators" -ge "$threshold" ]; then
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
  local pstate_service="/etc/systemd/system/amd-pstate-schedutil.service"
  
  # Create gaming P-State configuration
  sudo tee "$pstate_conf" > /dev/null << EOF
# AMD P-state configuration for optimal gaming performance
# Modern kernels (5.19+) handle pstate=active automatically in boot loaders
# This ensures compatibility with systemd-boot and GRUB
options amd_pstate=active
EOF
  
  # Detect available governors and pick the best balance
  local available_governors
  available_governors=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null || echo "")
  local chosen_governor="powersave"
  if echo "$available_governors" | grep -qw "schedutil"; then
    chosen_governor="schedutil"
  elif echo "$available_governors" | grep -qw "performance"; then
    chosen_governor="powersave"
  fi

  # Create systemd service
  sudo tee "$pstate_service" > /dev/null << EOF
[Unit]
Description=Set CPU governor to $chosen_governor
Wants=systemd-udev-settle.service

[Service]
Type=oneshot
ExecStart=/usr/bin/cpupower frequency-set -g $chosen_governor
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  
  # Enable the service (only if it was just created)
  if [ -f "$pstate_service" ]; then
    if sudo systemctl daemon-reload && sudo systemctl enable amd-pstate-schedutil.service; then
      log_success "AMD P-state governor service enabled"
    else
      log_warning "Failed to enable AMD P-state schedutil governor service"
    fi
  fi
  
  # Update initramfs if needed
  if command -v mkinitcpio >/dev/null 2>&1; then
    local kernels_ok=true
    for k in linux-zen linux-lts; do
      [ -f "/boot/vmlinuz-$k" ] || kernels_ok=false
    done
    if $kernels_ok; then
      sudo mkinitcpio -P linux-zen linux-lts 2>/dev/null && log_success "Initramfs updated for gaming P-State"
    else
      log_warning "Initramfs not updated — missing kernel images"
    fi
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
    local kernels_ok=true
    for k in linux linux-lts; do
      [ -f "/boot/vmlinuz-$k" ] || kernels_ok=false
    done
    if $kernels_ok; then
      sudo mkinitcpio -P linux linux-lts 2>/dev/null && log_success "Initramfs updated for system P-State"
    else
      log_warning "Initramfs not updated — missing kernel images"
    fi
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
    gum style --foreground "$GUM_WARN" "Laptop-specific optimizations available for $(echo $manufacturer | tr '[:lower:]' '[:upper]') $laptop_model:"
    gum style --margin "0 2" --foreground "$GUM_TEXT" "CPU-specific optimizations ($(echo $cpu_vendor | tr '[:lower:]' '[:upper]'))"
    
    # Show manufacturer-specific optimizations
    for opt in "${manufacturer_opts[@]}"; do
      gum style --margin "0 2" --foreground "$GUM_TEXT" "$opt"
    done
    
    echo ""
    gum style --foreground "$GUM_WARN" "Tip: Set AUTO_LAPTOP_OPTS=true to skip this prompt in future"
    if gum confirm --default=true "Enable laptop optimizations?"; then
      enable_laptop_opts=true
    fi
  else
    # Non-interactive mode
    echo ""
    echo -e "${THEME_WARN}Laptop-specific optimizations available for $(echo $manufacturer | tr '[:lower:]' '[:upper]') $laptop_model:${RESET}"
    echo -e "  \u2022 CPU-specific optimizations ($(echo $cpu_vendor | tr '[:lower:]' '[:upper]'))"
    
    # Show manufacturer-specific optimizations
    for opt in "${manufacturer_opts[@]}"; do
      echo -e "  \u2022 $opt"
    done
    
    echo ""
    echo -e "${THEME_TEXT}Tip: Set AUTO_LAPTOP_OPTS=true to enable optimizations automatically${RESET}"
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
      # Install ACPI with smart compatibility handling
      install_smart_acpi
      ;;
  esac

  # Show summary
  show_laptop_summary
}

# Apply advanced system optimizations (CachyOS-style)
setup_advanced_optimizations() {
  step "Applying advanced system optimizations"
  
  # Apply sysctl optimizations for better performance
  log_info "Applying kernel parameter optimizations..."
  
  # Network optimizations
  {
    echo "# Advanced network and memory optimizations generated by archinstaller"
    echo "net.core.default_qdisc=fq_codel"
    echo "net.ipv4.tcp_congestion_control=bbr"
    echo ""
    echo "# Reduce vfs cache pressure (complements swappiness from 99-swappiness.conf)"
    echo "vm.vfs_cache_pressure=50"
  } | sudo tee /etc/sysctl.d/99-archinstaller.conf >/dev/null

  sudo sysctl --system >>"$INSTALL_LOG" 2>&1
  
  log_success "Advanced system optimizations applied"
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

  echo ""
  log_success "Laptop optimizations completed successfully"
  echo ""
  echo -e "${THEME_TEXT}Laptop features configured:${RESET}"
  echo -e "  • Kernel-based power management (automatic)"
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
  echo -e "${THEME_WARN}Tips:${RESET}"
  if [ "$cpu_vendor" = "intel" ]; then
    echo -e "  • Thermal status: ${THEME_SECONDARY}sudo systemctl status thermald${RESET}"
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
setup_advanced_optimizations
setup_laptop_optimizations
