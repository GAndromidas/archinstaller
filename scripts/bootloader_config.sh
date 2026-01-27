#!/bin/bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

configure_limine() {
  # Smart limine.conf detection with multiple fallback strategies
  local limine_config=""
  local detection_methods=(
    "/boot/limine/limine.conf"        # Most common location (CachyOS/Arch standard)
    "/boot/limine.conf"               # Legacy location
    "/boot/EFI/limine/limine.conf"     # UEFI ESP location
    "/efi/limine/limine.conf"           # Alternative ESP location
    "/boot/loader/limine.conf"          # Alternative bootloader location
  )
  
  # Try each location in order of preference
  for limine_loc in "${detection_methods[@]}"; do
    if [ -f "$limine_loc" ]; then
      limine_config="$limine_loc"
      log_info "Found limine.conf at: $limine_config"
      break
    fi
  done

  # If not found, try to detect via bootctl or filesystem search
  if [ -z "$limine_config" ]; then
    # Try bootctl detection
    if command -v bootctl >/dev/null 2>&1; then
      local esp_path=$(bootctl --print-esp-path 2>/dev/null)
      if [ -n "$esp_path" ] && [ -f "$esp_path/limine/limine.conf" ]; then
        limine_config="$esp_path/limine/limine.conf"
        log_info "Detected limine.conf via bootctl: $limine_config"
      fi
    fi
    
    # Final fallback - search filesystem
    if [ -z "$limine_config" ]; then
      local found_config=$(find /boot /efi /boot/EFI -name "limine.conf" 2>/dev/null | head -n1)
      if [ -n "$found_config" ]; then
        limine_config="$found_config"
        log_info "Found limine.conf via filesystem search: $limine_config"
      fi
    fi
  fi

  if [ -z "$limine_config" ]; then
    log_warning "limine.conf not found in any location. Skipping Limine configuration."
    log_info "Searched locations: $(printf '%s, ' "${detection_methods[@]}" | sed 's/, $//')"
    return 0
  fi

  # Validate the configuration file format
  if ! grep -q "^[[:space:]]*timeout:" "$limine_config" && ! grep -q "^[[:space:]]*cmdline:" "$limine_config"; then
    log_warning "limine.conf appears to be in legacy format. Attempting conversion..."
    create_modern_limine_config "$limine_config"
    return 0
  fi

  log_info "Configuring Limine bootloader"
  
  # Create intelligent backup
  create_smart_backup "$limine_config"

  # Configure with smart parameter detection
  configure_limine_intelligent "$limine_config"
}

# Smart backup function that avoids unnecessary backups
create_smart_backup() {
  local config_file="$1"
  local backup_dir="${config_file}.backups"
  local max_backups=3
  
  # Create backup directory if it doesn't exist
  sudo mkdir -p "$backup_dir"
  
  # Remove old backups if超过限制
  find "$backup_dir" -name "*.backup.*" -type f | sort -r | tail -n +$((max_backups + 1)) | xargs -r sudo rm 2>/dev/null || true
  
  # Create new backup only if config changed
  local latest_backup=$(find "$backup_dir" -name "*.backup.*" -type f -printf '%T@ %p\n' | sort -n | tail -n1 | cut -d' ' -f2-)
  if [ -n "$latest_backup" ]; then
    if ! cmp -s "$config_file" "$latest_backup"; then
      sudo cp "$config_file" "${config_file}.backup.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
      log_debug "Configuration changed - backup created"
    else
      log_debug "Configuration unchanged - backup skipped"
    fi
  else
    sudo cp "$config_file" "${config_file}.backup.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
  fi
}

# Convert legacy limine.conf to modern format
create_modern_limine_config() {
  local legacy_config="$1"
  local modern_config="${legacy_config}.modern"
  
  log_info "Converting legacy limine.conf to modern format..."
  
  # Read and convert the configuration
  {
    echo "timeout: 3"
    echo ""
    
    # Convert APPEND lines to modern entries
    while IFS= read -r line; do
      if [[ "$line" =~ ^APPEND=(.*) ]]; then
        local append_content="${BASH_REMATCH[1]}"
        echo "/Arch Linux"
        echo "    protocol: linux"
        echo "    path: boot():/vmlinuz-linux"
        echo "    cmdline: $append_content"
        echo "    module_path: boot():/initramfs-linux.img"
      fi
    done < "$legacy_config"
    
    echo ""
    echo "//Snapshots"
  } > "$modern_config"
  
  # Backup and replace
  sudo cp "$legacy_config" "${legacy_config}.legacy.backup.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
  sudo mv "$modern_config" "$legacy_config"
  
  log_success "Converted limine.conf to modern format"
}

