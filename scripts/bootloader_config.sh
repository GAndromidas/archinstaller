#!/bin/bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# --- systemd-boot ---
add_systemd_boot_kernel_params() {
  local boot_entries_dir="/boot/loader/entries"
  if [ ! -d "$boot_entries_dir" ]; then
    log_warning "Boot entries directory not found. Skipping kernel parameter addition for systemd-boot."
    return 0 # Not an error that should stop the script
  fi

  local modified_count=0
  local entries_found=0

  # Find non-fallback .conf files and process them
  while IFS= read -r -d $'\0' entry; do
    ((entries_found++))
    local entry_name=$(basename "$entry")
    if ! grep -q "quiet loglevel=3" "$entry"; then # Check for existing parameters more generically
      if sudo sed -i '/^options / s/$/ quiet loglevel=3 systemd.show_status=auto rd.udev.log_level=3/' "$entry"; then
        log_success "Added kernel parameters to $entry_name"
        ((modified_count++))
      else
        log_error "Failed to add kernel parameters to $entry_name"
        # Continue to try other entries, but log the error
      fi
    else
      log_info "Kernel parameters already present in $entry_name - skipping."
    fi
  done < <(find "$boot_entries_dir" -name "*.conf" ! -name "*fallback.conf" -print0)

  if [ "$entries_found" -eq 0 ]; then
    log_warning "No systemd-boot entries found to modify."
  elif [ "$modified_count" -gt 0 ]; then
    log_success "Kernel parameters updated for $modified_count systemd-boot entries."
  else
    log_info "No systemd-boot entries needed parameter updates."
  fi
  return 0
}

