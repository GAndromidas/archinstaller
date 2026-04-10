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
    
    # Check for any of our target parameters to determine if update is needed
    local needs_update=false
    if ! grep -q "quiet" "$entry" || ! grep -q "loglevel=3" "$entry" || ! grep -q "systemd.show_status=auto" "$entry" || ! grep -q "rd.udev.log_level=3" "$entry"; then
      needs_update=true
    fi
    
    if [ "$needs_update" = true ]; then
      # Backup the entry before modification
      sudo cp "$entry" "${entry}.backup.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
      
      # Remove existing parameters if they exist, then add all parameters
      sudo sed -i 's/quiet//g; s/loglevel=[^ ]*//g; s/systemd\.show_status=[^ ]*//g; s/rd\.udev\.log_level=[^ ]*//g' "$entry"
      sudo sed -i 's/  */ /g; s/^ *//; s/ *$//' "$entry" # Clean up extra spaces
      
      # Add parameters to options line
      if sudo sed -i '/^options / s/$/ quiet loglevel=3 systemd.show_status=auto rd.udev.log_level=3/' "$entry"; then
        log_success "Updated kernel parameters in $entry_name"
        ((modified_count++))
      else
        log_error "Failed to add kernel parameters to $entry_name"
        # Continue to try other entries, but log the error
      fi
    else
      log_info "All kernel parameters already present in $entry_name - skipping."
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
    # Always apply optimal timeout and console-mode settings (independent of kernel choice)
    set_loader_config "timeout" "3"
    set_loader_config "console-mode" "max"
    ui_info "Set timeout to 3s and console-mode to max (optimal settings)"
    
    # Note: Default kernel setting is handled by gaming_mode.sh when Zen kernel is installed
    ui_info "Default kernel setting managed by gaming mode configuration"
  else
    log_warning "loader.conf not found. Skipping loader.conf configuration for systemd-boot."
  fi

  run_step "Removing systemd-boot fallback entries" sudo rm -f /boot/loader/entries/*fallback.conf
}

# --- Bootloader and Btrfs detection ---
BOOTLOADER=$(detect_bootloader)
IS_BTRFS=$(is_btrfs_system && echo "true" || echo "false")

# Helper function to safely set GRUB configuration values
set_grub_config() {
    local key="$1"
    local value="$2"
    local grub_config="/etc/default/grub"
    
    if grep -q "^${key}=" "$grub_config" 2>/dev/null; then
        sudo sed -i "s/^${key}=.*/${key}=${value}/" "$grub_config"
    else
        echo "${key}=${value}" | sudo tee -a "$grub_config" >/dev/null
    fi
}

# Helper function to safely set systemd-boot loader.conf values
set_loader_config() {
    local key="$1"
    local value="$2"
    local loader_config="/boot/loader/loader.conf"
    
    if [ ! -f "$loader_config" ]; then
        log_warning "loader.conf not found, cannot set configuration"
        return 1
    fi
    
    # Create backup before making changes
    cp "$loader_config" "${loader_config}.backup.$(date +%Y%m%d_%H%M%S)" || true
    
    # Check if key exists (including commented versions)
    if grep -q "^[#]*${key}[[:space:]]" "$loader_config" 2>/dev/null; then
        # Replace existing key (whether commented or not)
        sudo sed -i "s/^[#]*${key}[[:space:]].*/${key} ${value}/" "$loader_config"
    else
        # Add new key at the end
        echo "${key} ${value}" | sudo tee -a "$loader_config" >/dev/null
    fi
}

