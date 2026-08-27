#!/bin/bash
set -euo pipefail

# Ensure HOME is set before any path resolution
: "${HOME:=/root}"
export HOME

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

  # Set default zone to block — denies incoming connections (with ICMP response),
  # allows all outgoing. Safe default that won't lock out the user.
  sudo firewall-cmd --set-default-zone=block
  log_success "Default zone set to block (incoming denied, outgoing allowed)"

  # Allow SSH — check the permanent config before modifying
  if ! sudo firewall-cmd --permanent --list-services 2>/dev/null | grep -qw ssh; then
    sudo firewall-cmd --add-service=ssh --permanent
    log_success "SSH allowed through Firewalld."
  else
    log_info "SSH already allowed in Firewalld."
  fi

  # Allow ping/ICMP — block zone still responds to ICMP, but be explicit
  if ! sudo firewall-cmd --permanent --list-icmp-blocks 2>/dev/null | grep -qw echo-request; then
    sudo firewall-cmd --add-icmp-block=echo-request --permanent
    log_info "ICMP echo-request blocked (ping ignored). Set to allow if needed."
  fi

  # Reload to apply permanent rules
  sudo firewall-cmd --reload

  # Check if KDE Connect is installed
  if pacman -Q kdeconnect &>/dev/null; then
    # Allow KDE Connect ports (1714-1764 TCP/UDP)
    sudo firewall-cmd --add-port=1714-1764/udp --permanent
    sudo firewall-cmd --add-port=1714-1764/tcp --permanent
    sudo firewall-cmd --reload
    log_success "KDE Connect ports allowed through Firewalld."
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
    # Enable each service individually with proper error handling
    local enable_success=true
    for svc in "${services[@]}"; do
      if ! sudo systemctl enable --now "$svc" >>"$INSTALL_LOG" 2>&1; then
        log_error "Failed to enable $svc service"
        enable_success=false
      else
        log_success "Enabled $svc service"
      fi
    done
    
    if [[ "$enable_success" == true ]]; then
      log_success "All essential services enabled successfully."
    else
      log_error "Some services failed to enable"
    fi

    # Return instead of exit — this file may be sourced by the installer;
    # exiting here would kill the whole installation
    return 0
  fi

  local services=(
    bluetooth.service
    cronie.service
    fstrim.timer
    paccache.timer
    sshd.service
  )

  # power-profiles-daemon: required for powerdevil's power profile switching
  # (Performance/Balanced/Power Saver) to work in Plasma
  if pacman -Q powerdevil &>/dev/null || pacman -Q plasma-workspace &>/dev/null; then
    if ! pacman -Q power-profiles-daemon &>/dev/null; then
      install_packages_quietly power-profiles-daemon && services+=(power-profiles-daemon.service)
    elif ! systemctl is-enabled --quiet power-profiles-daemon 2>/dev/null; then
      services+=(power-profiles-daemon.service)
    fi
  fi

  # Check and configure virt-manager guest integration
  if command -v virsh &>/dev/null || pacman -Q libvirt &>/dev/null 2>&1 || pacman -Q virt-manager &>/dev/null 2>&1; then
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
  if pacman -Q rustdesk-bin &>/dev/null || pacman -Q rustdesk &>/dev/null; then
    services+=(rustdesk.service)
    log_success "rustdesk.service will be enabled."
  else
    log_warning "rustdesk is not installed. Skipping rustdesk.service."
  fi

  # Snapshot tooling — bootloader-aware strategy:
  #   Limine + btrfs  -> Snapper + snap-pac + limine-snapper-sync (bootable
  #                      snapshot menu in Limine, kept in sync automatically).
  #                      Set up in bootloader_config.sh; skip Timeshift here.
  #   Everything else -> Timeshift + timeshift-autosnap (as before)
  if [ "$(detect_bootloader)" = "limine" ] && is_btrfs_system && [ -f /etc/snapper/configs/root ]; then
    log_info "Limine + Snapper snapshot integration active — skipping timeshift-autosnap"
  elif pacman -Q snapper &>/dev/null && [ -f /etc/snapper/configs/root ] && ! pacman -Q timeshift &>/dev/null; then
    log_info "Snapper already configured without Timeshift — skipping timeshift-autosnap"
  elif pacman -Q timeshift &>/dev/null; then
    log_success "Timeshift detected - installing timeshift-autosnap for automatic snapshots..."
    if command -v yay >/dev/null 2>&1; then
      if yay -S --noconfirm --needed timeshift-autosnap >>"$INSTALL_LOG" 2>&1; then
        log_success "timeshift-autosnap installed successfully"
        sudo systemctl daemon-reload
        # timeshift-autosnap works via a pacman hook (00-timeshift-autosnap.hook),
        # NOT a systemd timer — snapshots are taken automatically on pacman
        # transactions. Nothing to enable here.
        log_success "timeshift-autosnap active — snapshots will be taken on every pacman transaction"
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
  # Enable each service individually with proper error handling
  local enable_success=true
  for svc in "${services[@]}"; do
    if ! sudo systemctl enable --now "$svc" >>"$INSTALL_LOG" 2>&1; then
      log_error "Failed to enable $svc service"
      enable_success=false
    else
      log_success "Enabled $svc service"
    fi
  done
  
  if [[ "$enable_success" == true ]]; then
    log_success "All essential services enabled successfully."
  else
    log_error "Some services failed to enable"
  fi

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
  
  # Install base Mesa first (needed for all GPU types)
  install_packages_quietly mesa lib32-mesa

  if lspci | grep -Eiq 'vga.*amd|3d.*amd|display.*amd'; then
    echo -e "${THEME_TEXT}AMD GPU detected. Installing AMD drivers and Vulkan support...${RESET}"
    install_packages_quietly xf86-video-amdgpu vulkan-radeon lib32-vulkan-radeon
    log_success "AMD drivers and Vulkan support installed"
    log_info "AMD GPU will use AMDGPU driver after reboot"
  elif lspci | grep -Eiq 'vga.*intel|3d.*intel|display.*intel'; then
    echo -e "${THEME_TEXT}Intel GPU detected. Installing Intel drivers and Vulkan support...${RESET}"
    install_packages_quietly vulkan-intel lib32-vulkan-intel
    log_success "Intel drivers and Vulkan support installed"
    log_info "Intel GPU will use i915 or xe driver after reboot"
  elif lspci | grep -Eiq 'vga.*nvidia|3d.*nvidia|display.*nvidia'; then
    configure_nvidia_drivers
  else
    echo -e "${THEME_WARN}No AMD, Intel or NVIDIA GPU detected. Using basic Mesa drivers already installed.${RESET}"
  fi

  # Verify GPU driver is loaded
  verify_gpu_driver
}

