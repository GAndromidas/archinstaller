#!/bin/bash
set -uo pipefail

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

cleanup_and_optimize() {
  step "Performing final cleanup and optimizations"
  # Check if lsblk is available for SSD detection
  if command_exists lsblk; then
    if lsblk -d -o rota | grep -q '^0$'; then
      run_step "Running fstrim on SSDs" sudo fstrim -v /
    fi
  else
    log_warning "lsblk not available. Skipping SSD optimization."
  fi
  run_step "Cleaning /tmp directory" sudo rm -rf /tmp/*
  run_step "Syncing disk writes" sync
}

setup_maintenance() {
  step "Performing comprehensive system cleanup"
  run_step "Cleaning pacman cache" sudo pacman -Sc --noconfirm
  run_step "Cleaning yay cache" yay -Sc --noconfirm

  # Flatpak cleanup - remove unused packages and runtimes
  if command -v flatpak >/dev/null 2>&1; then
    run_step "Removing unused flatpak packages" sudo flatpak uninstall --unused --noninteractive -y
    run_step "Removing unused flatpak runtimes" sudo flatpak uninstall --unused --noninteractive -y
    log_success "Flatpak cleanup completed"
  else
    log_info "Flatpak not installed, skipping flatpak cleanup"
  fi

  # Remove orphaned packages if any exist
  if pacman -Qtdq &>/dev/null; then
    run_step "Removing orphaned packages" sudo pacman -Rns $(pacman -Qtdq) --noconfirm
  else
    log_info "No orphaned packages found"
  fi

  # Only attempt to remove yay-debug if it's actually installed
  if pacman -Q yay-debug &>/dev/null; then
    run_step "Removing yay-debug package" yay -Rns yay-debug --noconfirm
  fi
}

cleanup_helpers() {
  run_step "Cleaning yay build dir" sudo rm -rf /tmp/yay
}

# Configure Snapper settings
configure_snapper() {
  step "Configuring Snapper for root filesystem"

  # Backup existing config if present
  if [ -f /etc/snapper/configs/root ]; then
    log_info "Snapper config already exists. Creating backup..."
    sudo cp /etc/snapper/configs/root /etc/snapper/configs/root.backup.$(date +%Y%m%d_%H%M%S) 2>/dev/null || true
    log_info "Updating existing Snapper configuration..."
  else
    log_info "Creating new Snapper configuration..."
    if ! sudo snapper -c root create-config / 2>/dev/null; then
      log_error "Failed to create Snapper configuration"
      return 1
    fi
  fi

  # Configure Snapper settings with optimized retention policy
  sudo sed -i 's/^TIMELINE_CREATE=.*/TIMELINE_CREATE="no"/' /etc/snapper/configs/root
  sudo sed -i 's/^TIMELINE_CLEANUP=.*/TIMELINE_CLEANUP="yes"/' /etc/snapper/configs/root
  sudo sed -i 's/^NUMBER_CLEANUP=.*/NUMBER_CLEANUP="yes"/' /etc/snapper/configs/root
  sudo sed -i 's/^TIMELINE_LIMIT_HOURLY=.*/TIMELINE_LIMIT_HOURLY="0"/' /etc/snapper/configs/root
  sudo sed -i 's/^TIMELINE_LIMIT_DAILY=.*/TIMELINE_LIMIT_DAILY="0"/' /etc/snapper/configs/root
  sudo sed -i 's/^TIMELINE_LIMIT_WEEKLY=.*/TIMELINE_LIMIT_WEEKLY="0"/' /etc/snapper/configs/root
  sudo sed -i 's/^TIMELINE_LIMIT_MONTHLY=.*/TIMELINE_LIMIT_MONTHLY="0"/' /etc/snapper/configs/root
  sudo sed -i 's/^TIMELINE_LIMIT_YEARLY=.*/TIMELINE_LIMIT_YEARLY="0"/' /etc/snapper/configs/root
  sudo sed -i 's/^NUMBER_LIMIT=.*/NUMBER_LIMIT="10"/' /etc/snapper/configs/root
  sudo sed -i 's/^NUMBER_LIMIT_IMPORTANT=.*/NUMBER_LIMIT_IMPORTANT="5"/' /etc/snapper/configs/root

  log_success "Snapper configuration completed (boot snapshots only, max 10 total)"
}

# Configure btrfs-assistant GUI settings
configure_btrfs_assistant_gui() {
  step "Configuring btrfs-assistant GUI settings"

  # btrfs-assistant uses /etc/btrfs-assistant.conf for system-wide config
  local BA_CONFIG="/etc/btrfs-assistant.conf"

  # Backup existing config if present
  if [ -f "$BA_CONFIG" ]; then
    sudo cp "$BA_CONFIG" "${BA_CONFIG}.backup.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
  fi

  # Check if config exists and append or create
  if [ -f "$BA_CONFIG" ]; then
    log_info "Updating existing btrfs-assistant configuration..."
    # Append snapshot location if not already present
    if ! grep -q "snapshot_location_root" "$BA_CONFIG" 2>/dev/null; then
      echo "snapshot_location_root = /.snapshots" | sudo tee -a "$BA_CONFIG" >/dev/null
    fi
  else
    log_info "Creating new btrfs-assistant configuration..."
    # Create basic config with snapshot location
    echo "snapshot_location_root = /.snapshots" | sudo tee "$BA_CONFIG" >/dev/null
  fi

  log_success "btrfs-assistant configuration updated at $BA_CONFIG"
  log_info "Maintenance tab will read settings from /etc/default/btrfsmaintenance"
  log_info "After reboot, open btrfs-assistant to see maintenance schedule"
}

