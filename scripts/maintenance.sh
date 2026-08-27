#!/bin/bash
set -euo pipefail

# Ensure HOME is set before any path resolution
: "${HOME:=/root}"
export HOME

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
  # Age-safe /tmp cleanup: keep live session sockets intact (X11, Wayland,
  # ICE, dbus, pulse) by only removing files older than 2 days.
  run_step "Cleaning old files from /tmp" sudo find /tmp -mindepth 1 -maxdepth 1 -mtime +2 -exec rm -rf {} + 2>/dev/null || true
  run_step "Syncing disk writes" sync
}

setup_maintenance() {
  step "Performing comprehensive system cleanup"
  # paccache keeps the last 2 versions (incl. current) — pacman -Sc purges
  # everything except the installed version, leaving no rollback option
  if command -v paccache >/dev/null 2>&1; then
    run_step "Cleaning pacman cache (keep 2 versions)" sudo paccache -rk2
  else
    run_step "Cleaning pacman cache" sudo pacman -Sc --noconfirm
  fi
  run_step "Cleaning yay cache" yay -Sc --noconfirm

  # Flatpak cleanup - remove unused packages and runtimes
  if command -v flatpak >/dev/null 2>&1; then
    run_step "Removing unused flatpak packages" sudo flatpak uninstall --unused --noninteractive -y
    run_step "Removing unused flatpak runtimes" sudo flatpak uninstall --unused --noninteractive -y
    log_success "Flatpak cleanup completed"
  else
    log_info "Flatpak not installed, skipping flatpak cleanup"
  fi

  # Remove orphaned packages if any exist (safely handle empty list)
  local orphans
  orphans=$(pacman -Qtdq 2>/dev/null) || true
  if [[ -n "$orphans" ]]; then
    # shellcheck disable=SC2086
    run_step "Removing orphaned packages" sudo pacman -Rns --noconfirm $orphans
  else
    log_info "No orphaned packages found"
  fi

  # Only attempt to remove yay-debug if it's actually installed
  if pacman -Q yay-debug &>/dev/null; then
    run_step "Removing yay-debug package" sudo pacman -Rns --noconfirm yay-debug
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
