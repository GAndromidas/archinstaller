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
      # Intel: Enable GuC/HuC firmware only when GuC firmware actually ships
      # for this machine (Gen 9.5+). Unconditional enable_guc on old iGPUs can
      # stall firmware loading, so gate on /lib/firmware/i915/*guc*.
      if compgen -G "/lib/firmware/i915/*guc*" >/dev/null 2>&1; then
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
    if sudo mkinitcpio -P 2>&1 | tee -a "$INSTALL_LOG" >/dev/null; then
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

    local KERNELS=()
    mapfile -t KERNELS < <(ls /boot/vmlinuz-* 2>/dev/null | sed 's|/boot/vmlinuz-||g')
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
        if sudo grub-mkconfig -o "$grub_cfg" 2>&1 | tee -a "$INSTALL_LOG" >/dev/null; then
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
# LIMINE HELPERS (must be defined before MAIN EXECUTION dispatch below)
# ============================================================================

# Detect ESP mountpoint (vfat partition). Echoes path, returns 1 if not found.
detect_esp_mount() {
  local esp
  esp=$(findmnt -n -o TARGET -t vfat 2>/dev/null | head -1 || true)
  if [[ -z "$esp" ]]; then
    local p
    for p in /boot /boot/efi /efi; do
      if [[ -d "$p" ]] && findmnt -n -o FSTYPE "$p" 2>/dev/null | grep -q vfat; then
        esp="$p"
        break
      fi
    done
  fi
  [[ -n "$esp" ]] || return 1
  echo "$esp"
}

# Install an AUR package using whatever helper is available.
# Returns 0 on success (or already installed), 1 otherwise. Never exits.
limine_install_aur_pkg() {
  local pkg="$1"
  if pacman -Qi "$pkg" &>/dev/null 2>&1; then
    log_info "$pkg already installed"
    return 0
  fi
  if command -v yay &>/dev/null; then
    install_aur_quietly "$pkg" && return 0
    log_warning "Failed to install $pkg via yay"
    return 1
  elif command -v paru &>/dev/null; then
    if sudo -u "${SUDO_USER:-$USER}" paru -S --noconfirm --needed "$pkg" >>"$INSTALL_LOG" 2>&1; then
      return 0
    fi
    log_warning "Failed to install $pkg via paru"
    return 1
  fi
  log_warning "No AUR helper (yay/paru) — skipping $pkg. Run step 3 (yay) first."
  return 1
}

