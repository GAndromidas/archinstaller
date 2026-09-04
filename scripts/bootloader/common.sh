#!/bin/bash
set -uo pipefail

# ============================================================================
# Bootloader Common Library - Kernel Parameters & Utilities
# ============================================================================
# Shared utilities for bootloader configuration across all bootloader types
# (systemd-boot, GRUB, Limine). Handles UKI cmdline, kernel params, and utils.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

# Global state for deferred initramfs rebuilds
export NEEDS_INITRAMFS_REBUILD=false

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
# FAILS (return 1, no output) when no root= exists and none is detectable.
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
# for /etc/kernel/cmdline. Existing root=/rw identifiers are kept; live-detected
# values fill gaps only for idempotent re-runs.
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

# Write kernel parameters to UKI /etc/kernel/cmdline
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