# Configure btrfsmaintenance settings
configure_btrfsmaintenance() {
  step "Configuring btrfsmaintenance services"

  # Arch Linux uses /etc/default/btrfsmaintenance
  local BTRMAINT_CONFIG="/etc/default/btrfsmaintenance"

  # Backup existing config if present
  if [ -f "$BTRMAINT_CONFIG" ]; then
    sudo cp "$BTRMAINT_CONFIG" "${BTRMAINT_CONFIG}.backup.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
  fi

  # Create comprehensive maintenance configuration
  cat << 'EOF' | sudo tee "$BTRMAINT_CONFIG" >/dev/null
## Path:        System/File systems/btrfs
## Type:        string(none,stdout,journal,syslog)
## Default:     "stdout"
#
# Output target for messages. Journal and syslog messages are tagged by the task name like
# 'btrfs-scrub' etc.
BTRFS_LOG_OUTPUT="stdout"

## Path:        System/File systems/btrfs
## Type:        string
## Default:     ""
#
# Run periodic defrag on selected paths. The files from a given path do not
# cross mount points or other subvolumes/snapshots. If you want to defragment
# nested subvolumes, all have to be listed in this variable.
# (Colon separated paths)
BTRFS_DEFRAG_PATHS="/:/home"

## Path:           System/File systems/btrfs
## Type:           string(none,daily,weekly,monthly)
## Default:        "none"
## ServiceRestart: btrfsmaintenance-refresh
#
# Frequency of defrag.
BTRFS_DEFRAG_PERIOD="weekly"

## Path:        System/File systems/btrfs
## Type:        string
## Default:     "+1M"
#
# Minimal file size to consider for defragmentation
BTRFS_DEFRAG_MIN_SIZE="+1M"

## Path:        System/File systems/btrfs
## Type:        string
## Default:     "/"
#
# Which mountpoints/filesystems to balance periodically. This may reclaim unused
# portions of the filesystem and make the rest more compact.
# (Colon separated paths)
# The special word/mountpoint "auto" will evaluate all mapped btrfs
# filesystems
BTRFS_BALANCE_MOUNTPOINTS="/:/home:/var/log"

## Path:           System/File systems/btrfs
## Type:           string(none,daily,weekly,monthly)
## Default:        "weekly"
## ServiceRestart: btrfsmaintenance-refresh
#
# Frequency of periodic balance.
#
# The frequency may be specified using one of the listed values or
# in the format documented in the "Calendar Events" section of systemd.time(7),
# if available.
BTRFS_BALANCE_PERIOD="weekly"

## Path:        System/File systems/btrfs
## Type:        string
## Default:     "5 10"
#
# The usage percent for balancing data block groups.
#
# Note: default values should not disturb normal work but may not reclaim
# enough block groups. If you observe that, add higher values but beware that
# this will increase IO load on the system.
BTRFS_BALANCE_DUSAGE="5 10"

## Path:        System/File systems/btrfs
## Type:        string
## Default:     "5"
#
# The usage percent for balancing metadata block groups. The values are also
# used in case the filesystem has mixed blockgroups.
#
# Note: default values should not disturb normal work but may not reclaim
# enough block groups. If you observe that, add higher values but beware that
# this will increase IO load on the system.
BTRFS_BALANCE_MUSAGE="5"

## Path:        System/File systems/btrfs
## Type:        string
## Default:     "/"
#
# Which mountpoints/filesystems to scrub periodically.
# (Colon separated paths)
# The special word/mountpoint "auto" will evaluate all mapped btrfs
# filesystems
BTRFS_SCRUB_MOUNTPOINTS="/:/home:/var/log"

## Path:        System/File systems/btrfs
## Type:        string(none,weekly,monthly)
## Default:     "monthly"
## ServiceRestart: btrfsmaintenance-refresh
#
# Frequency of periodic scrub.
#
# The frequency may be specified using one of the listed values or
# in the format documented in the "Calendar Events" section of systemd.time(7),
# if available.
BTRFS_SCRUB_PERIOD="monthly"

## Path:        System/File systems/btrfs
## Type:        string(idle,normal)
## Default:     "idle"
#
# Priority of IO at which the scrub process will run. Idle should not degrade
# performance but may take longer to finish.
BTRFS_SCRUB_PRIORITY="idle"

## Path:        System/File systems/btrfs
## Type:        boolean
## Default:     "false"
#
# Do read-only scrub and don't try to repair anything.
BTRFS_SCRUB_READ_ONLY="false"

## Path:           System/File systems/btrfs
## Description:    Configuration for periodic fstrim
## Type:           string(none,daily,weekly,monthly)
## Default:        "none"
## ServiceRestart: btrfsmaintenance-refresh
#
# Frequency of periodic trim. Off by default so it does not collide with
# fstrim.timer . If you do not use the timer, turn it on here. The recommended
# period is 'weekly'.
#
# The frequency may be specified using one of the listed values or
# in the format documented in the "Calendar Events" section of systemd.time(7),
# if available.
BTRFS_TRIM_PERIOD="none"

## Path:        System/File systems/btrfs
## Description: Configuration for periodic fstrim - mountpoints
## Type:        string
## Default:     "/"
#
# Which mountpoints/filesystems to trim periodically.
# (Colon separated paths)
# The special word/mountpoint "auto" will evaluate all mapped btrfs
# filesystems
BTRFS_TRIM_MOUNTPOINTS="/"

## Path:	System/File systems/btrfs
## Description:	Configuration to allow concurrent jobs
## Type: 	boolean
## Default:	"false"
#
# These maintenance tasks may compete for resources with each other, blocking
# out other tasks from using the file systems.  This option will force
# these jobs to run in FIFO order when scheduled at overlapping times.  This
# may include tasks scheduled to run when a system resumes or boots when
# the timer for these tasks(s) elapsed while the system was suspended
# or powered off.
BTRFS_ALLOW_CONCURRENCY="false"
EOF

  local timers_enabled=true

  if sudo systemctl enable btrfs-scrub.timer 2>/dev/null; then
    log_success "btrfs-scrub timers enabled (monthly integrity checks)"
  else
    log_warning "Some btrfs-scrub timers failed to enable"
    timers_enabled=false
  fi

  if sudo systemctl enable btrfs-balance.timer 2>/dev/null; then
    log_success "btrfs-balance timers enabled (weekly space optimization)"
  else
    log_warning "Some btrfs-balance timers failed to enable"
    timers_enabled=false
  fi

  if sudo systemctl enable btrfs-defrag.timer 2>/dev/null; then
    log_success "btrfs-defrag timers enabled (weekly defragmentation)"
  else
    log_warning "Some btrfs-defrag timers failed to enable"
    timers_enabled=false
  fi

  if [ "$timers_enabled" = true ]; then
    log_success "All btrfsmaintenance timers are enabled"
  else
    log_warning "Some btrfsmaintenance timers failed to enable"
  fi

  # Display timer status
  echo ""
  log_info "Maintenance timer status:"
  systemctl list-timers 'btrfs-*' --no-pager 2>/dev/null | head -n 20 || true
  echo ""
}

