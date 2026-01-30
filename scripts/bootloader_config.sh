#!/bin/bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# --- systemd-boot ---
add_systemd_boot_kernel_params() {
  local boot_entries_dir="/boot/loader/entries"
  if [ ! -d "$boot_entries_dir" ]; then
    log_warning "Boot entries directory not found. Skipping kernel parameter addition for systemd-boot."
    return 0 # Not an error that should stop the script
  fi

  local modified_count=0
  local entries_found=0

  # Find non-fallback .conf files and process them
  while IFS= read -r -d $'\0' entry; do
    ((entries_found++))
    local entry_name=$(basename "$entry")
    if ! grep -q "quiet loglevel=3" "$entry"; then # Check for existing parameters more generically
      if sudo sed -i '/^options / s/$/ quiet loglevel=3 systemd.show_status=auto rd.udev.log_level=3/' "$entry"; then
        log_success "Added kernel parameters to $entry_name"
        ((modified_count++))
      else
        log_error "Failed to add kernel parameters to $entry_name"
        # Continue to try other entries, but log the error
      fi
    else
      log_info "Kernel parameters already present in $entry_name - skipping."
    fi
  done < <(find "$boot_entries_dir" -name "*.conf" ! -name "*fallback.conf" -print0)

  if [ "$entries_found" -eq 0 ]; then
    log_warning "No systemd-boot entries found to modify."
  elif [ "$modified_count" -gt 0 ]; then
    log_success "Kernel parameters updated for $modified_count systemd-boot entries."
  else
    log_info "No systemd-boot entries needed parameter updates."
  fi
  return 0
}

