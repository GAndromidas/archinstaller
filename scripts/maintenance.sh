#!/bin/bash
set -uo pipefail

# Get directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

cleanup_and_optimize() {
  step "Performing final cleanup and optimizations"
  # Run fstrim in background (does not block other cleanup)
  if command_exists lsblk; then
    if lsblk -d -o rota | grep -q '^0$'; then
      sudo fstrim -v / >>"$INSTALL_LOG" 2>&1 &
      log_info "TRIM started in background"
    fi
  else
    log_warning "lsblk not available. Skipping SSD optimization."
  fi
  run_step "Cleaning /tmp directory" sudo find /tmp -mindepth 1 -maxdepth 1 \
    ! -path '/tmp/systemd-*' ! -path '/tmp/.X*' ! -path '/tmp/pulse-*' \
    ! -path '/tmp/archinstaller.log' ! -path '/tmp/archinstaller.state' \
    -exec rm -rf {} + 2>/dev/null || true
  # State/log live in /var/tmp (reboot-safe); clean stale legacy copies in /tmp
  # only when the live files exist, never the live files themselves.
  if [ -s /var/tmp/archinstaller.state ] || [ -s /var/tmp/archinstaller.log ]; then
    rm -f /tmp/archinstaller.log /tmp/archinstaller.state 2>/dev/null || true
  fi
}

setup_maintenance() {
  step "Performing comprehensive system cleanup"
  # Use paccache instead of pacman -Sc (keeps last 3 versions, safer for resume)
  run_step "Cleaning old pacman packages (keeping 3 versions)" sudo paccache -r
  run_step "Cleaning yay cache" yay -Sc --noconfirm 2>/dev/null || true

  # Flatpak cleanup - single call removes both unused packages and runtimes
  if command -v flatpak >/dev/null 2>&1; then
    run_step "Removing unused flatpak packages and runtimes" sudo flatpak uninstall --unused --noninteractive -y
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
