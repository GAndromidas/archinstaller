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

# Detect GPU
detect_gpu() {
    local cache_key="gpu"
    
    if [[ -n "${SYSTEM_CACHE[$cache_key]:-}" ]]; then
        echo "${SYSTEM_CACHE[$cache_key]}"
        return 0
    fi
    
    local gpu="unknown"
    
    if command -v lspci &>/dev/null; then
        if lspci | grep -qi "amd.*radeon\|amd.*gpu"; then
            gpu="amd"
        elif lspci | grep -qi "intel.*vga\|intel.*gpu"; then
            gpu="intel"
        fi
    fi
    
    SYSTEM_CACHE[$cache_key]="$gpu"
    echo "$gpu"
}

# Get RAM in GB
get_ram_gb() {
    local cache_key="ram_gb"
    
    if [[ -n "${SYSTEM_CACHE[$cache_key]:-}" ]]; then
        echo "${SYSTEM_CACHE[$cache_key]}"
        return 0
    fi
    
    local ram_kb
    ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local ram_gb=$((ram_kb / 1024 / 1024))
    
    SYSTEM_CACHE[$cache_key]="$ram_gb"
    echo "$ram_gb"
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
    if sudo test -d /boot/grub 2>/dev/null || sudo test -d /boot/grub2 2>/dev/null || \
       [ -d "/boot/efi/EFI/grub" ] || [ -d "/efi/EFI/grub" ]; then
        bootloader="grub"
    # Check for active Limine (config file takes priority)
    elif sudo test -f /boot/limine.conf 2>/dev/null || \
         sudo test -f /boot/limine/limine.conf 2>/dev/null || \
         sudo test -f /boot/EFI/limine/limine.conf 2>/dev/null || \
         sudo test -f /boot/EFI/arch-limine/limine.conf 2>/dev/null || \
         sudo test -d /boot/limine 2>/dev/null || \
         [ -d "/boot/EFI/limine" ] || [ -d "/boot/EFI/arch-limine" ]; then
        bootloader="limine"
    # Check for active systemd-boot (loader entries + loader.conf)
    elif sudo test -d /boot/loader/entries 2>/dev/null || [ -d "/efi/loader/entries" ] || \
         sudo test -f /boot/loader/loader.conf 2>/dev/null || [ -f "/efi/loader/loader.conf" ] || \
         [ -d "/boot/EFI/systemd" ] || [ -d "/efi/EFI/systemd" ] || \
         sudo test -d /boot/loader 2>/dev/null; then
        bootloader="systemd-boot"
    # Tier 2: Installed-package detection (may have false positives for inactive bootloaders)
    elif command -v grub-mkconfig &>/dev/null || pacman -Q grub &>/dev/null 2>&1; then
        bootloader="grub"
    elif command -v limine &>/dev/null || pacman -Q limine &>/dev/null 2>&1; then
        bootloader="limine"
    elif command -v bootctl &>/dev/null || pacman -Q systemd-boot &>/dev/null 2>&1 || \
         [ -d "/boot/EFI/BOOT" ] || [ -d "/efi/EFI/BOOT" ]; then
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

    # Method 1: UKI .efi files exist in the ESP (use sudo for /boot due to 700 perms with UKI)
    if sudo test -d /boot/efi/EFI/Linux 2>/dev/null && sudo ls /boot/efi/EFI/Linux/*.efi >/dev/null 2>&1; then
        result="true"
    elif sudo test -d /boot/EFI/Linux 2>/dev/null && sudo ls /boot/EFI/Linux/*.efi >/dev/null 2>&1; then
        result="true"
    fi

    # Method 2: systemd-boot entries reference .efi files (not vmlinuz)
    local entries_dir
    if [[ "$result" == "false" ]]; then
        entries_dir=$(find_systemd_boot_entries_dir)
        if [[ -n "$entries_dir" ]]; then
            while IFS= read -r -d '' entry; do
                if grep -qE "^\s*efi\s+/" "$entry" 2>/dev/null; then
                    result="true"
                    break
                fi
            done < <(find "$entries_dir" -name "*.conf" -print0 2>/dev/null)
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

# Find limine.conf file location
find_limine_config() {
    local limine_config=""
    for limine_loc in "/boot/limine/limine.conf" "/boot/limine.conf" "/boot/EFI/limine/limine.conf" "/boot/EFI/arch-limine/limine.conf" "/efi/limine/limine.conf"; do
        if sudo test -f "$limine_loc" 2>/dev/null || [ -f "$limine_loc" ]; then
            echo "$limine_loc"
            return 0
        fi
    done
    return 1
}

# Get system information summary
get_system_info() {
    local cpu=$(detect_cpu_vendor)
    local ram=$(get_ram_gb)
    local gpu=$(detect_gpu)
    local laptop
    is_laptop && laptop="Yes" || laptop="No"
    local bootloader=$(detect_bootloader)
    local btrfs
    is_btrfs_system && btrfs="Yes" || btrfs="No"
    
    cat << EOF
CPU: $cpu
RAM: ${ram} GB
GPU: $gpu
Laptop: $laptop
Bootloader: $bootloader
Btrfs: $btrfs
EOF
}