# --- systemd-boot ---
configure_boot() {
  run_step "Adding kernel parameters to systemd-boot entries" add_systemd_boot_kernel_params

  if [ -f "/boot/loader/loader.conf" ]; then
    sudo sed -i \
      -e '/^default /d' \
      -e '1i default @saved' \
      -e 's/^timeout.*/timeout 3/' \
      -e 's/^[#]*console-mode[[:space:]]\+.*/console-mode max/' \
      /boot/loader/loader.conf

    run_step "Ensuring timeout is set in loader.conf" \
        grep -q '^timeout' /boot/loader/loader.conf || echo "timeout 3" | sudo tee -a /boot/loader/loader.conf >/dev/null
    run_step "Ensuring console-mode is set in loader.conf" \
        grep -q '^console-mode' /boot/loader/loader.conf || echo "console-mode max" | sudo tee -a /boot/loader/loader.conf >/dev/null
  else
    log_warning "loader.conf not found. Skipping loader.conf configuration for systemd-boot."
  fi

  run_step "Removing systemd-boot fallback entries" sudo rm -f /boot/loader/entries/*fallback.conf
}

# --- Bootloader and Btrfs detection ---
BOOTLOADER=$(detect_bootloader)
IS_BTRFS=$(is_btrfs_system && echo "true" || echo "false")

# --- GRUB configuration ---
configure_grub() {
    step "Configuring GRUB: set default kernel to 'linux'"

    # /etc/default/grub settings
    sudo sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=3/' /etc/default/grub || echo 'GRUB_TIMEOUT=3' | sudo tee -a /etc/default/grub >/dev/null
    sudo sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub || echo 'GRUB_DEFAULT=saved' | sudo tee -a /etc/default/grub >/dev/null
    grep -q '^GRUB_SAVEDEFAULT=' /etc/default/grub && sudo sed -i 's/^GRUB_SAVEDEFAULT=.*/GRUB_SAVEDEFAULT=true/' /etc/default/grub || echo 'GRUB_SAVEDEFAULT=true' | sudo tee -a /etc/default/grub >/dev/null
    sudo sed -i 's@^GRUB_CMDLINE_LINUX_DEFAULT=.*@GRUB_CMDLINE_LINUX_DEFAULT="quiet splash loglevel=3 systemd.show_status=auto rd.udev.log_level=3 plymouth.ignore-serial-consoles"@' /etc/default/grub || \
        echo 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash loglevel=3 systemd.show_status=auto rd.udev.log_level=3 plymouth.ignore-serial-consoles"' | sudo tee -a /etc/default/grub >/dev/null

    # Enable submenu for additional kernels (linux-lts, linux-zen)
    grep -q '^GRUB_DISABLE_SUBMENU=' /etc/default/grub && sudo sed -i 's/^GRUB_DISABLE_SUBMENU=.*/GRUB_DISABLE_SUBMENU=notlinux/' /etc/default/grub || \
        echo 'GRUB_DISABLE_SUBMENU=notlinux' | sudo tee -a /etc/default/grub >/dev/null

    grep -q '^GRUB_GFXMODE=' /etc/default/grub || echo 'GRUB_GFXMODE=auto' | sudo tee -a /etc/default/grub >/dev/null
    grep -q '^GRUB_GFXPAYLOAD_LINUX=' /etc/default/grub || echo 'GRUB_GFXPAYLOAD_LINUX=keep' | sudo tee -a /etc/default/grub >/dev/null

    # Detect installed kernels
    KERNELS=($(ls /boot/vmlinuz-* 2>/dev/null | sed 's|/boot/vmlinuz-||g'))
    if [[ ${#KERNELS[@]} -eq 0 ]]; then
        log_error "No kernels found in /boot."
        return 1
    fi

    # Determine main kernel and secondary kernels (logic kept for informational purposes, not used for default setting)
    MAIN_KERNEL=""
    SECONDARY_KERNELS=()
    for k in "${KERNELS[@]}"; do
        [[ "$k" == "linux" ]] && MAIN_KERNEL="$k"
        [[ "$k" != "linux" && "$k" != "fallback" && "$k" != "rescue" ]] && SECONDARY_KERNELS+=("$k")
    done
    [[ -z "$MAIN_KERNEL" ]] && MAIN_KERNEL="${KERNELS[0]}"

    # Remove fallback/recovery kernels
    sudo rm -f /boot/initramfs-*-fallback.img /boot/vmlinuz-*-fallback 2>/dev/null || true

    # Regenerate grub.cfg
    sudo grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 || { log_error "grub-mkconfig failed"; return 1; }

    log_success "GRUB configured to remember the last chosen boot entry."
}

# --- Limine Basic Configuration ---
configure_limine_basic() {
  step "Configuring Limine bootloader"
  
  local limine_config=""
  limine_config=$(find_limine_config)
  
  if [ -z "$limine_config" ]; then
    log_error "limine.conf not found in any location"
    return 1
  fi
  
  log_info "Found limine.conf at: $limine_config"
  
  # Set timeout to 3 seconds
  if grep -q "^timeout:" "$limine_config"; then
    sudo sed -i 's/^timeout:.*/timeout: 3/' "$limine_config"
  else
    sudo sed -i '1i timeout: 3' "$limine_config"
  fi
  
  # Add Plymouth kernel parameters (splash, quiet, nowatchdog)
  if grep -q "^[[:space:]]*cmdline:" "$limine_config"; then
    local modified_count=0
    
    # Add splash parameter if missing
    if grep "^[[:space:]]*cmdline:" "$limine_config" | grep -qv "splash"; then
      sudo sed -i '/^[[:space:]]*cmdline:/ { /splash/! s/$/ splash/ }' "$limine_config"
      ((modified_count++))
      log_success "Added 'splash' to Limine cmdline parameters"
    fi
    
    # Add quiet parameter if missing
    if grep "^[[:space:]]*cmdline:" "$limine_config" | grep -qv "quiet"; then
      sudo sed -i '/^[[:space:]]*cmdline:/ { /quiet/! s/$/ quiet/ }' "$limine_config"
      ((modified_count++))
      log_success "Added 'quiet' to Limine cmdline parameters"
    fi
    
    # Add nowatchdog parameter if missing
    if grep "^[[:space:]]*cmdline:" "$limine_config" | grep -qv "nowatchdog"; then
      sudo sed -i '/^[[:space:]]*cmdline:/ { /nowatchdog/! s/$/ nowatchdog/ }' "$limine_config"
      ((modified_count++))
      log_success "Added 'nowatchdog' to Limine cmdline parameters"
    fi
    
    if [ $modified_count -gt 0 ]; then
      log_success "Plymouth parameters added to Limine configuration"
    else
      log_info "Plymouth parameters already present in Limine configuration"
    fi
  else
    log_warning "limine.conf not in modern format - cannot add Plymouth support"
  fi
  
  # Configure limine-snapper-sync to use correct limine.conf path
  if [ "$limine_config" != "/boot/limine.conf" ]; then
    log_info "Creating copy of limine.conf for limine-snapper-sync compatibility..."
    
    # Create copy at /boot/limine.conf for limine-snapper-sync
    sudo cp "$limine_config" "/boot/limine.conf"
    log_success "Created copy: $limine_config -> /boot/limine.conf"
    
    # Configure limine-snapper-sync to use the standard location
    sudo mkdir -p /etc/default
    sudo tee /etc/default/limine > /dev/null << EOF
# limine-snapper-sync configuration
ESP_PATH="/boot"
LIMINE_CONF_PATH="/boot/limine.conf"
EOF
    
    log_success "limine-snapper-sync configured to use: /boot/limine.conf"
  else
    log_info "limine.conf already at standard location - no copy needed"
  fi
  
  # Ensure Plymouth parameters are also in the copy (if different from original)
  if [ "$limine_config" != "/boot/limine.conf" ] && [ -f "/boot/limine.conf" ]; then
    log_info "Ensuring Plymouth parameters in copied limine.conf..."
    
    # Add Plymouth parameters to the copy if missing
    local modified_count=0
    
    if grep -q "^[[:space:]]*cmdline:" "/boot/limine.conf"; then
      if grep "^[[:space:]]*cmdline:" "/boot/limine.conf" | grep -qv "splash"; then
        sudo sed -i '/^[[:space:]]*cmdline:/ { /splash/! s/$/ splash/ }' "/boot/limine.conf"
        ((modified_count++))
      fi
      
      if grep "^[[:space:]]*cmdline:" "/boot/limine.conf" | grep -qv "quiet"; then
        sudo sed -i '/^[[:space:]]*cmdline:/ { /quiet/! s/$/ quiet/ }' "/boot/limine.conf"
        ((modified_count++))
      fi
      
      if grep "^[[:space:]]*cmdline:" "/boot/limine.conf" | grep -qv "nowatchdog"; then
        sudo sed -i '/^[[:space:]]*cmdline:/ { /nowatchdog/! s/$/ nowatchdog/ }' "/boot/limine.conf"
        ((modified_count++))
      fi
      
      if [ $modified_count -gt 0 ]; then
        log_success "Plymouth parameters added to copied limine.conf"
      fi
    fi
  fi
  
  log_success "Limine bootloader configured with Plymouth support"
}

# --- Console Font Setup ---
setup_console_font() {
    run_step "Installing console font" sudo pacman -S --noconfirm --needed terminus-font
    run_step "Configuring /etc/vconsole.conf" bash -c "(grep -q '^FONT=' /etc/vconsole.conf 2>/dev/null && sudo sed -i 's/^FONT=.*/FONT=ter-v16n/' /etc/vconsole.conf) || echo 'FONT=ter-v16n' | sudo tee -a /etc/vconsole.conf >/dev/null"
    run_step "Rebuilding initramfs" sudo mkinitcpio -P
}

# --- Main execution ---
if [ "$BOOTLOADER" = "grub" ]; then
    configure_grub
elif [ "$BOOTLOADER" = "systemd-boot" ]; then
    configure_boot
elif [ "$BOOTLOADER" = "limine" ]; then
    configure_limine_basic
else
    log_warning "No bootloader detected or bootloader is unsupported. Defaulting to systemd-boot configuration."
    configure_boot
fi

setup_console_font
