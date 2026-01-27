#!/bin/bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

configure_limine() {
  # Simple limine.conf detection (same as GRUB/systemd-boot pattern)
  local limine_config=""
  for limine_loc in "/boot/limine/limine.conf" "/boot/limine.conf" "/boot/EFI/limine/limine.conf" "/efi/limine/limine.conf"; do
    if [ -f "$limine_loc" ]; then
      limine_config="$limine_loc"
      break
    fi
  done

  if [ -z "$limine_config" ]; then
    log_warning "limine.conf not found. Skipping Limine configuration."
    return 0
  fi

  log_info "Configuring Limine bootloader"

  # Set timeout to 3 seconds (Limine format uses 'timeout: 3')
  if grep -q "^timeout:" "$limine_config"; then
    sudo sed -i 's/^timeout:.*/timeout: 3/' "$limine_config"
  else
    # Find the first line and insert timeout after it
    sudo sed -i '1i timeout: 3' "$limine_config"
  fi

  log_success "Limine bootloader configured"
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
    # Only configure Plymouth for Limine (snapshots handled in maintenance step)
    if command -v plymouth-set-default-theme >/dev/null 2>&1; then
        run_step "Adding Plymouth parameters to Limine entries" add_plymouth_to_limine
    fi
else
    log_warning "No bootloader detected or bootloader is unsupported. Defaulting to systemd-boot configuration."
    configure_boot
fi

setup_console_font

# --- Simple Plymouth for Limine ---
add_plymouth_to_limine() {
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
  
  # Add Plymouth parameters to cmdline entries
  if grep "^[[:space:]]*cmdline:" "$limine_config" | grep -qv "splash"; then
    sudo sed -i '/^[[:space:]]*cmdline:/ { /splash/! s/$/ splash/ }' "$limine_config"
    ((modified_count++))
    log_success "Added 'splash' to Limine cmdline parameters"
  else
    log_info "Splash parameter already present in Limine configuration"
  fi
  
  # Add quiet parameter if missing
  if grep "^[[:space:]]*cmdline:" "$limine_config" | grep -qv "quiet"; then
    sudo sed -i '/^[[:space:]]*cmdline:/ { /quiet/! s/splash/quiet splash/ }' "$limine_config"
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
    log_success "Plymouth configuration added to Limine bootloader ($modified_count changes)"
  else
    log_info "Plymouth parameters already present in Limine configuration"
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

  