# NVIDIA proprietary driver setup (opt-in — user confirms before anything is installed)
configure_nvidia_drivers() {
  ui_info "NVIDIA GPU detected."
  log_warning "NVIDIA proprietary drivers are opt-in because they can complicate a rolling-release system"

  if ! gum_confirm "Install NVIDIA proprietary drivers (nvidia-open)?" "Recommended for Turing (GTX 16xx) and newer. Skip if unsure or on an older GPU — nouveau will be kept."; then
    log_info "NVIDIA driver installation skipped by user — keeping nouveau"
    return 0
  fi

  local nvidia_pkg="nvidia-open" nvidia_kernel_pkg=""

  # Match kernel variant to the installed one so the module matches the running kernel
  if pacman -Q linux-lts &>/dev/null && ! pacman -Q linux &>/dev/null; then
    nvidia_kernel_pkg="nvidia-open-lts"
  fi

  ui_info "Installing NVIDIA drivers and Vulkan support..."
  if [ -n "$nvidia_kernel_pkg" ]; then
    install_packages_quietly "$nvidia_kernel_pkg" nvidia-utils lib32-nvidia-utils egl-wayland
  else
    install_packages_quietly "$nvidia_pkg" nvidia-utils lib32-nvidia-utils egl-wayland
  fi

  if [ $? -ne 0 ]; then
    log_error "NVIDIA driver installation failed — system will keep using nouveau"
    return 1
  fi

  enable_nvidia_drm_mode_setting

  log_success "NVIDIA drivers installed (open kernel modules)"
  log_warning "A reboot is required for the NVIDIA driver to take effect"
}

