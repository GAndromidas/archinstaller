#!/bin/bash
set -uo pipefail

# Hardware/system detection, cached to avoid redundant checks

# Cache for detection results
if ! declare -p SYSTEM_CACHE &>/dev/null; then declare -gA SYSTEM_CACHE=(); fi

# Find systemd-boot entries directory by checking common ESP mount points
if ! declare -f find_systemd_boot_entries_dir >/dev/null 2>&1; then
find_systemd_boot_entries_dir() {
  for dir in "/boot/loader/entries" "/efi/loader/entries" "/boot/efi/loader/entries"; do
    if sudo -n test -d "$dir" 2>/dev/null; then
      echo "$dir"
      return 0
    fi
  done
  return 1
}
fi

detect_cpu_vendor() {
    local cache_key="cpu_vendor"
    
    if [[ -n "${SYSTEM_CACHE[$cache_key]:-}" ]]; then
        echo "${SYSTEM_CACHE[$cache_key]}"
        return 0
    fi
    
    local vendor="unknown"
    if grep -qi "GenuineIntel" /proc/cpuinfo 2>/dev/null; then
        vendor="intel"
    elif grep -qi "AuthenticAMD" /proc/cpuinfo 2>/dev/null; then
        vendor="amd"
    fi
    
    SYSTEM_CACHE[$cache_key]="$vendor"
    echo "$vendor"
}

