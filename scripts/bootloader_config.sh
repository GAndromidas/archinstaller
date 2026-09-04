#!/bin/bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# --- Bootloader detection ---
BOOTLOADER=$(detect_bootloader)

# Slow full initramfs rebuilds are collected here and run exactly once at the
# end of this step (UKI cmdline changes, overlayfs hook wiring, ...).
NEEDS_INITRAMFS_REBUILD=false

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

  # Hide boot text so the Plymouth theme (installed and configured by
  # archinstall) shows instead. Harmless when Plymouth is absent, and merge
  # dedups it on re-runs.
  params="$params splash vt.global_cursor_default=0"

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

  # Full cmdline with root device (fallback chain; a rootless full cmdline
  # boots into "Failed to mount '' on real root", so fail loudly instead)
  local root_uuid=""
  root_uuid=$(detect_root_uuid || true)
  if [[ -n "$root_uuid" ]]; then
    echo "root=UUID=$root_uuid rw $params"
  else
    log_error "Cannot determine root filesystem UUID for full cmdline."
    return 1
  fi
}

# ============================================================================
# KERNEL CMDLINE MERGE
# ============================================================================
# Official archinstall writes installer-chosen params (root=, cryptdevice=,
# rd.luks.uuid=, resume=, zswap.*, ...) into bootloader configs. Replacing
# those lines wholesale would drop them and render encrypted/hibernating
# systems unbootable. So this installer OWNS only the keys below and MERGES:
# existing unmanaged params are preserved verbatim, managed keys are replaced.
MANAGED_PARAM_KEYS="quiet loglevel nowatchdog splash vt.global_cursor_default nvidia_drm.modeset nvidia_drm.fbdev NVreg_DynamicPowerManagement NVreg_PreserveVideoMemoryAllocations NVreg_TemporaryFilePath radeon.si_support amdgpu.si_support radeon.cik_support amdgpu.cik_support amd_pstate i915.enable_guc rootflags"

_merge_param_key() {
  local tok="$1"
  if [[ "$tok" == *=* ]]; then
    echo "${tok%%=*}"
  else
    echo "$tok"
  fi
}

# merge_kernel_params <existing> <managed> — echo merged cmdline.
# Tokens are space-separated (kernel cmdline convention).
merge_kernel_params() {
  local existing="$1" managed="$2"
  local out=()
  local tok key seen m
  # shellcheck disable=SC2086
  for tok in $existing; do
    [[ -z "$tok" ]] && continue
    key=$(_merge_param_key "$tok")
    # Drop tokens whose key we manage (they get re-added from $managed)
    # shellcheck disable=SC2076
    if [[ " $MANAGED_PARAM_KEYS " =~ " $key " ]]; then
      continue
    fi
    # Dedupe exact repeats
    seen=false
    for m in ${out[@]+"${out[@]}"}; do
      [[ "$m" == "$tok" ]] && seen=true && break
    done
    [[ "$seen" == false ]] && out+=("$tok")
  done
  # shellcheck disable=SC2086
  for tok in $managed; do
    [[ -z "$tok" ]] && continue
    out+=("$tok")
  done
  echo "${out[*]}"
}

# detect_root_uuid — echo the live root filesystem UUID for root=UUID=.
# Fallback chain: findmnt, then blkid on the backing device (covers odd
# btrfs-subvolume and mapper layouts). Fails loudly when undetectable.
detect_root_uuid() {
  local uuid src
  uuid=$(findmnt -n -o UUID / 2>/dev/null || true)
  if [[ -n "$uuid" ]]; then
    echo "$uuid"
    return 0
  fi
  src=$(findmnt -n -o SOURCE / 2>/dev/null | cut -d'[' -f1 || true)
  if [[ -n "$src" ]]; then
    uuid=$(sudo blkid -s UUID -o value "$src" 2>/dev/null || true)
    if [[ -n "$uuid" ]]; then
      echo "$uuid"
      return 0
    fi
  fi
  return 1
}

# ensure_root_rw <cmdline> — echo cmdline with root= and rw present (added from
# live system only when missing; existing values always win).
# FAILS (return 1, no output) when no root= exists and none is detectable:
# writing a rootless entry cmdline boots into "Failed to mount '' on real
# root", so callers must skip the write instead.
ensure_root_rw() {
  local merged="$1"
  if ! echo " $merged " | grep -qE ' root=[^ ]+ '; then
    local root_uuid
    if root_uuid=$(detect_root_uuid); then
      merged="root=UUID=$root_uuid${merged:+ $merged}"
    else
      log_error "Cannot determine root filesystem UUID — refusing to write a rootless cmdline."
      return 1
    fi
  fi
  if ! echo " $merged " | grep -qE '(^| )rw( |$)'; then
    merged="$merged rw"
  fi
  echo "$merged"
}

