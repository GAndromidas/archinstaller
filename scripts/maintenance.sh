#!/bin/bash
set -uo pipefail

# Get directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
source "$SCRIPT_DIR/snapshots.sh"

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
  
  log_info "Btrfs filesystem detected - configuring smart snapshot system"
  
  # Show what's being configured
  echo ""
  echo -e "${CYAN}Smart Snapshot System Configuration:${RESET}"
  echo -e "  • Interactive selection: Timeshift, Snapper, both, or skip"
  echo -e "  • Timeshift: 1 daily + 1 boot snapshot + pre-update autosnap"
  echo -e "  • Snapper: Boot snapshots only (max 10) + cleanup timers"
  echo -e "  • Bootloader integration: GRUB, systemd-boot, Limine"
  echo -e "  • Automated maintenance: scrub (monthly), balance (weekly), defrag (weekly)"
  echo -e "  • GUI management: btrfs-assistant for both systems"
  echo ""

  # Detect bootloader
  BOOTLOADER=$(detect_bootloader)
  
  # Debug: Show detection reasoning
  if [ "$BOOTLOADER" = "limine" ]; then
    log_info "Limine detection: Found /boot/limine.conf or /boot/limine directory or limine package"
  elif [ "$BOOTLOADER" = "systemd-boot" ]; then
    log_info "systemd-boot detection: Found /boot/loader/entries or /boot/loader/loader.conf"
  elif [ "$BOOTLOADER" = "grub" ]; then
    log_info "GRUB detection: Found /boot/grub or grub package"
  fi

  # Use smart snapshot system
  setup_smart_snapshots || { log_error "Smart snapshot setup failed"; return 1; }
  
  # Display current snapshots
  echo ""
  log_info "Current snapshots:"
  sudo snapper list 2>/dev/null || echo "  (No snapshots yet)"
  echo ""

  # Summary
  log_success "Btrfs snapshot setup completed successfully!"
  echo ""
  echo -e "${CYAN}Snapshot system configured:${RESET}"
  echo -e "  • Smart selection: Timeshift, Snapper, both, or skip"
  echo -e "  • Timeshift: 1 daily + 1 boot snapshot + pre-update autosnap"
  echo -e "  • Snapper: Boot snapshots only (max 10) + cleanup timers"
  echo -e "  • Bootloader integration: GRUB, systemd-boot, Limine"
  echo -e "  • Automated maintenance: scrub (monthly), balance (weekly), defrag (weekly)"
  echo -e "  • GUI management: btrfs-assistant for both systems"
  echo ""
  echo -e "${CYAN}How to use:${RESET}"
  echo -e "  • View snapshots: ${YELLOW}sudo timeshift --list${RESET} or ${YELLOW}sudo snapper list${RESET}"
  echo -e "  • Create snapshot: ${YELLOW}sudo timeshift --create${RESET} or ${YELLOW}sudo snapper create${RESET}"
  echo -e "  • Restore snapshot: ${YELLOW}sudo timeshift --restore${RESET} or ${YELLOW}sudo snapper rollback${RESET}"
  echo -e "  • Check maintenance timers: ${YELLOW}systemctl list-timers 'btrfs-*'${RESET}"
  echo -e "  • View maintenance config: ${YELLOW}cat /etc/default/btrfsmaintenance${RESET}"
  echo -e "  • Snapshots stored in: ${YELLOW}/.snapshots/ or ${YELLOW}/timeshift-btrfs/${RESET}"
  echo ""
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
