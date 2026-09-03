#!/bin/bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# --- Bootloader detection ---
BOOTLOADER=$(detect_bootloader)

# ============================================================================
# UNIFIED KERNEL PARAMETERS
# ============================================================================

# Build consistent kernel parameters across all bootloaders
# Usage: get_kernel_params [--cmdline-only]
#   --cmdline-only: Output only the parameters (no root= prefix)
get_kernel_params() {
  local cmdline_only=false
  [[ "${1:-}" == "--cmdline-only" ]] && cmdline_only=true

  local params=""

  # Base parameters (all systems)
  params="quiet loglevel=3 nowatchdog"

  # Plymouth splash (hide boot text, show progress)
  if command -v plymouth-set-default-theme &>/dev/null || pacman -Qi plymouth &>/dev/null 2>&1; then
    params="$params splash vt.global_cursor_default=0"
  fi

  # GPU-specific parameters
  local gpu_vendor=""
  if lspci 2>/dev/null | grep -qiE 'vga.*nvidia|3d.*nvidia|display.*nvidia'; then
    gpu_vendor="nvidia"
  elif lspci 2>/dev/null | grep -qiE 'vga.*amd|3d.*amd|display.*amd|vga.*radeon|3d.*radeon'; then
    gpu_vendor="amd"
  elif lspci 2>/dev/null | grep -qiE 'vga.*intel|display.*intel'; then
    gpu_vendor="intel"
  fi

  case "$gpu_vendor" in
    nvidia)
      # NVIDIA: Required for Wayland and modern drivers
      params="$params nvidia_drm.modeset=1 nvidia_drm.fbdev=1"
      # Laptop power management for Ampere+ GPUs
      if is_laptop 2>/dev/null; then
        params="$params NVreg_DynamicPowerManagement=0x03"
        params="$params NVreg_PreserveVideoMemoryAllocations=1"
        params="$params NVreg_TemporaryFilePath=/var/tmp"
      fi
      ;;
    amd)
      # AMD: amdgpu is the default driver, no extra params needed by default
      # Only add for older GCN 1-2 GPUs that need force-loading
      if lspci 2>/dev/null | grep -qiE 'vga.*amd.*oland|vga.*amd.*tonga|vga.*amd.*fiji|vga.*amd.*polaris'; then
        params="$params radeon.si_support=0 amdgpu.si_support=1"
        params="$params radeon.cik_support=0 amdgpu.cik_support=1"
      fi
      # AMD P-State for CPUs with CPPC support (Ryzen 5000+ / Zen 3+)
      if grep -qi "amd_pstate" /proc/cpuinfo 2>/dev/null || [ -d /sys/devices/system/cpu/amd_pstate ]; then
        params="$params amd_pstate=active"
      fi
      ;;
    intel)
      # Intel: Enable GuC/HuC firmware for Gen 9.5+ (11th gen+)
      local intel_gen=$(lspci 2>/dev/null | grep -i 'vga.*intel\|display.*intel' | grep -oP '\[\K[0-9a-f]+' | head -1)
      # If we can detect a recent Intel GPU, enable GuC
      if [[ -n "$intel_gen" ]]; then
        params="$params i915.enable_guc=3"
      fi
      ;;
  esac

  # Filesystem-specific root flags
  local root_fstype=$(findmnt -n -o FSTYPE / 2>/dev/null || echo "")
  case "$root_fstype" in
    btrfs)
      local root_subvol=$(findmnt -n -o OPTIONS / 2>/dev/null | grep -o 'subvol=[^,]*' | cut -d= -f2 || echo "/@")
      params="$params rootflags=subvol=$root_subvol"
      ;;
    ext4)
      params="$params rootflags=relatime"
      ;;
  esac

  if [[ "$cmdline_only" == true ]]; then
    echo "$params"
    return 0
  fi

  # Full cmdline with root device
  local root_uuid=$(findmnt -n -o UUID / 2>/dev/null || echo "")
  if [[ -n "$root_uuid" ]]; then
    echo "root=UUID=$root_uuid rw $params"
  else
    echo "$params"
  fi
}