# DRM kernel mode setting is required for Wayland with the proprietary driver.
enable_nvidia_drm_mode_setting() {
  local cmdline_conf="/etc/cmdline.d/nvidia-drm.conf"
  local mkinitcpio_conf="/etc/mkinitcpio.conf"

  # Path 1: systemd.kernel-install / UKI systems read /etc/kernel/cmdline or /etc/cmdline.d
  if [ -f /etc/kernel/cmdline ] || [ -f /etc/kernel/cmdline.d ]; then
    if ! grep -q 'nvidia-drm.modeset' /etc/kernel/cmdline 2>/dev/null; then
      sudo mkdir -p /etc/cmdline.d
      echo 'kernel_cmdline+=("nvidia-drm.modeset=1")' | sudo tee "$cmdline_conf" >/dev/null
      log_success "Added nvidia-drm.modeset=1 via /etc/cmdline.d"
    fi
  fi

  # Path 2: GRUB
  if [ -f /etc/default/grub ]; then
    if ! grep -q 'nvidia-drm.modeset' /etc/default/grub; then
      sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 nvidia-drm.modeset=1"/' /etc/default/grub
      if command -v grub-mkconfig >/dev/null 2>&1; then
        sudo grub-mkconfig -o /boot/grub/grub.cfg >>"$INSTALL_LOG" 2>&1 || log_warning "Failed to regenerate grub.cfg — run it manually after reboot"
      fi
      log_success "Added nvidia-drm.modeset=1 to GRUB"
    fi
  fi

  # Path 3: mkinitcpio MODULES — ensures KMS starts early enough for Wayland
  if [ -f "$mkinitcpio_conf" ]; then
    if ! grep -q '^MODULES=.*nvidia' "$mkinitcpio_conf"; then
      sudo sed -i 's/^MODULES=(\([^)]*\))/MODULES=(\1 nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' "$mkinitcpio_conf"
      log_success "Added NVIDIA modules to mkinitcpio for early KMS"
      if command -v mkinitcpio >/dev/null 2>&1; then
        sudo mkinitcpio -P >>"$INSTALL_LOG" 2>&1 || log_warning "mkinitcpio regeneration failed — run 'sudo mkinitcpio -P' manually"
      fi
    fi
  fi
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
    # Guard: cpu family can be missing on some VMs/ARM — treat as modern
    if [[ "$cpu_family" =~ ^[0-9]+$ ]] && [ "$cpu_family" -lt "23" ]; then  # Family 23+ is Zen and newer
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

  setup_zram "$ram_gb"

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

# Set up zram swap via zram-generator. Gives low-RAM systems breathing room
# and benefits all systems (compressed in-memory swap is faster than disk).
setup_zram() {
  local ram_gb="$1"

  # Skip if the system already has real swap configured — don't fight the user's setup
  if lsblk -rno TYPE 2>/dev/null | grep -q '^swap$'; then
    log_info "Disk swap already configured — skipping zram setup"
    return 0
  fi

  if ! command -v zramctl >/dev/null 2>&1 && ! pacman -Q zram-generator &>/dev/null; then
    install_packages_quietly zram-generator || {
      log_warning "Could not install zram-generator — skipping zram setup"
      return 0
    }
  fi

  # Size: half of RAM, capped at 8G (rule of thumb for modern systems with fast CPUs)
  local zram_size_mb=$(( ram_gb * 1024 / 2 ))
  [ "$zram_size_mb" -gt 8192 ] && zram_size_mb=8192
  [ "$zram_size_mb" -lt 1024 ] && zram_size_mb=1024

  if [ ! -f /etc/systemd/zram-generator.conf ]; then
    sudo tee /etc/systemd/zram-generator.conf >/dev/null <<EOF
# Generated by archinstaller
[zram0]
zram-size = ${zram_size_mb}M
compression-algorithm = zstd
EOF
    sudo systemctl daemon-reload >>"$INSTALL_LOG" 2>&1 || true
    sudo systemctl start systemd-zram-setup@zram0.service >>"$INSTALL_LOG" 2>&1 || true
    log_success "zram configured: ${zram_size_mb}MB with zstd compression"
  else
    log_info "zram-generator.conf already exists — skipping"
  fi
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
  step "Setting up audio system"

  # Install unconditionally: during installation no user session is running,
  # so runtime detection always reports "nothing detected" on a fresh system.
  # PipeWire is the standard on modern Plasma and replaces PulseAudio entirely.
  if pacman -Q pulseaudio &>/dev/null; then
    log_info "PulseAudio detected — PipeWire stack will replace it (pipewire-pulse takes over)"
    install_packages_quietly pipewire wireplumber pipewire-alsa pipewire-jack pipewire-pulse
    # Remove PulseAudio so both don't fight over the audio socket.
    # pulseaudio-alsa is a config shim pointing at pipewire/pulse — safe to remove with it.
    # -Rdd is needed because pipewire-pulse Provides/Conflicts with pulseaudio;
    # removing the dep-cycle strictly would also try to remove pipewire-packetry.
    sudo pacman -Rdd --noconfirm pulseaudio pulseaudio-alsa >>"$INSTALL_LOG" 2>&1 || \
      sudo pacman -Rns --noconfirm pulseaudio >>"$INSTALL_LOG" 2>&1 || true
    log_success "PipeWire installed and PulseAudio removed"
  else
    install_packages_quietly pipewire wireplumber pipewire-alsa pipewire-jack pipewire-pulse
    log_success "PipeWire audio stack installed"
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

        if ! gum_confirm "Continue on battery power?"; then
          log_error "Installation cancelled - please connect AC adapter"
          exit 1
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
    if lsusb 2>/dev/null | grep -iE "(bluetooth|broadcom|intel|realtek).*bluetooth" >>"$INSTALL_LOG" 2>&1; then
      bluetooth_detected=true
      detection_methods+=("USB device")
    fi
  fi
  
  # Method 3: PCI devices (internal cards, PCIe adapters)
  if command -v lspci >/dev/null 2>&1; then
    if lspci 2>/dev/null | grep -iE "(bluetooth|broadcom|intel|realtek).*bluetooth" >>"$INSTALL_LOG" 2>&1; then
      bluetooth_detected=true
      detection_methods+=("PCI device")
    fi
  fi
  
  # Method 4: Check for bluetooth kernel modules
  if lsmod 2>/dev/null | grep -iE "(btusb|bluetooth)" >>"$INSTALL_LOG" 2>&1; then
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
      gum style --foreground "$GUM_ERROR" --border thick --padding "1 2" \
        "  No Bluetooth hardware detected in your system" \
        "  Check if Bluetooth adapter is properly connected" \
        "  Bluetooth packages installed but service will not be started"
      echo ""
    else
      echo ""
      echo -e "${THEME_ERROR}  No Bluetooth hardware detected in your system${RESET}"
      echo -e "${THEME_ERROR}  Check if Bluetooth adapter is properly connected${RESET}"
      echo -e "${THEME_ERROR}  Bluetooth packages installed but service will not be started${RESET}"
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
    local kernels_ok=true
    for k in linux-zen linux-lts; do
      [ -f "/boot/vmlinuz-$k" ] || kernels_ok=false
    done
    if $kernels_ok; then
      sudo mkinitcpio -P 2>>"$INSTALL_LOG" && log_success "Initramfs regenerated for gaming P-State"
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
      sudo mkinitcpio -P 2>>"$INSTALL_LOG" && log_success "Initramfs regenerated for system P-State"
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
  else
    echo ""
    log_warning "Laptop-specific optimizations available for $(echo $manufacturer | tr '[:lower:]' '[:upper]') $laptop_model:"
    ui_info "CPU-specific optimizations ($(echo $cpu_vendor | tr '[:lower:]' '[:upper]'))"

    # Show manufacturer-specific optimizations
    for opt in "${manufacturer_opts[@]}"; do
      ui_info "  • $opt"
    done

    echo ""
    if gum_confirm "Enable laptop optimizations?" "Tip: Set AUTO_LAPTOP_OPTS=true to skip this prompt in future."; then
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
  
  # Idempotent upsert: replace existing keys instead of appending duplicates
  # on re-runs (tee -a grows the file unboundedly)
  local sysctl_conf="/etc/sysctl.d/99-archinstaller.conf"
  set_sysctl_key() {
    local key="$1" value="$2"
    if sudo grep -q "^${key}=" "$sysctl_conf" 2>/dev/null; then
      sudo sed -i "s|^${key}=.*|${key}=${value}|" "$sysctl_conf"
    else
      echo "${key}=${value}" | sudo tee -a "$sysctl_conf" >/dev/null
    fi
  }
  set_sysctl_key "net.core.default_qdisc" "fq_codel"
  set_sysctl_key "net.ipv4.tcp_congestion_control" "bbr"
  set_sysctl_key "vm.swappiness" "10"
  set_sysctl_key "vm.vfs_cache_pressure" "50"

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
setup_laptop_optimizations
