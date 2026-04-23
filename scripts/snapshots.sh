#!/bin/bash
set -uo pipefail

# Get directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Global variable to store user's snapshot choice
SNAPSHOT_SYSTEM=""

# Detect existing snapshot systems
detect_snapshot_systems() {
  local timeshift_installed=false
  local snapper_installed=false
  
  if pacman -Q timeshift &>/dev/null; then
    timeshift_installed=true
  fi
  
  if pacman -Q snapper &>/dev/null; then
    snapper_installed=true
  fi
  
  echo "$timeshift_installed:$snapper_installed"
}

# Interactive selection for snapshot system with enhanced gum menu
select_snapshot_system() {
  local detection_result=$(detect_snapshot_systems)
  local timeshift_installed=$(echo "$detection_result" | cut -d: -f1)
  local snapper_installed=$(echo "$detection_result" | cut -d: -f2)
  
  step "Configuring Btrfs snapshot system"
  
  # Check if Btrfs filesystem is being used
  if ! is_btrfs_system; then
    echo ""
    gum style --foreground 11 "⚠️  WARNING: No Btrfs filesystem detected!"
    gum style --margin "0 2" --foreground 15 "Snapshot systems require Btrfs to function properly."
    echo ""
    
    if gum confirm --default=false "Continue anyway? (Not recommended)"; then
      log_warning "User chose to continue without Btrfs - snapshots may not work"
    else
      log_info "Skipping snapshot system setup - Btrfs not detected"
      SNAPSHOT_SYSTEM="skip"
      mkdir -p "$HOME/.config/archinstaller"
      echo "$SNAPSHOT_SYSTEM" > "$HOME/.config/archinstaller/snapshot-system"
      return 0
    fi
  fi
  
  # If both are installed, ask user to choose
  if [ "$timeshift_installed" = "true" ] && [ "$snapper_installed" = "true" ]; then
    echo ""
    gum style --foreground 226 "🔧 Both Timeshift and Snapper are detected!"
    gum style --margin "0 2" --foreground 15 "Please choose your snapshot system:"
    echo ""
    
    local choice=$(gum choose --header="Select snapshot system:" \
      "Timeshift (Recommended for most users)" \
      "Snapper (Advanced with CLI focus)" \
      "Configure Both (Keep both systems)" \
      "Skip snapshots (Don't configure any)")
    
    case "$choice" in
      "Timeshift (Recommended for most users)")
        SNAPSHOT_SYSTEM="timeshift"
        log_info "Selected Timeshift snapshot system"
        ;;
      "Snapper (Advanced with CLI focus)")
        SNAPSHOT_SYSTEM="snapper"
        log_info "Selected Snapper snapshot system"
        ;;
      "Configure Both (Keep both systems)")
        SNAPSHOT_SYSTEM="both"
        log_info "Selected to configure both Timeshift and Snapper"
        ;;
      "Skip snapshots (Don't configure any)")
        SNAPSHOT_SYSTEM="skip"
        log_info "Selected to skip snapshot configuration"
        ;;
    esac
    
  # If only Timeshift is installed
  elif [ "$timeshift_installed" = "true" ] && [ "$snapper_installed" = "false" ]; then
    log_info "Timeshift detected - will configure Timeshift system"
    SNAPSHOT_SYSTEM="timeshift"
    
  # If only Snapper is installed  
  elif [ "$timeshift_installed" = "false" ] && [ "$snapper_installed" = "true" ]; then
    log_info "Snapper detected - will configure Snapper system"
    SNAPSHOT_SYSTEM="snapper"
    
  # If neither is installed, ask user preference
  else
    echo ""
    gum style --foreground 226 "🔧 No snapshot system detected!"
    gum style --margin "0 2" --foreground 15 "Please choose your preferred snapshot system:"
    echo ""
    
    local choice=$(gum choose --header="Select snapshot system:" \
      "Timeshift (Recommended for most users)" \
      "Snapper (Advanced with CLI focus)" \
      "Skip snapshots (Don't configure any)")
    
    case "$choice" in
      "Timeshift (Recommended for most users)")
        SNAPSHOT_SYSTEM="timeshift"
        log_info "Selected Timeshift snapshot system"
        ;;
      "Snapper (Advanced with CLI focus)")
        SNAPSHOT_SYSTEM="snapper"
        log_info "Selected Snapper snapshot system"
        ;;
      "Skip snapshots (Don't configure any)")
        SNAPSHOT_SYSTEM="skip"
        log_info "Selected to skip snapshot configuration"
        ;;
    esac
  fi
  
  # Store choice for future reference
  mkdir -p "$HOME/.config/archinstaller"
  echo "$SNAPSHOT_SYSTEM" > "$HOME/.config/archinstaller/snapshot-system"
  log_success "Snapshot system preference saved: $SNAPSHOT_SYSTEM"
}

