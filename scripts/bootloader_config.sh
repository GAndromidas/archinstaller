#!/bin/bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# --- Bootloader and Btrfs detection ---
BOOTLOADER=$(detect_bootloader)
IS_BTRFS=$(is_btrfs_system && echo "true" || echo "false")

# ============================================================================
# BOOTLOADER-SPECIFIC KERNEL PARAMETERS
# ============================================================================

# --- systemd-boot ---
configure_boot() {
  if is_uki_system; then
    log_info "UKI system — systemd-boot auto-discovers UKI images; no entries/loader.conf needed"
    ui_info "UKI system detected — boot configuration managed via mkinitcpio presets"
    return 0
  fi

  local entries_dir
  entries_dir=$(find_systemd_boot_entries_dir)
  local loader_conf=""
  if [ -n "$entries_dir" ]; then
    loader_conf="$(dirname "$entries_dir")/loader.conf"
  fi

  run_step "Renaming dated kernel entries to simple format" rename_dated_kernel_entries

  if [ -n "$loader_conf" ] && [ -f "$loader_conf" ]; then
    set_loader_config "timeout" "3"
    set_loader_config "console-mode" "max"
    ui_info "Set timeout to 3s and console-mode to max (optimal settings)"
  else
    log_warning "loader.conf not found. Skipping loader.conf configuration for systemd-boot."
  fi

  run_step "Checking kernel options consistency" check_kernel_options_consistency
}