# --- systemd-boot ---
configure_boot() {
  run_step "Adding kernel parameters to systemd-boot entries" add_systemd_boot_kernel_params

  if [ -f "/boot/loader/loader.conf" ]; then
    sudo sed -i \
      -e '/^default /d' \
      -e '1i default @saved' \
      -e 's/^timeout.*/timeout 3/' \
      -e 's/^[#]*console-mode[[:space:]]\+.*/console-mode max/' \
      /boot/loader/loader.conf

    run_step "Ensuring timeout is set in loader.conf" \
        grep -q '^timeout' /boot/loader/loader.conf || echo "timeout 3" | sudo tee -a /boot/loader/loader.conf >/dev/null
    run_step "Ensuring console-mode is set in loader.conf" \
        grep -q '^console-mode' /boot/loader/loader.conf || echo "console-mode max" | sudo tee -a /boot/loader/loader.conf >/dev/null
  else
    log_warning "loader.conf not found. Skipping loader.conf configuration for systemd-boot."
  fi

  run_step "Removing systemd-boot fallback entries" sudo rm -f /boot/loader/entries/*fallback.conf
}

# --- Bootloader and Btrfs detection ---
BOOTLOADER=$(detect_bootloader)
IS_BTRFS=$(is_btrfs_system && echo "true" || echo "false")

# --- GRUB configuration ---
configure_grub() {
    step "Configuring GRUB: set default kernel to 'linux'"

    # /etc/default/grub settings
    sudo sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=3/' /etc/default/grub || echo 'GRUB_TIMEOUT=3' | sudo tee -a /etc/default/grub >/dev/null
    sudo sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub || echo 'GRUB_DEFAULT=saved' | sudo tee -a /etc/default/grub >/dev/null
    grep -q '^GRUB_SAVEDEFAULT=' /etc/default/grub && sudo sed -i 's/^GRUB_SAVEDEFAULT=.*/GRUB_SAVEDEFAULT=true/' /etc/default/grub || echo 'GRUB_SAVEDEFAULT=true' | sudo tee -a /etc/default/grub >/dev/null
    sudo sed -i 's@^GRUB_CMDLINE_LINUX_DEFAULT=.*@GRUB_CMDLINE_LINUX_DEFAULT="quiet splash loglevel=3 systemd.show_status=auto rd.udev.log_level=3 plymouth.ignore-serial-consoles"@' /etc/default/grub || \
        echo 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash loglevel=3 systemd.show_status=auto rd.udev.log_level=3 plymouth.ignore-serial-consoles"' | sudo tee -a /etc/default/grub >/dev/null

    # Enable submenu for additional kernels (linux-lts, linux-zen)
    grep -q '^GRUB_DISABLE_SUBMENU=' /etc/default/grub && sudo sed -i 's/^GRUB_DISABLE_SUBMENU=.*/GRUB_DISABLE_SUBMENU=notlinux/' /etc/default/grub || \
        echo 'GRUB_DISABLE_SUBMENU=notlinux' | sudo tee -a /etc/default/grub >/dev/null

    grep -q '^GRUB_GFXMODE=' /etc/default/grub || echo 'GRUB_GFXMODE=auto' | sudo tee -a /etc/default/grub >/dev/null
    grep -q '^GRUB_GFXPAYLOAD_LINUX=' /etc/default/grub || echo 'GRUB_GFXPAYLOAD_LINUX=keep' | sudo tee -a /etc/default/grub >/dev/null

    # Detect installed kernels
    KERNELS=($(ls /boot/vmlinuz-* 2>/dev/null | sed 's|/boot/vmlinuz-||g'))
    if [[ ${#KERNELS[@]} -eq 0 ]]; then
        log_error "No kernels found in /boot."
        return 1
    fi

    # Determine main kernel and secondary kernels
    MAIN_KERNEL=""
    SECONDARY_KERNELS=()
    for k in "${KERNELS[@]}"; do
        [[ "$k" == "linux" ]] && MAIN_KERNEL="$k"
        [[ "$k" != "linux" && "$k" != "fallback" && "$k" != "rescue" ]] && SECONDARY_KERNELS+=("$k")
    done
    [[ -z "$MAIN_KERNEL" ]] && MAIN_KERNEL="${KERNELS[0]}"

    # Remove fallback/recovery kernels
    sudo rm -f /boot/initramfs-*-fallback.img /boot/vmlinuz-*-fallback 2>/dev/null || true

    # Regenerate grub.cfg
    sudo grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 || { log_error "grub-mkconfig failed"; return 1; }

    log_success "GRUB configured to remember the last chosen boot entry."
}

# --- Limine Bootloader Configuration ---

# Find Limine configuration file
find_limine_config() {
  local config_paths=(
    "/boot/limine/limine.conf"
    "/boot/limine.conf"
    "/boot/EFI/arch-limine/limine.conf"
    "/boot/EFI/BOOT/limine.conf"
  )
  
  for path in "${config_paths[@]}"; do
    if [ -f "$path" ]; then
      echo "$path"
      return 0
    fi
  done
  
  return 1
}

# Create Limine directory structure
setup_limine_directories() {
  local limine_dir="/boot/limine"
  
  if [ ! -d "$limine_dir" ]; then
    log_info "Creating Limine directory structure..."
    sudo mkdir -p "$limine_dir"
  fi
  
  # Ensure ESP is mounted
  if ! mountpoint -q /boot; then
    log_warning "/boot is not mounted. Attempting to mount..."
    sudo mount /boot || {
      log_error "Failed to mount /boot"
      return 1
    }
  fi
}

# Detect existing OS installations
detect_os_installations() {
  local os_list=()
  
  # Detect Arch Linux installations
  if [ -f "/etc/os-release" ] && grep -q "ID=arch" "/etc/os-release"; then
    os_list+=("arch")
  fi
  
  # Detect Windows installations
  for disk in /dev/sd[a-z] /dev/hd[a-z] /dev/nvme[0-9]n[0-9]p[0-9]; do
    if [ -b "$disk" ]; then
      if sudo file -s "$disk" 2>/dev/null | grep -q "NTFS" || \
         sudo dd if="$disk" bs=512 count=1 2>/dev/null | strings | grep -qi "MSWIN"; then
        os_list+=("windows:$disk")
        break
      fi
    fi
  done
  
  printf '%s\n' "${os_list[@]}"
}

# Create Linux boot entry
create_linux_entry() {
  local config_file="$1"
  local entry_name="$2"
  local kernel_path="${3:-boot():/vmlinuz-linux}"
  local initramfs_path="${4:-boot():/initramfs-linux.img}"
  
  # Get root filesystem information
  local root_uuid=""
  local root_fstype=""
  local root_subvol=""
  
  root_uuid=$(findmnt -n -o UUID / 2>/dev/null || echo "")
  root_fstype=$(findmnt -n -o FSTYPE / 2>/dev/null || echo "")
  
  if [ -z "$root_uuid" ]; then
    log_error "Could not determine root UUID"
    return 1
  fi
  
  # Build kernel command line
  local cmdline="root=UUID=$root_uuid rw"
  
  # Add filesystem-specific options
  case "$root_fstype" in
    btrfs)
      # Detect Btrfs subvolume
      root_subvol=$(findmnt -n -o OPTIONS / | grep -o 'subvol=[^,]*' | cut -d= -f2 || echo "/@")
      cmdline="$cmdline rootflags=subvol=$root_subvol"
      ;;
    ext4)
      cmdline="$cmdline rootflags=relatime"
      ;;
  esac
  
  # Add common parameters
  cmdline="$cmdline quiet splash loglevel=3 systemd.show_status=auto rd.udev.log_level=3 plymouth.ignore-serial-consoles"
  
  # Get machine ID for snapshot identification
  local machine_id=""
  if [ -f "/etc/machine-id" ]; then
    machine_id=$(cat /etc/machine-id | head -c 32)
  fi
  
  # Create the boot entry
  cat << EOF | sudo tee -a "$config_file" > /dev/null

/$entry_name
protocol: linux
path: $kernel_path
cmdline: $cmdline
module_path: $initramfs_path
EOF
  
  # Add machine-id comment if available
  if [ -n "$machine_id" ]; then
    cat << EOF | sudo tee -a "$config_file" > /dev/null
comment: machine-id=$machine_id
EOF
  fi
  
  log_success "Added Linux entry: $entry_name"
}

# Create Windows boot entry
create_windows_entry() {
  local config_file="$1"
  local disk="$2"
  
  cat << EOF | sudo tee -a "$config_file" > /dev/null

/Windows
protocol: chainloader
path: chainloader():$disk
driver: chainloader
EOF
  
  log_success "Added Windows entry: $disk"
}

# Create snapshot section
create_snapshot_section() {
  local config_file="$1"
  
  cat << EOF | sudo tee -a "$config_file" > /dev/null


//Snapshots
EOF
  
  log_success "Added Snapshots section"
}

# --- Limine Basic Configuration ---
configure_limine_basic() {
  step "Configuring Limine bootloader"
  
  # Setup directories
  setup_limine_directories || return 1
  
  local limine_config="/boot/limine/limine.conf"
  
  # Backup existing configuration
  if [ -f "$limine_config" ]; then
    log_info "Backing up existing limine.conf..."
    sudo cp "$limine_config" "${limine_config}.backup.$(date +%Y%m%d_%H%M%S)"
  fi
  
  # Create new configuration
  log_info "Creating Limine configuration at: $limine_config"
  
  # Write configuration header
  cat << EOF | sudo tee "$limine_config" > /dev/null
# Limine Bootloader Configuration
# Generated by archinstaller

timeout: 3
interface_resolution: 1024x768

EOF
  
  # Detect OS installations
  log_info "Detecting OS installations..."
  local os_installations
  mapfile -t os_installations < <(detect_os_installations)
  
  if [ ${#os_installations[@]} -eq 0 ]; then
    log_warning "No OS installations detected"
    return 1
  fi
  
  # Add boot entries
  for os in "${os_installations[@]}"; do
    case "$os" in
      "arch")
        create_linux_entry "$limine_config" "Arch Linux"
        
        # Add LTS kernel entry if available
        if [ -f "/boot/vmlinuz-linux-lts" ] && [ -f "/boot/initramfs-linux-lts.img" ]; then
          create_linux_entry "$limine_config" "Arch Linux (LTS)" \
            "boot():/vmlinuz-linux-lts" \
            "boot():/initramfs-linux-lts.img"
        fi
        ;;
      windows:*)
        local disk="${os#windows:}"
        create_windows_entry "$limine_config" "$disk"
        ;;
    esac
  done
  
  # Add snapshot section for Btrfs systems
  if [ "$(findmnt -n -o FSTYPE /)" = "btrfs" ]; then
    create_snapshot_section "$limine_config"
  fi
  
  log_success "Limine configuration completed"
  log_info "Configuration file: $limine_config"
}

# --- Console Font Setup ---
setup_console_font() {
    run_step "Installing console font" sudo pacman -S --noconfirm --needed terminus-font
    run_step "Configuring /etc/vconsole.conf" bash -c "(grep -q '^FONT=' /etc/vconsole.conf 2>/dev/null && sudo sed -i 's/^FONT=.*/FONT=ter-v16n/' /etc/vconsole.conf) || echo 'FONT=ter-v16n' | sudo tee -a /etc/vconsole.conf >/dev/null"
    run_step "Rebuilding initramfs" sudo mkinitcpio -P
}

# --- Main execution ---
if [ "$BOOTLOADER" = "grub" ]; then
    configure_grub
elif [ "$BOOTLOADER" = "systemd-boot" ]; then
    configure_boot
elif [ "$BOOTLOADER" = "limine" ]; then
    configure_limine_basic
else
    log_warning "No bootloader detected or bootloader is unsupported. Defaulting to systemd-boot configuration."
    configure_boot
fi

setup_console_font