# --- GRUB configuration ---
configure_grub() {
    step "Configuring GRUB"

    # Always set optimal timeout regardless of kernel choice
    set_grub_config "GRUB_TIMEOUT" "3"
    ui_info "Set GRUB timeout to 3 seconds (optimal setting)"
    
    # Always use saved entry behavior (kernel default handled by gaming_mode.sh)
    step "Configuring GRUB: set saved entry as default"
    set_grub_config "GRUB_DEFAULT" "saved"
    ui_info "Set saved entry as default boot entry"
    ui_info "Note: Zen kernel default setting handled by gaming mode when installed"

    set_grub_config "GRUB_SAVEDEFAULT" "true"
    set_grub_config "GRUB_CMDLINE_LINUX_DEFAULT" '"quiet splash loglevel=3 systemd.show_status=auto rd.udev.log_level=3 plymouth.ignore-serial-consoles"'
    set_grub_config "GRUB_DISABLE_SUBMENU" "notlinux"
    set_grub_config "GRUB_GFXMODE" "auto"
    set_grub_config "GRUB_GFXPAYLOAD_LINUX" "keep"

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

    # Regenerate grub.cfg only if changes were made
    local grub_config="/etc/default/grub"
    local grub_cfg="/boot/grub/grub.cfg"
    local backup_grub_config="${grub_config}.backup.$(date +%Y%m%d_%H%M%S)"
    
    # Create backup before regenerating
    if [ -f "$grub_config" ]; then
        cp "$grub_config" "$backup_grub_config" || true
    fi
    
    # Only regenerate if grub config exists
    if [ -f "$grub_config" ]; then
        ui_info "Regenerating GRUB configuration..."
        if sudo grub-mkconfig -o "$grub_cfg" >/dev/null 2>&1; then
            log_success "GRUB configuration regenerated successfully"
        else
            log_error "grub-mkconfig failed"
            # Restore backup if regeneration failed
            if [ -f "$backup_grub_config" ]; then
                sudo mv "$backup_grub_config" "$grub_config" || true
            fi
            return 1
        fi
    else
        log_warning "GRUB config file not found, skipping regeneration"
        return 1
    fi

    if pacman -Qi linux-zen &>/dev/null; then
        log_success "GRUB configured with Zen kernel as default"
    else
        log_success "GRUB configured to remember the last chosen boot entry."
    fi
}

# --- Limine Bootloader Configuration (Idempotent Implementation) ---
configure_limine_basic() {
  step "Configuring Limine bootloader"
  
  # Use standard limine.conf location that works with limine-snapper-sync
  local limine_config="/boot/limine.conf"
  
  # Create simple configuration
  log_info "Creating idempotent Limine configuration at: $limine_config"
  
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
  
  # Create complete limine.conf atomically
  {
    cat << EOF
# Limine Bootloader Configuration
# Generated by archinstaller on $(date)
# Root UUID: $root_uuid
# Filesystem: $root_fstype

timeout: 3
interface_resolution: 1024x768

EOF
    
    # Add kernels in smart order (Zen first if installed)
    local kernels_added=()
    
    # Zen kernel first if installed (from gaming_mode.sh script)
    if pacman -Qi linux-zen &>/dev/null; then
      if [[ -f "/boot/vmlinuz-linux-zen" ]] && [[ -f "/boot/initramfs-linux-zen.img" ]]; then
        cat << EOF

Arch Linux (Zen Kernel)
protocol: linux
path: boot():/vmlinuz-linux-zen
cmdline: $cmdline
module_path: boot():/initramfs-linux-zen.img
EOF
        kernels_added+=("zen")
        ui_info "Added Zen kernel entry to Limine"
      fi
    fi
    
    # Standard kernel (always added)
    if [[ -f "/boot/vmlinuz-linux" ]] && [[ -f "/boot/initramfs-linux.img" ]]; then
      cat << EOF

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
      cat << EOF

Arch Linux (LTS)
protocol: linux
path: boot():/vmlinuz-linux-lts
cmdline: $cmdline
module_path: boot():/initramfs-linux-lts.img
EOF
    fi
    
    # Enhanced Windows detection with more disk paths
    local windows_found=false
    for disk in /dev/sda1 /dev/sdb1 /dev/sdc1 /dev/nvme0n1p1 /dev/nvme1n1p1; do
      if [ -b "$disk" ] && sudo file -s "$disk" 2>/dev/null | grep -q "NTFS"; then
        cat << EOF

/Windows
protocol: chainloader
path: chainloader():$disk
driver: chainloader
EOF
        log_success "Added Windows entry: $disk"
        windows_found=true
        break
      fi
    done
    
    if [ "$windows_found" = false ]; then
      log_info "No Windows partition detected"
    fi
    
  } | sudo tee "$limine_config" > /dev/null
  
  if pacman -Qi linux-zen &>/dev/null; then
    log_success "Limine configured with Zen kernel prioritized"
  else
    log_success "Idempotent Limine configuration completed"
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
