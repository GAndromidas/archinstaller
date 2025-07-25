#!/bin/bash
set -uo pipefail

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$SCRIPT_DIR/scripts"
source "$SCRIPT_DIR/common.sh"

# Apply all boot configurations at once
configure_boot() {
  # Make systemd-boot silent
  find /boot/loader/entries -name "*.conf" ! -name "*fallback.conf" -exec \
    sudo sed -i '/options/s/$/ quiet loglevel=3 systemd.show_status=auto rd.udev.log_level=3/' {} \; 2>/dev/null || true
  
  # Configure loader.conf
  if [ -f "/boot/loader/loader.conf" ]; then
    sudo sed -i \
      -e '/^default /d' \
      -e '1i default @saved' \
      -e 's/^timeout.*/timeout 3/' \
      -e 's/^[#]*console-mode[[:space:]]\+.*/console-mode max/' \
      /boot/loader/loader.conf
    
    # Add missing lines
    grep -q '^timeout' /boot/loader/loader.conf || echo "timeout 3" | sudo tee -a /boot/loader/loader.conf >/dev/null
    grep -q '^console-mode' /boot/loader/loader.conf || echo "console-mode max" | sudo tee -a /boot/loader/loader.conf >/dev/null
  fi
  
  # Remove fallback entries
  sudo rm -f /boot/loader/entries/*fallback.conf 2>/dev/null || true
}

setup_fastfetch_config() {
  if command -v fastfetch >/dev/null; then
    if [ -f "$HOME/.config/fastfetch/config.jsonc" ]; then
      log_warning "fastfetch config already exists. Skipping generation."
    else
      run_step "Creating fastfetch config" bash -c 'fastfetch --gen-config'
    fi
    
    # Safe config file copy
    if [ -f "$CONFIGS_DIR/config.jsonc" ]; then
      mkdir -p "$HOME/.config/fastfetch"
      cp "$CONFIGS_DIR/config.jsonc" "$HOME/.config/fastfetch/config.jsonc"
      log_success "fastfetch config copied from configs directory."
    else
      log_warning "config.jsonc not found in configs directory. Using generated config."
    fi
  else
    log_warning "fastfetch not installed. Skipping config setup."
  fi
}

# Execute ultra-fast boot configuration
if [ -d /boot/loader ] || [ -d /boot/EFI/systemd ]; then
    configure_boot
fi
setup_fastfetch_config

# --- Bootloader and Btrfs detection ---
if [ -d /boot/loader ] || [ -d /boot/EFI/systemd ]; then
    BOOTLOADER="systemd-boot"
elif [ -d /boot/grub ] || [ -f /etc/default/grub ]; then
    BOOTLOADER="grub"
else
    BOOTLOADER="unknown"
fi

if findmnt -n -o FSTYPE / | grep -q btrfs; then
    IS_BTRFS=true
else
    IS_BTRFS=false
fi

# --- GRUB configuration ---
configure_grub() {
    # Set kernel parameters for Plymouth and quiet boot
    sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash loglevel=3 systemd.show_status=auto rd.udev.log_level=3 plymouth.ignore-serial-consoles"/' /etc/default/grub

    # Set default entry to saved and enable save default
    if grep -q '^GRUB_DEFAULT=' /etc/default/grub; then
        sudo sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub
    else
        echo 'GRUB_DEFAULT=saved' | sudo tee -a /etc/default/grub
    fi
    if grep -q '^GRUB_SAVEDEFAULT=' /etc/default/grub; then
        sudo sed -i 's/^GRUB_SAVEDEFAULT=.*/GRUB_SAVEDEFAULT=true/' /etc/default/grub
    else
        echo 'GRUB_SAVEDEFAULT=true' | sudo tee -a /etc/default/grub
    fi

    # Set timeout to 3 seconds
    sudo sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=3/' /etc/default/grub

    # Set console mode (gfxmode)
    grep -q '^GRUB_GFXMODE=' /etc/default/grub || echo 'GRUB_GFXMODE=auto' | sudo tee -a /etc/default/grub
    grep -q '^GRUB_GFXPAYLOAD_LINUX=' /etc/default/grub || echo 'GRUB_GFXPAYLOAD_LINUX=keep' | sudo tee -a /etc/default/grub

    # Remove all fallback initramfs images
    sudo rm -f /boot/initramfs-*-fallback.img

    # Show all kernels and fallback entries in main menu
    if grep -q '^GRUB_DISABLE_SUBMENU=' /etc/default/grub; then
        sudo sed -i 's/^GRUB_DISABLE_SUBMENU=.*/GRUB_DISABLE_SUBMENU=y/' /etc/default/grub
    else
        echo 'GRUB_DISABLE_SUBMENU=y' | sudo tee -a /etc/default/grub
    fi

    # Show Btrfs snapshots in main menu if grub-btrfs is installed
    if pacman -Q grub-btrfs &>/dev/null; then
        if grep -q '^GRUB_BTRFS_SUBMENU=' /etc/default/grub; then
            sudo sed -i 's/^GRUB_BTRFS_SUBMENU=.*/GRUB_BTRFS_SUBMENU=n/' /etc/default/grub
        else
            echo 'GRUB_BTRFS_SUBMENU=n' | sudo tee -a /etc/default/grub
        fi
    fi

    # Regenerate grub config
    sudo grub-mkconfig -o /boot/grub/grub.cfg

    # Set default to standard linux kernel on first run
    default_entry=$(grep -P "menuentry 'Arch Linux'" /boot/grub/grub.cfg | grep -v "fallback" | head -n1 | sed "s/menuentry '\([^']*\)'.*/\1/")
    if [ -n "$default_entry" ]; then
        sudo grub-set-default "$default_entry"
        echo "Set GRUB default to: $default_entry"
    fi
}

