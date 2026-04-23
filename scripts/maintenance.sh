#!/bin/bash
set -uo pipefail

# Get directory where this script is located
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

# Execute all maintenance steps
cleanup_and_optimize
setup_maintenance
cleanup_helpers

# Final message
echo ""
log_success "Maintenance and optimization completed"
log_info "System is ready for use"
