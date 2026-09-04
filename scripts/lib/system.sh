#!/bin/bash
set -uo pipefail

# ============================================================================
# System Detection Library - Hardware and System Information
# Uses caching to avoid redundant checks
# ============================================================================

# Cache for detection results
declare -gA SYSTEM_CACHE=()

# Find systemd-boot entries directory by checking common ESP mount points
if ! declare -f find_systemd_boot_entries_dir >/dev/null 2>&1; then
find_systemd_boot_entries_dir() {
  for dir in "/boot/loader/entries" "/efi/loader/entries" "/boot/efi/loader/entries"; do
    if sudo test -d "$dir" 2>/dev/null; then
      echo "$dir"
      return 0
    fi
  done
  return 1
}
fi

# Detect CPU vendor
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

# Detect if system is a laptop
is_laptop() {
    local cache_key="is_laptop"
    
    if [[ -n "${SYSTEM_CACHE[$cache_key]:-}" ]]; then
        [[ "${SYSTEM_CACHE[$cache_key]}" == "true" ]]
        return $?
    fi
    
    local is_laptop=false
    
    # Check for laptop indicators via power supply
    if [[ -d "/sys/class/power_supply" ]]; then
        while IFS= read -r supply; do
            if [[ "$supply" == *"BAT"* ]]; then
                is_laptop=true
                break
            fi
        done < <(ls /sys/class/power_supply 2>/dev/null)
    fi
    
    # Check chassis type from DMI
    if command -v dmidecode &>/dev/null; then
        local chassis
        chassis=$(sudo dmidecode -s chassis-type 2>/dev/null | tr '[:upper:]' '[:lower:]')
        case "$chassis" in
            *laptop*|*notebook*|*portable*) is_laptop=true ;;
        esac
    fi
    
    SYSTEM_CACHE[$cache_key]="$is_laptop"
    [[ "$is_laptop" == "true" ]]
}

# Detect if system uses Btrfs filesystem
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

# Detect bootloader type
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
    if sudo test -f /boot/EFI/arch-limine/limine.conf 2>/dev/null || \
       sudo test -f /boot/EFI/BOOT/limine.conf 2>/dev/null || \
       sudo test -f /boot/efi/EFI/arch-limine/limine.conf 2>/dev/null || \
       sudo test -f /boot/efi/EFI/BOOT/limine.conf 2>/dev/null || \
       sudo test -f /efi/EFI/arch-limine/limine.conf 2>/dev/null || \
       sudo test -f /efi/EFI/BOOT/limine.conf 2>/dev/null || \
       sudo test -f /boot/limine.conf 2>/dev/null || sudo test -f /boot/limine/limine.conf 2>/dev/null || \
       sudo test -f /boot/efi/limine.conf 2>/dev/null || sudo test -f /efi/limine.conf 2>/dev/null || \
       sudo test -f /limine/limine.conf 2>/dev/null || sudo test -f /limine.conf 2>/dev/null || \
       sudo grep -q "^Target = limine" /etc/pacman.d/hooks/99-limine.hook 2>/dev/null || \
       sudo efibootmgr 2>/dev/null | grep -qi "limine" || \
       command -v limine-snapper-sync &>/dev/null; then
        bootloader="limine"
    elif sudo test -d /boot/grub 2>/dev/null || sudo test -d /boot/grub2 2>/dev/null || \
       sudo test -d /boot/efi/EFI/grub 2>/dev/null || sudo test -d /efi/EFI/grub 2>/dev/null; then
        bootloader="grub"
    # rEFInd (official archinstall deploys to <esp>/EFI/refind/)
    elif sudo test -f /boot/EFI/refind/refind_x64.efi 2>/dev/null || \
       sudo test -f /boot/efi/EFI/refind/refind_x64.efi 2>/dev/null || \
       sudo test -f /efi/EFI/refind/refind_x64.efi 2>/dev/null || \
       sudo test -f /boot/EFI/refind/refind.conf 2>/dev/null || \
       sudo efibootmgr 2>/dev/null | grep -qi "rEFInd"; then
        bootloader="refind"
    # Check for active systemd-boot (loader entries + loader.conf)
    elif sudo test -d /boot/loader/entries 2>/dev/null || sudo test -d /efi/loader/entries 2>/dev/null || \
         sudo test -f /boot/loader/loader.conf 2>/dev/null || sudo test -f /efi/loader/loader.conf 2>/dev/null || \
         sudo test -d /boot/EFI/systemd 2>/dev/null || sudo test -d /efi/EFI/systemd 2>/dev/null || \
         sudo test -d /boot/loader 2>/dev/null; then
        bootloader="systemd-boot"
    # EFISTUB: kernels live directly on a FAT /boot with no bootloader
    # directory at all (official archinstall efistub layout).
    elif [[ "$(sudo findmnt -n -o FSTYPE /boot 2>/dev/null || findmnt -n -o FSTYPE /boot 2>/dev/null)" == "vfat" ]] && \
         sudo ls /boot/vmlinuz-* >/dev/null 2>&1; then
        bootloader="efistub"
    # Tier 2: Installed-package detection (may have false positives for inactive bootloaders)
    elif pacman -Q limine &>/dev/null 2>&1; then
        bootloader="limine"
    elif command -v grub-mkconfig &>/dev/null || pacman -Q grub &>/dev/null 2>&1; then
        bootloader="grub"
    elif command -v bootctl &>/dev/null || pacman -Q systemd-boot &>/dev/null 2>&1 || \
         sudo test -d /boot/EFI/BOOT 2>/dev/null || sudo test -d /efi/EFI/BOOT 2>/dev/null; then
        bootloader="systemd-boot"
    # Tier 3: Fallback based on firmware / distro
    elif [ -d /sys/firmware/efi ]; then
        bootloader="systemd-boot"
    elif [ -f /etc/arch-release ]; then
        bootloader="systemd-boot"
    fi

    SYSTEM_CACHE[$cache_key]="$bootloader"
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
    if sudo test -d /boot/efi/EFI/Linux 2>/dev/null && sudo ls /boot/efi/EFI/Linux/*.efi >/dev/null 2>&1; then
        result="true"
    elif sudo test -d /boot/EFI/Linux 2>/dev/null && sudo ls /boot/EFI/Linux/*.efi >/dev/null 2>&1; then
        result="true"
    elif sudo test -d /efi/EFI/Linux 2>/dev/null && sudo ls /efi/EFI/Linux/*.efi >/dev/null 2>&1; then
        result="true"
    fi

    # Method 2: systemd-boot entries reference .efi files (not vmlinuz).
    # sudo: entry files live under /boot, which archinstall may lock to 700.
    local entries_dir
    if [[ "$result" == "false" ]]; then
        entries_dir=$(find_systemd_boot_entries_dir)
        if [[ -n "$entries_dir" ]]; then
            while IFS= read -r -d '' entry; do
                if sudo grep -qE "^\s*efi\s+/" "$entry" 2>/dev/null; then
                    result="true"
                    break
                fi
            done < <(sudo find "$entries_dir" -name "*.conf" -print0 2>/dev/null)
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