# --- grub-btrfs installation if needed ---
install_grub_btrfs_if_needed() {
    if [ "$BOOTLOADER" = "grub" ] && [ "$IS_BTRFS" = true ]; then
        if ! pacman -Q grub-btrfs &>/dev/null; then
            yay -S --noconfirm grub-btrfs
        fi
        # Add Timeshift post-snapshot hook for grub-btrfs
        sudo mkdir -p /etc/timeshift/scripts
        sudo tee /etc/timeshift/scripts/post-snapshot > /dev/null <<'EOF'
#!/bin/bash
# Timeshift post-snapshot hook to update GRUB menu with new Btrfs snapshots
if command -v grub-btrfsd &>/dev/null; then
    sudo grub-btrfsd --syslog --once /boot/grub
fi
EOF
        sudo chmod +x /etc/timeshift/scripts/post-snapshot
    fi
}

# --- Windows Dual-Boot Detection and Configuration ---

detect_windows() {
    # Check for Windows EFI bootloader
    if [ -d /boot/efi/EFI/Microsoft ] || [ -d /boot/EFI/Microsoft ]; then
        return 0
    fi
    # Check for NTFS partitions (Windows)
    if lsblk -f | grep -qi ntfs; then
        return 0
    fi
    return 1
}

add_windows_to_grub() {
    sudo pacman -S --noconfirm os-prober
    # Ensure GRUB_DISABLE_OS_PROBER is not set to true
    if grep -q '^GRUB_DISABLE_OS_PROBER=' /etc/default/grub; then
        sudo sed -i 's/^GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub
    else
        echo 'GRUB_DISABLE_OS_PROBER=false' | sudo tee -a /etc/default/grub
    fi
    sudo grub-mkconfig -o /boot/grub/grub.cfg
    echo "Windows entry added to GRUB (if detected by os-prober)."
}

find_windows_efi_partition() {
    local partitions=($(lsblk -n -o NAME,TYPE | grep "part" | awk '{print "/dev/"$1}'))
    for partition in "${partitions[@]}"; do
        local temp_mount="/tmp/windows_efi_check"
        mkdir -p "$temp_mount"
        if mount "$partition" "$temp_mount" 2>/dev/null; then
            if [ -d "$temp_mount/EFI/Microsoft" ]; then
                umount "$temp_mount"
                rm -rf "$temp_mount"
                echo "$partition"
                return 0
            fi
            umount "$temp_mount"
        fi
        rm -rf "$temp_mount"
    done
    return 1
}

add_windows_to_systemdboot() {
    # Only copy EFI files if not already present
    if [ ! -d "/boot/EFI/Microsoft" ]; then
        local windows_partition
        windows_partition=$(find_windows_efi_partition)
        if [ -z "$windows_partition" ]; then
            echo "Error: Could not find Windows EFI partition"
            return 1
        fi
        local mount_point="/mnt/winefi"
        mkdir -p "$mount_point"
        if mount "$windows_partition" "$mount_point"; then
            if [ -d "$mount_point/EFI/Microsoft" ]; then
                cp -R "$mount_point/EFI/Microsoft" /boot/EFI/
                echo "Copied Microsoft EFI files to /boot/EFI/Microsoft."
            else
                echo "Error: Microsoft EFI files not found in $windows_partition"
            fi
            umount "$mount_point"
        else
            echo "Error: Failed to mount Windows EFI partition"
        fi
        rm -rf "$mount_point"
    else
        echo "Microsoft EFI files already present in /boot/EFI/Microsoft."
    fi

    # Create loader entry if not present
    local entry="/boot/loader/entries/windows.conf"
    if [ ! -f "$entry" ]; then
        cat <<EOF | sudo tee "$entry"
title   Windows
efi     /EFI/Microsoft/Boot/bootmgfw.efi
EOF
        echo "Added Windows entry to systemd-boot."
    else
        echo "Windows entry already exists in systemd-boot."
    fi
}

set_localtime_for_windows() {
    sudo timedatectl set-local-rtc 1 --adjust-system-clock
    echo "Set hardware clock to local time for Windows compatibility."
}

# --- Main Execution ---

# Apply GRUB config if needed
if [ "$BOOTLOADER" = "grub" ]; then
    configure_grub
    install_grub_btrfs_if_needed
fi

# Windows dual-boot configuration
if detect_windows; then
    echo "Windows installation detected. Configuring dual-boot..."
    # Always install ntfs-3g for NTFS access
    sudo pacman -S --noconfirm ntfs-3g

    if [ "$BOOTLOADER" = "grub" ]; then
        add_windows_to_grub
    elif [ "$BOOTLOADER" = "systemd-boot" ]; then
        add_windows_to_systemdboot
    fi
    set_localtime_for_windows
fi 