# Setup GRUB bootloader for snapshots
setup_grub_bootloader() {
  step "Configuring GRUB bootloader for snapshot support"

  # Install grub-btrfs for automatic snapshot boot entries
  if ! pacman -Q grub-btrfs &>/dev/null; then
    log_info "Installing grub-btrfs for snapshot support..."
    install_packages_quietly grub-btrfs
  else
    log_info "grub-btrfs already installed"
  fi

  # Enable grub-btrfsd daemon for automatic menu updates
  if command -v grub-btrfsd &>/dev/null; then
    log_info "Enabling grub-btrfsd service for automatic snapshot detection..."
    if sudo systemctl enable --now grub-btrfsd.service; then
      log_success "grub-btrfsd service enabled and started."
      # Check service status and logs for debugging if it's not working
      if ! sudo systemctl is-active --quiet grub-btrfsd.service; then
        log_error "grub-btrfsd.service is not active despite being enabled. Checking logs..."
        sudo journalctl -u grub-btrfsd.service --since "10 minutes ago" --no-pager || true
      fi
    else
      log_error "Failed to enable grub-btrfsd service. Please check manually."
    fi
  fi

  # Regenerate GRUB configuration
  log_info "Regenerating GRUB configuration..."
  if sudo grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null; then
    log_success "GRUB configuration complete - snapshots will appear in boot menu"
  else
    log_error "Failed to regenerate GRUB configuration"
    return 1
  fi
}

# Setup Limine bootloader with proper snapshot integration
setup_limine_bootloader() {
  step "Configuring Limine bootloader for snapshot support"

  # Check for limine.conf in standard locations (prefer /boot/limine/limine.conf)
  local LIMINE_CONFIG=""
  LIMINE_CONFIG=$(find_limine_config)

  if [ -z "$LIMINE_CONFIG" ]; then
    log_error "limine.conf not found in any standard location"
    return 1
  fi

  log_info "Found limine.conf at: $LIMINE_CONFIG"

  # Set timeout to 3 seconds if not already set (Limine format uses 'timeout: 3')
  if grep -q "^timeout:" "$LIMINE_CONFIG"; then
    sudo sed -i 's/^timeout:.*/timeout: 3/' "$LIMINE_CONFIG"
    log_success "Set Limine timeout to 3 seconds"
  else
    # Find the first line and insert timeout after it
    sudo sed -i '1i timeout: 3' "$LIMINE_CONFIG"
    log_success "Added Limine timeout of 3 seconds"
  fi

  # Remove old DEFAULT_ENTRY line (Limine doesn't use this format)
  sudo sed -i '/^DEFAULT_ENTRY=/d' "$LIMINE_CONFIG"

  # Fix subvolume path format (subvol=@ -> subvol=/@)
  sudo sed -i 's/rootflags=subvol=@/rootflags=subvol=\/@/g' "$LIMINE_CONFIG"

  # Add machine-id comments for snapshot support (required by limine-snapper-sync)
  if ! grep -q "comment: machine-id=" "$LIMINE_CONFIG"; then
    if [ -f "/etc/machine-id" ]; then
      local machine_id=$(cat /etc/machine-id)
      if [ -n "$machine_id" ]; then
        sudo sed -i '/^[^[:space:]]/{
          /^[^[:space:]]*\/[^+]/{
            /comment: machine-id=/!i\
    comment: machine-id='$machine_id'
          }
        }' "$LIMINE_CONFIG"
        log_success "Added machine-id: $machine_id for snapshot targeting"
      else
        log_warning "No machine-id found - adding placeholder"
        sudo sed -i '/^[^[:space:]]/{
          /^[^[:space:]]*\/[^+]/{
            /comment: machine-id=/!i\
    comment: machine-id=
          }
        }' "$LIMINE_CONFIG"
      fi
    else
      log_warning "/etc/machine-id not found - adding placeholder"
      sudo sed -i '/^[^[:space:]]/{
        /^[^[:space:]]*\/[^+]/{
          /comment: machine-id=/!i\
    comment: machine-id=
        }
      }' "$LIMINE_CONFIG"
    fi
  else
    log_info "Machine-id already present"
  fi

  # Configure limine.conf first, then copy for limine-snapper-sync
  
  # Step 1: Configure Plymouth parameters in original limine.conf
  log_info "Configuring Plymouth parameters in limine.conf at: $LIMINE_CONFIG"
  local modified_count=0
  
  if grep -q "^[[:space:]]*cmdline:" "$LIMINE_CONFIG"; then
    # Add splash parameter if missing
    if grep "^[[:space:]]*cmdline:" "$LIMINE_CONFIG" | grep -qv "splash"; then
      sudo sed -i '/^[[:space:]]*cmdline:/ { /splash/! s/$/ splash/ }' "$LIMINE_CONFIG"
      ((modified_count++))
      log_success "Added 'splash' to limine.conf"
    fi
    
    # Add quiet parameter if missing
    if grep "^[[:space:]]*cmdline:" "$LIMINE_CONFIG" | grep -qv "quiet"; then
      sudo sed -i '/^[[:space:]]*cmdline:/ { /quiet/! s/$/ quiet/ }' "$LIMINE_CONFIG"
      ((modified_count++))
      log_success "Added 'quiet' to limine.conf"
    fi
    
    # Add nowatchdog parameter if missing
    if grep "^[[:space:]]*cmdline:" "$LIMINE_CONFIG" | grep -qv "nowatchdog"; then
      sudo sed -i '/^[[:space:]]*cmdline:/ { /nowatchdog/! s/$/ nowatchdog/ }' "$LIMINE_CONFIG"
      ((modified_count++))
      log_success "Added 'nowatchdog' to limine.conf"
    fi
    
    if [ $modified_count -gt 0 ]; then
      log_success "Plymouth parameters configured in limine.conf"
    else
      log_info "Plymouth parameters already present in limine.conf"
    fi
  else
    log_warning "limine.conf not in modern format - cannot add Plymouth support"
  fi
  
  # Step 2: Add machine-id comments for snapshot identification (ArchWiki recommended)
  log_info "Adding machine-id comments to limine.conf..."
  if [ -f "/etc/machine-id" ]; then
    local machine_id=$(cat /etc/machine-id | head -c 32)
    if [ -n "$machine_id" ]; then
      # Check if any kernel entries lack machine-id
      if grep -q "^[[:space:]]*protocol: linux" "$LIMINE_CONFIG" && \
         ! grep -q "comment: machine-id=" "$LIMINE_CONFIG"; then
        # Add machine-id to kernel entries
        sudo sed -i '/^[[:space:]]*\/[^+]/{
          /^[[:space:]]*\/[^+]/{
            /comment: machine-id=/!i\
    comment: machine-id='"$machine_id"'
          }
        }' "$LIMINE_CONFIG"
        log_success "Added machine-id comments to limine.conf"
      elif grep -q "comment: machine-id=" "$LIMINE_CONFIG"; then
        log_info "Machine-id comments already present in limine.conf"
      fi
    else
      log_warning "Could not read machine-id"
    fi
  else
    log_warning "Machine-id file not found"
  fi
  
  # Step 3: Add Windows MBR entry if detected (before Snapshots)
  log_info "Checking for Windows MBR installations..."
  local windows_disk=""
  
  # Smart Windows MBR detection
  for disk in /dev/sd[a-z] /dev/hd[a-z] /dev/nvme[0-9]n[0-9]p[0-9]; do
    if [ -b "$disk" ]; then
      # Check for Windows boot signature and NTFS filesystem
      if sudo file -s "$disk" 2>/dev/null | grep -q "NTFS" || \
         sudo dd if="$disk" bs=512 count=1 2>/dev/null | strings | grep -qi "MSWIN"; then
        windows_disk="$disk"
        log_success "Found Windows installation on: $windows_disk"
        break
      fi
    fi
  done
  
  if [ -n "$windows_disk" ]; then
    # Add Windows entry before Snapshots section
    log_info "Adding Windows MBR entry to limine.conf..."
    
    # Remove existing //Snapshots if present (we'll add it back after Windows)
    local temp_file=$(mktemp)
    grep -v "//Snapshots" "$LIMINE_CONFIG" > "$temp_file" 2>/dev/null || cp "$LIMINE_CONFIG" "$temp_file"
    
    # Add Windows entry
    cat << EOF | sudo tee -a "$temp_file" > /dev/null