# --- Limine + Snapper Configuration ---
configure_limine_snapper() {
  step "Configuring Limine bootloader with Snapper support"

  if is_uki_system; then
    log_info "UKI system — configuring /etc/kernel.cmdline"
    configure_uki_cmdline
    ui_info "UKI system detected — kernel parameters configured via /etc/kernel.cmdline"
    return 0
  fi

  if [ ! -d /sys/firmware/efi ]; then
    log_error "Limine requires UEFI boot; legacy BIOS detected. Skipping Limine setup."
    return 1
  fi

  local esp_mount
  if ! esp_mount=$(detect_esp_mount); then
    log_error "Could not detect ESP mountpoint (vfat partition). Skipping Limine setup."
    return 1
  fi
  log_info "ESP mountpoint: $esp_mount"

  # Snapper needs btrfs on /. Without it, still configure Limine kernel entries
  # but skip snapshot integration instead of failing the whole step.
  local want_snapper=true
  if ! findmnt -n -o FSTYPE / 2>/dev/null | grep -q btrfs; then
    log_warning "Root is not btrfs — Limine will be configured without Snapper snapshots."
    want_snapper=false
  fi

  # Install required packages
  step "Installing Limine and Snapper packages"
  local repo_pkgs=(limine efibootmgr)
  if [[ "$want_snapper" == true ]]; then
    repo_pkgs+=(btrfs-progs snapper)
  fi
  if ! sudo pacman -Sy --needed --noconfirm "${repo_pkgs[@]}" >>"$INSTALL_LOG" 2>&1; then
    log_error "Failed to install required packages: ${repo_pkgs[*]}"
    return 1
  fi

  # AUR snapshot integration (non-fatal if helper/packages unavailable)
  if [[ "$want_snapper" == true ]]; then
    limine_install_aur_pkg "limine-snapper-sync" || true
    limine_install_aur_pkg "snap-pac" || true
    if command -v mkinitcpio &>/dev/null; then
      if ! pacman -Qi limine-mkinitcpio-hook &>/dev/null 2>&1; then
        limine_install_aur_pkg "limine-mkinitcpio-hook" || true
      fi
    fi
  fi

  # Configure Snapper (btrfs only)
  local snapper_conf="/etc/snapper/configs/root"
  if [[ "$want_snapper" == true ]]; then
    step "Configuring Snapper..."
    if [[ ! -f "$snapper_conf" ]]; then
      sudo snapper -c root create-config / >>"$INSTALL_LOG" 2>&1 || \
        log_warning "snapper create-config failed (may already be configured)."
    fi

    if ! mountpoint -q /.snapshots 2>/dev/null; then
      sudo mount -a 2>/dev/null || true
    fi
    mountpoint -q /.snapshots 2>/dev/null || \
      log_warning "/.snapshots not mounted yet; will mount on next boot."

    if [[ -f "$snapper_conf" ]]; then
      sudo sed -i 's/^TIMELINE_MIN_AGE=.*/TIMELINE_MIN_AGE="1800"/' "$snapper_conf"
      sudo sed -i 's/^TIMELINE_LIMIT_HOURLY=.*/TIMELINE_LIMIT_HOURLY="5"/' "$snapper_conf"
      sudo sed -i 's/^TIMELINE_LIMIT_DAILY=.*/TIMELINE_LIMIT_DAILY="7"/' "$snapper_conf"
      sudo sed -i 's/^TIMELINE_LIMIT_WEEKLY=.*/TIMELINE_LIMIT_WEEKLY="0"/' "$snapper_conf"
      sudo sed -i 's/^TIMELINE_LIMIT_MONTHLY=.*/TIMELINE_LIMIT_MONTHLY="0"/' "$snapper_conf"
      sudo sed -i 's/^TIMELINE_LIMIT_YEARLY=.*/TIMELINE_LIMIT_YEARLY="0"/' "$snapper_conf"
      log_success "Snapper timeline limits configured."
    fi

    sudo systemctl enable --now snapper-timeline.timer 2>/dev/null || true
    sudo systemctl enable --now snapper-cleanup.timer 2>/dev/null || true
    log_success "Snapper timers enabled."
  fi

  # Deploy Limine EFI binary
  step "Deploying Limine EFI binary..."

  local limine_efi_src=""
  local p
  for p in \
    /usr/share/limine/BOOTX64.EFI \
    /usr/lib/limine/BOOTX64.EFI \
    /usr/share/limine/limine-x86_64.efi; do
    if [[ -f "$p" ]]; then
      limine_efi_src="$p"
      break
    fi
  done
  if [[ -z "$limine_efi_src" ]]; then
    log_error "Limine EFI binary not found under /usr/share/limine or /usr/lib/limine."
    return 1
  fi
  local limine_efi_dir="$esp_mount/EFI/limine"
  sudo mkdir -p "$limine_efi_dir"
  sudo cp "$limine_efi_src" "$limine_efi_dir/BOOTX64.EFI"
  log_success "Limine EFI binary deployed."

  # Create EFI NVRAM entry if missing
  if sudo efibootmgr 2>/dev/null | grep -qi limine; then
    log_info "Limine EFI boot entry already exists."
  else
    local esp_dev esp_disk esp_part
    esp_dev=$(findmnt -n -o SOURCE "$esp_mount" 2>/dev/null || true)
    if [[ "$esp_dev" =~ ^/dev/nvme[0-9]+n[0-9]+p([0-9]+)$ ]]; then
      esp_disk="${esp_dev%p*}"
      esp_part="${BASH_REMATCH[1]}"
    elif [[ "$esp_dev" =~ ^/dev/(.+)(p[0-9]+)$ ]]; then
      esp_disk="/dev/${BASH_REMATCH[1]}"
      esp_part="${BASH_REMATCH[2]#p}"
    elif [[ "$esp_dev" =~ ^/dev/[a-z]+([0-9]+)$ ]]; then
      esp_disk="${esp_dev%[0-9]*}"
      esp_part="${BASH_REMATCH[1]}"
    else
      log_warning "Could not parse ESP device ($esp_dev) — skipping NVRAM entry. Select EFI/limine/BOOTX64.EFI manually."
      esp_disk=""
    fi

    if [[ -n "${esp_disk:-}" ]]; then
      log_info "Creating EFI NVRAM entry..."
      if sudo efibootmgr --create \
          --disk "$esp_disk" \
          --part "$esp_part" \
          --label "Limine" \
          --loader '\\EFI\\limine\\BOOTX64.EFI' \
          --unicode >>"$INSTALL_LOG" 2>&1; then
        log_success "EFI boot entry created."
      else
        log_warning "efibootmgr failed — you may need to create the Limine entry manually."
      fi
    fi
  fi

  # Configure limine-snapper-sync settings (btrfs only)
  local limine_defaults="/etc/default/limine"
  sudo mkdir -p "$(dirname "$limine_defaults")"

  if [[ "$want_snapper" == true ]]; then
    local esp_path_val="$esp_mount"
    [[ "$esp_path_val" == "/boot" ]] && esp_path_val=""

    local os_name="Arch Linux"
    if [[ -r /etc/os-release ]]; then
      # shellcheck disable=SC1091
      . /etc/os-release
      [[ -n "${NAME:-}" ]] && os_name="$NAME"
    fi

    # Create file with sudo if missing (redirection must not run as user)
    if ! sudo test -f "$limine_defaults" 2>/dev/null; then
      printf '%s\n' "### OS Entry Targeting" "### Settings managed by archinstaller limine-snapper setup" | \
        sudo tee "$limine_defaults" >/dev/null
    fi

    limine_set_default_key() {
      local key="$1" value="$2"
      if sudo grep -q "^$key=" "$limine_defaults" 2>/dev/null; then
        sudo sed -i "s|^$key=.*|$key=$value|" "$limine_defaults"
      else
        printf '%s=%s\n' "$key" "$value" | sudo tee -a "$limine_defaults" >/dev/null
      fi
    }

    limine_set_default_key "TARGET_OS_NAME" "\"$os_name\""
    limine_set_default_key "MAX_SNAPSHOT_ENTRIES" "10"
    limine_set_default_key "LIMIT_USAGE_PERCENT" "80"
    limine_set_default_key "ESP_PATH" "\"$esp_path_val\""
    limine_set_default_key "SNAPSHOT_FORMAT_CHOICE" "8"
    limine_set_default_key "HASH_FUNCTION" "sha256"
    limine_set_default_key "COMMANDS_BEFORE_SAVE" "\"\""
    limine_set_default_key "COMMANDS_AFTER_SAVE" "\"\""
    limine_set_default_key "SPACE_NUMBER" "5"
    log_success "limine-snapper-sync configured at $limine_defaults"
  fi

  # Generate boot entries
  step "Generating Limine boot entries..."
  local limine_conf="$esp_mount/limine.conf"

  if command -v limine-update &>/dev/null; then
    log_info "Running limine-update to regenerate boot entries..."
    if sudo limine-update >>"$INSTALL_LOG" 2>&1; then
      log_success "limine-update completed."
    else
      log_warning "limine-update returned an error."
    fi
  fi

  if [[ "$want_snapper" == true ]]; then
    if sudo test -f "$limine_conf" 2>/dev/null && ! sudo grep -q 'Snapshots' "$limine_conf" 2>/dev/null; then
      printf '\n  //Snapshots\n' | sudo tee -a "$limine_conf" >/dev/null
      log_success "Added //Snapshots marker to $limine_conf."
    fi

    if command -v limine-snapper-sync &>/dev/null; then
      log_info "Running limine-snapper-sync..."
      if sudo limine-snapper-sync >>"$INSTALL_LOG" 2>&1; then
        log_success "limine-snapper-sync completed."
      else
        log_warning "limine-snapper-sync returned an error (normal on first run)."
      fi
    fi

    if systemctl list-unit-files 2>/dev/null | grep -q limine-snapper-sync; then
      sudo systemctl enable --now limine-snapper-sync.service 2>/dev/null || true
      log_success "limine-snapper-sync.service enabled."
    fi
  fi

  # Install snap-manager helper (btrfs only; harmless to skip otherwise)
  if [[ "$want_snapper" == true ]]; then
  step "Installing snapshot manager helper..."

  sudo tee /usr/local/bin/snap-manager >/dev/null << 'HELPER_EOF'
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

  sudo chmod +x /usr/local/bin/snap-manager
  log_success "Helper script installed: /usr/local/bin/snap-manager"
  fi

  # Summary (no reboot here — the main installer offers one reboot at the end)
  log_success "Limine setup complete: $esp_mount/limine.conf"
  if [[ "$want_snapper" == true ]]; then
    log_info "Snapshots created by snap-pac will appear in the Limine menu after reboot."
    log_info "Useful: snap-manager list | snap-manager create 'desc' | snap-manager sync"
  else
    log_info "Reboot at the end of the install to boot via Limine."
  fi
}

# ============================================================================
# MAIN EXECUTION (dispatch AFTER all function definitions)
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