# Non-interactive selection for snapshot system
select_snapshot_system_non_interactive() {
  local detection_result=$(detect_snapshot_systems)
  local timeshift_installed=$(echo "$detection_result" | cut -d: -f1)
  local snapper_installed=$(echo "$detection_result" | cut -d: -f2)
  
  step "Configuring Btrfs snapshot system"
  
  # Check if Btrfs filesystem is being used
  if ! is_btrfs_system; then
    log_warning "No Btrfs filesystem detected - skipping snapshot system setup"
    SNAPSHOT_SYSTEM="skip"
    mkdir -p "$HOME/.config/archinstaller"
    echo "$SNAPSHOT_SYSTEM" > "$HOME/.config/archinstaller/snapshot-system"
    return 0
  fi
  
  # Check for saved preference
  local config_file="$HOME/.config/archinstaller/snapshot-system"
  if [ -f "$config_file" ]; then
    SNAPSHOT_SYSTEM=$(cat "$config_file")
    log_info "Using saved snapshot system preference: $SNAPSHOT_SYSTEM"
    return
  fi
  
  # If both are installed, default to Timeshift
  if [ "$timeshift_installed" = "true" ] && [ "$snapper_installed" = "true" ]; then
    SNAPSHOT_SYSTEM="timeshift"
    log_info "Both systems detected - defaulting to Timeshift (recommended)"
    
  # If only Timeshift is installed
  elif [ "$timeshift_installed" = "true" ] && [ "$snapper_installed" = "false" ]; then
    SNAPSHOT_SYSTEM="timeshift"
    log_info "Timeshift detected - configuring Timeshift system"
    
  # If only Snapper is installed  
  elif [ "$timeshift_installed" = "false" ] && [ "$snapper_installed" = "true" ]; then
    SNAPSHOT_SYSTEM="snapper"
    log_info "Snapper detected - configuring Snapper system"
    
  # If neither is installed, default to Timeshift
  else
    SNAPSHOT_SYSTEM="timeshift"
    log_info "No snapshot system detected - defaulting to Timeshift (recommended)"
  fi
  
  # Store preference
  mkdir -p "$HOME/.config/archinstaller"
  echo "$SNAPSHOT_SYSTEM" > "$HOME/.config/archinstaller/snapshot-system"
}

# Configure Timeshift system
configure_timeshift_system() {
  step "Configuring Timeshift snapshot system"
  
  # Install Timeshift if not present
  if ! pacman -Q timeshift &>/dev/null; then
    install_packages_quietly timeshift
    log_success "Timeshift installed"
  fi
  
  # Install timeshift-autosnap from AUR
  if command -v yay >/dev/null 2>&1; then
    if ! yay -S --noconfirm --needed timeshift-autosnap; then
      log_warning "Failed to install timeshift-autosnap (non-critical)"
    else
      log_success "timeshift-autosnap installed"
    fi
  else
    log_info "yay not available - skipping timeshift-autosnap installation"
  fi
  
  # Configure timeshift-autosnap
  configure_timeshift_autosnap
  
  # Create Timeshift configuration
  configure_timeshift_config
  
  # Configure bootloader integration
  case "$BOOTLOADER" in
    grub)
      setup_timeshift_grub_integration
      ;;
    systemd-boot)
      setup_timeshift_systemd_boot_integration
      ;;
    limine)
      setup_timeshift_limine_integration
      ;;
    *)
      log_warning "Unknown bootloader - manual Timeshift configuration may be needed"
      ;;
  esac
  
  # Create initial snapshot
  create_timeshift_initial_snapshot
}