# True when the root filesystem sits on an encrypted device (archinstall LUKS).
is_encrypted_root() {
  local src
  src=$(findmnt -n -o SOURCE / 2>/dev/null | cut -d'[' -f1 || echo "")
  [[ "$src" == /dev/mapper/* || "$src" == /dev/dm-* ]] && return 0
  lsblk -n -o NAME,FSTYPE 2>/dev/null | grep -q crypto_LUKS && \
    lsblk -n -o MOUNTPOINT 2>/dev/null | grep -qx "/" && return 0
  return 1
}

# True when UEFI Secure Boot is active (binaries are signature-checked).
is_secureboot_active() {
  local last
  last=$(od -An -tu1 /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null | awk '{print $NF}')
  [[ "$last" == "1" ]]
}

# build_file_cmdline <current-file-content> — echo the merged ROOTFUL cmdline
# for /etc/kernel/cmdline. That file feeds mkinitcpio UKI, limine-entry-tool
# AND limine-snapper-sync snapshot generation: all three need root= IN the
# file (a rootless file poisons generated snapshot entries into unbootable
# "Failed to mount '' on real root" ones). Existing root=/rw identifiers are
# proven (system boots with them) and kept; live-detected values fill gaps
# only, so re-runs are idempotent and never duplicate root=. Fails (no
# output) when no root can be established — callers must skip the write.
build_file_cmdline() {
  local current="$1"
  local full managed_part
  full=$(get_kernel_params) || return 1
  managed_part="$full"
  if echo " $current " | grep -qE ' root=[^ ]+ '; then
    managed_part=$(echo "$managed_part" | tr ' ' '\n' | grep -vE '^root=' | tr '\n' ' ' || true)
  fi
  if echo " $current " | grep -qE '(^| )rw( |$)'; then
    managed_part=$(echo "$managed_part" | tr ' ' '\n' | grep -vE '^rw$' | tr '\n' ' ' || true)
  fi
  local merged
  merged=$(merge_kernel_params "$current" "$managed_part")
  merged=$(echo "$merged" | tr -s ' ' | sed 's/^ //; s/ $//')
  if ! merged=$(ensure_root_rw "$merged"); then
    return 1
  fi
  echo "$merged"
}

# Write kernel parameters to UKI /etc/kernel/cmdline (rootful: mkinitcpio and
# downstream snapshot generators need root= IN this file)
configure_uki_cmdline() {
  local cmdline_file="/etc/kernel/cmdline"

  local current_params=""
  if [[ -f "$cmdline_file" ]]; then
    current_params=$(sudo cat "$cmdline_file" 2>/dev/null || echo "")
  fi
  local merged
  if ! merged=$(build_file_cmdline "$current_params"); then
    log_error "Refusing to write rootless UKI cmdline — leaving $cmdline_file untouched."
    return 1
  fi

  if [[ "$current_params" == "$merged" ]]; then
    log_info "UKI cmdline already configured"
  else
    [[ -f "$cmdline_file" ]] && sudo cp "$cmdline_file" "${cmdline_file}.backup.$(date +%Y%m%d_%H%M%S)"
    log_info "Backed up existing UKI cmdline"
    echo "$merged" | sudo tee "$cmdline_file" >/dev/null
    log_success "UKI cmdline written: $merged"
  fi
  log_to_file "UKI cmdline value: $merged"

  # Plymouth presets/hooks belong to archinstall — not touched here.

  # Ensure /boot/efi/EFI/Linux directory exists for UKI output
  local esp_mount
  esp_mount=$(findmnt -n -o TARGET /boot/efi 2>/dev/null || findmnt -n -o TARGET /boot 2>/dev/null || echo "/boot")
  local uki_dir="${esp_mount}/EFI/Linux"
  if [[ ! -d "$uki_dir" ]]; then
    sudo mkdir -p "$uki_dir" 2>/dev/null && \
      log_info "Created UKI output directory: $uki_dir" || \
      log_warning "Failed to create $uki_dir"
  fi

  # Defer the (slow) full rebuild: collected once at end of step 6.
  NEEDS_INITRAMFS_REBUILD=true
}

# Sync /etc/kernel/cmdline only (no image rebuild) for NVRAM-managed
# bootloaders (refind/efistub) whose cmdline lives in firmware entries.
configure_uki_cmdline_note_only() {
  local cmdline_file="/etc/kernel/cmdline"
  local current=""
  if sudo test -f "$cmdline_file" 2>/dev/null; then
    current=$(sudo cat "$cmdline_file" 2>/dev/null || echo "")
  fi
  local merged
  if ! merged=$(build_file_cmdline "$current"); then
    log_error "Refusing to write rootless $cmdline_file — leaving it untouched."
    return 1
  fi
  if [[ "$current" != "$merged" ]]; then
    [[ -n "$current" ]] && sudo cp "$cmdline_file" "${cmdline_file}.backup.$(date +%Y%m%d_%H%M%S)"
    echo "$merged" | sudo tee "$cmdline_file" >/dev/null
    log_success "Synced $cmdline_file (firmware entries still authoritative)"
  else
    log_info "$cmdline_file already up to date"
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

  if [ -n "$loader_conf" ] && sudo test -f "$loader_conf" 2>/dev/null; then
    set_loader_config "timeout" "3"
    set_loader_config "console-mode" "max"
    ui_info "Set timeout to 3s and console-mode to max (optimal settings)"
  else
    # /boot is 700 after archinstall, bare [ -f ] fails - try to create via set_loader_config
    if [ -n "$loader_conf" ] && set_loader_config "timeout" "3"; then
      set_loader_config "console-mode" "max"
      ui_info "Set timeout to 3s and console-mode to max (optimal settings) - created loader.conf"
    else
      log_warning "loader.conf not found. Skipping loader.conf configuration for systemd-boot."
    fi
  fi

  # Update kernel options in all entries with unified params
  run_step "Updating kernel options with unified parameters" update_systemd_boot_options "$kernel_params"

  run_step "Checking kernel options consistency" check_kernel_options_consistency

  # Universal snapper stack for all bootloaders (btrfs-assistant/snap-pac) when snapper present
  # Robust, not limine-only; AUR limine-snapper-sync stays limine-only
  if is_btrfs_system 2>/dev/null && pacman -Q snapper &>/dev/null; then
    run_step "Configuring Btrfs-Assistant snapshot limits" ensure_snapper_aux_universal
  elif is_btrfs_system 2>/dev/null; then
    run_step "Configuring Btrfs-Assistant snapshot limits" apply_btrfs_assistant_profile
  fi
}

# Update kernel options in systemd-boot entries - smart for archinstall dated entries
update_systemd_boot_options() {
  local new_params="$1"
  local entries_dir
  entries_dir=$(find_systemd_boot_entries_dir)

  if [ -z "$entries_dir" ]; then
    return 0
  fi

  # Smart find: archinstall creates dated entries like 2026-09-04_10-49-12_linux.conf
  # Regular entries are simple like linux.conf, linux-lts.conf
  # Use sudo find for 700 /boot, handle both patterns
  local entries=()
  while IFS= read -r -d '' entry; do
    entries+=("$entry")
  done < <(sudo find "$entries_dir" -maxdepth 1 -name "*.conf" ! -name "*fallback*" -print0 2>/dev/null)

  if [[ ${#entries[@]} -eq 0 ]]; then
    log_warning "No systemd-boot entries found in $entries_dir"
    return 0
  fi

  log_info "Found ${#entries[@]} systemd-boot entries in $entries_dir"
  for entry in "${entries[@]}"; do
    log_info "  - $(basename "$entry")"
  done

  local updated=0
  local entry
  for entry in "${entries[@]}"; do
    local entry_name=$(basename "$entry")
    # Smart detection: dated archinstall entry (2026-09-04_10-49-12_linux.conf) vs simple (linux.conf)
    if [[ "$entry_name" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}_(.*)\.conf$ ]]; then
      log_info "Dated archinstall entry detected: $entry_name -> will patch options in-place (e.g. add amd_pstate=active)"
    fi
    # Merge with the existing options line: preserves archinstall-written
    # root= (PARTUUID c9862f4f-c053-4124-a6a3-55be71016782), zswap.enabled=0, rw, rootfstype etc.
    # Only managed keys (quiet, amd_pstate, etc.) are replaced - example file keeps PARTUUID
    local existing=""
    if sudo grep -q "^options " "$entry" 2>/dev/null; then
      existing=$(sudo grep "^options " "$entry" 2>/dev/null | sed 's/^options //')
    fi

    # Build new options line (refuse rootless: a missing root= boots into
    # "Failed to mount '' on real root" — skip the entry instead)
    local new_options
    new_options=$(merge_kernel_params "$existing" "$new_params")
    if ! new_options=$(ensure_root_rw "$new_options"); then
      log_error "Skipping $(basename "$entry"): cannot ensure root= — entry left untouched."
      continue
    fi
    log_to_file "Entry $(basename "$entry") options: $new_options"

    # Update or add options line - handles files with header comments (# Created by archinstall)
    if sudo grep -q "^options " "$entry" 2>/dev/null; then
      sudo sed -i "s|^options .*|options $new_options|" "$entry"
      log_info "Patched $entry_name options (added managed params like amd_pstate=active if needed)"
    else
      echo "options $new_options" | sudo tee -a "$entry" >/dev/null
      log_info "Added options to $entry_name"
    fi
    ((updated++))
  done

  [[ $updated -gt 0 ]] && log_success "Updated kernel options in $updated systemd-boot entries (dated + simple handled)"
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
  done < <(sudo find "$entries_dir" -name "*.conf" ! -name "*fallback*" -print0 2>/dev/null)

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
    local current_options=$(sudo grep "^options " "$entry" 2>/dev/null | sed 's/^options //' || echo "")
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
      if ui_confirm "Sync all kernel entries to use the same options?" "Kernel options are inconsistent across entries — this may cause boot issues."; then
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
  done < <(sudo find "$entries_dir" -name "*.conf" ! -name "*fallback*" -print0 2>/dev/null)

  if [[ ${#kernel_entries[@]} -eq 0 ]]; then
    log_warning "No kernel entries found to sync"
    return 0
  fi

  local standard_entry="${kernel_entries[0]}"
  local standard_options=$(sudo grep "^options " "$standard_entry" 2>/dev/null | sed 's/^options //' || echo "")

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

    local current_options=$(sudo grep "^options " "$entry" 2>/dev/null | sed 's/^options //' || echo "")

    if [[ "$current_options" != "$standard_options" ]]; then
      local temp_file=$(mktemp)
      trap 'rm -f "$temp_file"' RETURN
      sudo grep -v "^options " "$entry" 2>/dev/null > "$temp_file" || grep -v "^options " "$entry" 2>/dev/null > "$temp_file" || true
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
  done < <(sudo find "$entries_dir" -name "*[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9]-[0-9][0-9]-[0-9][0-9]_*.conf" ! -name "*fallback*" -print0 2>/dev/null)

  log_info "Boot entries directory: $entries_dir"
  log_info "Found ${#dated_entries[@]} dated kernel entries"

  if [[ ${#dated_entries[@]} -eq 0 ]]; then
    log_info "No dated kernel entries found — entries already in simple format"
    # List all .conf files for debugging
    log_info "All entries in directory:"
    sudo find "$entries_dir" -name "*.conf" -exec basename {} \; 2>/dev/null | while read -r f; do
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

      if sudo test -f "$simple_path" 2>/dev/null; then
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

      if sudo test -f "$simple_path" 2>/dev/null; then
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
  # Only check for essential fields: linux and initrd.
  # sudo: entries live under /boot, which archinstall may lock to 700 —
  # bare grep would fail and wrongly reject every entry.
  if ! sudo grep -q "^linux " "$entry" 2>/dev/null; then
    log_warning "Entry $(basename "$entry") missing linux field"
    return 1
  fi

  if ! sudo grep -q "^initrd " "$entry" 2>/dev/null; then
    log_warning "Entry $(basename "$entry") missing initrd field"
    return 1
  fi

  if ! sudo grep -q "^options " "$entry" 2>/dev/null; then
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
    if sudo test -f "$f" 2>/dev/null; then
      loader_config="$f"
      break
    fi
  done

  if [[ -z "$loader_config" ]]; then
    return 0
  fi

  if sudo grep -q "^default $old_name$" "$loader_config" 2>/dev/null; then
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

    # Merge kernel parameters (quiet, splash, nvidia, etc.) with the existing
    # GRUB_CMDLINE_LINUX_DEFAULT — archinstall writes cryptdevice/resume here
    # on encrypted systems, so never replace wholesale. GRUB_CMDLINE_LINUX is
    # left untouched for the same reason (it used to be blanked — a boot
    # breaker when the installer put params there).
    local grub_current=""
    grub_current=$(grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub 2>/dev/null | cut -d= -f2- | tr -d '"' || echo "")
    local grub_merged
    grub_merged=$(merge_kernel_params "$grub_current" "$kernel_params")
    # Quote: /etc/default/grub is shell-sourced, unquoted spaces break it.
    set_grub_config "GRUB_CMDLINE_LINUX_DEFAULT" "\"$grub_merged\""
    ui_info "Kernel parameters: $grub_merged"

    local KERNELS=()
    mapfile -t KERNELS < <(sudo ls /boot/vmlinuz-* 2>/dev/null | sed 's|/boot/vmlinuz-||g')
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

    if sudo test -f "$grub_config" 2>/dev/null; then
        sudo cp "$grub_config" "$backup_grub_config" || true
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

    # Universal snapper stack for all bootloaders (btrfs-assistant/snap-pac) when snapper present
    if is_btrfs_system 2>/dev/null && pacman -Q snapper &>/dev/null; then
      run_step "Configuring Btrfs-Assistant snapshot limits" ensure_snapper_aux_universal
    elif is_btrfs_system 2>/dev/null; then
      run_step "Configuring Btrfs-Assistant snapshot limits" apply_btrfs_assistant_profile
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
        local entries_dir_derived
        entries_dir_derived=$(find_systemd_boot_entries_dir 2>/dev/null || true)
        # fallback: entries_dir from caller scope if find fails (700 /boot already handled by find)
        if [ -z "$entries_dir_derived" ] && [ -n "${entries_dir:-}" ]; then
            entries_dir_derived="$entries_dir"
        fi
        if [ -n "$entries_dir_derived" ]; then
          local derived_conf="$(dirname "$entries_dir_derived")/loader.conf"
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

    local current_content cat_status=0
    current_content=$(sudo cat "$loader_config" 2>/dev/null) || cat_status=$?
    if [ $cat_status -ne 0 ]; then
        if sudo test -f "$loader_config" 2>/dev/null; then
            log_error "Failed to read $loader_config for key '$key' (cat exit $cat_status)"
            return 1
        else
            # File doesn't exist yet (700 /boot, first run) -> create from scratch
            current_content=""
        fi
    fi

    local new_content

    # Check if the key exists, potentially commented out
    # Matches: timeout 1, #timeout 1, #console-mode keep, console-mode max
    if echo "$current_content" | grep -qE "^[#]*${key}[[:space:]]"; then
        # Replace existing or uncomment and replace (handles #console-mode keep -> console-mode max)
        new_content=$(echo "$current_content" | sed "s/^[#]*${key}[[:space:]].*/${key} ${value}/")
    else
        # Append new key-value pair if not found
        if [ -z "$current_content" ]; then
            new_content="${key} ${value}"
        else
            new_content="${current_content}
${key} ${value}"
        fi
    fi

    # Ensure directory exists (needs sudo: /boot is 700)
    local target_dir=$(dirname "$loader_config")
    if ! sudo test -d "$target_dir" 2>/dev/null; then
        sudo mkdir -p "$target_dir" 2>/dev/null || {
            log_error "Failed to create directory $target_dir"
            return 1
        }
    fi

    # Robust atomic write: uses /tmp for privileged /boot (700) so bare > never fails,
    # then sudo mv — never chmods /boot, so no revert needed and boot never breaks
    if is_boot_privileged 2>/dev/null; then
        log_info "Writing $loader_config via privileged atomic write (preserving 700)"
    fi
    if ! privileged_write "$new_content" "$loader_config"; then
        log_error "Failed to write $loader_config for key '$key'"
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
    for p in /boot /boot/efi /efi /limine; do
      if sudo test -d "$p" 2>/dev/null && findmnt -n -o FSTYPE "$p" 2>/dev/null | grep -q vfat; then
        esp="$p"
        break
      fi
    done
  fi
  [[ -n "$esp" ]] || return 1
  echo "$esp"
}

# Run a command while holding the limine-snapper-sync FAT32 mutex, so our
# limine.conf edits can't race the watcher/service mid-write (FAT32 has no
# journaling — a torn write = unbootable menu). No-op if the lib isn't
# installed yet. Usage: with_limine_lock func arg1...
with_limine_lock() {
  if [[ -r /usr/lib/limine/limine-mutex ]]; then
    # shellcheck disable=SC1091
    source /usr/lib/limine/limine-mutex
    mutex_lock "archinstaller"
    "$@"
    local rc=$?
    mutex_unlock || true
    return $rc
  else
    "$@"
  fi
}

# Helpers executed under with_limine_lock (must be plain functions, same shell)
# Kernel cmdline tokens never contain | or & — pipe delimiter is safe below.
_limine_replace_line() {
  local conf="$1" ln="$2" content="$3"
  sudo sed -i "${ln}s|^.*|$content|" "$conf"
}

_limine_append_snapshots_marker() {
  printf '\n  //Snapshots\n' | sudo tee -a "$1" >/dev/null
}

# patch_limine_cmdlines <conf> <unified> — merge unified params into BASE
# entry cmdline: lines. Snapshot entries (rootflags pointing into
# /@/.snapshots) belong to limine-snapper-sync: it derives them from the base
# entries at sync time, so patching them here would corrupt their subvol AND
# fight the watcher. They heal automatically on the next sync once the base
# and /etc/kernel/cmdline are correct.
# Lines that can't be rooted are skipped individually (left untouched); a
# rootless entry boots into "Failed to mount '' on real root", so blanking
# is never an option.
patch_limine_cmdlines() {
  local conf="$1" unified="$2"
  local entry_lns=()
  mapfile -t entry_lns < <(sudo grep -nE '^[[:space:]]*cmdline:' "$conf" 2>/dev/null | cut -d: -f1)
  if [ ${#entry_lns[@]} -eq 0 ]; then
    return 0
  fi
  sudo cp "$conf" "${conf}.backup.$(date +%Y%m%d_%H%M%S)"
  local patched=0 skipped=0 snap_skipped=0
  local ln existing merged indent
  for ln in "${entry_lns[@]}"; do
    existing=$(sudo sed -n "${ln}p" "$conf" 2>/dev/null | sed -E 's/^[[:space:]]*cmdline:[[:space:]]*//')
    if echo "$existing" | grep -q '/\.snapshots'; then
      log_to_file "Limine $conf line $ln is a snapshot entry — left for limine-snapper-sync."
      ((snap_skipped++))
      continue
    fi
    merged=$(merge_kernel_params "$existing" "$unified")
    if ! merged=$(ensure_root_rw "$merged"); then
      log_error "Skipping $conf line $ln: cannot ensure root= — left untouched."
      ((skipped++))
      continue
    fi
    indent=$(sudo sed -n "${ln}p" "$conf" 2>/dev/null | sed -E 's/^([[:space:]]*cmdline:).*/\1/')
    with_limine_lock _limine_replace_line "$conf" "$ln" "$indent $merged"
    log_to_file "Limine $conf line $ln cmdline: $merged"
    ((patched++))
  done
  log_success "Patched $patched base cmdline line(s) ($skipped refused, $snap_skipped snapshot-owned) in $conf"
}

# Thin wrappers to shared single-source in common.sh (no duplication, fast guard)
ensure_snapper_aux_universal() { snapper_ensure_aux_packages; snapper_apply_btrfs_assistant_profile; }
apply_btrfs_assistant_profile() { snapper_apply_btrfs_assistant_profile; }

# Wire the overlayfs initramfs hook from limine-mkinitcpio-hook so booting a
# read-only snapshot actually works (GDM and other writers fail without a
# writable layer). Upstream rule: btrfs-overlayfs after filesystems for
# busybox/udev hooks, sd-btrfs-overlayfs for the systemd hook.
configure_limine_overlayfs() {
  local mkconf="/etc/mkinitcpio.conf"
  if ! command -v mkinitcpio &>/dev/null || [[ ! -f "$mkconf" ]]; then
    log_info "mkinitcpio not in use — skipping overlayfs hook setup"
    return 0
  fi
  if ! pacman -Qi limine-mkinitcpio-hook &>/dev/null 2>&1; then
    return 0
  fi

  # Upstream rule: <name>-overlayfs goes after filesystems; only the hook
  # NAME differs (sd- variant for the systemd hook, plain for busybox/udev).
  local hook=""
  if grep -q "^HOOKS=.*\bsystemd\b" "$mkconf"; then
    hook="sd-btrfs-overlayfs"
    [[ -f /usr/lib/initcpio/install/sd-btrfs-overlayfs ]] || { log_warning "$hook hook file missing — skipping"; return 0; }
  else
    hook="btrfs-overlayfs"
    [[ -f /usr/lib/initcpio/install/btrfs-overlayfs ]] || { log_warning "$hook hook file missing — skipping"; return 0; }
  fi

  if grep -q "^HOOKS=.*\b$hook\b" "$mkconf"; then
    log_info "$hook already present in mkinitcpio HOOKS"
    return 0
  fi

  validate_config_file "$mkconf" >/dev/null 2>&1 || true
  if sudo sed -i "s/^\(HOOKS=.*\bfilesystems\b\)/\1 $hook/" "$mkconf" && \
     grep -q "^HOOKS=.*\b$hook\b" "$mkconf"; then
    log_success "Added $hook after filesystems in mkinitcpio (read-only snapshots can boot)"
    # Defer the (slow) full rebuild: collected once at end of step 6.
    NEEDS_INITRAMFS_REBUILD=true
  else
    log_warning "Failed to add $hook to mkinitcpio HOOKS"
  fi
}

# Limine theme - Catppuccin Mocha, better looking, clean dark
# Handles 700 /boot via privileged atomic write and FAT32 mutex, idempotent
_limine_write_file() {
  local src="$1" dst="$2"
  sudo tee "$dst" >/dev/null < "$src"
}

configure_limine_theme() {
  local conf="$1"
  if [[ -z "$conf" ]]; then
    log_warning "Limine theme: no config path, skipping"
    return 0
  fi
  # Idempotent - if already themed with correct branding, skip (migrates Archinstaller -> Arch Linux)
  if sudo grep -qE "^\s*term_palette:" "$conf" 2>/dev/null && sudo grep -qE "^\s*interface_branding:\s*Arch Linux" "$conf" 2>/dev/null; then
    log_info "Limine theme already present in $conf"
    return 0
  fi
  # Handle background.png from archinstaller wherever it is cloned ($HOME/archinstaller)
  # Robust: $SCRIPT_DIR is /path/to/archinstaller/scripts, so ../configs is /path/to/archinstaller/configs
  local wallpaper_line=""
  local bg_src=""
  for cand_src in "$SCRIPT_DIR/../configs/background.png" "$SCRIPT_DIR/configs/background.png" "./configs/background.png" "$HOME/archinstaller/configs/background.png" "$PWD/configs/background.png"; do
    if [[ -f "$cand_src" ]]; then
      bg_src="$cand_src"
      break
    fi
  done
  # Fallback: also check CONFIGS_DIR if defined
  if [[ -z "$bg_src" && -n "${CONFIGS_DIR:-}" && -f "$CONFIGS_DIR/background.png" ]]; then
    bg_src="$CONFIGS_DIR/background.png"
  fi
  if [[ -f "$bg_src" ]]; then
    local esp_for_bg
    esp_for_bg=$(findmnt -n -o TARGET -t vfat 2>/dev/null | head -1 || findmnt -n -o TARGET /boot 2>/dev/null || echo "/boot")
    local bg_dst=""
    for cand in "$esp_for_bg/background.png" "$esp_for_bg/limine/background.png" "/boot/background.png"; do
      if sudo mkdir -p "$(dirname "$cand")" 2>/dev/null && sudo cp "$bg_src" "$cand" 2>/dev/null && sudo test -f "$cand" 2>/dev/null; then
        bg_dst="boot():/background.png"
        log_success "Copied Limine wallpaper to $cand (2752x1536, Catppuccin Mocha)"
        # Also ensure limine dir copy for fallback boot():/limine/background.png
        if [[ "$cand" == "$esp_for_bg/background.png" ]]; then
          sudo mkdir -p "$esp_for_bg/limine" 2>/dev/null && sudo cp "$bg_src" "$esp_for_bg/limine/background.png" 2>/dev/null || true
        fi
        break
      fi
    done
    if [[ -n "$bg_dst" ]]; then
      wallpaper_line="wallpaper: $bg_dst
backdrop: 1e1e2e
"
    fi
  fi
  # Theme header - polished, wallpaper optional (falls back to solid term_background if no image)
  local theme="# Arch Linux Limine theme
# Clean dark, blue accent, Arch branding
timeout: 3
default_entry: 1
hash_mismatch_panic: no
graphics: yes
quiet: no
interface_branding: Arch Linux
interface_branding_colour: 89b4fa
interface_help_colour: 6c7086
editor_enabled: yes
editor_highlighting: yes
${wallpaper_line}wallpaper_style: stretched
term_palette: 1e1e2e;f38ba8;a6e3a1;f9e2af;89b4fa;f5c2e7;94e2d5;cdd6f4
term_palette_bright: 585b70;f38ba8;a6e3a1;f9e2af;89b4fa;f5c2e7;94e2d5;cdd6f4
term_background: 1e1e2e
term_foreground: cdd6f4
term_background_bright: 1e1e2e
term_foreground_bright: cdd6f4
term_margin: 64
term_margin_gradient: 4
"
  local existing=""
  if sudo test -f "$conf" 2>/dev/null; then
    existing=$(sudo cat "$conf" 2>/dev/null || echo "")
    # Remove existing global theme keys + timeout to avoid duplicates, keep entries
    existing=$(echo "$existing" | grep -vE "^\s*#*\s*(timeout:|default_entry|hash_mismatch_panic|quiet|graphics:|interface_branding|interface_help|wallpaper|backdrop|term_palette|term_background|term_foreground|term_margin|editor_)" || true)
    # Trim leading blank lines
    existing=$(echo "$existing" | sed '/./,$!d' || true)
  fi
  local tmp
  tmp=$(mktemp /tmp/limine_theme.XXXXXX 2>/dev/null || echo "/tmp/limine_theme.$$")
  {
    printf "%s" "$theme"
    if [[ -n "$existing" ]]; then
      printf "\n%s" "$existing"
    fi
  } > "$tmp"
  if [[ ! -s "$tmp" ]]; then
    log_error "Limine theme temp empty"
    rm -f "$tmp"
    return 1
  fi
  # FAT32 atomic via mutex, privileged 700
  if with_limine_lock _limine_write_file "$tmp" "$conf"; then
    log_success "Applied Limine theme to $conf (Catppuccin Mocha, Arch blue)"
  else
    log_warning "Failed to apply Limine theme to $conf"
  fi
  rm -f "$tmp"
}

# Install an AUR package using whatever helper is available.
# Optional 2nd arg pre-answers one stdin prompt (e.g. an install scriptlet
# asking Y/n) — without it, the prompt is invisible under dashboard_run
# (output goes to the log) while stdin stays live, looking like a hang.
# Returns 0 on success (or already installed), 1 otherwise. Never exits.
limine_install_aur_pkg() {
  local pkg="$1"
  local stdin_answer="${2:-}"
  if pacman -Qi "$pkg" &>/dev/null 2>&1; then
    log_info "$pkg already installed"
    return 0
  fi
  if command -v yay &>/dev/null; then
    if [[ -n "$stdin_answer" ]]; then
      local output
      if output=$(printf '%s\n' "$stdin_answer" | yay -S --noconfirm --needed "$pkg" 2>&1); then
        echo "$output" >>"$INSTALL_LOG" 2>&1
        INSTALLED_PACKAGES+=("$pkg")
        return 0
      fi
      echo "$output" >>"$INSTALL_LOG" 2>&1
      FAILED_PACKAGES+=("$pkg")
      log_warning "Failed to install $pkg via yay"
      return 1
    fi
    install_aur_quietly "$pkg" && return 0
    log_warning "Failed to install $pkg via yay"
    return 1
  elif command -v paru &>/dev/null; then
    if [[ -n "$stdin_answer" ]]; then
      if printf '%s\n' "$stdin_answer" | sudo -u "${SUDO_USER:-$USER}" paru -S --noconfirm --needed "$pkg" >>"$INSTALL_LOG" 2>&1; then
        INSTALLED_PACKAGES+=("$pkg")
        return 0
      fi
      FAILED_PACKAGES+=("$pkg")
      log_warning "Failed to install $pkg via paru"
      return 1
    fi
    if sudo -u "${SUDO_USER:-$USER}" paru -S --noconfirm --needed "$pkg" >>"$INSTALL_LOG" 2>&1; then
      return 0
    fi
    log_warning "Failed to install $pkg via paru"
    return 1
  fi
  log_warning "No AUR helper (yay/paru) — skipping $pkg. Run step 3 (yay) first."
  return 1
}

# Install limine-mkinitcpio-hook. Its install scriptlet asks
# "Would you like to run 'limine-mkinitcpio' now? [Y/n]" on stdin — ask up
# front with gum (Gaming Mode style) and pre-answer, or it hangs silently
# under the dashboard. Yes builds now (slow); No defers to our end-of-step
# rebuild, which covers it.
install_limine_mkinitcpio_hook() {
  if pacman -Qi limine-mkinitcpio-hook &>/dev/null 2>&1; then
    log_info "limine-mkinitcpio-hook already installed"
    return 0
  fi
  if ! command -v yay &>/dev/null && ! command -v paru &>/dev/null; then
    log_warning "No AUR helper — skipping limine-mkinitcpio-hook (kernel entries won't auto-update; install it later)."
    return 1
  fi
  local answer="y"
  if ui_confirm "Run limine-mkinitcpio now during install?" "The hook package asks this on stdin, hidden under the dashboard. Yes builds initramfs now (slow); No defers to the rebuild at the end of this step."; then
    answer="y"
    log_info "Will run limine-mkinitcpio during hook install."
  else
    answer="n"
    log_info "Skipping limine-mkinitcpio run during hook install (covered by step-end rebuild)."
  fi
  limine_install_aur_pkg "limine-mkinitcpio-hook" "$answer"
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
  # Full -Syu (never bare -Sy: partial upgrades break Arch).
  if ! sudo pacman -Syu --needed --noconfirm "${repo_pkgs[@]}" >>"$INSTALL_LOG" 2>&1; then
    log_error "Failed to install required packages: ${repo_pkgs[*]}"
    return 1
  fi

  # AUR snapshot integration (non-fatal if helper/packages unavailable)
  if [[ "$want_snapper" == true ]]; then
    limine_install_aur_pkg "limine-snapper-sync" || true
    # snap-pac lives in the official repos — prefer that, AUR as fallback.
    # (Step 7 installs it too when snapper is detected; --needed keeps this idempotent.)
    if ! pacman -Qi snap-pac &>/dev/null 2>&1; then
      sudo pacman -S --needed --noconfirm snap-pac >>"$INSTALL_LOG" 2>&1 || \
        limine_install_aur_pkg "snap-pac" || true
    else
      log_info "snap-pac already installed"
    fi
    if command -v mkinitcpio &>/dev/null; then
      install_limine_mkinitcpio_hook || true
    fi
    # Overlayfs hook AFTER the hook package exists: makes read-only snapshots
    # bootable (GDM and other writers fail without a writable layer).
    configure_limine_overlayfs || true
  fi

  # Configure Snapper (btrfs only) - universal stack (btrfs-assistant/snap-pac) for all bootloaders
  # Limine-specific AUR sync (limine-snapper-sync) stays limine-only, but btrfs-assistant profile is shared
  if [[ "$want_snapper" == true ]]; then
    step "Configuring Snapper..."
    if ! mountpoint -q /.snapshots 2>/dev/null; then
      sudo mount -a 2>/dev/null || true
    fi
    mountpoint -q /.snapshots 2>/dev/null || \
      log_warning "/.snapshots not mounted yet; will mount on next boot."

    # Universal snapper aux (btrfs-assistant/snap-pac) + ArchWiki profile - not limine-only
    ensure_snapper_aux_universal

    sudo systemctl enable --now snapper-timeline.timer 2>/dev/null || true
    sudo systemctl enable --now snapper-cleanup.timer 2>/dev/null || true
    log_success "Snapper timers enabled."
  fi

  # Locate an existing Limine install or deploy fresh.
  # Official archinstall deploys to <esp>/EFI/arch-limine/ — or <esp>/EFI/BOOT/
  # when "removable" (its UEFI default) — with limine.conf alongside the EFI
  # binary. Refreshing in place is critical: deploying a second copy elsewhere
  # would not be the copy the firmware boots.
  step "Locating Limine EFI binary..."

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

  local limine_dir="" limine_conf=""
  local d
  for d in "$esp_mount/EFI/arch-limine" "$esp_mount/EFI/BOOT" "$esp_mount/EFI/limine" \
           "$esp_mount/limine" /boot/limine /boot; do
    if sudo test -f "$d/BOOTX64.EFI" 2>/dev/null || sudo test -f "$d/BOOTIA32.EFI" 2>/dev/null || \
       sudo test -f "$d/BOOTAA64.EFI" 2>/dev/null || sudo test -f "$d/limine_x64.efi" 2>/dev/null || \
       sudo test -f "$d/limine.conf" 2>/dev/null; then
      limine_dir="$d"
      limine_conf="$d/limine.conf"
      break
    fi
  done

  if [[ -n "$limine_dir" ]]; then
    # Refresh-in-place keeps the booted copy current — EXCEPT under Secure
    # Boot, where the deployed binary is sbctl-signed and overwriting it
    # breaks verification.
    if is_secureboot_active; then
      log_warning "Secure Boot is active — leaving signed Limine binary untouched (re-sign with sbctl after manual updates)."
    else
      log_info "Existing Limine install found at $limine_dir — refreshing binary in place."
      local efi_src_dir
      efi_src_dir=$(dirname "$limine_efi_src")
      local f
      for f in BOOTX64.EFI BOOTIA32.EFI BOOTAA64.EFI; do
        if sudo test -f "$limine_dir/$f" 2>/dev/null && [[ -f "$efi_src_dir/$f" ]]; then
          sudo cp "$efi_src_dir/$f" "$limine_dir/$f" && \
            log_success "Refreshed $limine_dir/$f"
        fi
      done
      if sudo test -f "$limine_dir/limine_x64.efi" 2>/dev/null; then
        # limine-entry-tool naming — refresh from upstream if the file exists
        for p in "$efi_src_dir/limine_x64.efi" "$limine_efi_src"; do
          if [[ -f "$p" ]]; then
            sudo cp "$p" "$limine_dir/limine_x64.efi" && log_success "Refreshed $limine_dir/limine_x64.efi"
            break
          fi
        done
      fi
    fi
  else
    # No existing install — fresh deploy in archinstall's non-removable layout,
    # plus the same pacman hook archinstall writes so upgrades redeploy.
    limine_dir="$esp_mount/EFI/limine"
    limine_conf="$limine_dir/limine.conf"
    step "Deploying Limine EFI binary..."
    sudo mkdir -p "$limine_dir"
    sudo cp "$limine_efi_src" "$limine_dir/BOOTX64.EFI"
    log_success "Limine EFI binary deployed to $limine_dir."

    local hook_dir="/etc/pacman.d/hooks"
    sudo mkdir -p "$hook_dir"
    if ! sudo test -f "$hook_dir/99-limine.hook" 2>/dev/null; then
      printf '%s\n' "[Trigger]" "Operation = Install" "Operation = Upgrade" "Type = Package" \
        "Target = limine" "" "[Action]" "Description = Deploying Limine after upgrade..." \
        "When = PostTransaction" "Exec = /bin/sh -c \"/usr/bin/cp /usr/share/limine/BOOTX64.EFI $limine_dir/\"" | \
        sudo tee "$hook_dir/99-limine.hook" >/dev/null
      log_success "Limine pacman hook installed."
    fi

    # Fresh deploy has no config yet — write a minimal archinstall-style one,
    # but only when kernels live on the ESP (Limine reads FAT only). With a
    # separate ESP + non-UKI kernels on ext4/btrfs /boot, Limine cannot read
    # them — same layout rule archinstall itself enforces.
    if [[ "$esp_mount" == "/boot" ]]; then
      local fresh_kernels=()
      mapfile -t fresh_kernels < <(sudo ls /boot/vmlinuz-* 2>/dev/null | sed 's|/boot/vmlinuz-||g')
      if [[ ${#fresh_kernels[@]} -gt 0 ]]; then
        local full_params
        if ! full_params=$(get_kernel_params) || ! echo " $full_params " | grep -qE ' root=[^ ]+ '; then
          log_error "Cannot build a rooted cmdline — refusing to write a rootless fresh limine.conf."
          return 1
        fi
        {
          echo "timeout: 3"
          local k
          for k in "${fresh_kernels[@]}"; do
            printf '\n/Arch Linux (%s)\n' "$k"
            echo "    protocol: linux"
            echo "    path: boot():/vmlinuz-$k"
            echo "    cmdline: $full_params"
            echo "    module_path: boot():/initramfs-$k.img"
          done
        } | sudo tee "$limine_conf" >/dev/null
        log_success "Wrote minimal Limine config with ${#fresh_kernels[@]} kernel entries."
      else
        log_warning "No kernels in /boot — skipping initial limine.conf."
      fi
    else
      log_error "ESP ($esp_mount) is separate from /boot and no UKI is configured — Limine cannot read non-FAT /boot. Enable UKI or use a FAT /boot (see ArchWiki Limine)."
    fi
  fi

  # Apply Limine theme for better looking boot menu - handles all locations including /boot/limine.conf (user's case)
  # Robust for 700 /boot via privileged write + FAT32 mutex, idempotent, handles auto-generated limine-entry-tool
  {
    local _theme_targets=()
    [[ -n "${limine_conf:-}" ]] && _theme_targets+=("$limine_conf")
    [[ -n "${limine_dir:-}" ]] && _theme_targets+=("$limine_dir/limine.conf")
    _theme_targets+=("/boot/limine.conf" "/boot/limine/limine.conf" "$esp_mount/limine.conf" "$esp_mount/EFI/limine/limine.conf" "$esp_mount/EFI/BOOT/limine.conf" "/boot/EFI/limine/limine.conf")
    local _seen=" "
    local _lc
    for _lc in "${_theme_targets[@]}"; do
      [[ -n "$_lc" ]] || continue
      if [[ "$_seen" == *" $_lc "* ]]; then continue; fi
      _seen+="$_lc "
      if sudo test -f "$_lc" 2>/dev/null; then
        configure_limine_theme "$_lc"
      fi
    done
    unset _lc _theme_targets _seen
  }

  # Ensure an NVRAM entry exists pointing at the REAL install dir (firmware
  # entries get wiped by updates/resets; archinstall skips this for removable
  # installs, so re-check every run). Loader path is ESP-relative.
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
      log_warning "Could not parse ESP device ($esp_dev) — skipping NVRAM entry. Select ${limine_dir} manually in firmware."
      esp_disk=""
    fi

    if [[ -n "${esp_disk:-}" ]]; then
      # ESP-relative loader path, e.g. /boot/EFI/arch-limine -> \EFI\arch-limine\BOOTX64.EFI
      local efi_bin="BOOTX64.EFI"
      sudo test -f "$limine_dir/$efi_bin" 2>/dev/null || efi_bin=$(sudo ls "$limine_dir" 2>/dev/null | grep -im1 '\.efi$' || echo "BOOTX64.EFI")
      local loader_path="${limine_dir#$esp_mount}/$efi_bin"
      loader_path=${loader_path//\//\\}
      log_info "Creating EFI NVRAM entry ($loader_path)..."
      if sudo efibootmgr --create \
          --disk "$esp_disk" \
          --part "$esp_part" \
          --label "Limine" \
          --loader "$loader_path" \
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
    # auto prunes by boot-partition usage (upstream default) instead of a hard
    # cap; LIMIT 80 stays stricter than upstream's 85.
    limine_set_default_key "MAX_SNAPSHOT_ENTRIES" "auto"
    limine_set_default_key "LIMIT_USAGE_PERCENT" "80"
    limine_set_default_key "ESP_PATH" "\"$esp_path_val\""
    # replace is upstream's default and the right method for Arch @-subvolume
    # layouts (rsync also works; snapper/opensuse needs an OpenSUSE layout).
    limine_set_default_key "RESTORE_METHOD" "replace"
    # Skip snapper's config autodetect on every run — we always use root.
    limine_set_default_key "SNAPPER_CONFIG_NAME" "root"
    limine_set_default_key "SNAPSHOT_FORMAT_CHOICE" "8"
    # sha256 via coreutils is always present; xxhash needs an extra package.
    limine_set_default_key "HASH_FUNCTION" "sha256"
    limine_set_default_key "COMMANDS_BEFORE_SAVE" "\"\""
    limine_set_default_key "COMMANDS_AFTER_SAVE" "\"\""
    limine_set_default_key "SPACE_NUMBER" "5"
    log_success "limine-snapper-sync configured at $limine_defaults"
  fi

  # Kernel parameters for non-UKI Limine. Official archinstall writes per-entry
  # `    cmdline:` lines into limine.conf, so patch those in place. Also sync
  # /etc/kernel/cmdline (the shared default consulted by mkinitcpio, dracut
  # and limine-entry-tool). Snapshot entries derive from the base entries, so
  # this must run BEFORE limine-snapper-sync below.
  step "Updating Limine kernel parameters..."
  local unified_cmdline
  unified_cmdline=$(get_kernel_params --cmdline-only)
  # Rootful shared file: snapshot generation derives from it, so it must
  # carry root= (a rootless file poisons every new snapshot entry).
  local cmdline_file="/etc/kernel/cmdline"
  local current_cmdline=""
  if sudo test -f "$cmdline_file" 2>/dev/null; then
    current_cmdline=$(sudo cat "$cmdline_file" 2>/dev/null || echo "")
  fi
  local merged_cmdline
  if ! merged_cmdline=$(build_file_cmdline "$current_cmdline"); then
    log_error "Refusing to write rootless $cmdline_file — leaving it untouched."
  elif [[ "$current_cmdline" != "$merged_cmdline" ]]; then
    [[ -n "$current_cmdline" ]] && sudo cp "$cmdline_file" "${cmdline_file}.backup.$(date +%Y%m%d_%H%M%S)"
    echo "$merged_cmdline" | sudo tee "$cmdline_file" >/dev/null
    log_success "Updated $cmdline_file"
  else
    log_info "$cmdline_file already up to date"
  fi
  log_to_file "/etc/kernel/cmdline value: ${merged_cmdline:-<unchanged>}"

  # Secure Boot with enrolled config checksum: editing limine.conf (or the
  # binary) breaks verification. Warn and skip file edits; packages/snapper
  # above are unaffected.
  local skip_conf_edit=false
  if is_secureboot_active; then
    if sudo grep -q "^ENABLE_ENROLL_LIMINE_CONFIG=yes" /etc/default/limine 2>/dev/null; then
      log_warning "Secure Boot + enrolled Limine config detected — skipping limine.conf edits (re-enroll with limine-enroll-config after changing params)."
      skip_conf_edit=true
    else
      log_warning "Secure Boot is active — binary/config signatures left untouched where verification applies."
    fi
  fi

  if command -v limine-update &>/dev/null; then
    log_info "Regenerating entries with limine-update (reads $cmdline_file)..."
    if sudo limine-update >>"$INSTALL_LOG" 2>&1; then
      log_success "limine-update completed."
    else
      log_warning "limine-update returned an error."
    fi
  fi

  # Patch EVERY cmdline: line in limine.conf (base + snapshot entries), even
  # after limine-update just regenerated them: tools write entries from their
  # own sources and can drop root=, which boots into "Failed to mount '' on
  # real root". Lines that can't be rooted are LEFT UNTOUCHED, never blanked.
  if [[ "$skip_conf_edit" == true ]]; then
    : # warned above (Secure Boot enrolled config)
  elif sudo test -f "$limine_conf" 2>/dev/null; then
    if sudo grep -qE '^[[:space:]]*cmdline:' "$limine_conf" 2>/dev/null; then
      patch_limine_cmdlines "$limine_conf" "$unified_cmdline"
    else
      log_warning "No cmdline entries in $limine_conf — leaving it untouched."
    fi
  else
    log_warning "Limine config not found at $limine_conf — skipping kernel parameter update."
  fi

  if [[ "$want_snapper" == true ]]; then
    if sudo test -f "$limine_conf" 2>/dev/null && ! sudo grep -q 'Snapshots' "$limine_conf" 2>/dev/null; then
      with_limine_lock _limine_append_snapshots_marker "$limine_conf"
      log_success "Added //Snapshots marker to $limine_conf."
    fi

    if command -v limine-snapper-sync &>/dev/null; then
      log_info "Running limine-snapper-sync (also heals stale snapshot cmdlines from the fixed base)..."
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

  # Final verification AFTER the sync above: every cmdline must name a root
  # device. Anything still rootless is NOT safe to boot.
  if sudo test -f "$limine_conf" 2>/dev/null; then
    local bad_lines
    bad_lines=$(sudo grep -E '^[[:space:]]*cmdline:' "$limine_conf" 2>/dev/null | grep -vE 'root=[^ ]+' || true)
    if [[ -n "$bad_lines" ]]; then
      log_error "Rootless cmdline lines remain in $limine_conf — DO NOT boot these entries:"
      echo "$bad_lines" | while IFS= read -r bl; do log_error "  $bl"; done
    else
      log_success "All Limine cmdline entries name a root device."
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
        echo -e "${YELLOW}Boot into a snapshot from the Limine menu first, then restore.${NC}"
        echo "  sudo limine-snapper-restore    # guided restore (recommended)"
        echo "  (snapper rollback only works on OpenSUSE-style layouts)"
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

# Report ESP/boot readability up front: on archinstall systems /boot is often
# root-only, and every silent "not found, skipping" below traces back to this.
report_boot_access() {
  local esp
  esp=$(detect_esp_mount || echo "unknown")
  log_info "ESP mountpoint: $esp"
  local perms
  perms=$(sudo stat -c '%a %U:%G' /boot 2>/dev/null || echo "unreadable")
  log_info "/boot perms: $perms"
  if sudo ls /boot >/dev/null 2>&1; then
    log_info "/boot readable via sudo — privileged reads enabled."
  else
    log_error "/boot NOT readable even via sudo — bootloader tuning will be skipped."
  fi
}

# Bootloader-specific configuration (kernel params + bootloader settings)
log_info "Detected bootloader: $BOOTLOADER"
report_boot_access
if is_encrypted_root; then
  log_info "Encrypted root detected — existing crypt device parameters will be preserved, never replaced."
fi
if [ "$BOOTLOADER" = "grub" ]; then
    configure_grub
elif [ "$BOOTLOADER" = "systemd-boot" ]; then
    configure_boot
elif [ "$BOOTLOADER" = "limine" ]; then
    configure_limine_snapper
elif [ "$BOOTLOADER" = "refind" ] || [ "$BOOTLOADER" = "efistub" ]; then
    # rEFInd/EFISTUB are NVRAM-managed: there are no loader entries or
    # grub.cfg semantics to tune, and writing systemd-boot files here would
    # create configs the firmware never reads. Sync the shared cmdline file
    # and leave boot alone.
    log_warning "$BOOTLOADER manages boot via NVRAM — skipping bootloader tuning (no files written)."
    log_info "To change kernel params for $BOOTLOADER, update your NVRAM boot entries (efibootmgr) manually."
    configure_uki_cmdline_note_only
else
    log_warning "No bootloader detected or bootloader is unsupported. Defaulting to systemd-boot configuration."
    configure_boot
fi

# Single collected initramfs rebuild for the whole step (was up to 3× -P).
# limine-mkinitcpio-hook installs an alpm hook that asks
# "Would you like to run 'limine-mkinitcpio' now? [Y/n]" on stdin.
# Under dashboard_run stdout is on the log and stdin is live — answering
# is invisible and looks like a hang (UI shows the earlier Yes/No but this
# second prompt has no UI). Pre-answer with 'n': limine entries were already
# updated via limine-update/limine-mkinitcpio above, this is just the
# plain mkinitcpio image for /boot/initramfs-*.img.
if [[ "$NEEDS_INITRAMFS_REBUILD" == true ]]; then
  if [[ -d /etc/mkinitcpio.d ]] && command -v mkinitcpio &>/dev/null; then
    ui_info "Regenerating initramfs (all pending step-6 changes)..."
    if printf 'n\n' | sudo mkinitcpio -P 2>&1 | tee -a "$INSTALL_LOG" >/dev/null; then
      log_success "Initramfs regenerated"
    else
      log_warning "Initramfs regeneration had issues — check mkinitcpio presets"
    fi
  else
    log_info "Initramfs rebuild requested but mkinitcpio not in use — skipping"
  fi
fi