# Check kernel options consistency and only sync if necessary
check_kernel_options_consistency() {
  local entries_dir
  entries_dir=$(find_systemd_boot_entries_dir)
  if [ -z "$entries_dir" ]; then
    log_warning "No boot entries directory found, skipping consistency check."
    return 0
  fi

  ui_info "Checking kernel options consistency..."

  local kernel_entries=()
  while IFS= read -r -d $'\0' entry; do
    kernel_entries+=("$entry")
  done < <(find "$entries_dir" -name "*.conf" ! -name "*fallback*" -print0)

  if [[ ${#kernel_entries[@]} -eq 0 ]]; then
    log_warning "No kernel entries found to check"
    return 0
  fi

  if [[ ${#kernel_entries[@]} -eq 1 ]]; then
    log_info "Only one kernel entry found — consistency check not needed"
    return 0
  fi

  local options_list=()
  local entry_names=()

  for entry in "${kernel_entries[@]}"; do
    local entry_name=$(basename "$entry")
    local current_options=$(grep "^options " "$entry" | sed 's/^options //' || echo "")
    options_list+=("$current_options")
    entry_names+=("$entry_name")
  done

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
  else
    log_warning "Inconsistent kernel options detected across entries"
    log_info "Options vary between entries — this may cause boot issues"
    for i in "${!entry_names[@]}"; do
      log_info "${entry_names[$i]}: ${options_list[$i]}"
    done

    if command -v gum >/dev/null 2>&1; then
      echo ""
      gum style --foreground "$GUM_WARN" "Kernel options are inconsistent across entries"
      gum style --foreground "$GUM_TEXT" "This may cause boot issues"
      echo ""
    fi
    if gum_confirm "Sync all kernel entries to use the same options?"; then
      sync_all_kernel_options
    else
      log_warning "Kernel options left inconsistent — manual review recommended"
    fi
  fi
}

# Sync kernel options across all kernel entries
sync_all_kernel_options() {
  local entries_dir
  entries_dir=$(find_systemd_boot_entries_dir)
  if [ -z "$entries_dir" ]; then
    log_warning "No boot entries directory found, skipping sync."
    return 0
  fi

  ui_info "Syncing kernel options across all entries..."

  local kernel_entries=()
  while IFS= read -r -d $'\0' entry; do
    kernel_entries+=("$entry")
  done < <(find "$entries_dir" -name "*.conf" ! -name "*fallback*" -print0)

  if [[ ${#kernel_entries[@]} -eq 0 ]]; then
    log_warning "No kernel entries found to sync"
    return 0
  fi

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

    if [[ "$entry" == "$standard_entry" ]]; then
      continue
    fi

    local current_options=$(grep "^options " "$entry" | sed 's/^options //' || echo "")

    if [[ "$current_options" != "$standard_options" ]]; then
      local temp_file=$(mktemp)
      trap 'rm -f "$temp_file"' RETURN
      grep -v "^options " "$entry" > "$temp_file"
      echo "options $standard_options" >> "$temp_file"
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
  local entries_dir
  entries_dir=$(find_systemd_boot_entries_dir)

  if [ -z "$entries_dir" ]; then
    log_warning "Boot entries directory not found. Skipping entry renaming."
    return 0
  fi

  ui_info "Checking for dated kernel entries to rename to simple format..."

  local renamed_count=0

  local dated_entries=()
  while IFS= read -r -d '' entry; do
    dated_entries+=("$entry")
  done < <(find "$entries_dir" -name "*[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9]-[0-9][0-9]-[0-9][0-9]_*.conf" ! -name "*fallback*" -print0 2>/dev/null)

  log_info "Boot entries directory: $entries_dir"
  log_info "Found ${#dated_entries[@]} dated kernel entries"

  if [[ ${#dated_entries[@]} -eq 0 ]]; then
    log_info "No dated kernel entries found — entries already in simple format"
    # List all .conf files for debugging
    log_info "All entries in directory:"
    find "$entries_dir" -name "*.conf" -exec basename {} \; 2>/dev/null | while read -r f; do
      log_info "  - $f"
    done
    return 0
  fi

  check_renaming_conflicts "${dated_entries[@]}"

  for dated_entry in "${dated_entries[@]}"; do
    local entry_name=$(basename "$dated_entry")
    log_info "Processing entry: $entry_name"

    if [[ "$entry_name" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}_(.*)\.conf$ ]]; then
      local kernel_type="${BASH_REMATCH[1]}"
      local simple_name="${kernel_type}.conf"
      local simple_path="$entries_dir/$simple_name"
      log_info "Regex matched - kernel type: $kernel_type, simple name: $simple_name"

      if [[ -f "$simple_path" ]]; then
        log_warning "Simple entry $simple_name already exists, skipping rename of $entry_name"
        continue
      fi

      if ! validate_kernel_entry "$dated_entry"; then
        log_warning "Invalid kernel entry $entry_name, skipping rename"
        continue
      fi

      log_info "Attempting to rename: $dated_entry -> $simple_path"
      if sudo mv "$dated_entry" "$simple_path"; then
        log_success "Renamed $entry_name to $simple_name"
        ((renamed_count++))
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

check_renaming_conflicts() {
  local entries_dir
  entries_dir=$(find_systemd_boot_entries_dir)
  [ -z "$entries_dir" ] && return 0
  local conflicts_found=false

  for dated_entry in "$@"; do
    local entry_name=$(basename "$dated_entry")

    if [[ "$entry_name" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}_(.*)\.conf$ ]]; then
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
    log_warning "Renaming conflicts detected — some entries may not be renamed"
  fi
}

validate_kernel_entry() {
  local entry="$1"

  # Title field is optional (archinstall entries don't have it)
  # Only check for essential fields: linux and initrd
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

update_loader_conf_references() {
  local old_name="$1"
  local new_name="$2"
  local loader_config=""
  for f in "/boot/loader/loader.conf" "/efi/loader/loader.conf" "/boot/efi/loader/loader.conf"; do
    if [ -f "$f" ]; then
      loader_config="$f"
      break
    fi
  done

  if [[ -z "$loader_config" ]]; then
    return 0
  fi

  if grep -q "^default $old_name$" "$loader_config"; then
    sudo sed -i "s|^default $old_name$|default $new_name|" "$loader_config"
    log_success "Updated loader.conf reference: $old_name -> $new_name"
  fi
}

# --- GRUB configuration ---
configure_grub() {
    step "Configuring GRUB"

    if is_uki_system; then
      log_info "UKI system — kernel parameters baked into UKI image"
      ui_info "UKI system detected — kernel parameters configured via /etc/kernel/cmdline"
      return 0
    fi

    # Traditional system: configure GRUB
    set_grub_config "GRUB_TIMEOUT" "3"
    ui_info "Set GRUB timeout to 3 seconds (optimal setting)"

    step "Configuring GRUB: set saved entry as default"
    set_grub_config "GRUB_DEFAULT" "saved"
    ui_info "Set saved entry as default boot entry"

    set_grub_config "GRUB_SAVEDEFAULT" "true"

    set_grub_config "GRUB_DISABLE_SUBMENU" "notlinux"
    set_grub_config "GRUB_GFXMODE" "auto"
    set_grub_config "GRUB_GFXPAYLOAD_LINUX" "keep"

    local KERNELS=($(ls /boot/vmlinuz-* 2>/dev/null | sed 's|/boot/vmlinuz-||g'))
    if [[ ${#KERNELS[@]} -eq 0 ]]; then
        log_error "No kernels found in /boot."
        return 1
    fi

    local MAIN_KERNEL=""
    local SECONDARY_KERNELS=()
    for k in "${KERNELS[@]}"; do
        [[ "$k" == "linux" ]] && MAIN_KERNEL="$k"
        [[ "$k" != "linux" && "$k" != "fallback" && "$k" != "rescue" ]] && SECONDARY_KERNELS+=("$k")
    done
    [[ -z "$MAIN_KERNEL" ]] && MAIN_KERNEL="${KERNELS[0]}"

    local grub_config="/etc/default/grub"
    local grub_cfg="/boot/grub/grub.cfg"
    local backup_grub_config="${grub_config}.backup.$(date +%Y%m%d_%H%M%S)"

    if [ -f "$grub_config" ]; then
        cp "$grub_config" "$backup_grub_config" || true
    fi

    if [ -f "$grub_config" ]; then
        ui_info "Regenerating GRUB configuration..."
        if sudo grub-mkconfig -o "$grub_cfg" >>"$INSTALL_LOG" 2>&1; then
            log_success "GRUB configuration regenerated successfully"
        else
            log_error "grub-mkconfig failed"
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

# --- Limine Bootloader Configuration ---
configure_limine_basic() {
  step "Configuring Limine bootloader"

  if is_uki_system; then
    log_info "UKI system — kernel parameters baked into UKI image"
    ui_info "UKI system detected — kernel parameters configured via /etc/kernel/cmdline"
    return 0
  fi

  local limine_config="/boot/limine.conf"

  log_info "Creating idempotent Limine configuration at: $limine_config"

  if [ -f "$limine_config" ]; then
    log_info "Backing up existing limine.conf..."
    sudo cp "$limine_config" "${limine_config}.backup.$(date +%Y%m%d_%H%M%S)"
  fi

  local root_uuid=""
  root_uuid=$(findmnt -n -o UUID / 2>/dev/null || echo "")

  if [ -z "$root_uuid" ]; then
    log_error "Could not determine root UUID"
    return 1
  fi

  local cmdline="root=UUID=$root_uuid rw nowatchdog"

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

  local limine_tmp=$(mktemp)
  {
    cat << EOF
# Limine Bootloader Configuration
# Generated by archinstaller on $(date)
# Root UUID: $root_uuid
# Filesystem: $root_fstype

timeout: 3
interface_resolution: 1024x768

EOF

    local kernels_added=()
    local kernel_name kernel_initramfs entry_title

    # Generate an entry for EVERY installed kernel, not just a hardcoded few —
    # a config with no matching entry leaves the system unbootable.
    for kernel_img in /boot/vmlinuz-*; do
      [ -e "$kernel_img" ] || continue
      kernel_name="${kernel_img#/boot/vmlinuz-}"
      kernel_initramfs="/boot/initramfs-${kernel_name}.img"
      [ -f "$kernel_initramfs" ] || continue

      case "$kernel_name" in
        linux)          entry_title="Arch Linux" ;;
        linux-lts)      entry_title="Arch Linux (LTS)" ;;
        linux-zen)      entry_title="Arch Linux (linux-zen)" ;;
        *)              entry_title="Arch Linux ($kernel_name)" ;;
      esac

      cat << EOF
$entry_title
protocol: linux
path: boot():/vmlinuz-$kernel_name
cmdline: $cmdline
module_path: boot():/initramfs-$kernel_name.img
EOF
      kernels_added+=("$kernel_name")
      ui_info "Added $entry_title entry to Limine"
    done

    # Safety net: refuse to install a config without at least one kernel entry,
    # and restore the backup so the system stays bootable.
    if [ ${#kernels_added[@]} -eq 0 ]; then
      log_error "No bootable kernel entries could be generated — keeping existing limine.conf"
      rm -f "$limine_tmp"
      return 1
    fi

    # Detect Windows via partition type (EFI System partitions), not hardcoded device paths.
    # On UEFI, Windows boots via its ESP's bootmgfw.efi — not by chainloading the NTFS partition.
    local windows_found=false
    if command -v lsblk >/dev/null 2>&1; then
      while IFS= read -r esp_path; do
        if sudo test -f "${esp_path}/EFI/Microsoft/Boot/bootmgfw.efi" 2>/dev/null; then
          local esp_partuuid
          esp_partuuid=$(lsblk -rno PATH,PARTUUID "$esp_path" 2>/dev/null | awk '{print $2}')
          if [ -n "$esp_partuuid" ]; then
            cat << EOF

/Windows
protocol: efi
path: uuid($esp_partuuid):/EFI/Microsoft/Boot/bootmgfw.efi
EOF
            log_success "Added Windows entry via ESP: $esp_path"
            windows_found=true
          else
            log_warning "Found Windows ESP at $esp_path but could not determine PARTUUID — skipping Windows entry"
          fi
          break
        fi
      done < <(lsblk -rno PATH,PARTTYPENAME 2>/dev/null | awk '$2 == "EFI System" {print $1}')
    fi

    if [ "$windows_found" = false ]; then
      log_info "No Windows partition detected"
    fi

  } > "$limine_tmp"

  # Only replace the live config if the generated one is valid
  if ! grep -q '^protocol: linux$' "$limine_tmp"; then
    log_error "Generated Limine config is invalid — keeping existing configuration"
    rm -f "$limine_tmp"
    return 1
  fi
  sudo mv "$limine_tmp" "$limine_config"

  log_success "Limine configured with ${#kernels_added[@]} kernel entr(ies)"
  log_info "Configuration file: $limine_config"
  log_info "Kernels configured: ${kernels_added[*]}"
  log_info "Limine bootloader configured successfully"
}

# ============================================================================
# PART 3: HELPER FUNCTIONS
# ============================================================================

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

set_loader_config() {
    local key="$1"
    local value="$2"
    local loader_config=""
    for f in "/boot/loader/loader.conf" "/efi/loader/loader.conf" "/boot/efi/loader/loader.conf"; do
      if [ -f "$f" ]; then
        loader_config="$f"
        break
      fi
    done

    if [ -z "$loader_config" ]; then
        log_warning "loader.conf not found, cannot set configuration"
        return 1
    fi

    if grep -q "^[#]*${key}[[:space:]]" "$loader_config" 2>/dev/null; then
        sudo sed -i "s/^[#]*${key}[[:space:]].*/${key} ${value}/" "$loader_config"
    else
        echo "${key} ${value}" | sudo tee -a "$loader_config" >/dev/null
    fi
}

# ============================================================================
# PART 4: SNAPSHOT INTEGRATION (Limine + btrfs only)
# ============================================================================

# Bootable snapshot menu for Limine via Snapper.
# limine-snapper-sync keeps the //Snapshots entries in limine.conf in sync with
# snapper automatically — created snapshots appear, deleted ones disappear.
# GRUB/systemd-boot systems keep using Timeshift + timeshift-autosnap instead
# (handled in system_services.sh).
configure_limine_snapper_integration() {
  if [ "$BOOTLOADER" != "limine" ]; then
    return 0
  fi
  if ! is_btrfs_system; then
    log_info "Root is not btrfs — Limine snapshot menu requires btrfs. Skipping."
    return 0
  fi

  step "Configuring Limine snapshot menu (Snapper)"

  # Already configured? Just make sure the service is enabled and exit.
  if [ -f /etc/snapper/configs/root ] && pacman -Q limine-snapper-sync &>/dev/null; then
    log_info "Snapper + limine-snapper-sync already configured"
    sudo systemctl enable --now limine-snapper-sync.service >>"$INSTALL_LOG" 2>&1 || true
    return 0
  fi

  ui_warn "This sets up bootable snapshot entries in the Limine menu using Snapper."
  ui_info "Snapshots taken before pacman transactions will appear in a Snapshots submenu"
  ui_info "and can be booted directly for rollback. This replaces Timeshift autosnap."

  if ! gum_confirm "Set up Limine snapshot menu with Snapper?" "Requires btrfs root (detected). Timeshift is unaffected but timeshift-autosnap will not be installed."; then
    log_info "Limine/Snapper setup skipped by user — falling back to Timeshift flow"
    return 0
  fi

  # 1. Install snapper + snap-pac from repos
  install_packages_quietly snapper snap-pac || {
    log_error "Failed to install snapper/snap-pac — aborting snapshot setup"
    return 1
  }

  # 2. Create snapper root config if missing
  if [ ! -f /etc/snapper/configs/root ]; then
    sudo snapper -c root create-config / >>"$INSTALL_LOG" 2>&1 || {
      log_error "Failed to create snapper root config — aborting snapshot setup"
      return 1
    }
    log_success "Created snapper root config"
  fi

  # Sensible retention: keep rollback useful without filling the disk
  sudo snapper -c root set-config "TIMELINE_LIMIT=10" "NUMBER_LIMIT=20" >>"$INSTALL_LOG" 2>&1 || true

  # 3. Install limine-snapper-sync from AUR (non-fatal on failure)
  if command -v yay >/dev/null 2>&1; then
    ui_info "Installing limine-snapper-sync from AUR (this may take a while)..."
    if yay_install_single "limine-snapper-sync" false; then
      sudo systemctl enable --now limine-snapper-sync.service >>"$INSTALL_LOG" 2>&1 || \
        log_warning "Could not enable limine-snapper-sync.service — enable it manually after reboot"
      log_success "limine-snapper-sync installed and enabled — Limine snapshot entries will stay in sync"
    else
      log_warning "limine-snapper-sync AUR build failed — snapshots still work via snapper/snap-pac,"
      log_warning "but the Limine snapshot menu will not be auto-synced. Retry later with: yay -S limine-snapper-sync"
    fi
  else
    log_warning "yay not available — cannot install limine-snapper-sync (AUR)."
    log_warning "Snapshots work via snapper/snap-pac; install limine-snapper-sync later for the boot menu."
  fi

  # 4. Add //Snapshots under each kernel entry in limine.conf (idempotent)
  add_snapshots_directive_to_limine

  # 5. ESP size check — bootable snapshot entries consume ESP space
  check_esp_size_for_snapshots

  log_success "Limine snapshot integration complete"
}

# Append '//Snapshots' inside every kernel entry block in limine.conf.
add_snapshots_directive_to_limine() {
  local limine_config="/boot/limine.conf"
  [ -f "$limine_config" ] || { log_warning "limine.conf not found — cannot add //Snapshots"; return 1; }

  if grep -q '^\s*//Snapshots' "$limine_config"; then
    log_info "//Snapshots directive already present in limine.conf"
    return 0
  fi

  local tmp=$(mktemp)
  # Insert '//Snapshots' right after the FIRST 'protocol:' line of the first
  # kernel entry. Limine's snapshot integration expects it inside the entry
  # block; our generated config uses unindented keys, so anchor on 'protocol:'.
  awk '
    !inserted && /^protocol:/ {
      print
      print "//Snapshots"
      inserted = 1
      next
    }
    { print }
  ' "$limine_config" > "$tmp"

  if grep -q '^	*//Snapshots' "$tmp"; then
    sudo cp "$tmp" "$limine_config" && log_success "Added //Snapshots to kernel entries in limine.conf"
  else
    log_warning "Could not insert //Snapshots automatically — add '//Snapshots' inside your Arch Linux entry manually"
  fi
  rm -f "$tmp"
}

# Warn if the ESP looks too small for storing bootable snapshot kernels.
check_esp_size_for_snapshots() {
  local esp_mnt=""
  for m in /efi /boot /boot/efi; do
    if findmnt -n -o SOURCE "$m" >/dev/null 2>&1 && [[ $(findmnt -n -o FSTYPE "$m") == vfat ]]; then
      esp_mnt="$m"
      break
    fi
  done
  [ -n "$esp_mnt" ] || return 0

  local size_mb=$(df -m --output=avail "$esp_mnt" 2>/dev/null | awk 'NR==2 {print $1}')
  local total_mb=$(df -m --output=size "$esp_mnt" 2>/dev/null | awk 'NR==2 {print $1}')
  [[ "$total_mb" =~ ^[0-9]+$ ]] || return 0

  if [ "$total_mb" -lt 4000 ]; then
    log_warning "ESP at $esp_mnt is ${total_mb}MB — limine-snapper-sync recommends 4GB+ when storing bootable snapshot kernels"
    log_warning "Old snapshot entries are auto-pruned when ESP usage exceeds limits, but consider enlarging the ESP"
  else
    log_info "ESP at $esp_mnt has ${total_mb}MB total (${size_mb}MB free) — sufficient for snapshot entries"
  fi
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

# Bootloader-specific configuration (kernel params + bootloader settings)
if [ "$BOOTLOADER" = "grub" ]; then
    configure_grub
elif [ "$BOOTLOADER" = "systemd-boot" ]; then
    configure_boot
elif [ "$BOOTLOADER" = "limine" ]; then
    configure_limine_basic
    configure_limine_snapper_integration
else
    log_warning "No bootloader detected or bootloader is unsupported. Defaulting to systemd-boot configuration."
    configure_boot
fi