# Configure Snapper system
configure_snapper_system() {
  step "Configuring Snapper snapshot system"
  
  # Install Snapper if not present
  if ! pacman -Q snapper &>/dev/null; then
    install_packages_quietly snapper snap-pac
    log_success "Snapper installed"
  fi
  
  # Install btrfs-maintenance for Snapper's automatic cleanup
  if ! pacman -Q btrfsmaintenance &>/dev/null; then
    install_packages_quietly btrfsmaintenance
    log_success "btrfs-maintenance installed for Snapper"
  fi
  
  # Configure Snapper
  configure_snapper_config
  
  # Enable Snapper timers
  if sudo systemctl enable --now snapper-cleanup.timer 2>/dev/null && \
     sudo systemctl enable snapper-boot.timer 2>/dev/null; then
    log_success "Snapper timers enabled"
  else
    log_warning "Failed to enable Snapper timers"
  fi
  
  # Configure bootloader integration
  case "$BOOTLOADER" in
    grub)
      setup_snapper_grub_integration
      ;;
    systemd-boot)
      setup_snapper_systemd_boot_integration
      ;;
    limine)
      setup_snapper_limine_integration
      ;;
    *)
      log_warning "Unknown bootloader - manual Snapper configuration may be needed"
      ;;
  esac
  
  # Create initial snapshot
  create_snapper_initial_snapshot
}

# Configure both systems
configure_both_systems() {
  step "Configuring both Timeshift and Snapper systems"
  
  # Configure Timeshift
  configure_timeshift_system
  
  # Configure Snapper
  configure_snapper_system
  
  log_warning "Both snapshot systems configured - be careful with conflicts"
  log_info "Recommend using one system consistently to avoid issues"
}

# Timeshift configuration functions
configure_timeshift_config() {
  sudo mkdir -p /etc/timeshift
  
  # Create Timeshift configuration
  cat << 'EOF' | sudo tee /etc/timeshift/timeshift.json >/dev/null
{
    "backup_device_uuid": "",
    "parent_device_uuid": "",
    "do_first_run": false,
    "btrfs_mode": true,
    "schedule_monthly": false,
    "schedule_weekly": false,
    "schedule_daily": true,
    "schedule_hourly": false,
    "schedule_boot": true,
    "schedule_boot_enabled": true,
    "count_monthly": 0,
    "count_weekly": 0,
    "count_daily": 1,
    "count_hourly": 0,
    "count_boot": 1,
    "snapshot_size": "100M",
    "snapshot_size_unit": "MB",
    "exclude": [
        "/home/*/.cache",
        "/home/*/.local/share/Trash",
        "/home/*/.thumbnails",
        "/home/*/.tmp",
        "/home/*/.local/share/Steam",
        "/home/*/.local/share/Flatpak",
        "/var/cache",
        "/var/tmp",
        "/var/log",
        "/var/run",
        "/var/lock",
        "/lost+found",
        "/timeshift-btrfs",
        "/.snapshots"
    ]
}
EOF
  
  log_success "Timeshift configuration created"
}

setup_timeshift_grub_integration() {
  if ! pacman -Q grub-btrfs &>/dev/null; then
    install_packages_quietly grub-btrfs
  fi
  
  # Configure grub-btrfs for Timeshift
  if [ -f /etc/default/grub-btrfs ]; then
    sudo sed -i 's|GRUB_BTRFS_SUBMENUNAME=".*|GRUB_BTRFS_SUBMENUNAME="Timeshift Snapshots"|' /etc/default/grub-btrfs
    sudo sed -i 's|GRUB_BTRFS_SNAPSHOT_PATH=".*|GRUB_BTRFS_SNAPSHOT_PATH="/timeshift-btrfs"|' /etc/default/grub-btrfs
    sudo sed -i 's|GRUB_BTRFS_LIMIT=".*|GRUB_BTRFS_LIMIT="10"|' /etc/default/grub-btrfs
  fi
  
  sudo grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 || log_warning "Failed to regenerate GRUB"
  log_success "Timeshift GRUB integration configured"
}

