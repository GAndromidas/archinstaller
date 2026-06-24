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
    if [ -d "$dir" ]; then
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
        if lspci | grep -qi "nvidia"; then
            gpu="nvidia"
        elif lspci | grep -qi "amd.*radeon\|amd.*gpu"; then
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

# Detect bootloader type
detect_bootloader() {
    local cache_key="bootloader"
    
    # Re-enable cache for performance
    if [[ -n "${SYSTEM_CACHE[$cache_key]:-}" ]]; then
        echo "${SYSTEM_CACHE[$cache_key]}"
        return 0
    fi
    
    local bootloader="unknown"
    
    # Check for GRUB first (most specific)
    if [ -d "/boot/grub" ] || [ -d "/boot/grub2" ] || [ -d "/boot/efi/EFI/grub" ] || [ -d "/efi/EFI/grub" ] || \
       command -v grub-mkconfig &>/dev/null || pacman -Q grub &>/dev/null 2>&1; then
        bootloader="grub"
    # Check for Limine next
    elif [ -d "/boot/limine" ] || [ -d "/boot/EFI/limine" ] || [ -d "/boot/EFI/arch-limine" ] || \
         [ -f "/boot/limine.conf" ] || [ -f "/boot/limine/limine.conf" ] || \
         [ -f "/boot/EFI/limine/limine.conf" ] || [ -f "/boot/EFI/arch-limine/limine.conf" ] || \
         command -v limine &>/dev/null || pacman -Q limine &>/dev/null 2>&1; then
        bootloader="limine"
    # Check for systemd-boot (most comprehensive check)
    elif [ -d "/boot/loader/entries" ] || [ -d "/efi/loader/entries" ] || [ -d "/boot/loader" ] || \
         [ -f "/boot/loader/loader.conf" ] || [ -f "/efi/loader/loader.conf" ] || \
         command -v bootctl &>/dev/null || pacman -Q systemd-boot &>/dev/null 2>&1 || \
         [ -d "/boot/EFI/systemd" ] || [ -d "/efi/EFI/systemd" ] || \
         [ -d "/boot/EFI/BOOT" ] || [ -d "/efi/EFI/BOOT" ]; then
        bootloader="systemd-boot"
    # Fallback: Default to systemd-boot for UEFI systems (most common on Arch)
    elif [ -d /sys/firmware/efi ]; then
        bootloader="systemd-boot"
    # Final fallback: Assume systemd-boot for Arch Linux (most common)
    elif [ -f /etc/arch-release ]; then
        bootloader="systemd-boot"
    else
        bootloader="unknown"
    fi
    
    SYSTEM_CACHE[$cache_key]="$bootloader"
    echo "$bootloader"
}

# Check if system is UKI (Unified Kernel Image)
# Uses multiple methods to avoid false positives
is_uki_system() {
    local cache_key="is_uki"
    
    if [[ -n "${SYSTEM_CACHE[$cache_key]:-}" ]]; then
        [[ "${SYSTEM_CACHE[$cache_key]}" == "true" ]]
        return $?
    fi
    
    local result="false"
    
    # Method 1: UKI .efi files exist in the ESP
    if [[ -d /boot/efi/EFI/Linux/ ]] && ls /boot/efi/EFI/Linux/*.efi >/dev/null 2>&1; then
        result="true"
    elif [[ -d /boot/EFI/Linux/ ]] && ls /boot/EFI/Linux/*.efi >/dev/null 2>&1; then
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
    
    # Method 3: UKI-related packages installed (last resort — packages can exist without UKI usage)
    if [[ "$result" == "false" ]]; then
        if pacman -Q systemd-ukify &>/dev/null 2>&1 || \
           pacman -Q ukify &>/dev/null 2>&1; then
            result="true"
        fi
    fi
    
    SYSTEM_CACHE[$cache_key]="$result"
    [[ "$result" == "true" ]]
}

# Find limine.conf file location
find_limine_config() {
    local limine_config=""
    for limine_loc in "/boot/limine/limine.conf" "/boot/limine.conf" "/boot/EFI/limine/limine.conf" "/boot/EFI/arch-limine/limine.conf" "/efi/limine/limine.conf"; do
        if [ -f "$limine_loc" ]; then
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
