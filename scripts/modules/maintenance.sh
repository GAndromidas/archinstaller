#!/bin/bash
set -uo pipefail

# Get directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

if [[ "${DRY_RUN:-false}" == true ]]; then
  ui_info "Dry-run: Maintenance and cleanup would run here."
  exit 0
fi

cleanup_and_optimize() {
  step "Performing final cleanup and optimizations"
  enable_trim_timer || true
  # Do not recursively purge /tmp — other running processes (X11 sockets,
  # PulseAudio, systemd) keep live state there and a broad purge risks
  # stepping on them. Only remove this installer's own legacy files.
  rm -f /tmp/archinstaller.log /tmp/archinstaller.state 2>/dev/null || true
}

# Periodic TRIM via the native systemd timer (weekly, standard practice)
# instead of a single one-shot fstrim right after install — but also runs
# one immediate trim so the benefit isn't delayed a full week on first boot.
enable_trim_timer() {
  if ! command_exists systemctl; then
    log_warning "systemctl unavailable; cannot enable fstrim.timer"
    return 1
  fi
  if sudo systemctl enable --now fstrim.timer >>"$INSTALL_LOG" 2>&1; then
    log_success "Enabled systemd fstrim.timer for periodic TRIM"
    sudo systemctl start fstrim.service >>"$INSTALL_LOG" 2>&1 || true
    return 0
  fi
  log_warning "Could not enable fstrim.timer; leaving existing TRIM configuration unchanged"
  return 1
}

setup_maintenance() {
  step "Performing comprehensive system cleanup"
  # Use paccache instead of pacman -Sc (keeps last 3 versions, safer for resume)
  run_step "Cleaning old pacman packages (keeping 3 versions)" sudo paccache -r
  # Leftover partial-download temp files (pacman's in-progress download
  # names before a package is fully verified/renamed) can accumulate from
  # transient network blips during a long install and confuse later cache
  # cleaning ("could not open file ... Error reading fd 8"). Harmless to
  # remove — these are never valid packages.
  sudo find /var/cache/pacman/pkg -maxdepth 1 -name 'download-*' -delete 2>/dev/null || true
  run_step "Cleaning yay cache" yay -Sc --noconfirm 2>/dev/null || true

  # Flatpak cleanup - single call removes both unused packages and runtimes
  if command -v flatpak >/dev/null 2>&1; then
    run_step "Removing unused flatpak packages and runtimes" sudo flatpak uninstall --unused --noninteractive -y
    log_success "Flatpak cleanup completed"
  else
    log_info "Flatpak not installed, skipping flatpak cleanup"
  fi

  # Remove orphaned packages if any exist. mapfile preserves all lines —
  # a plain `read` would only take the first line and silently drop the rest.
  local orphans
  orphans=$(pacman -Qtdq 2>/dev/null || true)
  if [[ -n "$orphans" ]]; then
    local orphan_packages=()
    mapfile -t orphan_packages <<< "$orphans"
    if [[ ${#orphan_packages[@]} -gt 0 ]]; then
      run_step "Removing orphaned packages" sudo pacman -Rns --noconfirm "${orphan_packages[@]}"
    else
      log_info "No orphaned packages found"
    fi
  else
    log_info "No orphaned packages found"
  fi

  # Safety net: yay.sh (as of this version) never installs yay-debug in the
  # first place — it builds with `makepkg -s` and installs only the real
  # package tarball. This check only matters for a system that had
  # yay-debug installed by an older version of the script.
  if pacman -Q yay-debug &>/dev/null; then
    run_step "Removing yay-debug package" sudo pacman -Rns --noconfirm yay-debug
  fi
}

cleanup_helpers() {
  # yay.sh builds in /tmp/archinstaller-yay-build.* and cleans up after
  # itself on success. This is a safety net for the one case it can't
  # handle itself: the build process being killed (crash, power loss)
  # before its own cleanup trap runs. Glob-scoped to our distinctive
  # prefix, never a bare /tmp/yay (that path is never actually created —
  # matching it against reality, not a guess) and never a bare /tmp/tmp.*
  # (would risk deleting unrelated processes' temp dirs).
  # shellcheck disable=SC2016
  # single quotes intentional: expression runs in inner bash -c, not here
  run_step "Cleaning leftover yay build directories" bash -c \
    'shopt -s nullglob; dirs=(/tmp/archinstaller-yay-build.*); [ ${#dirs[@]} -eq 0 ] || sudo rm -rf "${dirs[@]}"'

}

cleanup_snapper_snapshots() {
  # Never delete snapshots automatically — they may predate archinstaller
  # and be the user's only recovery path if something goes wrong. This
  # just reports the current count.
  if ! command -v snapper &>/dev/null || ! is_btrfs_system 2>/dev/null; then
    return 0
  fi
  local snap_count
  snap_count=$(sudo snapper -c root list 2>/dev/null | awk 'NR>2 && $1 ~ /^[0-9]+$/ {count++} END {print count+0}')
  log_info "Existing Snapper snapshots: $snap_count (preserved)"
  return 0
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
run_step "Checking snapper snapshots" cleanup_snapper_snapshots
run_step "Cleaning script-created .backup files" cleanup_script_backups

# Final message
echo ""
log_success "Maintenance and optimization completed"
log_info "System is ready for use"