# Intelligent configuration with parameter detection
configure_limine_intelligent() {
  local limine_config="$1"
  local modified_count=0
  
  # Detect system characteristics for smart configuration
  local has_plymouth=false
  local is_btrfs=false
  local has_gpu=false
  
  # Detect Plymouth installation
  if command -v plymouth-set-default-theme >/dev/null 2>&1 || [ -d "/usr/share/plymouth" ]; then
    has_plymouth=true
  fi
  
  # Detect Btrfs filesystem
  if [ -f "/etc/fstab" ] && grep -q "btrfs" /etc/fstab; then
    is_btrfs=true
  fi
  
  # Detect GPU drivers (for optimization)
  if lsmod | grep -q -E "(nvidia|amdgpu|i915)" 2>/dev/null; then
    has_gpu=true
  fi

  # Configure timeout based on system type
  if grep -q "^timeout:" "$limine_config"; then
    if [ "$has_gpu" = true ]; then
      sudo sed -i 's/^timeout:.*/timeout: 2/' "$limine_config"
      log_debug "Set timeout to 2 seconds (GPU detected for faster boot)"
    else
      sudo sed -i 's/^timeout:.*/timeout: 3/' "$limine_config"
    fi
    ((modified_count++))
  else
    if [ "$has_gpu" = true ]; then
      sudo sed -i '1i timeout: 2' "$limine_config"
    else
      sudo sed -i '1i timeout: 3' "$limine_config"
    fi
    ((modified_count++))
  fi

  # Smart Plymouth configuration
  if [ "$has_plymouth" = true ] && grep -q "^[[:space:]]*cmdline:" "$limine_config"; then
    # Add Plymouth parameters intelligently
    local plymouth_params=""
    
    # Check for missing parameters and add them
    if grep "^[[:space:]]*cmdline:" "$limine_config" | grep -qv "quiet"; then
      plymouth_params="$plymouth_params quiet"
    fi
    
    if grep "^[[:space:]]*cmdline:" "$limine_config" | grep -qv "splash"; then
      plymouth_params="$plymouth_params splash"
    fi
    
    if grep "^[[:space:]]*cmdline:" "$limine_config" | grep -qv "nowatchdog"; then
      plymouth_params="$plymouth_params nowatchdog"
    fi
    
    # Apply Plymouth parameters if any were added
    if [ -n "$plymouth_params" ]; then
      sudo sed -i "/^[[:space:]]*cmdline:/ s/$/$plymouth_params/" "$limine_config"
      ((modified_count++))
      log_success "Added Plymouth parameters: $plymouth_params"
    fi
  fi

  # Smart Btrfs configuration
  if [ "$is_btrfs" = true ]; then
    # Fix subvolume path format
    if grep -q "rootflags=subvol=@" "$limine_config"; then
      sudo sed -i 's/rootflags=subvol=@/rootflags=subvol=\/@/g' "$limine_config"
      ((modified_count++))
      log_debug "Fixed Btrfs subvolume path format"
    fi
    
    # Add machine-id comments for snapshot support
    if ! grep -q "comment: machine-id=" "$limine_config"; then
      if [ -f "/etc/machine-id" ]; then
        local machine_id=$(cat /etc/machine-id)
        sudo sed -i '/^[^[:space:]]/{
          /^[^[:space:]]*\/[^+]/{
            /comment: machine-id=/!i\
    comment: machine-id='$machine_id'
          }
        }' "$limine_config"
        ((modified_count++))
        log_debug "Added machine-id for snapshot targeting"
      else
        # Add empty machine-id placeholder
        sudo sed -i '/^[^[:space:]]/{
          /^[^[:space:]]*\/[^+]/{
            /comment: machine-id=/!i\
    comment: machine-id=
          }
        }' "$limine_config"
        ((modified_count++))
      fi
    fi
    
    # Add snapshots support if limine-snapper-sync is available
    if command -v limine-snapper-sync >/dev/null 2>&1 && ! grep -q "//Snapshots" "$limine_config"; then
      echo "" | sudo tee -a "$limine_config" >/dev/null
      echo "//Snapshots" | sudo tee -a "$limine_config" >/dev/null
      ((modified_count++))
      log_success "Enabled Btrfs snapshot boot entries"
    fi
  fi

  # Cleanup old configuration entries
  if grep -q "^DEFAULT_ENTRY=" "$limine_config"; then
    sudo sed -i '/^DEFAULT_ENTRY=/d' "$limine_config"
    ((modified_count++))
    log_debug "Removed legacy DEFAULT_ENTRY line"
  fi

  # Report results
  if [ $modified_count -gt 0 ]; then
    log_success "Limine intelligently configured ($modified_count optimizations applied)"
    if [ "$has_plymouth" = true ]; then
      log_info "✓ Plymouth support enabled"
    fi
    if [ "$is_btrfs" = true ]; then
      log_info "✓ Btrfs optimization applied"
    fi
    if [ "$has_gpu" = true ]; then
      log_info "✓ GPU-optimized timeout set"
    fi
  else
    log_info "Limine configuration already optimal"
  fi
}

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
    configure_limine
    # Also configure Plymouth specifically for limine if Plymouth was installed
    if command -v plymouth-set-default-theme >/dev/null 2>&1; then
        run_step "Adding Plymouth parameters to Limine entries" add_plymouth_to_limine
    fi
    # Configure snapshots if Btrfs is detected
    if [ "$IS_BTRFS" = "true" ]; then
        run_step "Configuring Limine for Btrfs snapshots" configure_limine_snapshots
    fi