/+Windows
protocol: chainloader
path: chainloader():${windows_disk}
driver: chainloader
EOF
    
    # Add back //Snapshots section
    echo "" | sudo tee -a "$temp_file" > /dev/null
    echo "" | sudo tee -a "$temp_file" > /dev/null
    echo "//Snapshots" | sudo tee -a "$temp_file" > /dev/null
    
    # Replace original file
    sudo mv "$temp_file" "$LIMINE_CONFIG"
    log_success "Added Windows MBR entry before Snapshots section"
  else
    log_info "No Windows MBR installation detected - skipping Windows entry"
  fi
  
  # Step 4: Add //Snapshots keyword for automatic snapshot entries
  log_info "Adding //Snapshots keyword to limine.conf..."
  if ! grep -q "//Snapshots" "$LIMINE_CONFIG" && ! grep -q "/Snapshots" "$LIMINE_CONFIG"; then
    # Add //Snapshots keyword as a separate section at the end of the file
    echo "" | sudo tee -a "$LIMINE_CONFIG" > /dev/null
    echo "" | sudo tee -a "$LIMINE_CONFIG" > /dev/null
    echo "//Snapshots" | sudo tee -a "$LIMINE_CONFIG" > /dev/null
    log_success "Added //Snapshots keyword to limine.conf as separate section"
  else
    log_info "//Snapshots keyword already present in limine.conf"
  fi
  
  # Step 5: Copy will be done after limine-snapper-sync is installed
  log_info "limine.conf configured - copy to /boot/limine.conf will be done after limine-snapper-sync installation"

  # Enable limine-snapper-sync service for automatic snapshot boot entries
  if command -v limine-snapper-sync >/dev/null 2>&1; then
    log_info "Enabling limine-snapper-sync service for automatic snapshot boot entries..."
    if sudo systemctl enable --now limine-snapper-sync.service 2>/dev/null; then
      log_success "limine-snapper-sync service enabled and started"
      log_info "Snapshot boot entries will be automatically generated and updated"
    else
      log_warning "Failed to enable limine-snapper-sync service"
    fi
  else
    log_info "limine-snapper-sync not installed - service will be enabled after installation"
  fi

  log_success "Limine bootloader configuration completed"
}