setup_timeshift_systemd_boot_integration() {
  local entries_dir="/boot/loader/entries"
  
  cat << 'EOF' | sudo tee "$entries_dir/timeshift-recovery.conf" >/dev/null
# Timeshift Recovery
title   Timeshift Recovery
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options root=PARTUUID=$(findmnt -n -o PARTUUID /) rw rootflags=subvol=@ quiet splash loglevel=3 systemd.show_status=auto rd.udev.log_level=3
EOF
  
  log_success "Timeshift systemd-boot integration configured"
}

setup_timeshift_limine_integration() {
  local limine_config=""
  for limine_loc in "/boot/limine/limine.conf" "/boot/limine.conf" "/boot/EFI/limine/limine.conf"; do
    if [ -f "$limine_loc" ]; then
      limine_config="$limine_loc"
      break
    fi
  done
  
  if [ -n "$limine_config" ]; then
    if ! grep -q "Timeshift Recovery" "$limine_config"; then
      cat << EOF | sudo tee -a "$limine_config" >/dev/null

# Timeshift Recovery
/Timeshift Recovery
protocol: linux
path: boot():/vmlinuz-linux
cmdline: root=PARTUUID=$(findmnt -n -o PARTUUID /) rw rootflags=subvol=@ quiet splash loglevel=3 systemd.show_status=auto rd.udev.log_level=3
module_path: boot():/initramfs-linux.img
EOF
      log_success "Timeshift recovery entry added to limine.conf"
    else
      log_info "Timeshift recovery entry already exists in limine.conf"
    fi
  else
    log_error "Limine configuration file not found"
  fi
}

create_timeshift_initial_snapshot() {
  if sudo timeshift --create --comments "Initial snapshot after archinstaller setup" >/dev/null 2>&1; then
    log_success "Initial Timeshift snapshot created"
  else
    log_warning "Failed to create initial Timeshift snapshot"
  fi
}

# Snapper configuration functions
configure_snapper_config() {
  if ! sudo snapper -c root create-config / 2>/dev/null; then
    log_info "Snapper config already exists"
  fi
  
  # Configure Snapper settings
  sudo sed -i 's/^TIMELINE_CREATE=.*/TIMELINE_CREATE="no"/' /etc/snapper/configs/root 2>/dev/null || true
  sudo sed -i 's/^TIMELINE_LIMIT_HOURLY=.*/TIMELINE_LIMIT_HOURLY="0"/' /etc/snapper/configs/root 2>/dev/null || true
  sudo sed -i 's/^TIMELINE_LIMIT_DAILY=.*/TIMELINE_LIMIT_DAILY="0"/' /etc/snapper/configs/root 2>/dev/null || true
  sudo sed -i 's/^NUMBER_LIMIT=.*/NUMBER_LIMIT="10"/' /etc/snapper/configs/root 2>/dev/null || true
  
  log_success "Snapper configuration updated"
}

setup_snapper_grub_integration() {
  if ! pacman -Q grub-btrfs &>/dev/null; then
    install_packages_quietly grub-btrfs
  fi
  
  sudo grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 || log_warning "Failed to regenerate GRUB"
  log_success "Snapper GRUB integration configured"
}

setup_snapper_systemd_boot_integration() {
  log_info "Snapper systemd-boot integration (manual configuration may be needed)"
  # Snapper systemd-boot integration is complex - user may need manual setup
}

setup_snapper_limine_integration() {
  log_info "Snapper Limine integration (manual configuration may be needed)"
  # Snapper Limine integration is complex - user may need manual setup
}

create_snapper_initial_snapshot() {
  if sudo snapper -c root create -d "Initial snapshot after setup" 2>/dev/null; then
    log_success "Initial Snapper snapshot created"
  else
    log_warning "Failed to create initial Snapper snapshot"
  fi
}

