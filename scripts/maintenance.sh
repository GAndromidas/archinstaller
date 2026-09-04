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

cleanup_snapper_snapshots() {
  # Clean snapper snapshots to leave system without snapshots after archinstaller (as requested)
  # Robust for 700 /boot, btrfs only, snapper present
  if ! is_btrfs_system 2>/dev/null; then
    return 0
  fi
  if ! pacman -Q snapper &>/dev/null 2>&1 && ! command -v snapper &>/dev/null; then
    return 0
  fi
  local snap_count
  snap_count=$(sudo snapper -c root list 2>/dev/null | awk 'NR>2 && $1 ~ /^[0-9]+$/ {print $1}' | wc -l)
  snap_count=$(echo "$snap_count" | tr -d ' ')
  if [[ -z "$snap_count" || "$snap_count" -eq 0 ]]; then
    log_info "No snapper snapshots to clean"
    return 0
  fi
  log_info "Cleaning $snap_count snapper snapshot(s) for clean post-install (no snapshots)"
  # Delete via snapper (updates DB) - batch delete if possible
  local ids
  ids=$(sudo snapper -c root list 2>/dev/null | awk 'NR>2 && $1 ~ /^[0-9]+$/ {print $1}' | tr '\n' ' ')
  if [[ -n "$ids" ]]; then
    # Try batch delete first (faster)
    if ! sudo snapper -c root delete $ids >>"$INSTALL_LOG" 2>&1; then
      # Fallback: delete one by one (handles busy snapshots)
      for id in $ids; do
        sudo snapper -c root delete "$id" >>"$INSTALL_LOG" 2>&1 || sudo btrfs subvolume delete "/.snapshots/$id/snapshot" 2>/dev/null || true
      done
    fi
    log_success "Cleaned snapper snapshots - system now without snapshots"
  fi
  # Cleanup any orphaned btrfs subvolumes under /.snapshots not tracked by snapper
  local orphans
  orphans=$(sudo btrfs subvolume list -o /.snapshots 2>/dev/null | awk '{print $NF}' || true)
  if [[ -n "$orphans" ]]; then
    echo "$orphans" | while read -r sv; do
      [[ -n "$sv" ]] || continue
      # Only delete if not tracked (snapper list doesn't contain the ID)
      local sid=$(basename "$(dirname "$sv")" 2>/dev/null || echo "")
      if ! echo "$ids" | grep -qw "$sid" 2>/dev/null; then
        sudo btrfs subvolume delete "/$sv" 2>/dev/null || true
      fi
    done
  fi
  # Also clean limine-snapper-sync history if present (bloated limine.conf //Snapshots already kept, but history subvols)
  if sudo test -d "/.snapshots" 2>/dev/null; then
    # Ensure /.snapshots is still a valid btrfs subvolume mount
    mountpoint -q /.snapshots 2>/dev/null || sudo mount -a 2>/dev/null || true
  fi
}

cleanup_script_backups() {
  # Remove .backup files the script created - only if no failures before maintenance
  # Keeps them for debugging if any step failed (STATE_FILE contains FAILED:)
  if [ -f "$STATE_FILE" ] && grep -q "^FAILED:" "$STATE_FILE" 2>/dev/null; then
    log_warning "Previous failures detected - keeping .backup files for debugging"
    log_info "Backups kept in /var/tmp/archinstaller_backups and *.backup.*"
    return 0
  fi

  local removed=0

  # Backups via validate_config_file -> /var/tmp/archinstaller_backups
  if [ -d /var/tmp/archinstaller_backups ]; then
    local count
    count=$(find /var/tmp/archinstaller_backups -type f -name "*.backup.*" 2>/dev/null | wc -l)
    if [ "$count" -gt 0 ]; then
      sudo rm -rf /var/tmp/archinstaller_backups 2>/dev/null || rm -rf /var/tmp/archinstaller_backups 2>/dev/null || true
      log_success "Removed $count backup(s) from /var/tmp/archinstaller_backups"
      removed=$((removed + count))
    fi
  fi

  # Kernel cmdline / GRUB / limine backups (privileged, 700 /boot)
  local conf
  for conf in /etc/kernel/cmdline.backup.* /etc/default/grub.backup.* /etc/kernel/cmdline.backup.* ; do
    for f in $conf; do
      [ -e "$f" ] || continue
      sudo rm -f "$f" 2>/dev/null || rm -f "$f" 2>/dev/null || true
      log_info "Removed backup $f"
      removed=$((removed + 1))
    done
  done

  # Limine / loader backups under /boot (sudo for 700)
  local limine_baks
  limine_baks=$(sudo find /boot -type f -name "*.backup.*" 2>/dev/null || true)
  if [ -n "$limine_baks" ]; then
    echo "$limine_baks" | while read -r f; do
      [ -n "$f" ] || continue
      sudo rm -f "$f" 2>/dev/null || true
      log_info "Removed backup $f"
    done
    local cnt=$(echo "$limine_baks" | wc -l)
    removed=$((removed + cnt))
  fi
  # Also check /efi and /boot/efi if separate ESP
  for esp in /efi /boot/efi; do
    if sudo test -d "$esp" 2>/dev/null; then
      local ebaks
      ebaks=$(sudo find "$esp" -type f -name "*.backup.*" 2>/dev/null || true)
      if [ -n "$ebaks" ]; then
        echo "$ebaks" | while read -r f; do sudo rm -f "$f" 2>/dev/null || true; log_info "Removed backup $f"; done
      fi
    fi
  done

  # User shell backups (.zshrc, starship.toml) - current user and root
  for home in "$HOME" /root /home/*; do
    [ -d "$home" ] || continue
    for bak in "$home/.zshrc.backup."* "$home/.config/starship.toml.backup."* "$home/.zshrc.backup"*; do
      [ -e "$bak" ] || continue
      rm -f "$bak" 2>/dev/null || sudo rm -f "$bak" 2>/dev/null || true
      log_info "Removed backup $bak"
      removed=$((removed + 1))
    done
  done

  if [ "$removed" -gt 0 ]; then
    log_success "Cleaned $removed script-created .backup file(s) - maintenance done, no failures"
  else
    log_info "No script-created .backup files to clean"
  fi
}

# Execute all maintenance steps
cleanup_and_optimize
setup_maintenance
cleanup_helpers
run_step "Cleaning snapper snapshots (clean post-install without snapshots)" cleanup_snapper_snapshots
run_step "Cleaning script-created .backup files" cleanup_script_backups

# Final message
echo ""
log_success "Maintenance and optimization completed"
log_info "System is ready for use"