# Setup systemd-boot bootloader for LTS kernel
setup_systemd_boot() {
  step "Configuring systemd-boot for LTS kernel fallback"

  local BOOT_DIR="/boot/loader/entries"

  # Find existing Arch Linux boot entry
  local TEMPLATE=$(find "$BOOT_DIR" -name "*arch*.conf" -o -name "*linux.conf" 2>/dev/null | grep -v lts | head -n1)

  if [ -n "$TEMPLATE" ] && [ -f "$TEMPLATE" ]; then
    local BASE=$(basename "$TEMPLATE" .conf)
    local LTS_ENTRY="$BOOT_DIR/${BASE}-lts.conf"

    if [ ! -f "$LTS_ENTRY" ]; then
      log_info "Creating systemd-boot entry for linux-lts kernel..."

      # Backup original template
      sudo cp "$TEMPLATE" "${TEMPLATE}.backup.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true

      sudo cp "$TEMPLATE" "$LTS_ENTRY"
      sudo sed -i 's/^title .*/title Arch Linux (LTS Kernel)/' "$LTS_ENTRY"
      sudo sed -i 's|vmlinuz-linux\>|vmlinuz-linux-lts|g' "$LTS_ENTRY"
      sudo sed -i 's|initramfs-linux\.img|initramfs-linux-lts.img|g' "$LTS_ENTRY"
      sudo sed -i 's|initramfs-linux-fallback\.img|initramfs-linux-lts-fallback.img|g' "$LTS_ENTRY"
      log_success "LTS kernel boot entry created: $LTS_ENTRY"
    else
      log_info "LTS kernel boot entry already exists"
    fi
  else
    log_warning "Could not find systemd-boot template. You may need to manually create LTS boot entry"
    return 1
  fi
}

# Setup pacman hook for snapshot notifications
setup_pacman_hook() {
  step "Installing pacman hook for snapshot notifications"

  sudo mkdir -p /etc/pacman.d/hooks

  # Backup existing hook if present
  if [ -f /etc/pacman.d/hooks/snapper-notify.hook ]; then
    sudo cp /etc/pacman.d/hooks/snapper-notify.hook /etc/pacman.d/hooks/snapper-notify.hook.backup.$(date +%Y%m%d_%H%M%S) 2>/dev/null || true
  fi

  cat << 'EOF' | sudo tee /etc/pacman.d/hooks/snapper-notify.hook >/dev/null
[Trigger]
Operation = Upgrade
Operation = Install
Operation = Remove
Type = Package
Target = *

[Action]
Description = Snapshot notification
When = PostTransaction
Exec = /usr/bin/sh -c 'echo ""; echo "System snapshot created before package changes."; echo "View snapshots: sudo snapper list"; echo "Rollback if needed: sudo snapper rollback <number>"; echo ""'
EOF

  log_success "Pacman hook installed - you'll be notified after package operations"
}

