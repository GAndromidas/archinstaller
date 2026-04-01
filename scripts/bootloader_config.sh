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
    # Remove zen kernel configuration from gaming_mode.sh to avoid duplication
  if [[ "$is_gaming_mode" == "true" && "$zen_kernel_installed" == "true" ]]; then
    ui_info "Zen kernel configuration handled in step 8 - removing from gaming mode"
    # Remove any zen kernel configuration that might have been set by gaming_mode.sh
    if [[ -f "/boot/loader/entries/linux-zen.conf" ]]; then
      ui_info "Updating existing zen kernel entry with optimized settings"
    fi
  else
    ui_info "Standard bootloader configuration applied"
  fi
    # Keep original behavior for standard mode or when zen kernel exists without gaming mode
      sudo sed -i \
        -e '/^default /d' \
        -e '1i default @saved' \
        /boot/loader/loader.conf
      ui_info "Keeping default boot behavior (not gaming mode or zen kernel not installed)"
    fi
    
    # Set timeout 3 for gaming mode, 5s for standard mode
    if [[ "$is_gaming_mode" == "true" ]]; then
      sudo sed -i \
        -e 's/^timeout.*/timeout 3/' \
        -e 's/^[#]*console-mode[[:space:]]\+.*/console-mode max/' \
        /boot/loader/loader.conf
      ui_info "Set timeout to 3s and console-mode to max for gaming"
    else
      sudo sed -i \
        -e 's/^timeout.*/timeout 5/' \
        -e 's/^[#]*console-mode[[:space:]]\+.*/console-mode keep/' \
        /boot/loader/loader.conf
      ui_info "Set timeout to 5s and console-mode to keep for standard mode"
    fi
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
    step "Configuring GRUB"

    # Smart GRUB configuration based on mode
    if [[ "$is_gaming_mode" == "true" && "$zen_kernel_installed" == "true" ]]; then
      step "Configuring GRUB for Gaming Mode with Zen Kernel"
      # Set zen kernel as default for gaming
      sudo sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=0/' /etc/default/grub || echo 'GRUB_DEFAULT=0' | sudo tee -a /etc/default/grub >/dev/null
      ui_info "Set GRUB to boot first kernel (Zen) for gaming"
    else
      step "Configuring GRUB: set default kernel to 'linux'"
      # Use saved/default behavior for standard mode
      sudo sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub || echo 'GRUB_DEFAULT=saved' | sudo tee -a /etc/default/grub >/dev/null
      ui_info "Using standard GRUB configuration (not gaming mode or zen kernel not installed)"
    fi

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

    # Determine main kernel and secondary kernels
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

# --- Limine Bootloader Configuration (Simple Implementation) ---
configure_limine_basic() {
  step "Configuring Limine bootloader"
  
  # Use standard limine.conf location that works with limine-snapper-sync
  local limine_config="/boot/limine.conf"
  
  # Create simple configuration
  log_info "Creating simple Limine configuration at: $limine_config"
  
  # Backup existing configuration
  if [ -f "$limine_config" ]; then
    log_info "Backing up existing limine.conf..."
    sudo cp "$limine_config" "${limine_config}.backup.$(date +%Y%m%d_%H%M%S)"
  fi
  
  # Get root filesystem information
  local root_uuid=""
  root_uuid=$(findmnt -n -o UUID / 2>/dev/null || echo "")
  
  if [ -z "$root_uuid" ]; then
    log_error "Could not determine root UUID"
    return 1
  fi
  
  # Build kernel command line
  local cmdline="root=UUID=$root_uuid rw quiet splash loglevel=3 systemd.show_status=auto rd.udev.log_level=3"
  
  # Add filesystem-specific options
  local root_fstype=$(findmnt -n -o FSTYPE / 2>/dev/null || echo "")
  case "$root_fstype" in
    btrfs)
      local root_subvol=$(findmnt -n -o OPTIONS / | grep -o 'subvol=[^,]*' | cut -d= -f2 || echo "/@")
      cmdline="$cmdline rootflags=subvol=$root_subvol"
      ;;
    ext4)
      cmdline="$cmdline rootflags=relatime"
      ;;
  esac
  
  # Create simple limine.conf
  cat << EOF | sudo tee "$limine_config" > /dev/null
# Limine Bootloader Configuration
# Generated by archinstaller

timeout: 3
interface_resolution: 1024x768

EOF
  
  # Add kernels in smart order (Zen first for gaming mode ONLY)
  local kernels_added=()
  
  # Zen kernel first if gaming mode AND zen kernel installed
  if [[ "$is_gaming_mode" == "true" && "$zen_kernel_installed" == "true" ]]; then
    if [[ -f "/boot/vmlinuz-linux-zen" ]] && [[ -f "/boot/initramfs-linux-zen.img" ]]; then
      cat << EOF | sudo tee -a "$limine_config" > /dev/null

Arch Linux (Zen Kernel)
protocol: linux
path: boot():/vmlinuz-linux-zen
cmdline: $cmdline
module_path: boot():/initramfs-linux-zen.img
EOF
      kernels_added+=("zen")
      ui_info "Added Zen kernel entry to Limine (gaming mode)"
    fi
  fi
  
  # Standard kernel (always added)
  if [[ -f "/boot/vmlinuz-linux" ]] && [[ -f "/boot/initramfs-linux.img" ]]; then
    cat << EOF | sudo tee -a "$limine_config" > /dev/null

Arch Linux
protocol: linux
path: boot():/vmlinuz-linux
cmdline: $cmdline
module_path: boot():/initramfs-linux.img
EOF
    kernels_added+=("standard")
    ui_info "Added standard kernel entry to Limine"
  fi
  
  # Add LTS kernel entry if available
  if [[ -f "/boot/vmlinuz-linux-lts" ]] && [[ -f "/boot/initramfs-linux-lts.img" ]]; then
    cat << EOF | sudo tee -a "$limine_config" > /dev/null

Arch Linux (LTS)
protocol: linux
path: boot():/vmlinuz-linux-lts
cmdline: $cmdline
module_path: boot():/initramfs-linux-lts.img
EOF
  fi
  
  # Simple Windows detection (no complex logic)
  for disk in /dev/sda /dev/sdb /dev/nvme0n1p1; do
    if [ -b "$disk" ] && sudo file -s "$disk" 2>/dev/null | grep -q "NTFS"; then
      cat << EOF | sudo tee -a "$limine_config" > /dev/null

/Windows
protocol: chainloader
path: chainloader():$disk
driver: chainloader
EOF
      log_success "Added Windows entry: $disk"
      break
    fi
  done
  
  if [[ "$is_gaming_mode" == "true" && "$zen_kernel_installed" == "true" ]]; then
    log_success "GRUB configured for Gaming Mode with Zen kernel as default"
  else
    log_success "GRUB configured to remember the last chosen boot entry."
  fi
  log_info "Configuration file: $limine_config"
  log_info "Kernels configured: ${kernels_added[*]}"
  log_warning "Note: Snapshot support removed for stability - use GRUB or systemd-boot for snapshots"
}

# --- Console Font Setup ---
setup_console_font() {
  run_step "Installing console font" sudo pacman -S --noconfirm --needed terminus-font
  run_step "Configuring /etc/vconsole.conf" bash -c "(grep -q '^FONT=' /etc/vconsole.conf 2>/dev/null && sudo sed -i 's/^FONT=.*/FONT=ter-v16n/' /etc/vconsole.conf) || echo 'FONT=ter-v16n' | sudo tee -a /etc/vconsole.conf >/dev/null"
  run_step "Rebuilding initramfs" sudo mkinitcpio -P
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