# Write kernel parameters to UKI /etc/kernel/cmdline
configure_uki_cmdline() {
  local cmdline_file="/etc/kernel/cmdline"
  local params
  params=$(get_kernel_params)

  local needs_update=true
  if [[ -f "$cmdline_file" ]]; then
    local current_params
    current_params=$(sudo cat "$cmdline_file" 2>/dev/null || echo "")
    if [[ "$current_params" == "$params" ]]; then
      log_info "UKI cmdline already configured"
      needs_update=false
    else
      sudo cp "$cmdline_file" "${cmdline_file}.backup.$(date +%Y%m%d_%H%M%S)"
      log_info "Backed up existing UKI cmdline"
    fi
  fi

  if [[ "$needs_update" == true ]]; then
    echo "$params" | sudo tee "$cmdline_file" >/dev/null
    log_success "UKI cmdline written: $params"
  fi

  # Add --splash to mkinitcpio preset if Plymouth is installed (ArchWiki: UKI + Plymouth)
  # Per ArchWiki: add --splash=<bmp> to *PRESET*_options= lines
  if pacman -Qi plymouth &>/dev/null 2>&1; then
    local splash_bmp="/usr/share/systemd/bootctl/splash-arch.bmp"
    if [[ -f "$splash_bmp" ]] && [[ -d /etc/mkinitcpio.d ]]; then
      local preset
      for preset in /etc/mkinitcpio.d/*.preset; do
        [[ -f "$preset" ]] || continue
        if grep -q '\-\-splash' "$preset" 2>/dev/null; then
          continue
        fi
        # Handle uncommented default_options lines
        if grep -q '^default_options=' "$preset" 2>/dev/null; then
          sudo sed -i "s|^default_options=.*|& --splash=${splash_bmp}|" "$preset" 2>/dev/null && \
            log_info "Added --splash to $preset" || \
            log_warning "Failed to add --splash to $preset"
        # Handle commented-out default_options (uncomment and add --splash)
        elif grep -q '^#default_options=' "$preset" 2>/dev/null; then
          sudo sed -i "s|^#default_options=.*|default_options=\"--splash=${splash_bmp}\"|" "$preset" 2>/dev/null && \
            log_info "Uncommented default_options with --splash in $preset" || \
            log_warning "Failed to update $preset"
        # No default_options line at all — add one
        else
          echo "default_options=\"--splash=${splash_bmp}\"" | sudo tee -a "$preset" >/dev/null 2>&1 && \
            log_info "Added default_options with --splash to $preset" || \
            log_warning "Failed to add default_options to $preset"
        fi
      done
    elif [[ ! -f "$splash_bmp" ]]; then
      log_warning "Splash bitmap not found at $splash_bmp — Plymouth splash may not display during early boot"
    fi
  fi

  # Ensure /boot/efi/EFI/Linux directory exists for UKI output
  local esp_mount
  esp_mount=$(findmnt -n -o TARGET /boot/efi 2>/dev/null || findmnt -n -o TARGET /boot 2>/dev/null || echo "/boot")
  local uki_dir="${esp_mount}/EFI/Linux"
  if [[ ! -d "$uki_dir" ]]; then
    sudo mkdir -p "$uki_dir" 2>/dev/null && \
      log_info "Created UKI output directory: $uki_dir" || \
      log_warning "Failed to create $uki_dir"
  fi

  # Regenerate UKI images if mkinitcpio presets exist
  if [[ -d /etc/mkinitcpio.d ]]; then
    ui_info "Regenerating UKI images..."
    if sudo mkinitcpio -P >>"$INSTALL_LOG" 2>&1; then
      log_success "UKI images regenerated"
    else
      log_warning "UKI image regeneration had issues — check mkinitcpio presets"
    fi
  fi
}

# ============================================================================
# BOOTLOADER-SPECIFIC KERNEL PARAMETERS
# ============================================================================

# --- systemd-boot ---
configure_boot() {
  # Detect UKI system: either already has UKI .efi files, or mkinitcpio presets configure UKI output
  local is_uki=false
  if is_uki_system; then
    is_uki=true
  elif grep -qr "^\s*default_uki=" /etc/mkinitcpio.d/ 2>/dev/null; then
    is_uki=true
    log_info "UKI output configured in mkinitcpio presets"
  fi

  if [[ "$is_uki" == true ]]; then
    log_info "UKI system — configuring /etc/kernel.cmdline and preset options"
    configure_uki_cmdline
    ui_info "UKI system detected — kernel parameters configured via /etc/kernel.cmdline"
    return 0
  fi

  # Get unified kernel parameters for non-UKI systemd-boot
  local kernel_params
  kernel_params=$(get_kernel_params --cmdline-only)

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

  # Update kernel options in all entries with unified params
  run_step "Updating kernel options with unified parameters" update_systemd_boot_options "$kernel_params"

  run_step "Checking kernel options consistency" check_kernel_options_consistency
}

# Update kernel options in systemd-boot entries
update_systemd_boot_options() {
  local new_params="$1"
  local entries_dir
  entries_dir=$(find_systemd_boot_entries_dir)

  if [ -z "$entries_dir" ]; then
    return 0
  fi

  local updated=0
  for entry in "$entries_dir"/*.conf; do
    [ -f "$entry" ] || continue
    [[ "$(basename "$entry")" == *fallback* ]] && continue

    # Read existing root device from options line
    local existing_root=""
    if grep -q "^options " "$entry"; then
      existing_root=$(grep "^options " "$entry" | sed 's/^options //' | grep -oP 'root=UUID=\S+')
    fi

    # Build new options line
    local new_options="${existing_root} rw ${new_params}"

    # Update or add options line
    if grep -q "^options " "$entry"; then
      sudo sed -i "s|^options .*|options $new_options|" "$entry"
    else
      echo "options $new_options" | sudo tee -a "$entry" >/dev/null
    fi
    ((updated++))
  done

  [[ $updated -gt 0 ]] && log_success "Updated kernel options in $updated systemd-boot entries"
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
      if gum confirm "Sync all kernel entries to use the same options?"; then
        sync_all_kernel_options
      else
        log_warning "Kernel options left inconsistent — manual review recommended"
      fi
    else
      log_warning "Inconsistent kernel options detected — auto-syncing for system stability"
      sync_all_kernel_options
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
      log_info "UKI system — configuring /etc/kernel/cmdline"
      configure_uki_cmdline
      ui_info "UKI system detected — kernel parameters configured via /etc/kernel/cmdline"
      return 0
    fi

    # Get unified kernel parameters (without root= prefix for GRUB)
    local kernel_params
    kernel_params=$(get_kernel_params --cmdline-only)

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

    # Set kernel parameters (quiet, splash, nvidia, etc.)
    set_grub_config "GRUB_CMDLINE_LINUX_DEFAULT" "$kernel_params"
    set_grub_config "GRUB_CMDLINE_LINUX" ""
    ui_info "Kernel parameters: $kernel_params"

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
      if sudo test -f "$f" 2>/dev/null; then # Use sudo test for file existence
        loader_config="$f"
        break
      fi
    done

    if [ -z "$loader_config" ]; then
        log_warning "loader.conf not found in standard paths, trying derived path..."
        if [ -n "$entries_dir" ]; then
          local derived_conf="$(dirname "$entries_dir")/loader.conf"
          if sudo test -f "$derived_conf" 2>/dev/null; then
            loader_config="$derived_conf"
          else
            loader_config="$derived_conf"
            log_info "Will create loader.conf at derived path: $loader_config"
          fi
        fi
    fi

    if [ -z "$loader_config" ]; then
        log_warning "loader.conf not found or not accessible, cannot set configuration for key '$key'"
        return 1
    fi

    local current_content
    current_content=$(sudo cat "$loader_config" 2>/dev/null)
    if [ $? -ne 0 ]; then
        log_error "Failed to read $loader_config for key '$key'"
        return 1
    fi

    local new_content

    # Check if the key exists, potentially commented out
    if echo "$current_content" | grep -qE "^[#]*${key}[[:space:]]"; then
        # Replace existing or uncomment and replace
        new_content=$(echo "$current_content" | sudo sed "s/^[#]*${key}[[:space:]].*/${key} ${value}/")
    else
        # Append new key-value pair if not found
        new_content="${current_content}
${key} ${value}"
    fi

    # Ensure directory exists
    local target_dir=$(dirname "$loader_config")
    if [ ! -d "$target_dir" ]; then
        sudo mkdir -p "$target_dir" 2>/dev/null || {
            log_error "Failed to create directory $target_dir"
            return 1
        }
    fi

    # Write to file atomically
    local temp_file="${loader_config}.tmp.$$"
    if ! echo "$new_content" > "$temp_file" 2>/dev/null; then
        log_error "Failed to write to temporary file $temp_file"
        rm -f "$temp_file"
        return 1
    fi

    if [ ! -s "$temp_file" ]; then
        log_error "Temporary file $temp_file is empty"
        rm -f "$temp_file"
        return 1
    fi

    if ! sudo mv "$temp_file" "$loader_config"; then
        log_error "Failed to move $temp_file to $loader_config"
        rm -f "$temp_file"
        return 1
    fi

    log_success "Successfully wrote configuration to $loader_config for key '$key'"
    return 0
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
    configure_limine_snapper
else
    log_warning "No bootloader detected or bootloader is unsupported. Defaulting to systemd-boot configuration."
    configure_boot
fi
#
# EOF optional - the configure_limine_snapper function is defined below


# --- Limine + Snapper Configuration ---
configure_limine_snapper() {
  step "Configuring Limine bootloader with Snapper support"

  if is_uki_system; then
    log_info "UKI system — configuring /etc/kernel.cmdline"
    configure_uki_cmdline
    ui_info "UKI system detected — kernel parameters configured via /etc/kernel.cmdline"
    return 0
  fi

  # Install required packages
  step "Installing Limine and Snapper packages"
  if ! pacman -Syu --needed --noconfirm limine efibootmgr btrfs-progs snapper; then
    log_error "Failed to install required packages"
    return 1
  fi

  # Install AUR helpers if needed
  if ! command -v yay &>/dev/null && ! command -v paru &>/dev/null; then
    log_info "No AUR helper found. Installing yay..."
    if ! sudo pacman -S --needed --noconfirm base-devel git; then
      log_error "Failed to install base-devel for AUR helper"
      return 1
    fi
    BUILD_USER="${SUDO_USER:-}"
    [[ -n "$BUILD_USER" && "$BUILD_USER" != "root" ]] || err "Re-run with 'sudo' from your normal user."
    YAY_TMP=$(mktemp -d)
    chown "$BUILD_USER" -R "$YAY_TMP"
    sudo -u "$BUILD_USER" git clone https://aur.archlinux.org/yay.git "$YAY_TMP/yay"
    sudo -u "$BUILD_USER" bash -c "cd '$YAY_TMP/yay' && makepkg -si --noconfirm"
    rm -rf "$YAY_TMP"
  fi

  # Install limine-snapper-sync and snap-pac via AUR
  install_aur "limine-snapper-sync"
  install_aur "snap-pac"

  # Install limine-mkinitcpio-hook for initramfs automation
  if command -v mkinitcpio &>/dev/null; then
    if ! pacman -Qi limine-mkinitcpio-hook &>/dev/null 2>&1; then
      install_aur "limine-mkinitcpio-hook"
    fi
  fi

  # Configure Snapper
  step "Configuring Snapper..."
  SNAPPER_CONF="/etc/snapper/configs/root"
  if [[ ! -f "$SNAPPER_CONF" ]]; then
    snapper -c root create-config / || warn "snapper create-config failed (may already be configured)."
  fi

  # Mount /.snapshots
  if ! mountpoint -q /.snapshots 2>/dev/null; then
    mount -a 2>/dev/null || true
  fi
  mountpoint -q /.snapshots 2>/dev/null || warn "/.snapshots not mounted yet; will mount on next boot."

  # Set timeline limits
  SNAPPER_CONF="/etc/snapper/configs/root"
  if [[ -f "$SNAPPER_CONF" ]]; then
    sed -i 's/^TIMELINE_MIN_AGE=.*/TIMELINE_MIN_AGE="1800"/' "$SNAPPER_CONF"
    sed -i 's/^TIMELINE_LIMIT_HOURLY=.*/TIMELINE_LIMIT_HOURLY="5"/' "$SNAPPER_CONF"
    sed -i 's/^TIMELINE_LIMIT_DAILY=.*/TIMELINE_LIMIT_DAILY="7"/' "$SNAPPER_CONF"
    sed -i 's/^TIMELINE_LIMIT_WEEKLY=.*/TIMELINE_LIMIT_WEEKLY="0"/' "$SNAPPER_CONF"
    sed -i 's/^TIMELINE_LIMIT_MONTHLY=.*/TIMELINE_LIMIT_MONTHLY="0"/' "$SNAPPER_CONF"
    sed -i 's/^TIMELINE_LIMIT_YEARLY=.*/TIMELINE_LIMIT_YEARLY="0"/' "$SNAPPER_CONF"
    ok "Snapper timeline limits configured."
  fi

  systemctl enable --now snapper-timeline.timer 2>/dev/null || true
  systemctl enable --now snapper-cleanup.timer 2>/dev/null || true
  ok "Snapper timers enabled."

  # Deploy Limine EFI binary
  step "Deploying Limine EFI binary..."

  LIMINE_EFI_SRC=""
  for p in \
    /usr/share/limine/BOOTX64.EFI \
    /usr/lib/limine/BOOTX64.EFI \
    /usr/share/limine/limine-x86_64.efi; do
    if [[ -f "$p" ]]; then
      LIMINE_EFI_SRC="$p"
      break
    fi
  done
  [[ -n "$LIMINE_EFI_SRC" ]] || err "Limine EFI binary not found."
  LIMINE_EFI_DIR="$ESP_MOUNT/EFI/limine"
  mkdir -p "$LIMINE_EFI_DIR"
  cp "$LIMINE_EFI_SRC" "$LIMINE_EFI_DIR/BOOTX64.EFI"
  ok "Limine EFI binary deployed."

  # Create EFI NVRAM entry if missing
  if efibootmgr | grep -qi limine; then
    ok "Limine EFI boot entry already exists."
  else
    ESP_DEV=$(findmnt -n -o SOURCE "$ESP_MOUNT")
    if [[ "$ESP_DEV" =~ ^/dev/(.+?)(p[0-9]+)$ ]]; then
      ESP_DISK="/dev/${BASH_REMATCH[1]}"
      ESP_PART="${BASH_REMATCH[2]#p}"
    elif [[ "$ESP_DEV" =~ ^/dev/nvme[0-9]+n[0-9]+p([0-9]+)$ ]]; then
      ESP_DISK="${ESP_DEV%p*}"
      ESP_PART="${BASH_REMATCH[1]}"
    elif [[ "$ESP_DEV" =~ ^/dev/sd[a-z]([0-9]+)$ ]]; then
      ESP_DISK="${ESP_DEV%[0-9]*}"
      ESP_PART="${BASH_REMATCH[1]}"
    else
      err "Could not parse ESP device: $ESP_DEV"
    fi

    info "Creating EFI NVRAM entry..."
    efibootmgr --create \
        --disk "$ESP_DISK" \
        --part "$ESP_PART" \
        --label "Limine" \
        --loader '\\EFI\\limine\\BOOTX64.EFI' \
        --unicode
    ok "EFI boot entry created."
  fi

  # Configure limine-snapper-sync settings
  LIMINE_DEFAULTS="/etc/default/limine"
  mkdir -p "$(dirname "$LIMINE_DEFAULTS")"

  ESP_PATH_VAL="$ESP_MOUNT"
  [[ "$ESP_PATH_VAL" == "/boot" ]] && ESP_PATH_VAL=""

  set_default_key() {
    local key="$1" value="$2"
    if grep -q "^$key=" "$LIMINE_DEFAULTS" 2>/dev/null; then
      sed -i "s|^$key=.*|$key=$value|" "$LIMINE_DEFAULTS"
    else
      printf '%s=%s\n' "$key" "$value" >> "$LIMINE_DEFAULTS"
    fi
  }

  if [[ ! -f "$LIMINE_DEFAULTS" ]]; then
    {
      echo "### OS Entry Targeting"
      echo "### Settings managed by archinstaller limine-snapper setup"
    } > "$LIMINE_DEFAULTS"
  fi

  set_default_key "TARGET_OS_NAME" "\"$NAME\""
  set_default_key "MAX_SNAPSHOT_ENTRIES" "10"
  set_default_key "LIMIT_USAGE_PERCENT" "80"
  set_default_key "ESP_PATH" "\"$ESP_PATH_VAL\""
  set_default_key "SNAPSHOT_FORMAT_CHOICE" "8"
  set_default_key "HASH_FUNCTION" "sha256"
  set_default_key "COMMANDS_BEFORE_SAVE" "\"\""
  set_default_key "COMMANDS_AFTER_SAVE" "\"\""
  set_default_key "SPACE_NUMBER" "5"
  ok "limine-snapper-sync configured at $LIMINE_DEFAULTS"

  # Generate boot entries
  step "Generating Limine boot entries..."
  LIMINE_CONF="$ESP_MOUNT/limine.conf"

  if command -v limine-update &>/dev/null; then
    info "Running limine-update to regenerate boot entries..."
    limine-update || warn "limine-update returned an error."
    ok "limine-update completed."
  fi

  if [[ -f "$LIMINE_CONF" ]] && ! grep -q 'Snapshots' "$LIMINE_CONF"; then
    printf '\n  //Snapshots\n' >> "$LIMINE_CONF"
    ok "Added //Snapshots marker to $LIMINE_CONF."
  fi

  if command -v limine-snapper-sync &>/dev/null; then
    info "Running limine-snapper-sync..."
    limine-snapper-sync || warn "limine-snapper-sync returned an error (normal on first run)."
    ok "limine-snapper-sync completed."
  fi

  # Enable limine-snapper-sync systemd service
  if systemctl list-unit-files 2>/dev/null | grep -q limine-snapper-sync; then
    systemctl enable --now limine-snapper-sync.service 2>/dev/null || true
    ok "limine-snapper-sync.service enabled."
  fi

  # Install snap-manager helper
  step "Installing snapshot manager helper..."

  cat > /usr/local/bin/snap-manager << 'HELPER_EOF'
#!/usr/bin/env bash
#
# snap-manager - Manage Btrfs snapshots with Limine integration (Arch)
#
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

case "${1:-help}" in
    create|c)
        DESC="${2:-manual snapshot}"
        snapper -c root create --description "$DESC"
        echo -e "${GREEN}Snapshot created:${NC} $DESC"
        limine-snapper-sync 2>/dev/null || true
        ;;
    list|ls)
        echo -e "${CYAN}Snapper snapshots:${NC}"
        snapper -c root list
        echo ""
        echo -e "${CYAN}Limine snapshot entries:${NC}"
        limine-snapper-list 2>/dev/null || echo "(limine-snapper-sync not available)"
        ;;
    sync)
        limine-snapper-sync
        echo -e "${GREEN}Limine snapshots synced.${NC}"
        ;;
    info|i)
        limine-snapper-info 2>/dev/null || snapper -c root list
        ;;
    delete|del|d)
        [[ -z "${2:-}" ]] && { echo "Usage: snap-manager delete <number>..."; exit 1; }
        shift
        for snap in "$@"; do
            snapper -c root delete "$snap"
            echo -e "${YELLOW}Deleted snapshot $snap${NC}"
        done
        limine-snapper-sync 2>/dev/null || true
        ;;
    restore|r)
        echo -e "${YELLOW}Restore available when booted into a snapshot.${NC}"
        echo "  sudo limine-snapper-restore <snapshot-id>"
        echo "  sudo snapper -c root rollback"
        ;;
    fix)
        CONF=$(find /boot -maxdepth 2 -name "limine.conf" 2>/dev/null | head -1)
        if [[ -n "$CONF" ]] && grep -q 'subvol=/' "$CONF"; then
            sed -i 's|subvol=/@/|subvol=@/|g' "$CONF"
            echo -e "${GREEN}Fixed subvol= paths in${NC} $CONF"
        else
            echo -e "${GREEN}No fix needed.${NC}"
        fi
        ;;
    help|--help|-h|"")
        echo -e "${CYAN}snap-manager${NC} - Btrfs snapshot management with Limine"
        echo ""
        echo "Commands:"
        echo "  create [desc]   Create a snapshot (default: 'manual snapshot')"
        echo "  list            List all snapshots"
        echo "  sync            Sync snapshot entries with Limine"
        echo "  info            Show snapshot info"
        echo "  delete <N>...   Delete snapshot(s)"
        echo "  restore         Restore instructions"
        echo "  fix             Fix subvol= paths in limine.conf"
        echo "  help            Show this help"
        ;;
    *)
        echo -e "${RED}Unknown command:${NC} $1"; exit 1 ;;
