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
      # Update entry without backup
      
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
  # First, rename any dated kernel entries to simple format
  run_step "Renaming dated kernel entries to simple format" rename_dated_kernel_entries
  
  run_step "Adding kernel parameters to systemd-boot entries" add_systemd_boot_kernel_params

  if [ -f "/boot/loader/loader.conf" ]; then
    # Always apply optimal timeout and console-mode settings (independent of kernel choice)
    set_loader_config "timeout" "3"
    set_loader_config "console-mode" "max"
    ui_info "Set timeout to 3s and console-mode to max (optimal settings)"
    
    # Note: Default kernel setting is handled by gaming_mode.sh when Arch Linux (linux-zen) is installed
    ui_info "Default kernel setting managed by gaming mode configuration"
  else
    log_warning "loader.conf not found. Skipping loader.conf configuration for systemd-boot."
  fi

  # Only sync options if they're inconsistent (don't override Plymouth configuration)
  run_step "Checking kernel options consistency" check_kernel_options_consistency

  run_step "Removing systemd-boot fallback entries" sudo rm -f /boot/loader/entries/*fallback.conf
}

# Check kernel options consistency and only sync if necessary
check_kernel_options_consistency() {
  local entries_dir="/boot/loader/entries"
  
  ui_info "Checking kernel options consistency..."
  
  # Find all kernel entries (excluding fallback)
  local kernel_entries=()
  while IFS= read -r -d $'\0' entry; do
    kernel_entries+=("$entry")
  done < <(find "$entries_dir" -name "*.conf" ! -name "*fallback*" -print0)
  
  if [[ ${#kernel_entries[@]} -eq 0 ]]; then
    log_warning "No kernel entries found to check"
    return 0
  fi
  
  if [[ ${#kernel_entries[@]} -eq 1 ]]; then
    log_info "Only one kernel entry found - consistency check not needed"
    return 0
  fi
  
  # Get options from all entries to check for consistency
  local options_list=()
  local entry_names=()
  
  for entry in "${kernel_entries[@]}"; do
    local entry_name=$(basename "$entry")
    local current_options=$(grep "^options " "$entry" | sed 's/^options //' || echo "")
    options_list+=("$current_options")
    entry_names+=("$entry_name")
  done
  
  # Check if all options are the same
  local first_options="${options_list[0]}"
  local consistent=true
  
  for i in "${!options_list[@]}"; do
    if [[ "${options_list[$i]}" != "$first_options" ]]; then
      consistent=false
      break
    fi
  done
  
  if [[ "$consistent" == true ]]; then
    log_success "All kernel entries already have consistent options"
    log_info "Common options: $first_options"
    
    # Check if splash is present (indicating Plymouth was configured)
    if [[ "$first_options" == *"splash"* ]]; then
      log_info "Plymouth splash parameter detected and consistent across entries"
    fi
  else
    log_warning "Inconsistent kernel options detected across entries"
    log_info "Options vary between entries - this may cause boot issues"
    
    # Show the differences
    for i in "${!entry_names[@]}"; do
      log_info "${entry_names[$i]}: ${options_list[$i]}"
    done
    
    # Handle inconsistent options
    if command -v gum >/dev/null 2>&1; then
      # Interactive mode - ask user
      echo ""
      gum style --foreground 226 "Kernel options are inconsistent across entries"
      gum style --foreground 15 "This may cause boot issues or Plymouth display problems"
      echo ""
      if gum confirm "Sync all kernel entries to use the same options?"; then
        sync_all_kernel_options
      else
        log_warning "Kernel options left inconsistent - manual review recommended"
      fi
    else
      # Non-interactive mode - auto-sync to ensure consistency
      log_warning "Inconsistent kernel options detected - auto-syncing for system stability"
      sync_all_kernel_options
    fi
  fi
}

# Sync kernel options across all kernel entries (only when explicitly requested)
sync_all_kernel_options() {
  local entries_dir="/boot/loader/entries"
  
  ui_info "Syncing kernel options across all entries..."
  
  # Find all kernel entries (excluding fallback)
  local kernel_entries=()
  while IFS= read -r -d $'\0' entry; do
    kernel_entries+=("$entry")
  done < <(find "$entries_dir" -name "*.conf" ! -name "*fallback*" -print0)
  
  if [[ ${#kernel_entries[@]} -eq 0 ]]; then
    log_warning "No kernel entries found to sync"
    return 0
  fi
  
  # Use the first entry as the standard for options
  local standard_entry="${kernel_entries[0]}"
  local standard_options=$(grep "^options " "$standard_entry" | sed 's/^options //' || echo "")
  
  if [[ -z "$standard_options" ]]; then
    log_warning "No options found in standard entry: $(basename "$standard_entry")"
    return 1
  fi
  
  ui_info "Using options from $(basename "$standard_entry") as standard"
  log_info "Standard options: $standard_options"
  
  local updated_count=0
  
  for entry in "${kernel_entries[@]}"; do
    local entry_name=$(basename "$entry")
    
    # Skip the standard entry itself
    if [[ "$entry" == "$standard_entry" ]]; then
      continue
    fi
    
    # Extract current options from the entry
    local current_options=$(grep "^options " "$entry" | sed 's/^options //' || echo "")
    
    # Only update if options are different
    if [[ "$current_options" != "$standard_options" ]]; then
      # Create a temporary file with updated options
      local temp_file=$(mktemp)
      
      # Copy all lines except options, then add new options
      grep -v "^options " "$entry" > "$temp_file"
      echo "options $standard_options" >> "$temp_file"
      
      # Replace the original file
      sudo mv "$temp_file" "$entry"
      
      log_success "Synced options in $entry_name"
      ((updated_count++))
    else
      log_info "Options already consistent in $entry_name"
    fi
  done
  
  if [[ $updated_count -gt 0 ]]; then
    log_success "Synced kernel options in $updated_count entries"
    ui_info "All kernel entries now have identical options"
  else
    log_info "All kernel entries already have consistent options"
  fi
}

# Rename dated kernel entries to simple format (archinstall compatibility)
rename_dated_kernel_entries() {
  local entries_dir="/boot/loader/entries"
  
  if [ ! -d "$entries_dir" ]; then
    log_warning "Boot entries directory not found. Skipping entry renaming."
    return 0
  fi
  
  ui_info "Checking for dated kernel entries to rename to simple format..."
  
  local renamed_count=0
  
  # Find dated kernel entries (pattern: YYYY-MM-DD_kernel.conf)
  local dated_entries=()
  while IFS= read -r -d '' entry; do
    dated_entries+=("$entry")
  done < <(find "$entries_dir" -name "*[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_*.conf" ! -name "*fallback*" -print0 2>/dev/null)
  
  if [[ ${#dated_entries[@]} -eq 0 ]]; then
    log_info "No dated kernel entries found - entries already in simple format"
    return 0
  fi
  
  # First, check for potential conflicts
  check_renaming_conflicts "${dated_entries[@]}"
  
  for dated_entry in "${dated_entries[@]}"; do
    local entry_name=$(basename "$dated_entry")
    
    # Extract kernel type from dated entry
    if [[ "$entry_name" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_(.*)\.conf$ ]]; then
      local kernel_type="${BASH_REMATCH[1]}"
      local simple_name="${kernel_type}.conf"
      local simple_path="$entries_dir/$simple_name"
      
      # Check if simple entry already exists
      if [[ -f "$simple_path" ]]; then
        log_warning "Simple entry $simple_name already exists, skipping rename of $entry_name"
        continue
      fi
      
      # Verify the dated entry is valid before renaming
      if ! validate_kernel_entry "$dated_entry"; then
        log_warning "Invalid kernel entry $entry_name, skipping rename"
        continue
      fi
      
      # Rename the dated entry to simple format
      if sudo mv "$dated_entry" "$simple_path"; then
        log_success "Renamed $entry_name to $simple_name"
        ((renamed_count++))
        
        # Update loader.conf if it references the old dated entry
        update_loader_conf_references "$entry_name" "$simple_name"
      else
        log_error "Failed to rename $entry_name to $simple_name"
      fi
    else
      log_warning "Entry $entry_name doesn't match expected date pattern, skipping"
    fi
  done
  
  if [[ $renamed_count -gt 0 ]]; then
    log_success "Renamed $renamed_count dated kernel entries to simple format"
    ui_info "All kernel entries now use simple naming (linux.conf, linux-lts.conf, etc.)"
  else
    log_info "No entries needed renaming"
  fi
}

# Check for potential conflicts before renaming
check_renaming_conflicts() {
  local entries_dir="/boot/loader/entries"
  local conflicts_found=false
  
  for dated_entry in "$@"; do
    local entry_name=$(basename "$dated_entry")
    
    if [[ "$entry_name" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_(.*)\.conf$ ]]; then
      local kernel_type="${BASH_REMATCH[1]}"
      local simple_name="${kernel_type}.conf"
      local simple_path="$entries_dir/$simple_name"
      
      if [[ -f "$simple_path" ]]; then
        log_warning "Conflict: Both $entry_name and $simple_name exist"
        conflicts_found=true
      fi
    fi
  done
  
  if [[ "$conflicts_found" == true ]]; then
    log_warning "Renaming conflicts detected - some entries may not be renamed"
  fi
}

# Validate that a kernel entry is properly formatted
validate_kernel_entry() {
  local entry="$1"
  
  # Check for required fields
  if ! grep -q "^title " "$entry"; then
    log_warning "Entry $(basename "$entry") missing title field"
    return 1
  fi
  
  if ! grep -q "^linux " "$entry"; then
    log_warning "Entry $(basename "$entry") missing linux field"
    return 1
  fi
  
  if ! grep -q "^initrd " "$entry"; then
    log_warning "Entry $(basename "$entry") missing initrd field"
    return 1
  fi
  
  if ! grep -q "^options " "$entry"; then
    log_warning "Entry $(basename "$entry") missing options field"
    return 1
  fi
  
  return 0
}

# Update loader.conf references from old dated names to new simple names
update_loader_conf_references() {
  local old_name="$1"
  local new_name="$2"
  local loader_config="/boot/loader/loader.conf"
  
  if [[ ! -f "$loader_config" ]]; then
    return 0
  fi
  
  # Check if loader.conf references the old entry
  if grep -q "^default $old_name$" "$loader_config"; then
    # Update the reference to use the new simple name
    sudo sed -i "s|^default $old_name$|default $new_name|" "$loader_config"
    log_success "Updated loader.conf reference: $old_name -> $new_name"
  fi
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
    ui_info "Note: Arch Linux (linux-zen) default setting handled by gaming mode when installed"

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
        log_success "GRUB configured with Arch Linux (linux-zen) as default"
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
    
    # Add kernels in smart order (Arch Linux (linux-zen) first if installed)
    local kernels_added=()
    
    # Arch Linux (linux-zen) first if installed (from gaming_mode.sh script)
    if pacman -Qi linux-zen &>/dev/null; then
      if [[ -f "/boot/vmlinuz-linux-zen" ]] && [[ -f "/boot/initramfs-linux-zen.img" ]]; then
        cat << EOF

Arch Linux (linux-zen)
protocol: linux
path: boot():/vmlinuz-linux-zen
cmdline: $cmdline
module_path: boot():/initramfs-linux-zen.img
EOF
        kernels_added+=("zen")
        ui_info "Added Arch Linux (linux-zen) entry to Limine"
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
    
    # Add LTS kernel entry if available (user-installed only)
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
    log_success "Limine configured with Arch Linux (linux-zen) prioritized"
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