is_laptop() {
    local cache_key="is_laptop"
    
    if [[ -n "${SYSTEM_CACHE[$cache_key]:-}" ]]; then
        [[ "${SYSTEM_CACHE[$cache_key]}" == "true" ]]
        return $?
    fi
    
    local is_laptop=false
    
    # Check for laptop indicators via power supply (glob, not ls parsing)
    if [[ -d "/sys/class/power_supply" ]]; then
        for supply_path in /sys/class/power_supply/*; do
            [[ -e "$supply_path" ]] || continue
            supply=$(basename "$supply_path")
            if [[ "$supply" == *"BAT"* ]]; then
                is_laptop=true
                break
            fi
        done
    fi
    
    # Check chassis type from DMI
    if command -v dmidecode &>/dev/null; then
        local chassis
        chassis=$(sudo -n dmidecode -s chassis-type 2>/dev/null | tr '[:upper:]' '[:lower:]')
        case "$chassis" in
            *laptop*|*notebook*|*portable*) is_laptop=true ;;
        esac
    fi
    
    SYSTEM_CACHE[$cache_key]="$is_laptop"
    [[ "$is_laptop" == "true" ]]
}

if ! declare -f is_btrfs_system >/dev/null 2>&1; then
is_btrfs_system() {
    local cache_key="is_btrfs"
    
    if [[ -n "${SYSTEM_CACHE[$cache_key]:-}" ]]; then
        [[ "${SYSTEM_CACHE[$cache_key]}" == "true" ]]
        return $?
    fi
    
    local result
    result=$(findmnt -no FSTYPE / 2>/dev/null | grep -q btrfs && echo "true" || echo "false")
    SYSTEM_CACHE[$cache_key]="$result"
    [[ "$result" == "true" ]]
}
fi

if ! declare -f detect_bootloader >/dev/null 2>&1; then
detect_bootloader() {
    local cache_key="bootloader"

    if [[ -n "${SYSTEM_CACHE[$cache_key]:-}" ]]; then
        echo "${SYSTEM_CACHE[$cache_key]}"
        return 0
    fi

    local bootloader="unknown"

    # Tier 1: Active bootloader detection (based on actual directories/configs)
    # Use sudo for /boot checks because /boot can have restricted permissions (e.g. 700 with UKI)
    # Limine is checked first: limine.conf is distinctive and would otherwise
    # fall through to the systemd-boot fallback below.
    # Layout reference: official archinstall deploys to <esp>/EFI/arch-limine/
    # (or <esp>/EFI/BOOT/ when "removable", which is its UEFI default) with
    # limine.conf alongside the EFI binary, plus a 99-limine.hook pacman hook.
    # NOTE: <esp>/EFI/BOOT/ alone is NOT a signal (systemd-boot uses it too) —
    # only limine.conf in these locations counts.
    # NOTE: every ESP-candidate test uses sudo. Official archinstall locks
    # /boot (and sometimes the ESP mountpoint) down to root-only, so bare
    # [ -f/-d ] checks silently miss everything and detection falls through.
    if sudo -n test -f /boot/EFI/arch-limine/limine.conf 2>/dev/null || \
       sudo -n test -f /boot/EFI/BOOT/limine.conf 2>/dev/null || \
       sudo -n test -f /boot/efi/EFI/arch-limine/limine.conf 2>/dev/null || \
       sudo -n test -f /boot/efi/EFI/BOOT/limine.conf 2>/dev/null || \
       sudo -n test -f /efi/EFI/arch-limine/limine.conf 2>/dev/null || \
       sudo -n test -f /efi/EFI/BOOT/limine.conf 2>/dev/null || \
       sudo -n test -f /boot/limine.conf 2>/dev/null || sudo -n test -f /boot/limine/limine.conf 2>/dev/null || \
       sudo -n test -f /boot/efi/limine.conf 2>/dev/null || sudo -n test -f /efi/limine.conf 2>/dev/null || \
       sudo -n test -f /limine/limine.conf 2>/dev/null || sudo -n test -f /limine.conf 2>/dev/null || \
       sudo -n grep -q "^Target = limine" /etc/pacman.d/hooks/99-limine.hook 2>/dev/null || \
       sudo -n efibootmgr 2>/dev/null | grep -qi "limine" || \
       command -v limine-snapper-sync &>/dev/null; then
        bootloader="limine"
    elif sudo -n test -d /boot/grub 2>/dev/null || sudo -n test -d /boot/grub2 2>/dev/null || \
       sudo -n test -d /boot/efi/EFI/grub 2>/dev/null || sudo -n test -d /efi/EFI/grub 2>/dev/null; then
        bootloader="grub"
    # rEFInd (official archinstall deploys to <esp>/EFI/refind/)
    elif sudo -n test -f /boot/EFI/refind/refind_x64.efi 2>/dev/null || \
       sudo -n test -f /boot/efi/EFI/refind/refind_x64.efi 2>/dev/null || \
       sudo -n test -f /efi/EFI/refind/refind_x64.efi 2>/dev/null || \
       sudo -n test -f /boot/EFI/refind/refind.conf 2>/dev/null || \
       sudo -n efibootmgr 2>/dev/null | grep -qi "rEFInd"; then
        bootloader="refind"
    # Check for active systemd-boot (loader entries + loader.conf)
    elif sudo -n test -d /boot/loader/entries 2>/dev/null || sudo -n test -d /efi/loader/entries 2>/dev/null || \
         sudo -n test -f /boot/loader/loader.conf 2>/dev/null || sudo -n test -f /efi/loader/loader.conf 2>/dev/null || \
         sudo -n test -d /boot/EFI/systemd 2>/dev/null || sudo -n test -d /efi/EFI/systemd 2>/dev/null || \
         sudo -n test -d /boot/loader 2>/dev/null; then
        bootloader="systemd-boot"
    # EFISTUB: kernels live directly on a FAT /boot with no bootloader
    # directory at all (official archinstall efistub layout).
    elif [[ "$(sudo -n findmnt -n -o FSTYPE /boot 2>/dev/null || findmnt -n -o FSTYPE /boot 2>/dev/null)" == "vfat" ]] && \
         sudo -n find /boot -maxdepth 1 -name 'vmlinuz-*' -print -quit 2>/dev/null | grep -q .; then
        bootloader="efistub"
    # Tier 2: Installed-package detection (may have false positives for inactive bootloaders)
    elif pacman -Q limine &>/dev/null 2>&1; then
        bootloader="limine"
    elif command -v grub-mkconfig &>/dev/null || pacman -Q grub &>/dev/null 2>&1; then
        bootloader="grub"
    elif command -v bootctl &>/dev/null || pacman -Q systemd-boot &>/dev/null 2>&1 || \
         sudo -n test -d /boot/EFI/BOOT 2>/dev/null || sudo -n test -d /efi/EFI/BOOT 2>/dev/null; then
        bootloader="systemd-boot"
    # Tier 3: Fallback based on firmware / distro
    elif [ -d /sys/firmware/efi ]; then
        bootloader="systemd-boot"
    elif [ -f /etc/arch-release ]; then
        bootloader="systemd-boot"
    fi

    # Do not cache "unknown": bootloader may be installed mid-run and a
    # stale cached miss would hide it from later steps.
    if [[ "$bootloader" != "unknown" ]]; then
        SYSTEM_CACHE[$cache_key]="$bootloader"
    fi
    echo "$bootloader"
}
fi

# Check if system is UKI (Unified Kernel Image)
# Uses multiple methods to avoid false positives
if ! declare -f is_uki_system >/dev/null 2>&1; then
is_uki_system() {
    local cache_key="is_uki"
    
    if [[ -n "${SYSTEM_CACHE[$cache_key]:-}" ]]; then
        [[ "${SYSTEM_CACHE[$cache_key]}" == "true" ]]
        return $?
    fi
    
    local result="false"

    # Method 1: UKI .efi files exist in the ESP (use sudo for /boot due to 700 perms with UKI).
    # archinstall writes them to <esp>/EFI/Linux/ — cover every ESP mountpoint.
    if sudo -n find /boot/efi/EFI/Linux -maxdepth 1 -name '*.efi' -print -quit 2>/dev/null | grep -q .; then
        result="true"
    elif sudo -n find /boot/EFI/Linux -maxdepth 1 -name '*.efi' -print -quit 2>/dev/null | grep -q .; then
        result="true"
    elif sudo -n find /efi/EFI/Linux -maxdepth 1 -name '*.efi' -print -quit 2>/dev/null | grep -q .; then
        result="true"
    fi

    # Method 2: systemd-boot entries reference .efi files (not vmlinuz).
    # sudo: entry files live under /boot, which archinstall may lock to 700.
    # Chainload entries (windows.conf: efi + no linux line) are NOT UKIs —
    # without the exclusion, adding a Windows menu row flips the whole
    # system to "UKI" and entry maintenance gets skipped.
    local entries_dir
    if [[ "$result" == "false" ]]; then
        entries_dir=$(find_systemd_boot_entries_dir)
        if [[ -n "$entries_dir" ]]; then
            while IFS= read -r -d '' entry; do
                if sudo -n grep -qE "^\s*efi\s+/" "$entry" 2>/dev/null \
                    && ! sudo -n grep -qE "^\s*linux\s+/" "$entry" 2>/dev/null; then
                    result="true"
                    break
                fi
            done < <(sudo -n find "$entries_dir" -name "*.conf" ! -name 'windows.conf' -print0 2>/dev/null)
        fi
    fi

    # Method 3: check for UKI output in mkinitcpio presets (more reliable than package presence)
    if [[ "$result" == "false" ]]; then
        if grep -qr "^\s*default_uki=" /etc/mkinitcpio.d/ 2>/dev/null; then
            result="true"
        fi
    fi
    
    SYSTEM_CACHE[$cache_key]="$result"
    [[ "$result" == "true" ]]
}
fi