esac
HELPER_EOF

  chmod +x /usr/local/bin/snap-manager
  ok "Helper script installed: /usr/local/bin/snap-manager"

  # Summary
  echo ""
  echo -e "${GREEN}══════════════════════════════════════════════════════════════════${NC}"
  echo -e "${GREEN} Setup Complete!${NC}"
  echo -e "${GREEN}══════════════════════════════════════════════════════════════════${NC}"
  echo ""
  echo "  Limine config:     $ESP_MOUNT/limine.conf"
  echo "  Snapper config:    $SNAPPER_CONF"
  echo "  limine defaults:   $LIMINE_DEFAULTS"
  echo ""
  echo -e "${CYAN}Quick commands:${NC}"
  echo "  snap-manager list           - List all snapshots"
  echo "  snap-manager create 'desc'  - Create a snapshot"
  echo "  snap-manager sync           - Sync snapshots to Limine"
  echo "  snap-manager delete <N>     - Delete a snapshot"
  echo "  snap-manager fix            - Fix subvol= paths in limine.conf"
  echo ""
  echo -e "${CYAN}Limine commands:${NC}"
  echo "  limine-snapper-sync         - Sync boot entries"
  echo "  limine-snapper-list         - List bootable snapshots"
  echo "  limine-update               - Regenerate kernel/EFI entries"
  echo ""
  echo -e "${YELLOW}Reboot to see snapshot entries in the Limine boot menu.${NC}"
  echo -e "${YELLOW}Snapshots created by 'snap-pac' will appear automatically.${NC}"
  echo ""
  read -rp "Reboot now? [Y/n] " REBOOT_CHOICE
  if [[ "${REBOOT_CHOICE:-Y}" =~ ^[Yy]?$ ]]; then
    info "Rebooting..."
    reboot
  fi
}