else
    log_warning "No bootloader detected or bootloader is unsupported. Defaulting to systemd-boot configuration."
    configure_boot
fi

setup_console_font

# --- Smart Plymouth for Limine ---
add_plymouth_to_limine() {
  # Verify Plymouth is actually installed
  if ! command -v plymouth-set-default-theme >/dev/null 2>&1 && [ ! -d "/usr/share/plymouth" ]; then
    log_warning "Plymouth not installed - skipping Plymouth configuration"
    return 1
  fi

  # Use smart detection
  local limine_config=""
  for limine_loc in "/boot/limine/limine.conf" "/boot/limine.conf" "/boot/EFI/limine/limine.conf" "/efi/limine/limine.conf"; do
    if [ -f "$limine_loc" ]; then
      limine_config="$limine_loc"
      break
    fi
  done

  if [ -z "$limine_config" ]; then
    log_warning "No limine.conf found for Plymouth configuration"
    return 1
  fi

  # Validate format compatibility
  if ! grep -q "^[[:space:]]*cmdline:" "$limine_config"; then
    log_warning "limine.conf not in modern format - cannot add Plymouth support"
    return 1
  fi

  local modified_count=0
  
  # Intelligent Plymouth parameter addition
  local cmdline_lines=$(grep "^[[:space:]]*cmdline:" "$limine_config")
  local has_splash=false
  local has_quiet=false
  local has_nowatchdog=false
  
  # Analyze current parameters
  while IFS= read -r line; do
    [[ "$line" =~ splash ]] && has_splash=true
    [[ "$line" =~ quiet ]] && has_quiet=true
    [[ "$line" =~ nowatchdog ]] && has_nowatchdog=true
  done <<< "$cmdline_lines"
  
  # Add missing parameters intelligently
  if [ "$has_splash" = false ] || [ "$has_quiet" = false ] || [ "$has_nowatchdog" = false ]; then
    create_smart_backup "$limine_config"
    
    # Build parameter string
    local plymouth_params=""
    [ "$has_quiet" = false ] && plymouth_params="$plymouth_params quiet"
    [ "$has_splash" = false ] && plymouth_params="$plymouth_params splash"
    [ "$has_nowatchdog" = false ] && plymouth_params="$plymouth_params nowatchdog"
    
    # Apply parameters with smart placement
    if [ -n "$plymouth_params" ]; then
      sudo sed -i "/^[[:space:]]*cmdline:/ s/$/$plymouth_params/" "$limine_config"
      ((modified_count++))
      log_success "Added Plymouth parameters: $plymouth_params"
    fi
  else
    log_info "Plymouth parameters already present in all Limine entries"
  fi
  
  # Verify Plymouth theme is set
  local current_theme=$(plymouth-set-default-theme 2>/dev/null | grep -v "^$" | head -n1)
  if [ -z "$current_theme" ]; then
    log_info "Setting Plymouth theme to bgrt"
    sudo plymouth-set-default-theme bgrt -R 2>/dev/null || true
    ((modified_count++))
  fi
  
  if [ $modified_count -gt 0 ]; then
    log_success "Plymouth configuration optimized for Limine ($modified_count changes)"
  fi
}

