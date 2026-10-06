#!/bin/bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

# DRY-RUN safety boundary: bootloader configuration contains many direct
# privileged writes and is intentionally not executed in preview mode.
if [[ "${DRY_RUN:-false}" == true ]]; then
  ui_info "Dry-run: Bootloader and kernel configuration would run here."
  exit 0
fi

# --- Bootloader detection ---
BOOTLOADER=$(detect_bootloader)

# Slow full initramfs rebuilds are collected here and run exactly once at the
# end of this step (UKI cmdline changes, overlayfs hook wiring, ...).
NEEDS_INITRAMFS_REBUILD=false

# SMART DISPLAY RESOLUTION DETECTION
# Single source for both `interface_resolution:` (limine.conf) and `video=`
# (kernel cmdline). Picks the largest mode among connected outputs so a
# 2K-primary + 1080p-secondary setup yields 2560x1440, while a single-1080p
# machine yields 1920x1080. No hardcoding, no per-machine config.
#
# Priority:
#   1. $LIMINE_RESOLUTION override (e.g. LIMINE_RESOLUTION=1920x1080 ./install.sh)
#   2. DRM modes of connected outputs (/sys/class/drm/card*-*/{status,modes})
#   3. fb modes (/sys/class/graphics/fb0/modes, first U:WxHp entry)
#   4. xrandr current mode (live X/Wayland session only)
#   5. Fallback 1920x1080 (safe everywhere, incl. headless/VM)
# Usage: detect_display_resolution  -> echoes e.g. 2560x1440
detect_display_resolution() {
  # 1. Explicit override wins (CI, VMs with weird EDID, user preference)
  if [[ -n "${LIMINE_RESOLUTION:-}" ]]; then
    if [[ "$LIMINE_RESOLUTION" =~ ^[0-9]+x[0-9]+$ ]]; then
      echo "$LIMINE_RESOLUTION"
      return 0
    else
      log_warning "Ignoring malformed LIMINE_RESOLUTION='$LIMINE_RESOLUTION' (want WxH)"
    fi
  fi

  local best="" best_pixels=0
  local d status mode w h pixels

  # 2. DRM: largest preferred mode among connected outputs.
  #    modes(5) lists preferred first, so head -1 is the native res; we still
  #    take the max across outputs to cover multi-monitor (2K + 1080p -> 2K).
  for d in /sys/class/drm/card*-*; do
    [[ -f "$d/status" && -f "$d/modes" ]] || continue
    status=$(cat "$d/status" 2>/dev/null || echo "")
    [[ "$status" == "connected" ]] || continue
    while IFS= read -r mode; do
      [[ "$mode" =~ ^([0-9]+)x([0-9]+) ]] || continue
      w="${BASH_REMATCH[1]}"
      h="${BASH_REMATCH[2]}"
      pixels=$((w * h))
      if ((pixels > best_pixels)); then
        best_pixels=$pixels
        best="${w}x${h}"
      fi
      break # preferred (first) mode per output is enough
    done < "$d/modes"
  done
  if [[ -n "$best" ]]; then
    echo "$best"
    return 0
  fi

  # 3. Framebuffer (efifb/simplefb/vesafb): U:2560x1440p-0 -> 2560x1440
  if [[ -r /sys/class/graphics/fb0/modes ]]; then
    mode=$(grep -oE 'U:[0-9]+x[0-9]+' /sys/class/graphics/fb0/modes 2>/dev/null | head -1 || true)
    if [[ "$mode" =~ U:([0-9]+x[0-9]+) ]]; then
      echo "${BASH_REMATCH[1]}"
      return 0
    fi
  fi

  # 4. xrandr (only when a display server runs; installer is usually TTY)
  if command -v xrandr &>/dev/null && [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
    local xr_best="" xr_pixels=0
    while IFS= read -r line; do
      # current mode line: "   2560x1440    164.99*+"
      if [[ "$line" =~ ([0-9]+)x([0-9]+).*\* ]]; then
        w="${BASH_REMATCH[1]}"
        h="${BASH_REMATCH[2]}"
        pixels=$((w * h))
        if ((pixels > xr_pixels)); then
          xr_pixels=$pixels
          xr_best="${w}x${h}"
        fi
      fi
    done < <(xrandr 2>/dev/null || true)
    if [[ -n "$xr_best" ]]; then
      echo "$xr_best"
      return 0
    fi
    unset xr_best xr_pixels
  fi

  # 5. Safe fallback (headless, VM with unknown output, no EDID)
  echo "1920x1080"
}

# Term font scale follows resolution: HiDPI (>=1440p height or >=2560 width)
# needs 2x2 for a readable menu, 1080p and below stays sharp at 1x1.
# Usage: detect_term_font_scale [resolution]  -> echoes e.g. 2x2
detect_term_font_scale() {
  local res="${1:-$(detect_display_resolution)}"
  local w=0 h=0
  if [[ "$res" =~ ^([0-9]+)x([0-9]+)$ ]]; then
    w="${BASH_REMATCH[1]}"
    h="${BASH_REMATCH[2]}"
  fi
  if ((w >= 2560 || h >= 1440)); then
    echo "2x2"
  else
    echo "1x1"
  fi
}

# UNIFIED KERNEL PARAMETERS

# Build consistent kernel parameters across all bootloaders
# Usage: get_kernel_params [--cmdline-only]
#   --cmdline-only: Output only the parameters (no root= prefix)
get_kernel_params() {
  local cmdline_only=false
  [[ "${1:-}" == "--cmdline-only" ]] && cmdline_only=true

  local params=""

  # Base parameters (all systems). Each one has a concrete reason:
  #   quiet loglevel=3 ............ standard quiet boot (cosmetic, universally expected)
  #   splash ...................... show the Plymouth splash installed by archinstall
  #                                 (harmless when Plymouth is absent; merge dedups on re-runs)
  #   vt.global_cursor_default=0 .. hide the blinking text cursor under the splash
  # No generic "performance" parameters are added here. In particular,
  # `nowatchdog` was removed: disabling the watchdog saves negligible power
  # and removes a hang-recovery mechanism, so the kernel default (watchdogs
  # enabled) is the safer choice.
  params="quiet loglevel=3 splash vt.global_cursor_default=0"

  # GPU-specific parameters (multi-GPU aware: a hybrid AMD iGPU + NVIDIA dGPU
  # needs BOTH sets; an AMD-only box must never get nvidia_drm.*).
  local lspci_out=""
  lspci_out=$(lspci 2>/dev/null || true)
  local has_nvidia=false has_amd=false has_intel=false
  echo "$lspci_out" | grep -qiE 'vga.*nvidia|3d.*nvidia|display.*nvidia' && has_nvidia=true
  echo "$lspci_out" | grep -qiE 'vga.*amd|3d.*amd|display.*amd|vga.*radeon|3d.*radeon' && has_amd=true
  echo "$lspci_out" | grep -qiE 'vga.*intel|display.*intel' && has_intel=true

  if [[ "$has_nvidia" == true ]]; then
    # NVIDIA: Required for Wayland and modern drivers
    params="$params nvidia_drm.modeset=1 nvidia_drm.fbdev=1"
    # Laptop power management for Ampere+ GPUs
    if is_laptop 2>/dev/null; then
      params="$params NVreg_DynamicPowerManagement=0x03"
      params="$params NVreg_PreserveVideoMemoryAllocations=1"
      params="$params NVreg_TemporaryFilePath=/var/tmp"
    fi
  fi
  if [[ "$has_amd" == true ]]; then
    # AMD: amdgpu is the default driver, no extra params needed by default
    # Only add for older GCN 1-2 GPUs that need force-loading
    if echo "$lspci_out" | grep -qiE 'vga.*amd.*oland|vga.*amd.*tonga|vga.*amd.*fiji|vga.*amd.*polaris'; then
      params="$params radeon.si_support=0 amdgpu.si_support=1"
      params="$params radeon.cik_support=0 amdgpu.cik_support=1"
    fi
    # AMD P-State for CPUs with CPPC support (Ryzen 5000+ / Zen 3+).
    # Kept deliberately: supported Arch kernels default to amd_pstate active
    # mode (CONFIG_X86_AMD_PSTATE_DEFAULT_MODE=3), but not every platform
    # enables it automatically — firmware without a proper _CPC/CPPC setup
    # and some server platforms still fall back to passive mode or
    # acpi_cpufreq (ArchWiki "CPU frequency scaling", amd_pstate section).
    # Passing amd_pstate=active pins the autonomous (EPP) mode on capable
    # hardware and is a no-op where the kernel already selected it. Gated on
    # detected driver support, so non-AMD or pre-Zen systems never get it.
    # This selects the scaling *driver mode*, not a governor — no userspace
    # governor forcing is done here.
    if grep -qi "amd_pstate" /proc/cpuinfo 2>/dev/null || [ -d /sys/devices/system/cpu/amd_pstate ]; then
      params="$params amd_pstate=active"
    fi
  fi
  if [[ "$has_intel" == true ]]; then
    # Intel: Enable GuC/HuC firmware only when GuC firmware actually ships
    # for this machine (Gen 9.5+). Unconditional enable_guc on old iGPUs can
    # stall firmware loading, so gate on /lib/firmware/i915/*guc*.
    if compgen -G "/lib/firmware/i915/*guc*" >/dev/null 2>&1; then
      params="$params i915.enable_guc=3"
    fi
  fi

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

  # No forced display resolution: KMS picks the native mode automatically.
  # (Older versions wrote video=WxH here, which is why 2560x1440/1920x1080
  # showed up in /proc/cmdline. Removed — see MANAGED_PARAM_KEYS cleanup.)

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

# KERNEL CMDLINE MERGE — pure helpers (MANAGED_PARAM_KEYS, merge/strip,
# root UUID, encrypted/SecureBoot probes) live in the single source
# scripts/lib/boot/kernel_params.sh (unit-tested, no mirrors).
if [[ -f "$SCRIPT_DIR/../lib/boot/kernel_params.sh" ]]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/../lib/boot/kernel_params.sh"
fi
if ! declare -f merge_kernel_params >/dev/null 2>&1; then
  log_error "Missing lib/boot/kernel_params.sh — cannot configure kernel cmdline"
  exit 1
fi


# build_file_cmdline <current-file-content> — echo the merged ROOTFUL cmdline
# for /etc/kernel/cmdline. That file feeds mkinitcpio UKI, limine-entry-tool
# AND limine-snapper-sync snapshot generation: all three need root= IN the
# file (a rootless file poisons generated snapshot entries into unbootable
# "Failed to mount '' on real root" ones). Existing root=/rw identifiers are
# proven (system boots with them) and kept; live-detected values fill gaps
# only, so re-runs are idempotent and never duplicate root=. Fails (no
# output) when no root can be established — callers must skip the write.
build_file_cmdline() {
  local current="${1:-}"
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
    current_params=$(sudo -n cat "$cmdline_file" 2>/dev/null || echo "")
  fi
  local merged
  if ! merged=$(build_file_cmdline "$current_params"); then
    log_error "Refusing to write rootless UKI cmdline — leaving $cmdline_file untouched."
    return 1
  fi

  if [[ "$current_params" == "$merged" ]]; then
    log_info "UKI cmdline already configured"
  else
    [[ -f "$cmdline_file" ]] && sudo -n cp "$cmdline_file" "${cmdline_file}.backup.$(date +%Y%m%d_%H%M%S)"
    log_info "Backed up existing UKI cmdline"
    echo "$merged" | sudo -n tee "$cmdline_file" >/dev/null
    log_success "UKI cmdline written: $merged"
  fi
  log_to_file "UKI cmdline value: $merged"

  # Plymouth presets/hooks belong to archinstall — not touched here.

  # Ensure /boot/efi/EFI/Linux directory exists for UKI output
  local esp_mount
  esp_mount=$(findmnt -n -o TARGET /boot/efi 2>/dev/null || findmnt -n -o TARGET /boot 2>/dev/null || echo "/boot")
  local uki_dir="${esp_mount}/EFI/Linux"
  if [[ ! -d "$uki_dir" ]]; then
    if sudo -n mkdir -p "$uki_dir" 2>/dev/null; then
      log_info "Created UKI output directory: $uki_dir"
    else
      log_warning "Failed to create $uki_dir"
    fi
  fi

  # Defer the (slow) full rebuild: collected once at end of step 6.
  NEEDS_INITRAMFS_REBUILD=true
}

# Sync /etc/kernel/cmdline only (no image rebuild) for NVRAM-managed
# bootloaders (refind/efistub) whose cmdline lives in firmware entries.
configure_uki_cmdline_note_only() {
  local cmdline_file="/etc/kernel/cmdline"
  local current=""
  if sudo -n test -f "$cmdline_file" 2>/dev/null; then
    current=$(sudo -n cat "$cmdline_file" 2>/dev/null || echo "")
  fi
  local merged
  if ! merged=$(build_file_cmdline "$current"); then
    log_error "Refusing to write rootless $cmdline_file — leaving it untouched."
    return 1
  fi
  if [[ "$current" != "$merged" ]]; then
    [[ -n "$current" ]] && sudo -n cp "$cmdline_file" "${cmdline_file}.backup.$(date +%Y%m%d_%H%M%S)"
    echo "$merged" | sudo -n tee "$cmdline_file" >/dev/null
    log_success "Synced $cmdline_file (firmware entries still authoritative)"
  else
    log_info "$cmdline_file already up to date"
  fi
}

# BOOTLOADER-SPECIFIC KERNEL PARAMETERS

# --- systemd-boot completeness (install, fallback, entries, verify) ---
# Mirrors the guarantees of switch-bootloader.sh: the identified loader must
# end up INSTALLED (ESP binaries + NVRAM + boot order), with a fallback
# initramfs, microcode loading, complete entries (kernels + Windows +
# sort-keys), and a final verification gate. No other stacks are touched —
# this installer configures the detected loader, it never migrates.

# Order our NVRAM entry first, keep the rest untouched (same algorithm as
# limine_order_entry_first, generalized beyond Limine).
order_boot_entry_first() {
  local want="${1:-}" label="${2:-bootloader}"
  local order
  order=$(sudo -n efibootmgr 2>/dev/null | grep -i '^BootOrder:' | cut -d: -f2 | tr -d ' ' || true)
  if [[ -z "$order" ]]; then
    log_warning "Could not read BootOrder — skipping reorder."
    return 0
  fi
  local want_up new_order seen p p_up
  want_up=$(echo "$want" | tr 'a-f' 'A-F')
  new_order="$want_up"; seen=",$want_up,"
  local IFS=','
  for p in $order; do
    [[ -n "$p" ]] || continue
    p_up=$(echo "$p" | tr 'a-f' 'A-F')
    [[ "$seen" == *",$p_up,"* ]] && continue
    seen+="$p_up,"; new_order="$new_order,$p_up"
  done
  if sudo -n efibootmgr -o "$new_order" >>"$INSTALL_LOG" 2>&1; then
    log_success "BootOrder set to $new_order ($label first)."
  else
    log_warning "Could not set BootOrder."
  fi
}

# systemd-boot NVRAM ids (Linux Boot Manager label or systemd loader path).
systemd_boot_nvram_ids() {
  command -v efibootmgr &>/dev/null || return 0
  sudo -n efibootmgr -v 2>/dev/null | grep -iE 'Linux Boot Manager|systemd-boot|\\EFI\\systemd\\'     | grep -oE '^Boot[0-9A-Fa-f]{4}' | sed 's/^Boot//' || true
}

ensure_systemd_boot_installed() {
  local esp="${1:-}"
  [[ -n "$esp" ]] || { log_warning "No ESP — skipping loader install."; return 0; }
  if ! command -v bootctl &>/dev/null; then
    log_warning "bootctl not found — skipping loader install."
    return 0
  fi
  # sudo (not -n check): bootctl cannot assess the ESP unprivileged and would
  # falsely report "not installed" (observed live: install ok, check failed).
  if [[ "$(sudo -n bootctl is-installed 2>/dev/null || echo no)" != "yes" ]]; then
    log_info "Installing systemd-boot to $esp..."
    if sudo -n bootctl install --esp-path="$esp" >>"$INSTALL_LOG" 2>&1; then
      log_success "systemd-boot installed to $esp"
    else
      log_error "bootctl install failed — entries below may never boot."
      return 1
    fi
  else
    log_info "systemd-boot already installed in ESP"
  fi
  # Fallback must BE the deployed binary (installers skip identical copies,
  # so only content-compare; any deployed variant matches).
  local main="$esp/EFI/systemd/systemd-bootx64.efi"
  if ! sudo -n test -f "$main" 2>/dev/null; then
    main=$(sudo -n find "$esp/EFI/systemd" -maxdepth 1 -name 'systemd-boot*.efi' 2>/dev/null | head -1 || true)
  fi
  if [[ -n "$main" ]] && ! sudo -n cmp -s "$esp/EFI/BOOT/BOOTX64.EFI" "$main" 2>/dev/null; then
    sudo -n cp -a "$main" "$esp/EFI/BOOT/BOOTX64.EFI" 2>/dev/null       && log_success "Refreshed fallback BOOTX64.EFI"       || log_warning "Could not refresh fallback BOOTX64.EFI"
  fi
  local ids first
  ids=$(systemd_boot_nvram_ids || true)
  first=$(echo "$ids" | head -1 || true)
  if [[ -n "$first" ]]; then
    order_boot_entry_first "$first" "systemd-boot"
  else
    log_warning "No systemd-boot NVRAM entry found — firmware may not list it (fallback BOOTX64.EFI still boots)."
  fi
}

# Fallback initramfs preset (PRESETS array AND image lines — -P builds only
# listed presets; image lines alone silently build nothing). Defers the slow
# rebuild via NEEDS_INITRAMFS_REBUILD like the rest of this step.
ensure_fallback_preset() {
  local kpkg suffix preset
  for kpkg in linux linux-zen linux-lts linux-hardened; do
    pacman -Q "$kpkg" &>/dev/null 2>&1 || continue
    if [[ "$kpkg" == "linux" ]]; then suffix="linux"; else suffix="${kpkg#linux-}"; fi
    if sudo -n test -f "/boot/initramfs-$suffix-fallback.img" 2>/dev/null; then
      log_info "Fallback image present for $kpkg"
      continue
    fi
    preset="/etc/mkinitcpio.d/${kpkg}.preset"
    if ! sudo -n test -f "$preset" 2>/dev/null; then
      log_warning "No preset $preset for installed $kpkg — skipping fallback"
      continue
    fi
    sudo -n cp "$preset" "${preset}.backup.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
    if sudo -n grep -qE "^PRESETS=.*fallback" "$preset" 2>/dev/null; then
      log_info "Fallback already listed in PRESETS ($preset)"
    elif sudo -n grep -qE "^#PRESETS=\('default' 'fallback'\)" "$preset" 2>/dev/null; then
      sudo -n sed -i -E "s/^#PRESETS=\('default' 'fallback'\)/PRESETS=('default' 'fallback')/" "$preset" 2>/dev/null         && log_success "Enabled fallback PRESETS in $preset"         || log_warning "Could not update PRESETS in $preset"
      sudo -n sed -i -E "s/^PRESETS=\('default'\)$/#PRESETS=('default')/" "$preset" 2>/dev/null || true
    elif sudo -n grep -qE "^PRESETS=" "$preset" 2>/dev/null; then
      sudo -n sed -i -E "/^PRESETS=/ s/\)$/ 'fallback')/" "$preset" 2>/dev/null         && log_success "Appended fallback to PRESETS in $preset"         || log_warning "Could not update PRESETS in $preset"
    else
      printf "\nPRESETS=('default' 'fallback')\n" | sudo -n tee -a "$preset" >/dev/null         && log_success "Added fallback PRESETS to $preset"         || log_warning "Could not update $preset"
    fi
    if sudo -n grep -qE '^#fallback_image=' "$preset" 2>/dev/null; then
      sudo -n sed -i -E 's/^#(fallback_image|fallback_options)=/\1=/' "$preset" 2>/dev/null         && log_success "Enabled fallback image lines in $preset"         || log_warning "Could not enable fallback image in $preset"
    elif ! sudo -n grep -qE '^fallback_image=' "$preset" 2>/dev/null; then
      printf '\nfallback_image="/boot/initramfs-%s-fallback.img"\nfallback_options="-S autodetect"\n' "$suffix"         | sudo -n tee -a "$preset" >/dev/null         && log_success "Appended fallback image lines to $preset"         || log_warning "Could not update $preset"
    fi
    NEEDS_INITRAMFS_REBUILD=true
  done
}

# Microcode package so loader entries can load it via an early initrd line
# (systemd-boot entries have no GRUB early-initrd mechanism).
ensure_microcode_pkg() {
  local want=""
  if grep -qi 'AuthenticAMD' /proc/cpuinfo 2>/dev/null; then want="amd-ucode";
  elif grep -qi 'GenuineIntel' /proc/cpuinfo 2>/dev/null; then want="intel-ucode"; fi
  [[ -n "$want" ]] || { log_info "Unknown CPU vendor — skipping microcode check"; return 0; }
  if pacman -Q "$want" &>/dev/null 2>&1; then log_info "Microcode package present ($want)"; return 0; fi
  log_info "Installing microcode package $want..."
  install_packages_quietly "$want" 2>>"$INSTALL_LOG"     || log_warning "Microcode install failed — entries will boot without early microcode"
}

# Kernel entry files carrying a linux line (excludes chainload entries like
# windows.conf, which have efi but no linux and must never get options).
kernel_entry_files() {
  local dir="${1:-}"
  [[ -n "$dir" ]] || return 0
  local f
  while IFS= read -r -d '' f; do
    sudo -n grep -qE '^linux[[:space:]]' "$f" 2>/dev/null && printf '%s\0' "$f"
  done < <(sudo -n find "$dir" -maxdepth 1 -name '*.conf' -print0 2>/dev/null || true)
}

# Sort-key for a kernel entry file: main entries first (00-), fallbacks last
# (zz-). Auto entries (auto-windows, firmware) sort between — deterministic
# Arch-first, fallback-last menu without touching anything else.
entry_sort_key() {
  local base
  base=$(basename "${1:-}" .conf)
  if [[ "$base" == *fallback* ]]; then echo "zz-$base";
  else echo "00-$base"; fi
}

# Backfill missing sort-key lines on existing entries (never overwrites set keys).
ensure_entry_sort_keys() {
  local dir="${1:-}" f key
  [[ -n "$dir" ]] || return 0
  while IFS= read -r -d '' f; do
    sudo -n grep -qE '^sort-key[[:space:]]' "$f" 2>/dev/null && continue
    key=$(entry_sort_key "$f")
    if sudo -n grep -qE '^title[[:space:]]' "$f" 2>/dev/null; then
      sudo -n sed -i "0,/^title[[:space:]]/s//&\nsort-key $key/" "$f" 2>/dev/null         && log_info "Added sort-key $key to $(basename "$f")"         || log_warning "Could not add sort-key to $(basename "$f")"
    else
      printf 'sort-key %s\n' "$key" | sudo -n tee -a "$f" >/dev/null 2>/dev/null         && log_info "Added sort-key $key to $(basename "$f")" || true
    fi
  done < <(kernel_entry_files "$dir" || true)
}

# Canonical menu titles: every kernel entry displays "Arch Linux"
# (main kernel) or "Arch Linux (<suffix>[ ]fallback)" — never a filename,
# date stamp, or kernel version. archinstall entries often carry NO title
# line at all, in which case the loader shows the raw filename
# (2026-10-06_07-48-52_linux.conf). Existing titles are replaced only when
# they look auto-generated (missing, dated, or filename-derived); a
# genuinely custom title is left alone.
canonical_entry_title() {
  local entry="${1:-}" suffix="${2:-linux}" title=""
  local base
  base=$(basename "$entry" .conf)
  if [[ "$base" == *fallback* ]]; then
    if [[ "$suffix" == "linux" ]]; then title="Arch Linux (fallback)";
    else title="Arch Linux ($suffix fallback)"; fi
  else
    if [[ "$suffix" == "linux" ]]; then title="Arch Linux";
    else title="Arch Linux ($suffix)"; fi
  fi
  echo "$title"
}

ensure_entry_titles() {
  local dir="${1:-}" f current suffix want body new_content
  [[ -n "$dir" ]] || return 0
  while IFS= read -r -d '' f; do
    suffix=$(sudo -n grep -E '^linux[[:space:]]' "$f" 2>/dev/null | head -1       | grep -oE '/vmlinuz-[^[:space:]]+' | sed 's|.*/vmlinuz-||' || true)
    [[ -n "$suffix" ]] || suffix="linux"
    want=$(canonical_entry_title "$f" "$suffix")
    current=$(sudo -n grep -E '^title[[:space:]]' "$f" 2>/dev/null | head -1       | sed -E 's/^title[[:space:]]+//' || true)
    if [[ "$current" == "$want" ]]; then
      log_info "Title already canonical in $(basename "$f")"
      continue
    fi
    local base
    base=$(basename "$f" .conf)
    if [[ -n "$current" ]]       && ! echo "$current" | grep -qE '[0-9]{4}-[0-9]{2}-[0-9]{2}'       && [[ "$current" != "$base" && "$current" != "${base//_/ }" ]]; then
      log_info "Keeping custom title in $(basename "$f"): '$current'"
      continue
    fi
    body=$(sudo -n grep -vE '^title[[:space:]]' "$f" 2>/dev/null || true)
    body=$(printf '%s' "$body" | sed '/./,$!d' || true)
    new_content=$(printf 'title   %s\n%s\n' "$want" "$body")
    if [[ "${DRY_RUN:-false}" == true ]]; then
      log_info "Dry-run: would set title '$want' in $(basename "$f")"
      continue
    fi
    if privileged_write "$new_content" "$f" 2>/dev/null; then
      log_success "Set title '$want' in $(basename "$f")"
    else
      log_warning "Could not set title in $(basename "$f")"
    fi
  done < <(kernel_entry_files "$dir" || true)
}

# Windows chainload entry (explicit beats auto-detection: auto rows proved# Windows chainload entry (explicit beats auto-detection: auto rows proved
# unreliable and unorderable). Written only when Windows is detected (ESP
# file, case-insensitive locate, or NVRAM label).
write_windows_boot_entry() {
  local entries_dir="${1:-}" esp="${2:-}" entry
  [[ -n "$entries_dir" && -n "$esp" ]] || return 0
  entry="$entries_dir/windows.conf"
  local win_src=""
  win_src=$(sudo -n find "$esp/EFI" -ipath '*microsoft*boot*bootmgfw.efi' 2>/dev/null | head -1 || true)
  if [[ -z "$win_src" ]]; then
    if detect_second_os_evidence 2>/dev/null || sudo -n efibootmgr -v 2>/dev/null | grep -qi 'Windows Boot Manager'; then
      log_warning "Windows detected (NVRAM) but bootmgfw.efi not found on ESP — skipping Windows entry"
    else
      log_info "No Windows detected — skipping Windows boot entry"
    fi
    return 0
  fi
  local rel="${win_src#$esp}"
  {
    echo "title   Windows 11"
    echo "sort-key 01-windows"
    echo "efi     $rel"
  } | sudo -n tee "$entry" >/dev/null     && log_success "Wrote Windows boot entry ($entry → $rel)"     || log_warning "Could not write Windows boot entry"
  # Our explicit row replaces the auto one: without this the auto-detected
  # duplicate appears next to it. Firmware row is separate (auto-firmware).
  set_loader_config "auto-entries" "no" || true
}

# Create arch.conf (+fallback) from scratch when NO kernel entries exist
# (fresh ESP / never-configured loader). Existing entries are maintained,
# never overwritten.
create_systemd_boot_entries() {
  local entries_dir="${1:-}" esp="${2:-}"
  [[ -n "$entries_dir" && -n "$esp" ]] || return 0
  local existing=0
  existing=$(kernel_entry_files "$entries_dir" | tr '\0' '\n' | grep -c . || true)
  if ((existing > 0)); then
    log_info "Kernel entries already present ($existing) — maintaining, not recreating"
    return 0
  fi
  local full
  if ! full=$(get_kernel_params) || ! echo " $full " | grep -qE ' root=[^ ]+ '; then
    log_error "Cannot build a rooted cmdline — refusing to write rootless entries."
    return 1
  fi
  local ucode_line=""
  if pacman -Q amd-ucode &>/dev/null 2>&1 && sudo -n test -f /boot/amd-ucode.img 2>/dev/null; then
    ucode_line="initrd  /amd-ucode.img"
  elif pacman -Q intel-ucode &>/dev/null 2>&1 && sudo -n test -f /boot/intel-ucode.img 2>/dev/null; then
    ucode_line="initrd  /intel-ucode.img"
  fi
  local kpkg suffix created=0
  for kpkg in linux linux-zen linux-lts linux-hardened; do
    pacman -Q "$kpkg" &>/dev/null 2>&1 || continue
    if [[ "$kpkg" == "linux" ]]; then suffix="linux"; else suffix="${kpkg#linux-}"; fi
    sudo -n test -f "/boot/vmlinuz-$suffix" 2>/dev/null || continue
    {
      if [[ "$suffix" == "linux" ]]; then
        printf 'title   Arch Linux\nsort-key 00-arch\nlinux   /vmlinuz-linux\n'
      else
        printf 'title   Arch Linux (%s)\nsort-key 00-arch-%s\nlinux   /vmlinuz-%s\n' "$suffix" "$suffix" "$suffix"
      fi
      [[ -n "$ucode_line" ]] && printf '%s\n' "$ucode_line"
      printf 'initrd  /initramfs-%s.img\noptions %s\n' "$suffix" "$full"
    } | sudo -n tee "$entries_dir/arch${suffix:+$([ "$suffix" = linux ] && echo "" || echo "-$suffix")}.conf" >/dev/null       && created=$((created + 1)) || log_warning "Could not write entry for $kpkg"
    if sudo -n test -f "/boot/initramfs-$suffix-fallback.img" 2>/dev/null; then
      {
        if [[ "$suffix" == "linux" ]]; then
          printf 'title   Arch Linux (fallback)\nsort-key zz-00-arch-fallback\nlinux   /vmlinuz-linux\n'
        else
          printf 'title   Arch Linux (%s fallback)\nsort-key zz-00-arch-%s-fallback\nlinux   /vmlinuz-%s\n' "$suffix" "$suffix" "$suffix"
        fi
        [[ -n "$ucode_line" ]] && printf '%s\n' "$ucode_line"
        printf 'initrd  /initramfs-%s-fallback.img\noptions %s\n' "$suffix" "$full"
      } | sudo -n tee "$entries_dir/arch${suffix:+$([ "$suffix" = linux ] && echo "" || echo "-$suffix")}-fallback.conf" >/dev/null         && log_info "Wrote fallback entry for $kpkg" || true
    fi
  done
  if ((created > 0)); then
    log_success "Created $created systemd-boot kernel entries"
    if ! sudo -n grep -qE '^default[[:space:]]' "$entries_dir/../loader.conf" 2>/dev/null; then
      set_loader_config "default" "arch.conf" || true
    fi
  else
    log_warning "No entries created (no vmlinuz for installed kernel packages)"
  fi
  write_windows_boot_entry "$entries_dir" "$esp"
}

# Final gate: the configured loader must actually boot (mirrors
# switch-bootloader.sh final_boot_check, installer logging).
verify_systemd_boot_entries() {
  local esp="${1:-}" fail=0
  local entries_dir
  entries_dir=$(find_systemd_boot_entries_dir 2>/dev/null || true)
  if [[ -z "$entries_dir" ]]; then
    log_error "VERIFY FAIL: no loader entries directory."
    return 1
  fi
  local count=0 f
  while IFS= read -r -d '' f; do count=$((count + 1)); done < <(kernel_entry_files "$entries_dir" || true)
  if ((count == 0)); then
    log_error "VERIFY FAIL: no kernel entries in $entries_dir."
    return 1
  fi
  log_info "VERIFY: $count kernel entries present"
  local lin field ref bad=0
  while IFS= read -r -d '' f; do
    while IFS= read -r lin; do
      case "$lin" in
        linux*|initrd*|efi*)
          field=$(echo "$lin" | awk '{print $2}')
          [[ -n "$field" ]] || continue
          ref="$field"
          [[ "$ref" != /* ]] && ref="/$ref"
          if sudo -n test -f "$esp$ref" 2>/dev/null || sudo -n test -f "$ref" 2>/dev/null; then :;
          else log_error "VERIFY FAIL: $(basename "$f") references missing $field"; bad=$((bad + 1)); fi
          ;;
      esac
    done < <(sudo -n cat "$f" 2>/dev/null || true)
  done < <(sudo -n find "$entries_dir" -maxdepth 1 -name '*.conf' -print0 2>/dev/null || true)
  ((bad > 0)) && fail=1
  if [[ "$(sudo -n bootctl is-installed 2>/dev/null || echo no)" != "yes" ]]; then
    log_error "VERIFY FAIL: systemd-boot not installed in ESP."
    fail=1
  fi
  if [[ -z "$(systemd_boot_nvram_ids || true)" ]]; then
    log_warning "VERIFY: no systemd-boot NVRAM entry (firmware fallback still boots)."
  fi
  if ((fail != 0)); then
    log_error "systemd-boot verification FAILED — do not assume the new config boots."
    return 1
  fi
  log_success "systemd-boot verification passed ($count entries resolve, loader installed)."
}

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

  # Completeness chain (mirrors switch-bootloader.sh): install the loader,
  # microcode, fallback preset, then entries — then maintain + verify.
  local esp_mount=""
  esp_mount=$(detect_esp_mount 2>/dev/null || true)
  if [[ -z "$esp_mount" ]]; then
    log_warning "No ESP mountpoint detected — loader install/entry creation skipped (entry maintenance continues)."
  else
    run_step "Ensuring systemd-boot is installed" ensure_systemd_boot_installed "$esp_mount"
  fi
  run_step "Ensuring microcode package" ensure_microcode_pkg
  run_step "Ensuring fallback initramfs preset" ensure_fallback_preset

  # Get unified kernel parameters for non-UKI systemd-boot
  local kernel_params
  kernel_params=$(get_kernel_params --cmdline-only)

  local entries_dir
  entries_dir=$(find_systemd_boot_entries_dir 2>/dev/null || true)
  if [[ -z "$entries_dir" && -n "$esp_mount" ]]; then
    entries_dir="$esp_mount/loader/entries"
    sudo -n mkdir -p "$entries_dir" 2>/dev/null || true
  fi
  local loader_conf=""
  if [ -n "$entries_dir" ]; then
    loader_conf="$(dirname "$entries_dir")/loader.conf"
  fi

  if [[ -n "$entries_dir" && -n "$esp_mount" ]]; then
    run_step "Creating missing systemd-boot entries" create_systemd_boot_entries "$entries_dir" "$esp_mount"
  fi

  run_step "Renaming dated kernel entries to simple format" rename_dated_kernel_entries

  if [ -n "$loader_conf" ] && sudo -n test -f "$loader_conf" 2>/dev/null; then
    set_loader_config "timeout" "3"
    set_loader_config "console-mode" "max"
    ui_info "Set timeout to 3s and console-mode to max"
  else
    # /boot is 700 after archinstall, bare [ -f ] fails - try to create via set_loader_config
    if [ -n "$loader_conf" ] && set_loader_config "timeout" "3"; then
      set_loader_config "console-mode" "max"
      ui_info "Set timeout to 3s and console-mode to max - created loader.conf"
    else
      log_warning "loader.conf not found. Skipping loader.conf configuration for systemd-boot."
    fi
  fi

  # Update kernel options in all entries with unified params (fallback
  # entries included — same kernel, same options; the initrd lines differ
  # and are never touched)
  run_step "Updating kernel options with unified parameters" update_systemd_boot_options "$kernel_params"

  # Deterministic menu order Arch-first/fallback-last on existing entries
  # (never overwrites keys the user or a previous run set).
  if [[ -n "${entries_dir:-}" ]]; then
    run_step "Ensuring entry sort-keys" ensure_entry_sort_keys "$entries_dir"
    run_step "Ensuring canonical entry titles" ensure_entry_titles "$entries_dir"
  fi

  run_step "Checking kernel options consistency" check_kernel_options_consistency

  # Universal snapper stack for all bootloaders (btrfs-assistant/snap-pac) when snapper present
  # Robust, not limine-only; AUR limine-snapper-sync stays limine-only
  if is_btrfs_system 2>/dev/null && pacman -Q snapper &>/dev/null; then
    run_step "Configuring Btrfs-Assistant snapshot limits" ensure_snapper_aux_universal
  elif is_btrfs_system 2>/dev/null; then
    run_step "Configuring Btrfs-Assistant snapshot limits" apply_btrfs_assistant_profile
  fi

  # Final gate: the configured loader must actually boot (entries resolve,
  # loader owns the ESP, NVRAM entry present).
  if [[ -n "${esp_mount:-}" ]]; then
    if ! verify_systemd_boot_entries "$esp_mount"; then
      log_error "systemd-boot configuration did not verify — review before rebooting."
      return 1
    fi
  else
    log_warning "No ESP — skipping systemd-boot verification."
  fi
}

# Update kernel options in systemd-boot entries - smart for archinstall dated entries
update_systemd_boot_options() {
  local new_params="${1:-}"
  local entries_dir
  entries_dir=$(find_systemd_boot_entries_dir)

  if [ -z "$entries_dir" ]; then
    return 0
  fi

  # Smart find: archinstall creates dated entries like 2026-09-04_10-49-12_linux.conf
  # Regular entries are simple like linux.conf, linux-lts.conf
  # Use sudo -n find for 700 /boot, handle both patterns
  local entries=()
  while IFS= read -r -d '' entry; do
    entries+=("$entry")
  done < <(sudo -n find "$entries_dir" -maxdepth 1 -name "*.conf" ! -name 'windows.conf' -print0 2>/dev/null)

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
    if ! sudo -n grep -qE '^linux[[:space:]]' "$entry" 2>/dev/null; then
      log_info "Skipping non-kernel entry $entry_name (no linux line — chainload entries keep no options)"
      continue
    fi
    # Smart detection: dated archinstall entry (2026-09-04_10-49-12_linux.conf) vs simple (linux.conf)
    if [[ "$entry_name" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}_(.*)\.conf$ ]]; then
      log_info "Dated archinstall entry detected: $entry_name -> will patch options in-place (e.g. add amd_pstate=active)"
    fi
    # Merge with the existing options line: preserves archinstall-written
    # root= (PARTUUID c9862f4f-c053-4124-a6a3-55be71016782), zswap.enabled=0, rw, rootfstype etc.
    # Only managed keys (quiet, amd_pstate, etc.) are replaced - example file keeps PARTUUID
    local existing=""
    if sudo -n grep -q "^options[[:space:]]" "$entry" 2>/dev/null; then
      existing=$(sudo -n grep "^options[[:space:]]" "$entry" 2>/dev/null | sed 's/^options[[:space:]]//')
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
    if sudo -n grep -q "^options[[:space:]]" "$entry" 2>/dev/null; then
      sudo -n sed -i "s|^options[[:space:]].*|options $new_options|" "$entry"
      log_info "Patched $entry_name options (added managed params like amd_pstate=active if needed)"
    else
      echo "options $new_options" | sudo -n tee -a "$entry" >/dev/null
      log_info "Added options to $entry_name"
    fi
    updated=$((updated + 1))
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
  done < <(sudo -n find "$entries_dir" -name "*.conf" ! -name 'windows.conf' -print0 2>/dev/null)

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
    local current_options=$(sudo -n grep "^options[[:space:]]" "$entry" 2>/dev/null | sed 's/^options[[:space:]]//' || echo "")
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

    if ui_confirm_destructive "Sync all kernel entries to use the same options?" "Kernel options are inconsistent across entries — this may cause boot issues." false; then
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
  done < <(sudo -n find "$entries_dir" -name "*.conf" ! -name 'windows.conf' -print0 2>/dev/null)

  if [[ ${#kernel_entries[@]} -eq 0 ]]; then
    log_warning "No kernel entries found to sync"
    return 0
  fi

  local standard_entry="${kernel_entries[0]}"
  local standard_options=$(sudo -n grep "^options[[:space:]]" "$standard_entry" 2>/dev/null | sed 's/^options[[:space:]]//' || echo "")

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

    local current_options=$(sudo -n grep "^options[[:space:]]" "$entry" 2>/dev/null | sed 's/^options[[:space:]]//' || echo "")

    if [[ "$current_options" != "$standard_options" ]]; then
      local temp_file=$(mktemp)
      trap 'rm -f "$temp_file"' RETURN
      sudo -n grep -v "^options[[:space:]]" "$entry" 2>/dev/null > "$temp_file" || grep -v "^options[[:space:]]" "$entry" 2>/dev/null > "$temp_file" || true
      echo "options $standard_options" >> "$temp_file"
      sudo -n mv "$temp_file" "$entry"
      log_success "Synced options in $entry_name"
      updated_count=$((updated_count + 1))
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
  done < <(sudo -n find "$entries_dir" -name "*[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9]-[0-9][0-9]-[0-9][0-9]_*.conf" ! -name "*fallback*" -print0 2>/dev/null)

  log_info "Boot entries directory: $entries_dir"
  log_info "Found ${#dated_entries[@]} dated kernel entries"

  if [[ ${#dated_entries[@]} -eq 0 ]]; then
    log_info "No dated kernel entries found — entries already in simple format"
    # List all .conf files for debugging
    log_info "All entries in directory:"
    sudo -n find "$entries_dir" -name "*.conf" -exec basename {} \; 2>/dev/null | while read -r f; do
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

      if sudo -n test -f "$simple_path" 2>/dev/null; then
        log_warning "Simple entry $simple_name already exists, skipping rename of $entry_name"
        continue
      fi

      if ! validate_kernel_entry "$dated_entry"; then
        log_warning "Invalid kernel entry $entry_name, skipping rename"
        continue
      fi

      log_info "Attempting to rename: $dated_entry -> $simple_path"
      if sudo -n mv "$dated_entry" "$simple_path"; then
        log_success "Renamed $entry_name to $simple_name"
        renamed_count=$((renamed_count + 1))
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

      if sudo -n test -f "$simple_path" 2>/dev/null; then
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
  local entry="${1:-}"

  # Title field is optional (archinstall entries don't have it)
  # Only check for essential fields: linux and initrd.
  # sudo: entries live under /boot, which archinstall may lock to 700 —
  # bare grep would fail and wrongly reject every entry.
  if ! sudo -n grep -q "^linux[[:space:]]" "$entry" 2>/dev/null; then
    log_warning "Entry $(basename "$entry") missing linux field"
    return 1
  fi

  if ! sudo -n grep -q "^initrd[[:space:]]" "$entry" 2>/dev/null; then
    log_warning "Entry $(basename "$entry") missing initrd field"
    return 1
  fi

  if ! sudo -n grep -q "^options[[:space:]]" "$entry" 2>/dev/null; then
    log_warning "Entry $(basename "$entry") missing options field"
    return 1
  fi

  return 0
}

update_loader_conf_references() {
  local old_name="${1:-}"
  local new_name="${2:-}"
  local loader_config=""
  for f in "/boot/loader/loader.conf" "/efi/loader/loader.conf" "/boot/efi/loader/loader.conf"; do
    if sudo -n test -f "$f" 2>/dev/null; then
      loader_config="$f"
      break
    fi
  done

  if [[ -z "$loader_config" ]]; then
    return 0
  fi

  if sudo -n grep -q "^default $old_name$" "$loader_config" 2>/dev/null; then
    sudo -n sed -i "s|^default $old_name$|default $new_name|" "$loader_config"
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

    # GRUB's 10_linux prepends its OWN rootflags=subvol=<rootsubvol>
    # (derived via make_system_path_relative_to_its_root, leading slash
    # stripped, so `@` where findmnt reports `/@`) to every entry at
    # mkconfig time. Shipping our own rootflags in DEFAULT duplicates it on
    # /proc/cmdline — and no merge can fix that, since the extra copy is
    # manufactured during generation. So on btrfs the GRUB merge owns every
    # managed key EXCEPT rootflags (10_linux is authoritative there);
    # stale stored copies are still stripped by the merge, and
    # GRUB_CMDLINE_LINUX is still scrubbed below against the FULL param set
    # (a stored copy there would be duplicated by 10_linux too).
    # Non-GRUB bootloaders (systemd-boot entries, Limine, UKI cmdline) have
    # no 10_linux and keep rootflags from get_kernel_params untouched.
    local grub_managed="$kernel_params"
    if is_btrfs_system 2>/dev/null; then
        grub_managed=$(echo "$kernel_params" | tr ' ' '\n' | grep -vE '^rootflags=' | tr '\n' ' ' | tr -s ' ' | sed 's/^ //; s/ $//')
    fi

    # Traditional system: configure GRUB
    set_grub_config "GRUB_TIMEOUT" "3"
    ui_info "Set GRUB timeout to 3 seconds"

    step "Configuring GRUB: set saved entry as default"
    set_grub_config "GRUB_DEFAULT" "saved"
    ui_info "Set saved entry as default boot entry"

    set_grub_config "GRUB_SAVEDEFAULT" "true"

    set_grub_config "GRUB_DISABLE_SUBMENU" "notlinux"
    # Native display resolution so the menu isn't rendered in a stretched
    # low-res fallback (giant text on 2K/HiDPI panels); `,auto` keeps a
    # fallback if the detected mode is ever unavailable.
    local grub_res
    grub_res=$(detect_display_resolution 2>/dev/null || echo "1920x1080")
    [[ "$grub_res" =~ ^[0-9]+x[0-9]+$ ]] || grub_res="1920x1080"
    set_grub_config "GRUB_GFXMODE" "$grub_res,auto"
    set_grub_config "GRUB_GFXPAYLOAD_LINUX" "keep"

    # Merge kernel parameters (quiet, splash, nvidia, etc.) with the existing
    # GRUB_CMDLINE_LINUX_DEFAULT — archinstall writes cryptdevice/resume here
    # on encrypted systems, so never replace wholesale. GRUB_CMDLINE_LINUX is
    # left untouched for the same reason (it used to be blanked — a boot
    # breaker when the installer put params there).
    local grub_current=""
    grub_current=$(grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub 2>/dev/null | cut -d= -f2- | tr -d '"' || echo "")
    local grub_merged
    grub_merged=$(merge_kernel_params "$grub_current" "$grub_managed")
    # Quote: /etc/default/grub is shell-sourced, unquoted spaces break it.
    set_grub_config "GRUB_CMDLINE_LINUX_DEFAULT" "\"$grub_merged\""
    ui_info "Kernel parameters: $grub_merged"

    # GRUB boots with CMDLINE_LINUX + CMDLINE_LINUX_DEFAULT concatenated —
    # if archinstall left managed keys (quiet, rootflags, ...) in LINUX as
    # well, they land on /proc/cmdline twice (10_linux ALSO prepends its own
    # rootflags on btrfs). Strip managed dupes from LINUX, keeping unmanaged
    # tokens (cryptdevice, resume, ...) untouched. Reference is the FULL
    # param set on purpose: rootflags must be scrubbed here even though it
    # is no longer shipped in DEFAULT (see above).
    local grub_linux=""
    grub_linux=$(grep -E '^GRUB_CMDLINE_LINUX=' /etc/default/grub 2>/dev/null | cut -d= -f2- | tr -d '"' || echo "")
    if [[ -n "$grub_linux" ]]; then
      local grub_linux_cleaned
      grub_linux_cleaned=$(strip_managed_dupes "$grub_linux" "$kernel_params")
      grub_linux_cleaned=$(echo "$grub_linux_cleaned" | tr -s ' ' | sed 's/^ //; s/ $//')
      if [[ "$grub_linux_cleaned" != "$grub_linux" ]]; then
        set_grub_config "GRUB_CMDLINE_LINUX" "\"$grub_linux_cleaned\""
        log_info "Removed duplicate managed params from GRUB_CMDLINE_LINUX (now: ${grub_linux_cleaned:-<empty>})"
      fi
    fi

    # Menu layout: kernels first, snapshots second, other OSes third, no
    # firmware entry. Runs before the kernel check so the layout persists
    # even when grub-mkconfig itself has to wait for kernels to appear.
    configure_grub_menu_order

    local KERNELS=()
    mapfile -t KERNELS < <(sudo -n find /boot -maxdepth 1 -name 'vmlinuz-*' 2>/dev/null | sed 's|.*/vmlinuz-||' | sort)
    if [[ ${#KERNELS[@]} -eq 0 ]]; then
        # kernel-install layout (/boot/<machine-id>/.../linux, no vmlinuz-*):
        # stock 10_linux cannot see those kernels, but GRUB's blscfg parser
        # reads the /boot/loader/entries/*.conf files kernel-install
        # maintains. Same approach as the standalone Limine→GRUB migration.
        local layout_count entry_count
        layout_count=$(sudo -n find /boot -maxdepth 3 -type f -name linux 2>/dev/null | wc -l)
        entry_count=$(sudo -n find /boot/loader/entries -maxdepth 1 -name '*.conf' 2>/dev/null | wc -l)
        if [[ "$layout_count" -gt 0 && "$entry_count" -gt 0 ]]; then
            set_grub_config "GRUB_ENABLE_BLSCFG" "true"
            log_success "kernel-install layout detected — GRUB will boot via loader entries (blscfg)"
        else
            log_error "No kernels found in /boot."
            return 1
        fi
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

    if sudo -n test -f "$grub_config" 2>/dev/null; then
        sudo -n cp "$grub_config" "$backup_grub_config" || true
    fi

    if [ -f "$grub_config" ]; then
        ui_info "Regenerating GRUB configuration..."
        if sudo -n grub-mkconfig -o "$grub_cfg" 2>&1 | tee -a "$INSTALL_LOG" >/dev/null; then
            log_success "GRUB configuration regenerated successfully"
            if ! sudo -n grep -qE 'menuentry |blscfg' "$grub_cfg" 2>/dev/null; then
                log_error "grub.cfg has no boot entries — investigate before rebooting."
                if [ -f "$backup_grub_config" ]; then
                    sudo -n mv "$backup_grub_config" "$grub_config" || true
                fi
                return 1
            fi
        else
            log_error "grub-mkconfig failed"
            if [ -f "$backup_grub_config" ]; then
                sudo -n mv "$backup_grub_config" "$grub_config" || true
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

# Cheap second-OS evidence WITHOUT os-prober, so os-prober is only
# installed when actually needed. Three independent signals:
#   1. NVRAM entries for foreign OS loaders (Windows Boot Manager and other
#      distros' shims — our own Arch entry deliberately never matches).
#   2. Foreign bootloader files on any ESP (unmounted ESPs get a temporary
#      read-only mount, always cleaned up; our own ESP's arch dir excluded).
#   3. NTFS partitions (Windows in any boot mode, incl. legacy/BIOS).
# Returns 0 when any signal fires. Best-effort: a miss just means os-prober
# stays uninstalled this run — re-evaluated every run.
detect_second_os_evidence() {
    # 1. NVRAM entries for foreign OS loaders.
    if command -v efibootmgr &>/dev/null; then
        if sudo -n efibootmgr -v 2>/dev/null | grep -qiE 'File\(\\EFI\\(Microsoft|ubuntu|fedora|debian|opensuse|suse|gentoo|centos|manjaro|endeavouros|pop|linuxmint|zorin|kali)'; then
            return 0
        fi
    fi
    # 2. Foreign bootloader files on ESPs.
    if _esp_has_foreign_loader; then
        return 0
    fi
    # 3. NTFS partitions (Windows, any boot mode).
    if lsblk -n -o FSTYPE 2>/dev/null | grep -qi '^ntfs$'; then
        return 0
    fi
    return 1
}

# True when some ESP carries a foreign OS loader: Windows bootmgfw.efi
# anywhere (shared ESP is the common dual-boot layout), a non-arch vendor
# shim/grub, or an arch grub on an ESP that is NOT ours (second Arch install
# on another disk). Never true for our own ESP alone.
_esp_has_foreign_loader() {
    local our_esp our_part
    our_esp=$(detect_esp_mount 2>/dev/null || echo "")
    our_part=""
    if [[ -n "$our_esp" ]]; then
        our_part=$(findmnt -n -o SOURCE "$our_esp" 2>/dev/null || echo "")
        our_part=$(readlink -f "$our_part" 2>/dev/null || echo "$our_part")
    fi
    local vfat_parts=()
    while IFS= read -r p; do
        [[ -n "$p" ]] && vfat_parts+=("/dev/$p")
    done < <(lsblk -n -o NAME,FSTYPE 2>/dev/null | awk '$2=="vfat" {print $1}')
    local part mnt tmp cleanup vendor vname this_part is_ours found
    for part in ${vfat_parts[@]+"${vfat_parts[@]}"}; do
        mnt=$(findmnt -n -o TARGET "$part" 2>/dev/null || echo "")
        tmp=""; cleanup=false
        if [[ -z "$mnt" ]]; then
            mnt=$(mktemp -d /tmp/esp_probe.XXXXXX 2>/dev/null || echo "")
            [[ -z "$mnt" ]] && continue
            if ! sudo -n mount -o ro "$part" "$mnt" 2>/dev/null; then
                rmdir "$mnt" 2>/dev/null || true
                continue
            fi
            cleanup=true
        fi
        found=false
        if sudo -n test -f "$mnt/EFI/Microsoft/Boot/bootmgfw.efi" 2>/dev/null; then
            found=true
        else
            this_part=$(readlink -f "$part" 2>/dev/null || echo "$part")
            is_ours=false
            { [[ -n "$our_part" && "$this_part" == "$our_part" ]]; } && is_ours=true
            { [[ -n "$our_esp" && "$mnt" == "$our_esp" ]]; } && is_ours=true
            for vendor in "$mnt"/EFI/*/; do
                [[ -d "$vendor" ]] || continue
                vname=$(basename "$vendor")
                case "$vname" in
                    BOOT) ;;
                    arch)
                        if [[ "$is_ours" == false ]]; then
                            found=true; break
                        fi
                        ;;
                    *)
                        if sudo -n test -f "$vendor/grubx64.efi" 2>/dev/null \
                            || sudo -n test -f "$vendor/shimx64.efi" 2>/dev/null \
                            || sudo -n test -f "$vendor/BOOTX64.EFI" 2>/dev/null; then
                            found=true; break
                        fi
                        ;;
                esac
            done
        fi
        if [[ "$cleanup" == true ]]; then
            sudo -n umount "$mnt" 2>/dev/null || true
            rmdir "$mnt" 2>/dev/null || true
        fi
        [[ "$found" == true ]] && return 0
    done
    return 1
}

# GRUB menu layout: kernels on top, snapshots second, second OS third, and
# no firmware/NVRAM utility entries. Stock /etc/grub.d numbering runs
# 10_linux, then 30_os-prober, 30_uefi-firmware and (GRUB 2.16+)
# 31_efi_bootnext, and only then the grub-btrfs 41_snapshots-btrfs script —
# so without intervention the order is kernels → other OSes → firmware →
# NVRAM utilities → snapshots. Every change below is idempotent and
# re-applied on each run (a grub/grub-btrfs package update can restore stock
# script permissions).
find_grub_snapshot_src() {
    # Echoes the installed grub-btrfs menu script. grub-customizer renames
    # /etc/grub.d entries, so match by suffix, not number. Skips proxies and
    # our own reorder destination.
    local f b
    for f in /etc/grub.d/41_snapshots-btrfs /etc/grub.d/*snapshots-btrfs; do
        b=$(basename "$f")
        [[ "$b" == *proxy* ]] && continue
        [[ "$b" == "15_snapshots-btrfs" ]] && continue
        if [[ -f "$f" ]] 2>/dev/null || sudo -n test -f "$f" 2>/dev/null; then echo "$f"; return 0; fi
    done
    return 1
}

configure_grub_menu_order() {
    step "Configuring GRUB menu order (kernels, snapshots, other OSes)"

    # 1. Remove the "UEFI Firmware Settings" entry completely. Upstream GRUB
    # provides no GRUB_* knob for it — the supported mechanism is making
    # 30_uefi-firmware non-executable so grub-mkconfig skips it.
    if [[ -x /etc/grub.d/30_uefi-firmware ]]; then
        if sudo -n chmod -x /etc/grub.d/30_uefi-firmware 2>/dev/null; then
            log_success "Disabled UEFI Firmware Settings menu entry"
        else
            log_warning "Could not disable 30_uefi-firmware"
        fi
    else
        log_info "UEFI Firmware Settings entry already disabled"
    fi

    # 1b. Remove raw NVRAM Boot#### entries (GRUB 2.16+ 31_efi_bootnext).
    # This script mirrors UEFI NVRAM boot options (BootManagerMenuApp, EFI
    # Firmware Setup, misc devices, ...) into the menu independently of
    # os-prober — `os-prober` output stays empty while these still appear,
    # which is exactly the reported symptom. Same supported mechanism:
    # non-executable scripts are skipped by grub-mkconfig. Real second-OS
    # entries (30_os-prober) are unaffected.
    if [[ ! -e /etc/grub.d/31_efi_bootnext ]]; then
        log_info "No 31_efi_bootnext script (older GRUB) — nothing to disable"
    elif [[ ! -x /etc/grub.d/31_efi_bootnext ]]; then
        log_info "EFI BootNext NVRAM entries already disabled"
    elif sudo -n chmod -x /etc/grub.d/31_efi_bootnext 2>/dev/null; then
        log_success "Disabled EFI BootNext NVRAM menu entries"
    else
        log_warning "Could not disable 31_efi_bootnext"
    fi

    # 2. Second OS via os-prober — smart: os-prober is installed and enabled
    # ONLY when another OS actually exists on some disk. Upstream default is
    # disabled; with no second OS probing buys nothing and only slows
    # grub-mkconfig. The toggle is re-evaluated every run, so adding Windows
    # later just takes one more installer run to pick it up.
    local second_os=false
    if detect_second_os_evidence; then
        second_os=true
    elif pacman -Q os-prober &>/dev/null 2>&1; then
        # Already installed (pre-installed by user?) — run it; it may see
        # what the cheap checks missed.
        if sudo -n os-prober 2>/dev/null | grep -q .; then
            second_os=true
        fi
    fi
    if [[ "$second_os" == true ]]; then
        if ! pacman -Q os-prober &>/dev/null 2>&1; then
            log_info "Second OS detected — installing os-prober..."
            install_packages_quietly os-prober 2>>"$INSTALL_LOG" \
                || log_warning "os-prober install failed — second-OS entries unavailable"
        fi
        if pacman -Q os-prober &>/dev/null 2>&1; then
            if sudo -n os-prober 2>/dev/null | grep -q .; then
                set_grub_config "GRUB_DISABLE_OS_PROBER" "false"
                log_success "os-prober enabled (second OS found, entries will be generated)"
            else
                set_grub_config "GRUB_DISABLE_OS_PROBER" "true"
                log_info "os-prober ran but found no bootable second OS — leaving it disabled"
            fi
        else
            set_grub_config "GRUB_DISABLE_OS_PROBER" "true"
        fi
    else
        set_grub_config "GRUB_DISABLE_OS_PROBER" "true"
        log_info "No second OS detected — os-prober not installed/enabled"
    fi

    # 3. Snapshots between kernels and os-prober (btrfs + snapper/timeshift
    # only). The package ships 41_snapshots-btrfs, which sorts after
    # 30_os-prober — so a managed 15_ copy is kept in sync ahead of it while
    # the 41 original stays non-executable (entries generated exactly once).
    if ! is_btrfs_system 2>/dev/null; then
        log_info "Root is not btrfs — skipping snapshot menu entries"
        return 0
    fi
    if ! pacman -Q snapper &>/dev/null 2>&1 && ! pacman -Q timeshift &>/dev/null 2>&1; then
        log_info "Neither snapper nor timeshift installed — skipping snapshot menu entries"
        return 0
    fi
    local snap_src snap_dst="/etc/grub.d/15_snapshots-btrfs"
    snap_src=$(find_grub_snapshot_src || true)
    if ! pacman -Q grub-btrfs &>/dev/null 2>&1; then
        log_info "Installing grub-btrfs for snapshot boot entries..."
        if ! install_packages_quietly grub-btrfs 2>>"$INSTALL_LOG"; then
            log_warning "grub-btrfs install failed — skipping snapshot menu entries"
            [[ -f "$snap_dst" ]] && sudo -n grep -q "Managed by archinstaller" "$snap_dst" 2>/dev/null \
                && sudo -n rm -f "$snap_dst" 2>/dev/null || true
            return 0
        fi
    fi
    if [[ -n "$snap_src" && "$snap_src" != "$snap_dst" ]]; then
        if ! sudo -n test -f "$snap_dst" 2>/dev/null || [[ "$snap_src" -nt "$snap_dst" ]]; then
            if sudo -n cp "$snap_src" "$snap_dst" 2>/dev/null \
                && echo "# Managed by archinstaller — runs snapshot entries ahead of os-prober" \
                    | sudo -n tee -a "$snap_dst" >/dev/null; then
                log_success "Snapshot menu entries placed ahead of os-prober (15_snapshots-btrfs)"
            else
                log_warning "Could not install 15_snapshots-btrfs"
                return 0
            fi
        else
            log_info "Snapshot menu order already in place (15_snapshots-btrfs)"
        fi
        sudo -n chmod +x "$snap_dst" 2>/dev/null || true
        sudo -n chmod -x "$snap_src" 2>/dev/null || true
    elif [[ -n "$snap_src" ]]; then
        log_info "Snapshot menu order already in place ($snap_dst)"
        sudo -n chmod +x "$snap_dst" 2>/dev/null || true
    else
        log_warning "grub-btrfs installed but no *snapshots-btrfs script in /etc/grub.d — snapshot entries unavailable"
        return 0
    fi
    if sudo -n systemctl enable --now grub-btrfsd.service >>"$INSTALL_LOG" 2>&1; then
        log_success "grub-btrfsd enabled (snapshot menu refreshes automatically)"
    else
        log_warning "Could not enable grub-btrfsd — snapshot entries still generate at grub-mkconfig time"
    fi
}

# PART 3: HELPER FUNCTIONS

set_grub_config() {
    local key="${1:-}"
    local value="${2:-}"
    local grub_config="/etc/default/grub"

    if grep -q "^${key}=" "$grub_config" 2>/dev/null; then
        # Values can contain '/' (e.g. rootflags=subvol=/@) and '&', both of
        # which are special in the sed replacement — escape them first, or the
        # write silently fails with "unknown option to `s'" (observed on a
        # real btrfs run: GRUB_CMDLINE_LINUX_DEFAULT never updated).
        local escaped_value="${value//\\/\\\\}"
        escaped_value="${escaped_value//\//\\/}"
        escaped_value="${escaped_value//&/\\&}"
        sudo -n sed -i "s/^${key}=.*/${key}=${escaped_value}/" "$grub_config"
    else
        echo "${key}=${value}" | sudo -n tee -a "$grub_config" >/dev/null
    fi
}

set_loader_config() {
    local key="${1:-}"
    local value="${2:-}"
    local loader_config=""
    for f in "/boot/loader/loader.conf" "/efi/loader/loader.conf" "/boot/efi/loader/loader.conf"; do
      if sudo -n test -f "$f" 2>/dev/null; then # Use sudo -n test for file existence
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
          if sudo -n test -f "$derived_conf" 2>/dev/null; then
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
    current_content=$(sudo -n cat "$loader_config" 2>/dev/null) || cat_status=$?
    if [ $cat_status -ne 0 ]; then
        if sudo -n test -f "$loader_config" 2>/dev/null; then
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
        # shellcheck disable=SC2001
        # sed needed here: pattern uses regex character classes + variable key
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
    if ! sudo -n test -d "$target_dir" 2>/dev/null; then
        sudo -n mkdir -p "$target_dir" 2>/dev/null || {
            log_error "Failed to create directory $target_dir"
            return 1
        }
    fi

    # Robust atomic write: uses /tmp for privileged /boot (700) so bare > never fails,
    # then sudo -n mv — never chmods /boot, so no revert needed and boot never breaks
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

# LIMINE HELPERS (must be defined before MAIN EXECUTION dispatch below)

# Detect ESP mountpoint (vfat partition). Echoes path, returns 1 if not found.
detect_esp_mount() {
  local esp
  esp=$(findmnt -n -o TARGET -t vfat 2>/dev/null | head -1 || true)
  if [[ -z "$esp" ]]; then
    local p
    for p in /boot /boot/efi /efi /limine; do
      if sudo -n test -d "$p" 2>/dev/null && findmnt -n -o FSTYPE "$p" 2>/dev/null | grep -q vfat; then
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
    # Acquire/release as root, matching `sudo limine-update` and `sudo
    # limine-snapper-sync`, which use this same mutex internally. Doing
    # this as the invoking user instead (as before) meant a lock file
    # created by root earlier in the run (/run/lock/boot-partition.lock)
    # became unwritable/unremovable from here — every subsequent call hit
    # "Permission denied" and "Mutex lock timeout", silently skipping the
    # protection this mutex exists for (a torn write on FAT32, which has
    # no journaling, if limine-snapper-sync's watcher fires mid-edit).
    # Harmless on a fresh install with nothing else racing it, but not
    # actually providing the protection it's there for. Confirmed via a
    # real install log, not something the mocked test environment could
    # have caught (no real /run/lock permission semantics there).
    sudo -v 2>/dev/null || true
    sudo -n bash -c 'source /usr/lib/limine/limine-mutex && mutex_lock "archinstaller"' 2>/dev/null || true
    "$@"
    local rc=$?
    sudo -n bash -c 'source /usr/lib/limine/limine-mutex && mutex_unlock' 2>/dev/null || true
    return $rc
  else
    "$@"
  fi
}

# Helpers executed under with_limine_lock (must be plain functions, same shell)
# Kernel cmdline tokens never contain | or & — pipe delimiter is safe below.
_limine_replace_line() {
  local conf="${1:-}" ln="${2:-}" content="${3:-}"
  sudo -n sed -i "${ln}s|^.*|$content|" "$conf"
}

_limine_append_snapshots_marker() {
  printf '\n  //Snapshots\n' | sudo -n tee -a "$1" >/dev/null
}

# Remove helper executed under with_limine_lock (plain function, same shell).
_limine_remove_file() {
  sudo -n rm -f "$1"
}

# Delete the top-level EFI-fallback entry block entirely (through the next
# top-level entry or EOF). Matching is case-insensitive on purpose:
# limine-entry-tool writes `/EFI fallback` or `/EFI Fallback` depending on
# version, and a case-sensitive match silently misses one of them (which is
# how the entry survived pruning before). Returns 0 when removed,
# 2 when absent, 1 on error — so callers can log accurately.
limine_remove_efi_fallback() {
  local conf="${1:-}"
  sudo -n grep -qiE "^/efi fallback[[:space:]]*$" "$conf" 2>/dev/null || return 2
  local tmp
  tmp=$(mktemp /tmp/limine_rm_entry.XXXXXX) || return 1
  if sudo -n cat "$conf" 2>/dev/null | awk '
      /^\/\// { in_target = 0; print; next }
      /^\// { cur = substr($0, 2); sub(/[ \t\r]+$/, "", cur); in_target = (tolower(cur) == "efi fallback") }
      !in_target { print }
    ' > "$tmp" && [[ -s "$tmp" ]]; then
    with_limine_lock _limine_write_file "$tmp" "$conf"
    local rc=$?
    rm -f "$tmp"
    return $rc
  fi
  rm -f "$tmp"
  return 1
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
  local conf="${1:-}" unified="${2:-}"
  # Both cmdline key spellings: archinstall writes `cmdline:`, entry-tool
  # writes `kernel_cmdline:`. Values merge identically either way.
  local entry_lns=()
  mapfile -t entry_lns < <(sudo -n grep -nE '^[[:space:]]*(kernel_)?cmdline:' "$conf" 2>/dev/null | cut -d: -f1)
  if [ ${#entry_lns[@]} -eq 0 ]; then
    return 0
  fi
  sudo -n cp "$conf" "${conf}.backup.$(date +%Y%m%d_%H%M%S)"
  local patched=0 skipped=0 snap_skipped=0
  local ln existing merged indent
  for ln in "${entry_lns[@]}"; do
    existing=$(sudo -n sed -n "${ln}p" "$conf" 2>/dev/null | sed -E 's/^[[:space:]]*(kernel_)?cmdline:[[:space:]]*//')
    if echo "$existing" | grep -q '/\.snapshots'; then
      log_to_file "Limine $conf line $ln is a snapshot entry — left for limine-snapper-sync."
      snap_skipped=$((snap_skipped + 1))
      continue
    fi
    merged=$(merge_kernel_params "$existing" "$unified")
    if ! merged=$(ensure_root_rw "$merged"); then
      log_error "Skipping $conf line $ln: cannot ensure root= — left untouched."
      skipped=$((skipped + 1))
      continue
    fi
    indent=$(sudo -n sed -n "${ln}p" "$conf" 2>/dev/null | sed -E 's/^([[:space:]]*(kernel_)?cmdline:).*/\1/')
    with_limine_lock _limine_replace_line "$conf" "$ln" "$indent $merged"
    log_to_file "Limine $conf line $ln cmdline: $merged"
    patched=$((patched + 1))
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
  if sudo -n sed -i "s/^\(HOOKS=.*\bfilesystems\b\)/\1 $hook/" "$mkconf" && \
     grep -q "^HOOKS=.*\b$hook\b" "$mkconf"; then
    log_success "Added $hook after filesystems in mkinitcpio (read-only snapshots can boot)"
    # Defer the (slow) full rebuild: collected once at end of step 6.
    NEEDS_INITRAMFS_REBUILD=true
  else
    log_warning "Failed to add $hook to mkinitcpio HOOKS"
  fi
}

# Limine theme - custom theme (user-spec full header)
# Handles 700 /boot via privileged atomic write and FAT32 mutex, idempotent.
# Resolution + font scale are smart: largest connected mode (2K-primary +
# 1080p-secondary -> 2560x1440, single-1080p box -> 1920x1080); 2x2 on HiDPI,
# 1x1 otherwise. Override with LIMINE_RESOLUTION=WxH.
_limine_write_file() {
  local src="${1:-}" dst="${2:-}"
  sudo -n tee "$dst" >/dev/null < "$src"
}

configure_limine_theme() {
  local conf="${1:-}"
  if [[ -z "$conf" ]]; then
    log_warning "Limine theme: no config path, skipping"
    return 0
  fi
  # Strip the unwanted "EFI Fallback" entry entirely, every time this step
  # touches a config: it chainloads the same loader firmware/NVRAM already
  # resolves. Done first (before the idempotent early-return below) so an
  # entry regenerated by limine-update / limine-snapper-sync earlier in the
  # run — or by a kernel update since the last run — is caught too.
  if sudo -n test -f "$conf" 2>/dev/null; then
    local _prc
    if limine_remove_efi_fallback "$conf"; then
      _prc=0
    else
      _prc=$?
    fi
    if [[ "$_prc" -eq 0 ]]; then
      log_success "Removed EFI Fallback entry from $conf."
    elif [[ "$_prc" -ne 2 ]]; then
      log_warning "Could not prune EFI Fallback entry in $conf."
    fi
    unset _prc
  fi
  local resolution font_scale
  resolution=$(detect_display_resolution 2>/dev/null || echo "1920x1080")
  [[ "$resolution" =~ ^[0-9]+x[0-9]+$ ]] || resolution="1920x1080"
  font_scale=$(detect_term_font_scale "$resolution" 2>/dev/null || echo "1x1")

  # Idempotent: all signature keys + detected resolution/scale must match.
  # Resolution is part of the check so a 1080p box re-themes after a 2K image
  # (and vice versa) instead of keeping a stale interface_resolution/video=.
  if sudo -n grep -q "term_palette: 05142a;" "$conf" 2>/dev/null \
    && sudo -n grep -q "default_entry: Arch Linux/linux" "$conf" 2>/dev/null \
    && sudo -n grep -qE "^\s*interface_branding:\s*Arch Linux" "$conf" 2>/dev/null \
    && sudo -n grep -q "term_palette_bright: 45475a;" "$conf" 2>/dev/null \
    && sudo -n grep -q "graphic_palette: 05142a;" "$conf" 2>/dev/null \
    && sudo -n grep -q "interface_resolution: $resolution" "$conf" 2>/dev/null \
    && sudo -n grep -q "term_font_scale: $font_scale" "$conf" 2>/dev/null \
    && sudo -n grep -q "term_background_bright: 181825" "$conf" 2>/dev/null; then
    log_info "Limine theme already present in $conf ($resolution, $font_scale)"
    return 0
  fi
  # Full user-spec header. interface_resolution / term_font_scale / video=
  # stay in sync via detect_display_resolution (see get_kernel_params).
  local theme="# LIMINE BOOTLOADER CONFIGURATION

# ------------------------------------------------------------------------------
# General Boot Settings
# ------------------------------------------------------------------------------
timeout: 3
default_entry: Arch Linux/linux
hash_mismatch_panic: no

# ------------------------------------------------------------------------------
# Branding & Display Setup
# ------------------------------------------------------------------------------
interface_branding: Arch Linux
interface_branding_colour: 3e93af
interface_resolution: $resolution
term_font_scale: $font_scale

# ------------------------------------------------------------------------------
# Background & Graphics
# ------------------------------------------------------------------------------
graphics: yes

# ------------------------------------------------------------------------------
# Terminal Theme: Colors & Palettes
# ------------------------------------------------------------------------------
# Primary Text & Background (6-digit hex format)
term_background: 05142a
term_foreground: cdd6f4
term_background_bright: 181825

# Color Palettes (Base & Bright)
term_palette: 05142a;f38ba8;a6e3a1;f9e2af;3e93af;f5c2e7;94e2d5;cdd6f4
term_palette_bright: 45475a;f38ba8;a6e3a1;f9e2af;89b4fa;f5c2e7;94e2d5;a6adc8

# Selection & Highlight UI
term_highlight_background: 313244
term_highlight_foreground: cdd6f4

# Margins & Outer Background (Fills screen outside terminal window)
term_margin: 0
term_margin_gradient: 0

# ------------------------------------------------------------------------------
# Graphical UI Theme
# ------------------------------------------------------------------------------
graphic_background: 05142a
graphic_foreground: cdd6f4
graphic_margin: 0
graphic_palette: 05142a;f38ba8;a6e3a1;f9e2af;3e93af;f5c2e7;94e2d5;cdd6f4
graphic_palette_bright: 45475a;f38ba8;a6e3a1;f9e2af;89b4fa;f5c2e7;94e2d5;a6adc8
"
  local existing=""
  if sudo -n test -f "$conf" 2>/dev/null; then
    existing=$(sudo -n cat "$conf" 2>/dev/null || echo "")
    # Remove existing global theme keys + timeout + bloat, keep only kernel/snapshots entries.
    # Covers every key in the header above plus legacy wallpaper/editor keys.
    existing=$(echo "$existing" | grep -vE "^\s*(timeout:|default_entry|hash_mismatch_panic|quiet|graphics:|graphic_background|graphic_foreground|graphic_margin|graphic_palette|graphic_palette_bright|interface_branding|interface_branding_colour|interface_resolution|interface_help|wallpaper|wallpaper_style|term_palette|term_palette_bright|term_background|term_background_bright|term_foreground|term_highlight_background|term_highlight_foreground|term_font_scale|term_margin|term_margin_gradient|editor_)" || true)
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
    log_success "Applied Limine theme to $conf ($resolution, $font_scale, custom theme)"
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
  local pkg="${1:-}"
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
# "Would you like to run 'limine-mkinitcpio' now? [Y/n]" on stdin — always
# pre-answer "n" (no prompt): the single collected mkinitcpio -P rebuild at
# the end of this step covers it, so building now would just do the slow
# rebuild twice. Piping the answer also keeps it non-interactive under the
# dashboard, where stdin would otherwise hang silently.
# Override: LIMINE_MKINITCPIO_RUN_NOW=true answers "y".
install_limine_mkinitcpio_hook() {
  if pacman -Qi limine-mkinitcpio-hook &>/dev/null 2>&1; then
    log_info "limine-mkinitcpio-hook already installed"
    return 0
  fi
  if ! command -v yay &>/dev/null && ! command -v paru &>/dev/null; then
    log_warning "No AUR helper — skipping limine-mkinitcpio-hook (kernel entries won't auto-update; install it later)."
    return 1
  fi
  local answer="n"
  if [[ "${LIMINE_MKINITCPIO_RUN_NOW:-false}" == true ]]; then
    answer="y"
    log_info "Will run limine-mkinitcpio during hook install (LIMINE_MKINITCPIO_RUN_NOW=true)."
  else
    log_info "Skipping limine-mkinitcpio run during hook install (covered by step-end rebuild)."
  fi
  limine_install_aur_pkg "limine-mkinitcpio-hook" "$answer"
}

# NVRAM hygiene for the two-binary problem. limine-mkinitcpio-hook deploys
# its own binary to ${ESP}/EFI/limine/limine_x64.efi and registers a fresh
# NVRAM entry for it on install — usually first in BootOrder. That binary
# has no limine.conf in its directory, so the next reboot lands on
# "[config file not found]" with an empty menu even though the real,
# fully-configured install sits one directory over (observed on a real KVM
# reboot, not theorized). Our own binaries are BOOTX64.EFI et al., so the
# exact loader filename below can never match them.
limine_prune_hook_entries() {
  local verbose_list
  verbose_list=$(sudo -n efibootmgr -v 2>/dev/null || true)
  if [[ -z "$verbose_list" ]]; then
    log_warning "efibootmgr unavailable — skipping NVRAM hygiene (if boot order looks wrong, pick the ${limine_dir:-Limine} entry manually in firmware)."
    return 0
  fi
  local line num pruned=0
  while IFS= read -r line; do
    [[ "$line" =~ ^Boot([0-9A-Fa-f]{4}) ]] || continue
    num="${BASH_REMATCH[1]}"
    echo "$line" | grep -qiE '\\EFI\\limine\\limine_x64\.efi' || continue
    if sudo -n efibootmgr -b "$num" -B >>"$INSTALL_LOG" 2>&1; then
      log_success "Removed hook-binary NVRAM entry Boot$num (\\EFI\\limine\\limine_x64.efi has no config — booting it shows '[config file not found]')."
      pruned=$((pruned + 1))
    else
      log_warning "Could not remove NVRAM entry Boot$num."
    fi
  done <<< "$verbose_list"
  if [[ "$pruned" -eq 0 ]]; then
    log_info "No hook-binary NVRAM entries found."
  fi
}

# Move an existing boot entry first in BootOrder, preserving the relative
# order of everything else. Never deletes anything.
limine_order_entry_first() {
  local want="${1:-}"
  local order
  order=$(sudo -n efibootmgr 2>/dev/null | grep -i '^BootOrder:' | cut -d: -f2 | tr -d ' ' || true)
  if [[ -z "$order" ]]; then
    log_warning "Could not read BootOrder — skipping reorder."
    return 0
  fi
  local want_up
  want_up=$(echo "$want" | tr 'a-f' 'A-F')
  local new_order="$want_up" seen=",$want_up," p p_up
  local IFS=','
  # shellcheck disable=SC2162
  for p in $order; do
    [[ -n "$p" ]] || continue
    p_up=$(echo "$p" | tr 'a-f' 'A-F')
    [[ "$seen" == *",$p_up,"* ]] && continue
    seen+="$p_up,"
    new_order="$new_order,$p_up"
  done
  if sudo -n efibootmgr -o "$new_order" >>"$INSTALL_LOG" 2>&1; then
    log_success "BootOrder set to $new_order (configured Limine first)."
  else
    log_warning "Could not set BootOrder."
  fi
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
  if ! sudo -n pacman -Syu --needed --noconfirm "${repo_pkgs[@]}" >>"$INSTALL_LOG" 2>&1; then
    log_error "Failed to install required packages: ${repo_pkgs[*]}"
    return 1
  fi

  # AUR snapshot integration (non-fatal if helper/packages unavailable)
  if [[ "$want_snapper" == true ]]; then
    limine_install_aur_pkg "limine-snapper-sync" || true
    # snap-pac lives in the official repos — prefer that, AUR as fallback.
    # (Step 7 installs it too when snapper is detected; --needed keeps this idempotent.)
    if ! pacman -Qi snap-pac &>/dev/null 2>&1; then
      sudo -n pacman -S --needed --noconfirm snap-pac >>"$INSTALL_LOG" 2>&1 || \
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

    # Universal snapper aux (btrfs-assistant/snap-pac) + ArchWiki profile - not limine-only.
    # Must run BEFORE the mount check below: this is what actually creates
    # the /.snapshots subvolume (via `snapper -c root create-config /`) in
    # the first place. Checking mount status before this ran was checking
    # something that didn't exist to be mounted yet — confirmed via a real
    # install+reboot: the warning below fired every time, and "will mount
    # on next boot" turned out to be false (verify.sh confirmed still
    # unmounted after a real reboot), because nothing had created the
    # subvolume/fstab entry yet at the point the old check ran.
    ensure_snapper_aux_universal

    # archinstall's own default btrfs layout commonly creates a top-level
    # @snapshots subvolume with its own fstab entry (distinct from the
    # simpler case where .snapshots is just a plain nested subvolume that
    # needs no separate mount). If create-config above didn't need the
    # ArchWiki workaround path, this explicit mount never ran — do it
    # unconditionally here so both layouts end up actually mounted, not
    # just the one that happened to hit the workaround branch.
    if ! mountpoint -q /.snapshots 2>/dev/null; then
      local root_dev
      root_dev=$(findmnt -n -o SOURCE / 2>/dev/null | cut -d'[' -f1)
      if [[ -n "$root_dev" ]] && sudo -n btrfs subvolume list / 2>/dev/null | grep -q "path @snapshots"; then
        sudo -n mount -o subvol=@snapshots "$root_dev" /.snapshots 2>/dev/null || true
      fi
      mountpoint -q /.snapshots 2>/dev/null || sudo -n mount -a 2>/dev/null || true
    fi

    if mountpoint -q /.snapshots 2>/dev/null; then
      log_success "/.snapshots is mounted"
    elif sudo -n snapper -c root list &>/dev/null; then
      # Not a separate mountpoint, but that's not actually a problem: for
      # the common single-subvolume layout, .snapshots is just a nested
      # subvolume inside the already-mounted root filesystem, with no
      # separate fstab entry at all — `mountpoint -q` correctly reports
      # false here even when everything works perfectly. Confirmed via a
      # real install log where `mountpoint -q` failed this exact check yet
      # snapper successfully created and listed 19 snapshots in the same
      # run — the mountpoint test was checking a condition that doesn't
      # apply to this (very common) layout. Test what actually matters —
      # whether `snapper list` actually works — instead.
      log_success "Snapper is working (nested subvolume, no separate mount needed)"
    else
      log_warning "/.snapshots could not be mounted and 'snapper -c root list' failed. Check 'sudo -n btrfs subvolume list /' and /etc/fstab after reboot — snapshots won't work until this is resolved."
    fi

    # Shared snapper timers (timeline + cleanup + boot) + scrub.
    # snapper_enable_timers is a no-op without snapper/btrfs; scrub skips
    # when timeshift is present (competing stack).
    snapper_enable_timers || true
    log_success "Snapper timers enabled."
    # Monthly scrub for bit-rot detection — snapper stack only, never with timeshift
    enable_btrfs_scrub_timer || true
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
    if sudo -n test -f "$d/BOOTX64.EFI" 2>/dev/null || sudo -n test -f "$d/BOOTIA32.EFI" 2>/dev/null || \
       sudo -n test -f "$d/BOOTAA64.EFI" 2>/dev/null || sudo -n test -f "$d/limine_x64.efi" 2>/dev/null || \
       sudo -n test -f "$d/limine.conf" 2>/dev/null; then
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
        if sudo -n test -f "$limine_dir/$f" 2>/dev/null && [[ -f "$efi_src_dir/$f" ]]; then
          sudo -n cp "$efi_src_dir/$f" "$limine_dir/$f" && \
            log_success "Refreshed $limine_dir/$f"
        fi
      done
      if sudo -n test -f "$limine_dir/limine_x64.efi" 2>/dev/null; then
        # limine-entry-tool naming — refresh from upstream if the file exists
        for p in "$efi_src_dir/limine_x64.efi" "$limine_efi_src"; do
          if [[ -f "$p" ]]; then
            sudo -n cp "$p" "$limine_dir/limine_x64.efi" && log_success "Refreshed $limine_dir/limine_x64.efi"
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
    sudo -n mkdir -p "$limine_dir"
    sudo -n cp "$limine_efi_src" "$limine_dir/BOOTX64.EFI"
    log_success "Limine EFI binary deployed to $limine_dir."

    local hook_dir="/etc/pacman.d/hooks"
    sudo -n mkdir -p "$hook_dir"
    if ! sudo -n test -f "$hook_dir/99-limine.hook" 2>/dev/null; then
      printf '%s\n' "[Trigger]" "Operation = Install" "Operation = Upgrade" "Type = Package" \
        "Target = limine" "" "[Action]" "Description = Deploying Limine after upgrade..." \
        "When = PostTransaction" "Exec = /bin/sh -c \"/usr/bin/cp /usr/share/limine/BOOTX64.EFI $limine_dir/\"" | \
        sudo -n tee "$hook_dir/99-limine.hook" >/dev/null
      log_success "Limine pacman hook installed."
    fi

    # Fresh deploy has no config yet — write a minimal archinstall-style one,
    # but only when kernels live on the ESP (Limine reads FAT only). With a
    # separate ESP + non-UKI kernels on ext4/btrfs /boot, Limine cannot read
    # them — same layout rule archinstall itself enforces.
    if [[ "$esp_mount" == "/boot" ]]; then
      local fresh_kernels=()
      mapfile -t fresh_kernels < <(sudo -n find /boot -maxdepth 1 -name 'vmlinuz-*' 2>/dev/null | sed 's|.*/vmlinuz-||' | sort)
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
        } | sudo -n tee "$limine_conf" >/dev/null
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
  # Deliberately NOT theming /boot/limine.conf or /boot/limine/limine.conf
  # anymore — Limine's own mkinitcpio hook explicitly calls /boot/limine.conf
  # "the default" that it IGNORES in favor of the real ESP-located config
  # (confirmed via a real install log: the hook auto-creates this file on
  # every kernel rebuild and warns "Detected conflicting config" every
  # single time). Theming a file Limine's own hook says it ignores just
  # keeps it looking legitimate instead of helping the user notice and
  # remove it — see the cleanup step near the end of this function instead,
  # which removes it once the real config is confirmed configured.
  {
    local _theme_targets=()
    [[ -n "${limine_conf:-}" ]] && _theme_targets+=("$limine_conf")
    [[ -n "${limine_dir:-}" ]] && _theme_targets+=("$limine_dir/limine.conf")
    _theme_targets+=("$esp_mount/EFI/limine/limine.conf" "$esp_mount/EFI/BOOT/limine.conf" "/boot/EFI/limine/limine.conf")
    local _seen=" "
    local _lc
    for _lc in "${_theme_targets[@]}"; do
      [[ -n "$_lc" ]] || continue
      if [[ "$_seen" == *" $_lc "* ]]; then continue; fi
      _seen+="$_lc "
      if sudo -n test -f "$_lc" 2>/dev/null; then
        configure_limine_theme "$_lc"
      fi
    done
    unset _lc _theme_targets _seen
  }

  # NVRAM hygiene for the two-binary problem (see limine_prune_hook_entries):
  # the hook registers its config-less binary first in BootOrder on install,
  # so prune those entries, match OURS by loader path (bare "Limine" labels
  # collide between archinstall's entry and the hook's), and order ours first.
  limine_prune_hook_entries || true

  # ESP-relative loader path for OUR binary, e.g. /boot/EFI/BOOT -> \EFI\BOOT\BOOTX64.EFI
  local efi_bin="BOOTX64.EFI"
  if ! sudo -n test -f "$limine_dir/$efi_bin" 2>/dev/null; then
    efi_bin=$(sudo -n ls "$limine_dir" 2>/dev/null | grep -im1 '\.efi$' || echo "BOOTX64.EFI")
  fi
  local loader_path="${limine_dir#"$esp_mount"}/$efi_bin"
  loader_path=${loader_path//\//\\}

  local limine_bootnum
  limine_bootnum=$(sudo -n efibootmgr -v 2>/dev/null | grep -iF "$loader_path" | grep -oE '^Boot[0-9A-Fa-f]{4}' | head -1 | sed 's/^Boot//' || true)

  if [[ -n "$limine_bootnum" ]]; then
    log_info "Limine EFI boot entry already exists (Boot$limine_bootnum → $loader_path)."
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
      log_info "Creating EFI NVRAM entry ($loader_path)..."
      if sudo -n efibootmgr --create \
          --disk "$esp_disk" \
          --part "$esp_part" \
          --label "Limine" \
          --loader "$loader_path" \
          --unicode >>"$INSTALL_LOG" 2>&1; then
        log_success "EFI boot entry created."
        limine_bootnum=$(sudo -n efibootmgr -v 2>/dev/null | grep -iF "$loader_path" | grep -oE '^Boot[0-9A-Fa-f]{4}' | head -1 | sed 's/^Boot//' || true)
      else
        log_warning "efibootmgr failed — you may need to create the Limine entry manually."
      fi
    fi
  fi

  # Boot through the configured install even after NVRAM resets or future
  # hook reinstalls re-register their binary: ours first, rest untouched.
  if [[ -n "$limine_bootnum" ]]; then
    limine_order_entry_first "$limine_bootnum" || true
  fi

  # Configure limine-snapper-sync settings (btrfs only)
  local limine_defaults="/etc/default/limine"
  sudo -n mkdir -p "$(dirname "$limine_defaults")"

  if [[ "$want_snapper" == true ]]; then
    local esp_path_val="$esp_mount"
    [[ "$esp_path_val" == "/boot" ]] && esp_path_val=""

    local os_name="Arch Linux"
    if [[ -r /etc/os-release ]]; then
      # shellcheck disable=SC1091
      . /etc/os-release
      [[ -n "${NAME:-}" ]] && os_name="$NAME"
    fi

    # Create file with sudo -n if missing (redirection must not run as user)
    if ! sudo -n test -f "$limine_defaults" 2>/dev/null; then
      printf '%s\n' "### OS Entry Targeting" "### Settings managed by archinstaller limine-snapper setup" | \
        sudo -n tee "$limine_defaults" >/dev/null
    fi

    limine_set_default_key() {
      local key="${1:-}" value="${2:-}"
      if sudo -n grep -q "^$key=" "$limine_defaults" 2>/dev/null; then
        sudo -n sed -i "s|^$key=.*|$key=$value|" "$limine_defaults"
      else
        printf '%s=%s\n' "$key" "$value" | sudo -n tee -a "$limine_defaults" >/dev/null
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
    # No "EFI Fallback" menu entry: it chainloads the same loader the
    # firmware/NVRAM already resolves, so it's redundant menu clutter.
    limine_set_default_key "ENABLE_LIMINE_FALLBACK" "no"
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
  if sudo -n test -f "$cmdline_file" 2>/dev/null; then
    current_cmdline=$(sudo -n cat "$cmdline_file" 2>/dev/null || echo "")
  fi
  local merged_cmdline
  if ! merged_cmdline=$(build_file_cmdline "$current_cmdline"); then
    log_error "Refusing to write rootless $cmdline_file — leaving it untouched."
  elif [[ "$current_cmdline" != "$merged_cmdline" ]]; then
    [[ -n "$current_cmdline" ]] && sudo -n cp "$cmdline_file" "${cmdline_file}.backup.$(date +%Y%m%d_%H%M%S)"
    echo "$merged_cmdline" | sudo -n tee "$cmdline_file" >/dev/null
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
    if sudo -n grep -q "^ENABLE_ENROLL_LIMINE_CONFIG=yes" /etc/default/limine 2>/dev/null; then
      log_warning "Secure Boot + enrolled Limine config detected — skipping limine.conf edits (re-enroll with limine-enroll-config after changing params)."
      skip_conf_edit=true
    else
      log_warning "Secure Boot is active — binary/config signatures left untouched where verification applies."
    fi
  fi

  if command -v limine-update &>/dev/null; then
    log_info "Regenerating entries with limine-update (reads $cmdline_file)..."
    if sudo -n limine-update >>"$INSTALL_LOG" 2>&1; then
      log_success "limine-update completed."
    else
      log_warning "limine-update returned an error."
    fi
  fi

  # No separate EFI-Fallback prune here: configure_limine_theme() strips
  # the entry from every config it touches (including ones regenerated by
  # limine-update / limine-snapper-sync), and it runs after them.

  # Patch EVERY cmdline: line in limine.conf (base + snapshot entries), even
  # after limine-update just regenerated them: tools write entries from their
  # own sources and can drop root=, which boots into "Failed to mount '' on
  # real root". Lines that can't be rooted are LEFT UNTOUCHED, never blanked.
  if [[ "$skip_conf_edit" == true ]]; then
    : # warned above (Secure Boot enrolled config)
  elif sudo -n test -f "$limine_conf" 2>/dev/null; then
    if sudo -n grep -qE '^[[:space:]]*(kernel_)?cmdline:' "$limine_conf" 2>/dev/null; then
      patch_limine_cmdlines "$limine_conf" "$unified_cmdline"
    else
      log_warning "No cmdline entries in $limine_conf — leaving it untouched."
    fi
  else
    log_warning "Limine config not found at $limine_conf — skipping kernel parameter update."
  fi

  # Single-config migration. limine-entry-tool and
  # limine-snapper-sync manage ONLY $ESP/limine.conf (/boot/limine.conf here)
  # and never touch deep configs — while a deep archinstall-format config
  # beside it either shadows the real menu or, once a bare //Snapshots
  # marker lands on its flat protocol-bearing entry, turns that entry into
  # an unbootable directory node ("PANIC: Boot protocol not specified",
  # observed on a real reboot). So when the entry-tool file is healthy
  # (has protocol-bearing leaves), back up the deep configs and remove them;
  # everything downstream (marker, sync, verify, theme) then targets the
  # single config via $limine_conf. On ANY doubt, abort and keep the old
  # deep-config behavior rather than risk a config-less boot.
  if [[ "$esp_mount" == "/boot" && -n "${limine_conf:-}" && "$limine_conf" != "/boot/limine.conf" ]] \
      && sudo -n test -f /boot/limine.conf 2>/dev/null \
      && sudo -n grep -qE '^[[:space:]]*protocol:' /boot/limine.conf 2>/dev/null; then
    local _seen=" " _migrated_any=false deep bts
    bts="/var/tmp/archinstaller_backups"
    sudo -n mkdir -p "$bts" 2>/dev/null || true
    for deep in "$limine_conf" "$esp_mount/EFI/BOOT/limine.conf" "$esp_mount/EFI/arch-limine/limine.conf" "$esp_mount/EFI/limine/limine.conf"; do
      [[ -n "$deep" && "$deep" != "/boot/limine.conf" ]] || continue
      [[ "$_seen" == *" $deep "* ]] && continue
      _seen+=" $deep "
      sudo -n test -f "$deep" 2>/dev/null || continue
      bts_name="$(basename "$(dirname "$deep")")_limine.conf.backup.$(date +%Y%m%d_%H%M%S)"
      sudo -n cp "$deep" "$bts/$bts_name" 2>/dev/null || true
      sudo -n cp "$deep" "$deep.backup.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
      if with_limine_lock _limine_remove_file "$deep"; then
        log_success "Removed shadowing deep config $deep (backed up to $bts/$bts_name)."
        _migrated_any=true
      else
        log_warning "Could not remove $deep — leaving it (may shadow the menu)."
      fi
    done
    unset deep bts bts_name
    if [[ "$_migrated_any" == true ]]; then
      limine_conf="/boot/limine.conf"
      log_success "Limine now uses the single entry-tool config /boot/limine.conf."
    else
      log_warning "Deep-config migration skipped (nothing removed) — keeping $limine_conf."
    fi
    unset _seen _migrated_any
  else
    log_info "Skipping single-config migration (separate ESP or /boot/limine.conf not entry-tool-healthy) — keeping ${limine_conf:-unknown}."
  fi

  # Post-migration the single config uses entry-tool `kernel_cmdline:` keys
  # (patch_limine_cmdlines handles both spellings). Belt and suspenders on
  # top of /etc/kernel/cmdline, which limine-update already consumed.
  if [[ "${limine_conf:-}" == "/boot/limine.conf" && "$skip_conf_edit" != true ]]; then
    patch_limine_cmdlines "$limine_conf" "$unified_cmdline"
  fi

  if [[ "$want_snapper" == true ]]; then
    # The marker is only safe on entry-tool-style files (existing //
    # children): on a flat archinstall entry it would convert the bootable
    # entry itself into an empty directory node. Sync only manages the
    # entry-tool file anyway, so skipping the marker elsewhere loses nothing.
    if sudo -n test -f "$limine_conf" 2>/dev/null && ! sudo -n grep -q 'Snapshots' "$limine_conf" 2>/dev/null \
        && sudo -n grep -qE '^[[:space:]]*//' "$limine_conf" 2>/dev/null; then
      with_limine_lock _limine_append_snapshots_marker "$limine_conf"
      log_success "Added //Snapshots marker to $limine_conf."
    elif sudo -n test -f "$limine_conf" 2>/dev/null && ! sudo -n grep -q 'Snapshots' "$limine_conf" 2>/dev/null; then
      log_info "Skipping //Snapshots marker for $limine_conf (flat entry format — the snapshot boot menu needs entry-tool //Kernel leaves)."
    fi

    if command -v limine-snapper-sync &>/dev/null; then
      log_info "Running limine-snapper-sync (also heals stale snapshot cmdlines from the fixed base)..."
      if sudo -n limine-snapper-sync >>"$INSTALL_LOG" 2>&1; then
        log_success "limine-snapper-sync completed."
      else
        log_warning "limine-snapper-sync returned an error (normal on first run)."
      fi
    fi

    if systemctl list-unit-files 2>/dev/null | grep -q limine-snapper-sync; then
      sudo -n systemctl enable --now limine-snapper-sync.service 2>/dev/null || true
      log_success "limine-snapper-sync.service enabled."
    fi
  fi

  # Final verification AFTER the sync above: every cmdline must name a root
  # device. Anything still rootless is NOT safe to boot. Both key spellings
  # (archinstall `cmdline:`, entry-tool `kernel_cmdline:`) are checked.
  if sudo -n test -f "$limine_conf" 2>/dev/null; then
    local bad_lines
    bad_lines=$(sudo -n grep -E '^[[:space:]]*(kernel_)?cmdline:' "$limine_conf" 2>/dev/null | grep -vE 'root=[^ ]+' || true)
    if [[ -n "$bad_lines" ]]; then
      log_error "Rootless cmdline lines remain in $limine_conf — DO NOT boot these entries:"
      echo "$bad_lines" | while IFS= read -r bl; do log_error "  $bl"; done
    else
      log_success "All Limine cmdline entries name a root device."
    fi
    # A menu with no protocol-bearing leaf panics at boot time with "Boot
    # protocol not specified for this entry" — fail loudly here instead.
    if ! sudo -n grep -qE '^[[:space:]]*protocol:' "$limine_conf" 2>/dev/null; then
      log_error "No protocol: entries in $limine_conf — the menu would show but nothing in it can boot."
    else
      log_success "Bootable (protocol-bearing) entries present in $limine_conf."
    fi
  fi

  # Same check for a separate /boot/limine.conf (abort path: entry-tool's own
  # file beside a deep config; a rootless entry there breaks that menu only).
  if [[ "${limine_conf:-}" != "/boot/limine.conf" ]] && sudo -n test -f /boot/limine.conf 2>/dev/null; then
    local fallback_bad
    fallback_bad=$(sudo -n grep -E '^[[:space:]]*(kernel_)?cmdline:' /boot/limine.conf 2>/dev/null | grep -vE 'root=[^ ]+' || true)
    if [[ -n "$fallback_bad" ]]; then
      log_warning "Rootless cmdline lines in /boot/limine.conf fallback:"
      echo "$fallback_bad" | while IFS= read -r bl; do log_warning "  $bl"; done
    else
      log_success "Fallback /boot/limine.conf cmdlines all name a root device."
    fi
  fi

  # Final theme pass - re-apply after limine-update/snapper-sync regenerated bloat (### comments)
  # Ensures Arch Linux branding + wallpaper + 700 handling, idempotent
  if sudo -n test -f "$limine_conf" 2>/dev/null; then
    configure_limine_theme "$limine_conf"
  fi

  # Install snap-manager helper (btrfs only; harmless to skip otherwise)
  if [[ "$want_snapper" == true ]]; then
  step "Installing snapshot manager helper..."

  sudo -n tee /usr/local/bin/snap-manager >/dev/null << 'HELPER_EOF'
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
        echo "  sudo -n limine-snapper-restore    # guided restore (recommended)"
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

  sudo -n chmod +x /usr/local/bin/snap-manager
  log_success "Helper script installed: /usr/local/bin/snap-manager"
  fi

  # Post-migration there is only the single config; on the abort path both
  # files remain (each readable by any Limine binary on the ESP).
  if [[ "${limine_conf:-}" == "/boot/limine.conf" ]]; then
    log_info "Single Limine config in effect: /boot/limine.conf (deep backups in /var/tmp/archinstaller_backups)."
  elif sudo -n test -f /boot/limine.conf 2>/dev/null; then
    log_info "Two Limine configs remain ($limine_conf + /boot/limine.conf) — either boots."
  fi

  # Summary (no reboot here — the main installer offers one reboot at the end)
  log_success "Limine setup complete: ${limine_conf:-$esp_mount/limine.conf}"
  if [[ "$want_snapper" == true ]]; then
    log_info "Snapshots created by snap-pac will appear in the Limine menu after reboot."
    log_info "Useful: snap-manager list | snap-manager create 'desc' | snap-manager sync"
  else
    log_info "Reboot at the end of the install to boot via Limine."
  fi
}

# MAIN EXECUTION (dispatch AFTER all function definitions)

# Report ESP/boot readability up front: on archinstall systems /boot is often
# root-only, and every silent "not found, skipping" below traces back to this.
report_boot_access() {
  local esp
  esp=$(detect_esp_mount || echo "unknown")
  log_info "ESP mountpoint: $esp"
  local perms
  perms=$(sudo -n stat -c '%a %U:%G' /boot 2>/dev/null || echo "unreadable")
  log_info "/boot perms: $perms"
  if sudo -n ls /boot >/dev/null 2>&1; then
    log_info "/boot readable via sudo -n — privileged reads enabled."
  else
    log_error "/boot NOT readable even via sudo -n — bootloader tuning will be skipped."
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
    # Refuse to guess. Silently defaulting to systemd-boot config on a
    # system whose real bootloader wasn't correctly identified could write
    # loader entries nothing ever reads while leaving the actual bootloader
    # unconfigured — on the single riskiest step in the whole installer,
    # "leave it alone and tell the user" is safer than "guess and modify
    # boot config." This step already runs under the "ask" policy, so
    # exiting here surfaces cleanly through install.sh's existing handling.
    log_error "No supported bootloader could be identified safely. Refusing to modify boot configuration."
    log_info "Detected: '${BOOTLOADER:-none}'. Supported: grub, systemd-boot, limine, refind, efistub."
    exit 1
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
    if printf 'n\n' | sudo -n mkinitcpio -P 2>&1 | tee -a "$INSTALL_LOG" >/dev/null; then
      log_success "Initramfs regenerated"
    else
      log_warning "Initramfs regeneration had issues — check mkinitcpio presets"
    fi
  elif command -v dracut &>/dev/null && [[ -d /etc/dracut.conf.d || -f /etc/dracut.conf ]]; then
    ui_info "Regenerating initramfs with dracut..."
    if sudo -n dracut --regenerate-all --force >>"$INSTALL_LOG" 2>&1; then
      log_success "Initramfs regenerated with dracut"
    else
      log_warning "Dracut regeneration had issues — check dracut configuration"
    fi
  else
    log_info "Initramfs rebuild requested but neither mkinitcpio nor dracut in use — skipping"
  fi
fi