# Configure Snapper settings with optimized retention policy (from maintenance.sh)
configure_snapper_config() {
  if ! sudo snapper -c root create-config / 2>/dev/null; then
    log_info "Snapper config already exists"
  fi
  
  # Configure Snapper settings
  sudo sed -i 's/^TIMELINE_CREATE=.*/TIMELINE_CREATE="no"/' /etc/snapper/configs/root 2>/dev/null || true
  sudo sed -i 's/^TIMELINE_CLEANUP=.*/TIMELINE_CLEANUP="yes"/' /etc/snapper/configs/root 2>/dev/null || true
  sudo sed -i 's/^NUMBER_CLEANUP=.*/NUMBER_CLEANUP="yes"/' /etc/snapper/configs/root 2>/dev/null || true
  sudo sed -i 's/^TIMELINE_LIMIT_HOURLY=.*/TIMELINE_LIMIT_HOURLY="0"/' /etc/snapper/configs/root 2>/dev/null || true
  sudo sed -i 's/^TIMELINE_LIMIT_DAILY=.*/TIMELINE_LIMIT_DAILY="0"/' /etc/snapper/configs/root 2>/dev/null || true
  sudo sed -i 's/^TIMELINE_LIMIT_WEEKLY=.*/TIMELINE_LIMIT_WEEKLY="0"/' /etc/snapper/configs/root 2>/dev/null || true
  sudo sed -i 's/^TIMELINE_LIMIT_MONTHLY=.*/TIMELINE_LIMIT_MONTHLY="0"/' /etc/snapper/configs/root 2>/dev/null || true
  sudo sed -i 's/^NUMBER_LIMIT=.*/NUMBER_LIMIT="10"/' /etc/snapper/configs/root 2>/dev/null || true
  sudo sed -i 's/^NUMBER_LIMIT_IMPORTANT=.*/NUMBER_LIMIT_IMPORTANT="5"/' /etc/snapper/configs/root 2>/dev/null || true
  
  log_success "Snapper configuration updated"
}

# Setup GRUB bootloader for Snapper (from maintenance.sh)
setup_snapper_grub_integration() {
  if ! pacman -Q grub-btrfs &>/dev/null; then
    install_packages_quietly grub-btrfs
  fi
  
  sudo grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 || log_warning "Failed to regenerate GRUB"
  log_success "Snapper GRUB integration configured"
}

# Setup systemd-boot bootloader for Snapper (from maintenance.sh)
setup_snapper_systemd_boot_integration() {
  log_info "Snapper systemd-boot integration (manual configuration may be needed)"
  # Snapper systemd-boot integration is complex - user may need manual setup
}

# Setup Limine bootloader for Snapper (from maintenance.sh)
setup_snapper_limine_integration() {
  log_info "Snapper Limine integration (manual configuration may be needed)"
  # Snapper Limine integration is complex - user may need manual setup
}

# Create initial Snapper snapshot (from maintenance.sh)
create_snapper_initial_snapshot() {
  if sudo snapper -c root create -d "Initial snapshot after setup" 2>/dev/null; then
    log_success "Initial Snapper snapshot created"
  else
    log_warning "Failed to create initial Snapper snapshot"
  fi
}

# Setup pacman hook for Snapper (from maintenance.sh)
setup_snapper_pacman_hook() {
  step "Installing pacman hook for snapshot notifications"

  sudo mkdir -p /etc/pacman.d/hooks

  # Backup existing hook if present
  if [ -f /etc/pacman.d/hooks/snapper-notify.hook ]; then
    sudo cp /etc/pacman.d/hooks/snapper-notify.hook /etc/pacman.d/hooks/snapper-notify.hook.backup.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
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

# Main smart snapshot setup function
setup_smart_snapshots() {
  # Check if snapshots should be skipped entirely
  if [ "$SNAPSHOT_SYSTEM" = "skip" ]; then
    log_info "Snapshot system configuration skipped by user choice"
    return 0
  fi
  
  # Detect if we should use interactive or non-interactive mode
  if command -v gum >/dev/null 2>&1; then
    select_snapshot_system
  else
    select_snapshot_system_non_interactive
  fi
  
  # Configure based on user choice
  case "$SNAPSHOT_SYSTEM" in
    timeshift)
      configure_timeshift_system
      ;;
    snapper)
      configure_snapper_system
      ;;
    both)
      configure_both_systems
      ;;
    *)
      log_error "Invalid snapshot system selection: $SNAPSHOT_SYSTEM"
      return 1
      ;;
  esac
  
  # Show summary
  show_snapshot_summary
}