# --- Smart Snapshots for Limine ---
configure_limine_snapshots() {
  # Verify Btrfs is actually being used
  if ! is_btrfs_system; then
    log_info "Btrfs not detected - skipping snapshot configuration"
    return 0
  fi

  # Verify limine-snapper-sync is available
  if ! command -v limine-snapper-sync >/dev/null 2>&1; then
    log_warning "limine-snapper-sync not installed - installing..."
    if command -v yay >/dev/null 2>&1; then
      yay -S --noconfirm limine-snapper-sync 2>/dev/null || log_warning "Failed to install limine-snapper-sync"
    else
      log_warning "Package manager not available - please install limine-snapper-sync manually"
    fi
  fi

  # Smart detection
  local limine_config=""
  for limine_loc in "/boot/limine/limine.conf" "/boot/limine.conf" "/boot/EFI/limine/limine.conf" "/efi/limine/limine.conf"; do
    if [ -f "$limine_loc" ]; then
      limine_config="$limine_loc"
      break
    fi
  done

  if [ -z "$limine_config" ]; then
    log_warning "No limine.conf found for snapshot configuration"
    return 1
  fi

  # Validate configuration format
  if ! grep -q "^[[:space:]]*cmdline:" "$limine_config"; then
    log_warning "limine.conf not in modern format - cannot configure snapshots"
    return 1
  fi

  local modified_count=0
  
  # Smart backup
  create_smart_backup "$limine_config"

  # Analyze current configuration
  local has_machine_id=false
  local has_snapshots=false
  local subvol_correct=true
  
  if grep -q "comment: machine-id=" "$limine_config"; then
    has_machine_id=true
  fi
  
  if grep -q "//Snapshots" "$limine_config"; then
    has_snapshots=true
  fi
  
  if grep -q "rootflags=subvol=@" "$limine_config"; then
    subvol_correct=false
  fi

  # Fix subvolume path format if needed
  if [ "$subvol_correct" = false ]; then
    sudo sed -i 's/rootflags=subvol=@/rootflags=subvol=\/@/g' "$limine_config"
    ((modified_count++))
    log_debug "Fixed Btrfs subvolume path format"
  fi

  # Add machine-id comments intelligently
  if [ "$has_machine_id" = false ]; then
    if [ -f "/etc/machine-id" ]; then
      local machine_id=$(cat /etc/machine-id)
      if [ -n "$machine_id" ]; then
        sudo sed -i '/^[^[:space:]]/{
          /^[^[:space:]]*\/[^+]/{
            /comment: machine-id=/!i\
    comment: machine-id='$machine_id'
          }
        }' "$limine_config"
        ((modified_count++))
        log_success "Added machine-id: $machine_id for snapshot targeting"
      else
        log_warning "No machine-id found - adding placeholder"
        sudo sed -i '/^[^[:space:]]/{
          /^[^[:space:]]*\/[^+]/{
            /comment: machine-id=/!i\
    comment: machine-id=
          }
        }' "$limine_config"
        ((modified_count++))
      fi
    else
      log_warning "/etc/machine-id not found - adding placeholder"
      sudo sed -i '/^[^[:space:]]/{
        /^[^[:space:]]*\/[^+]/{
          /comment: machine-id=/!i\
    comment: machine-id=
        }
      }' "$limine_config"
      ((modified_count++))
    fi
  else
    log_debug "Machine-id already present"
  fi

  # Add snapshots support
  if [ "$has_snapshots" = false ]; then
    # Check if limine-snapper-sync service is available
    if command -v limine-snapper-sync >/dev/null 2>&1; then
      echo "" | sudo tee -a "$limine_config" >/dev/null
      echo "//Snapshots" | sudo tee -a "$limine_config" >/dev/null
      ((modified_count++))
      log_success "Enabled Btrfs snapshot boot entries"
      
      # Enable and start the service
      if systemctl is-active --quiet limine-snapper-sync; then
        log_debug "limine-snapper-sync service already running"
      else
        sudo systemctl enable --now limine-snapper-sync 2>/dev/null || log_warning "Failed to enable limine-snapper-sync"
      fi
    else
      log_warning "limine-snapper-sync not available - skipping snapshot entries"
    fi
  else
    log_debug "Snapshot support already enabled"
  fi

  # Configure snapper if needed
  if ! snapper list-configs >/dev/null 2>&1 | grep -q "root"; then
    log_info "Creating snapper root configuration..."
    sudo snapper create-config --subvolume="/@/" --fstype="btrfs" root 2>/dev/null || log_warning "Failed to create snapper config"
  fi

  # Optimize for snapshot integration
  local limine_dir=$(dirname "$limine_config")
  if [ -d "$limine_dir" ]; then
    local available_space=$(df "$limine_dir" | awk 'NR==2 {print $4}')
    local space_mb=$((available_space / 1024))
    
    if [ $space_mb -lt 500 ]; then
      log_warning "Low disk space in $limine_dir (${space_mb}MB free) - snapshots may be limited"
    else
      log_debug "Sufficient space in $limine_dir (${space_mb}MB free)"
    fi
  fi

  if [ $modified_count -gt 0 ]; then
    log_success "Smart snapshot configuration completed ($modified_count changes)"
    log_info "✓ Btrfs snapshot integration enabled"
    log_info "✓ Machine-id targeting configured"
    log_info "✓ Subvolume path optimized"
  else
    log_info "Snapshot configuration already optimal"
  fi
}

  
