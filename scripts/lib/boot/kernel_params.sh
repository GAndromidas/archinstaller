#!/bin/bash
set -uo pipefail

# Pure kernel-cmdline helpers — single source of truth.
# Extracted from scripts/modules/bootloader_config.sh so unit tests can
# source the real code instead of maintaining mirrors. No side effects on
# source; safe to load from install.sh, modules, and tests/unit.sh.

# get_kernel_params() no longer generates video=WxH or nowatchdog, so keeping
# the keys here strips those stale tokens from existing entries on the next
# run instead of preserving them.
MANAGED_PARAM_KEYS="quiet loglevel nowatchdog splash vt.global_cursor_default nvidia_drm.modeset nvidia_drm.fbdev NVreg_DynamicPowerManagement NVreg_PreserveVideoMemoryAllocations NVreg_TemporaryFilePath radeon.si_support amdgpu.si_support radeon.cik_support amdgpu.cik_support amd_pstate i915.enable_guc rootflags video"

if ! declare -f _merge_param_key >/dev/null 2>&1; then
_merge_param_key() {
  local tok="${1:-}"
  if [[ "$tok" == *=* ]]; then
    echo "${tok%%=*}"
  else
    echo "$tok"
  fi
}
fi

# merge_kernel_params <existing> <managed> — echo merged cmdline.
# Tokens are space-separated (kernel cmdline convention).
if ! declare -f merge_kernel_params >/dev/null 2>&1; then
merge_kernel_params() {
  local existing="${1:-}" managed="${2:-}"
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
fi

# strip_managed_dupes <line> <reference> — drop tokens from <line> whose
# managed key also appears in <reference>. GRUB boots with CMDLINE_LINUX +
# CMDLINE_LINUX_DEFAULT concatenated, so a managed key (quiet, rootflags,
# ...) present in both lands on /proc/cmdline twice. Unmanaged tokens
# (cryptdevice, resume, ...) are always kept.
if ! declare -f strip_managed_dupes >/dev/null 2>&1; then
strip_managed_dupes() {
  local line="${1:-}" reference="${2:-}"
  local ref_keys=() out=()
  local tok key m managed seen
  # shellcheck disable=SC2086
  for m in $reference; do
    [[ -z "$m" ]] && continue
    ref_keys+=("$(_merge_param_key "$m")")
  done
  # shellcheck disable=SC2086
  for tok in $line; do
    [[ -z "$tok" ]] && continue
    key=$(_merge_param_key "$tok")
    managed=false
    # shellcheck disable=SC2076
    if [[ " $MANAGED_PARAM_KEYS " =~ " $key " ]]; then
      managed=true
    fi
    if [[ "$managed" == true && " ${ref_keys[*]} " == *" $key "* ]]; then
      continue
    fi
    seen=false
    for m in ${out[@]+"${out[@]}"}; do
      [[ "$m" == "$tok" ]] && seen=true && break
    done
    [[ "$seen" == false ]] && out+=("$tok")
  done
  echo "${out[*]}"
}
fi

# detect_root_uuid — echo the live root filesystem UUID for root=UUID=.
# Fallback chain: findmnt, then blkid on the backing device (covers odd
# btrfs-subvolume and mapper layouts). Fails loudly when undetectable.
if ! declare -f detect_root_uuid >/dev/null 2>&1; then
detect_root_uuid() {
  local uuid src
  uuid=$(findmnt -n -o UUID / 2>/dev/null || true)
  if [[ -n "$uuid" ]]; then
    echo "$uuid"
    return 0
  fi
  src=$(findmnt -n -o SOURCE / 2>/dev/null | cut -d'[' -f1 || true)
  if [[ -n "$src" ]]; then
    uuid=$(sudo -n blkid -s UUID -o value "$src" 2>/dev/null || true)
    if [[ -n "$uuid" ]]; then
      echo "$uuid"
      return 0
    fi
  fi
  return 1
}
fi

# ensure_root_rw <cmdline> — echo cmdline with root= and rw present (added from
# live system only when missing; existing values always win).
# FAILS (return 1, no output) when no root= exists and none is detectable:
# writing a rootless entry cmdline boots into "Failed to mount '' on real
# root", so callers must skip the write instead.
if ! declare -f ensure_root_rw >/dev/null 2>&1; then
ensure_root_rw() {
  local merged="${1:-}"
  if ! echo " $merged " | grep -qE ' root=[^ ]+ '; then
    local root_uuid
    if root_uuid=$(detect_root_uuid); then
      merged="root=UUID=$root_uuid${merged:+ $merged}"
    else
      if declare -f log_error >/dev/null 2>&1; then
        log_error "Cannot determine root filesystem UUID — refusing to write a rootless cmdline."
      fi
      return 1
    fi
  fi
  if ! echo " $merged " | grep -qE '(^| )rw( |$)'; then
    merged="$merged rw"
  fi
  echo "$merged"
}
fi

# True when the root filesystem sits on an encrypted device (archinstall LUKS).
if ! declare -f is_encrypted_root >/dev/null 2>&1; then
is_encrypted_root() {
  local src
  src=$(findmnt -n -o SOURCE / 2>/dev/null | cut -d'[' -f1 || echo "")
  [[ "$src" == /dev/mapper/* || "$src" == /dev/dm-* ]] && return 0
  lsblk -n -o NAME,FSTYPE 2>/dev/null | grep -q crypto_LUKS && \
    lsblk -n -o MOUNTPOINT 2>/dev/null | grep -qx "/" && return 0
  return 1
}
fi

# True when UEFI Secure Boot is active (binaries are signature-checked).
if ! declare -f is_secureboot_active >/dev/null 2>&1; then
is_secureboot_active() {
  local last
  last=$(od -An -tu1 /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null | awk '{print $NF}')
  [[ "$last" == "1" ]]
}
fi