# Main Btrfs snapshot setup function
setup_btrfs_snapshots() {
  # Check if system uses Btrfs
  if ! is_btrfs_system; then
    log_info "Root filesystem is not Btrfs. Snapshot setup skipped."
    return 0
  fi

  log_info "Btrfs filesystem detected on root partition"

  # Check available disk space
  local AVAILABLE_SPACE=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
  if [ "$AVAILABLE_SPACE" -lt 20 ]; then
    log_warning "Low disk space detected: ${AVAILABLE_SPACE}GB available (20GB+ recommended)"
  else
    log_success "Sufficient disk space available: ${AVAILABLE_SPACE}GB"
  fi

  # Auto-configure Btrfs snapshots (no user interaction needed)
  local setup_snapshots=true
  
  log_info "Btrfs filesystem detected - automatically configuring Btrfs snapshots and maintenance"
  
  # Show what's being configured
  echo ""
  echo -e "${CYAN}Automatically configuring Btrfs features:${RESET}"
  echo -e "  • Automatic snapshots before/after package operations"
  echo -e "  • Automatic snapshots on every system boot"
  echo -e "  • Retention: boot snapshots only (max 10 total)"
  echo -e "  • LTS kernel fallback for recovery"
  echo -e "  • Automated maintenance: scrub, balance, defrag"
  echo -e "  • GUI tool (btrfs-assistant) for snapshot management"
  echo ""

  # Detect bootloader
  local BOOTLOADER=$(detect_bootloader)
  log_info "Detected bootloader: $BOOTLOADER"
  
  # Debug: Show detection reasoning
  if [ "$BOOTLOADER" = "limine" ]; then
    log_info "Limine detection: Found /boot/limine.conf or /boot/limine directory or limine package"
  elif [ "$BOOTLOADER" = "systemd-boot" ]; then
    log_info "systemd-boot detection: Found /boot/loader/entries or /boot/loader/loader.conf"
  elif [ "$BOOTLOADER" = "grub" ]; then
    log_info "GRUB detection: Found /boot/grub or grub package"
  fi

  step "Setting up Btrfs snapshots system"

  # Remove Timeshift if installed (conflicts with Snapper)
  if pacman -Q timeshift &>/dev/null; then
    log_warning "Timeshift detected - removing to avoid conflicts with Snapper"
    sudo pacman -Rns --noconfirm timeshift 2>/dev/null || log_warning "Could not remove Timeshift cleanly"
  fi

  # Clean up Timeshift snapshots if they exist
  if [ -d "/timeshift-btrfs" ]; then
    log_info "Cleaning up Timeshift snapshot directory..."
    sudo rm -rf /timeshift-btrfs 2>/dev/null || log_warning "Could not remove Timeshift directory"
  fi

  # Install required packages
  step "Installing snapshot management packages"

  local grub_btrfs_package_to_install=""
  if [ "$BOOTLOADER" = "grub" ] && is_btrfs_system; then
    grub_btrfs_package_to_install="grub-btrfs"
  fi

  local limine_snapper_package_to_install=""
  if [ "$BOOTLOADER" = "limine" ] && is_btrfs_system; then
    limine_snapper_package_to_install="limine-snapper-sync"
  fi

  local snapper_packages=(snapper snap-pac btrfsmaintenance linux-lts linux-lts-headers)
  if [ -n "$grub_btrfs_package_to_install" ]; then
    snapper_packages+=("$grub_btrfs_package_to_install")
  fi

  # Add btrfs-assistant GUI only for non-server modes
  if [[ "${INSTALL_MODE:-}" != "server" ]]; then
    snapper_packages+=("btrfs-assistant")
    log_info "Installing full snapshot suite: ${snapper_packages[*]}"
  else
    log_info "Installing server (CLI-only) snapshot suite: ${snapper_packages[*]}"
  fi

  # Update package database first
  sudo pacman -Sy >/dev/null 2>&1 || log_warning "Failed to update package database"

  # Install pacman packages first
  install_packages_quietly "${snapper_packages[@]}"
  
  # Install AUR packages separately
  if [ -n "$limine_snapper_package_to_install" ]; then
    log_info "Installing AUR package: $limine_snapper_package_to_install"
    install_aur_quietly "$limine_snapper_package_to_install"
    
    # After limine-snapper-sync is installed, copy configured limine.conf to /boot/limine.conf
    if [ "$limine_snapper_package_to_install" = "limine-snapper-sync" ]; then
      log_info "limine-snapper-sync installed - now copying configured limine.conf to /boot/limine.conf"
      
      # Find the original limine.conf
      local original_limine_config=""
      original_limine_config=$(find_limine_config)
      
      if [ -n "$original_limine_config" ] && [ -f "$original_limine_config" ]; then
        # Copy the fully configured limine.conf to /boot/limine.conf for limine-snapper-sync
        if [ "$original_limine_config" != "/boot/limine.conf" ]; then
          sudo cp "$original_limine_config" "/boot/limine.conf"
          log_success "Copied configured limine.conf from $original_limine_config to /boot/limine.conf"
        else
          log_info "limine.conf already at /boot/limine.conf - no copy needed"
        fi
        
        # Configure limine-snapper-sync to use the standard location
        sudo mkdir -p /etc/default
        sudo tee /etc/default/limine > /dev/null << EOF
# limine-snapper-sync configuration
ESP_PATH="/boot"
LIMINE_CONF_PATH="/boot/limine.conf"
EOF
        
        log_success "limine-snapper-sync configured to use: /boot/limine.conf"
        
        # Enable and start limine-snapper-sync service
        log_info "Enabling limine-snapper-sync service..."
        if sudo systemctl enable --now limine-snapper-sync.service 2>/dev/null; then
          log_success "limine-snapper-sync service enabled and started"
          log_info "Snapshot boot entries will be automatically generated and updated"
          
          # Trigger immediate sync to populate //Snapshots section
          log_info "Generating initial snapshot boot entries..."
          if sudo systemctl restart limine-snapper-sync.service 2>/dev/null; then
            log_success "Snapshot boot entries generated"
          else
            log_warning "Failed to generate initial snapshot boot entries"
          fi
        else
          log_warning "Failed to enable limine-snapper-sync service"
        fi
      else
        log_warning "Could not find original limine.conf for copying"
      fi
    fi
  fi

  # Configure Snapper
  configure_snapper || { log_error "Snapper configuration failed"; return 1; }

  # Enable Snapper timers
  step "Enabling Snapper automatic snapshot timers"
  if sudo systemctl enable --now snapper-cleanup.timer 2>/dev/null && \
     sudo systemctl enable snapper-boot.timer 2>/dev/null; then
    log_success "Snapper timers enabled and started"
    log_info "Snapshots will be created on every boot"
  else
    log_error "Failed to enable Snapper timers"
    return 1
  fi

  # Configure btrfsmaintenance
  configure_btrfsmaintenance || log_warning "btrfsmaintenance configuration had issues but continuing"

  # Configure btrfs-assistant GUI
  configure_btrfs_assistant_gui || log_warning "btrfs-assistant GUI configuration had issues but continuing"

  # Configure bootloader

  # Re-run grub-mkconfig if GRUB and Btrfs are in use, after grub-btrfs is installed and configured
  if [ "$BOOTLOADER" = "grub" ] && is_btrfs_system; then
    log_info "Re-generating GRUB configuration to include Btrfs snapshot entries..."
    sudo grub-mkconfig -o /boot/grub/grub.cfg || log_error "Failed to re-generate GRUB configuration"
  fi

  # Enable limine-snapper-sync service for Limine and Btrfs
  if [ "$BOOTLOADER" = "limine" ] && is_btrfs_system; then
    # Configure limine-snapper-sync to use correct limine.conf path if needed
    local limine_config=""
    limine_config=$(find_limine_config)
    if [ "$limine_config" != "/boot/limine.conf" ]; then
      log_info "Creating copy of limine.conf for limine-snapper-sync compatibility..."
      
      # Create copy at /boot/limine.conf for limine-snapper-sync
      sudo cp "$limine_config" "/boot/limine.conf"
      log_success "Created copy: $limine_config -> /boot/limine.conf"
      
      # Ensure Plymouth parameters are also in the copy
      log_info "Ensuring Plymouth parameters in copied limine.conf..."
      local modified_count=0
      
      if grep -q "^[[:space:]]*cmdline:" "/boot/limine.conf"; then
        if grep "^[[:space:]]*cmdline:" "/boot/limine.conf" | grep -qv "splash"; then
          sudo sed -i '/^[[:space:]]*cmdline:/ { /splash/! s/$/ splash/ }' "/boot/limine.conf"
          ((modified_count++))
        fi
        
        if grep "^[[:space:]]*cmdline:" "/boot/limine.conf" | grep -qv "quiet"; then
          sudo sed -i '/^[[:space:]]*cmdline:/ { /quiet/! s/$/ quiet/ }' "/boot/limine.conf"
          ((modified_count++))
        fi
        
        if grep "^[[:space:]]*cmdline:" "/boot/limine.conf" | grep -qv "nowatchdog"; then
          sudo sed -i '/^[[:space:]]*cmdline:/ { /nowatchdog/! s/$/ nowatchdog/ }' "/boot/limine.conf"
          ((modified_count++))
        fi
        
        if [ $modified_count -gt 0 ]; then
          log_success "Plymouth parameters added to copied limine.conf"
        fi
      fi
      
      # Add machine-id comments for snapshot identification (ArchWiki recommended)
      log_info "Adding machine-id comments for snapshot identification..."
      if [ -f "/etc/machine-id" ]; then
        local machine_id=$(cat /etc/machine-id | head -c 32)
        if [ -n "$machine_id" ]; then
          # Check if any kernel entries lack machine-id
          if grep -q "^[[:space:]]*protocol: linux" "/boot/limine.conf" && \
             ! grep -q "comment: machine-id=" "/boot/limine.conf"; then
            # Add machine-id to kernel entries
            sudo sed -i '/^[[:space:]]*\/[^+]/{
              /^[[:space:]]*\/[^+]/{
                /comment: machine-id=/!i\
      comment: machine-id='"$machine_id"'
              }
            }' "/boot/limine.conf"
            log_success "Added machine-id comments to kernel entries"
          elif grep -q "comment: machine-id=" "/boot/limine.conf"; then
            log_info "Machine-id comments already present in kernel entries"
          fi
        else
          log_warning "Could not read machine-id"
        fi
      else
        log_warning "Machine-id file not found"
      fi
      
      # Configure limine-snapper-sync to use the standard location (ArchWiki recommended)
      sudo mkdir -p /etc/default
      sudo tee /etc/default/limine > /dev/null << EOF