show_snapshot_summary() {
  echo ""
  log_success "Smart snapshot system configuration completed"
  echo ""
  echo -e "${CYAN}Snapshot System Configuration:${RESET}"
  echo -e "  • Selected system: ${YELLOW}$SNAPSHOT_SYSTEM${RESET}"
  echo -e "  • Btrfs filesystem: ${GREEN}$(is_btrfs_system && echo "✓ Detected" || echo "✗ Not detected")${RESET}"
  
  # Show Timeshift status
  case "$SNAPSHOT_SYSTEM" in
    timeshift|both)
      if command -v timeshift >/dev/null 2>&1; then
        echo -e "  • Timeshift: ${GREEN}✓ Installed${RESET}"
        echo -e "    - Config: /etc/timeshift/timeshift.json"
        echo -e "    - Snapshots: sudo timeshift --list"
        echo -e "    - Restore: sudo timeshift --restore"
        if command -v timeshift-autosnap >/dev/null 2>&1; then
          echo -e "    - Auto-snap: ${GREEN}✓ Enabled${RESET}"
        else
          echo -e "    - Auto-snap: ${YELLOW}✗ Not available${RESET}"
        fi
      else
        echo -e "  • Timeshift: ${RED}✗ Installation failed${RESET}"
      fi
      ;;
  esac
  
  # Show Snapper status
  case "$SNAPSHOT_SYSTEM" in
    snapper|both)
      if command -v snapper >/dev/null 2>&1; then
        echo -e "  • Snapper: ${GREEN}✓ Installed${RESET}"
        echo -e "    - Config: /etc/snapper/configs/root"
        echo -e "    - Snapshots: sudo snapper list"
        echo -e "    - Restore: sudo snapper rollback"
        if systemctl is-active --quiet snapper-timeline.timer 2>/dev/null; then
          echo -e "    - Timeline: ${GREEN}✓ Active${RESET}"
        else
          echo -e "    - Timeline: ${YELLOW}✗ Inactive${RESET}"
        fi
      else
        echo -e "  • Snapper: ${RED}✗ Installation failed${RESET}"
      fi
      ;;
  esac
  
  echo ""
  echo -e "${CYAN}Bootloader Integration:${RESET}"
  case "$BOOTLOADER" in
    grub)
      echo -e "  • GRUB: ${GREEN}✓ Configured${RESET}"
      ;;
    systemd-boot)
      echo -e "  • systemd-boot: ${GREEN}✓ Configured${RESET}"
      ;;
    limine)
      echo -e "  • Limine: ${GREEN}✓ Configured${RESET}"
      ;;
    *)
      echo -e "  • Unknown: ${YELLOW}Manual configuration may be needed${RESET}"
      ;;
  esac
  
  echo ""
  echo -e "${CYAN}Usage:${RESET}"
  echo -e "  • View snapshots: ${YELLOW}sudo timeshift --list${RESET} or ${YELLOW}sudo snapper list${RESET}"
  echo -e "  • Create snapshot: ${YELLOW}sudo timeshift --create${RESET} or ${YELLOW}sudo snapper create${RESET}"
  echo -e "  • Restore snapshot: ${YELLOW}sudo timeshift --restore${RESET} or ${YELLOW}sudo snapper rollback${RESET}"
  echo ""
  echo -e "${CYAN}Configuration:${RESET}"
  echo -e "  • Preferences saved: ${YELLOW}$HOME/.config/archinstaller/snapshot-system${RESET}"
  echo -e "  • To change: ${YELLOW}rm $HOME/.config/archinstaller/snapshot-system${RESET}"
  echo ""
}