# limine-snapper-sync configuration (ArchWiki recommended)
ESP_PATH="/boot"
LIMINE_CONF_PATH="/boot/limine.conf"
EOF
      
      log_success "limine-snapper-sync configured to use: /boot/limine.conf"
      
      # Add //Snapshots keyword for automatic snapshot entries (ArchWiki method)
      if ! grep -q "//Snapshots" "/boot/limine.conf" && ! grep -q "/Snapshots" "/boot/limine.conf"; then
        log_info "Adding //Snapshots keyword for automatic snapshot entries..."
        
        # Add //Snapshots keyword as a separate section at the end of the file
        echo "" | sudo tee -a "/boot/limine.conf" > /dev/null
        echo "" | sudo tee -a "/boot/limine.conf" > /dev/null
        echo "//Snapshots" | sudo tee -a "/boot/limine.conf" > /dev/null
        
        log_success "Added //Snapshots keyword to limine.conf as separate section"
      else
        log_info "//Snapshots keyword already present in limine.conf"
      fi
    else
      log_info "limine.conf already at standard location - no copy needed"
      
      # Ensure Plymouth parameters are present even if limine.conf is already in place
      log_info "Ensuring Plymouth parameters in limine.conf..."
      local modified_count=0
      
      if grep -q "^[[:space:]]*cmdline:" "/boot/limine.conf"; then
        if grep "^[[:space:]]*cmdline:" "/boot/limine.conf" | grep -qv "splash"; then
          sudo sed -i '/^[[:space:]]*cmdline:/ { /splash/! s/$/ splash/ }' "/boot/limine.conf"
          ((modified_count++))
        fi
        
        if grep "^[[:space:]]*cmdline:" "/boot/limine.conf" | grep -qv "quiet"; then
          sudo sed -i '/^[[:space:]]*cmdline:/ { /quiet/! s/$/ quiet/ }' "/boot/limine.conf"
          ((modified_count++))
        fi
        
        if grep "^[[:space:]]*cmdline:" "/boot/limine.conf" | grep -qv "nowatchdog"; then
          sudo sed -i '/^[[:space:]]*cmdline:/ { /nowatchdog/! s/$/ nowatchdog/ }' "/boot/limine.conf"
          ((modified_count++))
        fi
        
        if [ $modified_count -gt 0 ]; then
          log_success "Plymouth parameters added to limine.conf"
        fi
      fi
      
      # Add machine-id comments for snapshot identification (ArchWiki recommended)
      log_info "Adding machine-id comments for snapshot identification..."
      if [ -f "/etc/machine-id" ]; then
        local machine_id=$(cat /etc/machine-id | head -c 32)
        if [ -n "$machine_id" ]; then
          # Check if any kernel entries lack machine-id
          if grep -q "^[[:space:]]*protocol: linux" "/boot/limine.conf" && \
             ! grep -q "comment: machine-id=" "/boot/limine.conf"; then
            # Add machine-id to kernel entries
            sudo sed -i '/^[[:space:]]*\/[^+]/{
              /^[[:space:]]*\/[^+]/{
                /comment: machine-id=/!i\
      comment: machine-id='"$machine_id"'
              }
            }' "/boot/limine.conf"
            log_success "Added machine-id comments to kernel entries"
          elif grep -q "comment: machine-id=" "/boot/limine.conf"; then
            log_info "Machine-id comments already present in kernel entries"
          fi
        else
          log_warning "Could not read machine-id"
        fi
      else
        log_warning "Machine-id file not found"
      fi
      
      # Ensure //Snapshots keyword is present even if limine.conf is already in place
      if ! grep -q "//Snapshots" "/boot/limine.conf" && ! grep -q "/Snapshots" "/boot/limine.conf"; then
        log_info "Adding //Snapshots keyword for automatic snapshot entries..."
        echo "" | sudo tee -a "/boot/limine.conf" > /dev/null
        echo "" | sudo tee -a "/boot/limine.conf" > /dev/null
        echo "//Snapshots" | sudo tee -a "/boot/limine.conf" > /dev/null
        log_success "Added //Snapshots keyword to limine.conf as separate section"
      fi
    fi
    
    if command -v limine-snapper-sync &>/dev/null; then
      log_info "Enabling limine-snapper-sync service for snapshot integration..."
      if sudo systemctl enable --now limine-snapper-sync.service 2>/dev/null; then
        log_success "limine-snapper-sync service enabled and started"
        
        # Trigger immediate sync to populate //Snapshots section
        log_info "Generating snapshot boot entries..."
        if sudo systemctl restart limine-snapper-sync.service 2>/dev/null; then
          log_success "Snapshot boot entries updated"
        else
          log_warning "Failed to update snapshot boot entries (non-critical)"
        fi
      else
        log_warning "Failed to enable limine-snapper-sync service (non-critical)"
      fi
    else
      log_warning "limine-snapper-sync not found - snapshot boot entries will not be generated automatically"
    fi
  fi
  case "$BOOTLOADER" in
    grub)
      setup_grub_bootloader || log_warning "GRUB configuration had issues but continuing"
      ;;
    systemd-boot)
      setup_systemd_boot || log_warning "systemd-boot configuration had issues but continuing"
      ;;
    limine)
      setup_limine_bootloader || log_warning "Limine configuration had issues but continuing"
      ;;
    *)
      log_warning "Could not detect GRUB, systemd-boot, or Limine. Bootloader configuration skipped."
      log_info "Snapper will still work, but you may need to manually configure boot entries."
      ;;
  esac

  # Setup pacman hook
  setup_pacman_hook || log_warning "Pacman hook setup had issues but continuing"

  # Create initial snapshot
  step "Creating initial snapshot"
  if sudo snapper -c root create -d "Initial snapshot after setup" 2>/dev/null; then
    log_success "Initial snapshot created"
    
    # Trigger limine-snapper-sync to update boot entries with new snapshot
    if [ "$BOOTLOADER" = "limine" ] && is_btrfs_system && command -v limine-snapper-sync &>/dev/null; then
      log_info "Updating limine.conf with snapshot entries..."
      if sudo systemctl restart limine-snapper-sync.service 2>/dev/null; then
        log_success "Snapshot boot entries updated in limine.conf"
      else
        log_warning "Failed to update snapshot boot entries (non-critical)"
      fi
    fi
  else
    log_warning "Failed to create initial snapshot (non-critical)"
  fi

  # Verify installation
  step "Verifying Btrfs snapshot setup"
  local verification_passed=true

  if sudo snapper list &>/dev/null; then
    log_success "Snapper is working correctly"
  else
    log_error "Snapper verification failed"
    verification_passed=false
  fi

  if systemctl is-active --quiet snapper-timeline.timer && \
     systemctl is-active --quiet snapper-cleanup.timer && \
     systemctl is-enabled --quiet snapper-boot.timer; then
    log_success "Snapper timers are active (timeline, cleanup, boot)"
  else
    log_warning "Some Snapper timers may not be running correctly"
    verification_passed=false
  fi

  if systemctl is-active --quiet btrfs-scrub@-.timer && systemctl is-active --quiet btrfs-balance@-.timer; then
    log_success "Btrfs maintenance timers are active"
  else
    log_warning "Some btrfs maintenance timers may not be running correctly"
  fi

  # Display current snapshots
  echo ""
  log_info "Current snapshots:"
  sudo snapper list 2>/dev/null || echo "  (No snapshots yet)"
  echo ""

  # Summary
  if [ "$verification_passed" = true ]; then
    log_success "Btrfs snapshot setup completed successfully!"
    echo ""
    echo -e "${CYAN}Snapshot system configured:${RESET}"
    echo -e "  • Automatic snapshots before/after package operations"
    echo -e "  • Automatic snapshots on every system boot"
    echo -e "  • Retention: 1 hourly, 1 daily, 1 weekly (max 10 snapshots)"
    echo -e "  • LTS kernel fallback: Available in boot menu"
    echo -e "  • Automated maintenance:"
    echo -e "    - Scrub (monthly): /, /home, /var/log"
    echo -e "    - Balance (weekly): /, /home, /var/log"
    echo -e "    - Defrag (weekly): /, /home"
    echo -e "  • GUI management: Launch 'btrfs-assistant' from your menu"
    echo ""
    echo -e "${CYAN}How to use:${RESET}"
    echo -e "  • View snapshots: ${YELLOW}sudo snapper list${RESET}"
    if [ "$BOOTLOADER" = "grub" ]; then
      echo -e "  • Boot snapshots: Select 'Arch Linux snapshots' in GRUB menu"
      echo -e "  • GRUB auto-updates when new snapshots are created"
    elif [ "$BOOTLOADER" = "limine" ]; then
      echo -e "  • Boot snapshots: Managed by limine-snapper-sync service"
      echo -e "  • limine-snapper-sync: Auto-generates snapshot boot entries"
      echo -e "  • LTS kernel: Select 'Arch Linux (LTS Kernel)' in Limine menu"
    fi
    echo -e "  • Restore via GUI: Launch 'btrfs-assistant'"
    echo -e "  • Check maintenance timers: ${YELLOW}systemctl list-timers 'btrfs-*'${RESET}"
    echo -e "  • View maintenance config: ${YELLOW}cat /etc/default/btrfsmaintenance${RESET}"
    echo -e "  • Emergency fallback: Boot 'Arch Linux (LTS Kernel)'"
    echo -e "  • Snapshots stored in: ${YELLOW}/.snapshots/${RESET}"
    echo ""
    echo -e "${CYAN}btrfs-assistant Maintenance tab:${RESET}"
    echo -e "  • The Maintenance tab shows enabled timers (checkboxes)"
    echo -e "  • If unchecked, click them to enable - this will activate the timers"
    echo -e "  • Configuration is stored in ${YELLOW}/etc/default/btrfsmaintenance${RESET}"
    echo ""
  else
    log_warning "Btrfs snapshot setup completed with some warnings"
    log_info "Most functionality should still work. Review errors above."
  fi
}

# Execute all maintenance and snapshot steps
cleanup_and_optimize
setup_maintenance
cleanup_helpers
setup_btrfs_snapshots

# Final message
echo ""
log_success "Maintenance and optimization completed"
log_info "System is ready for use"
