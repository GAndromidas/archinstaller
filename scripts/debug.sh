#!/bin/bash
set -uo pipefail
# archinstaller debug / verify - run in VM after install to check job correctness
# or run with --lint to check scripts themselves for 700 /boot, snapper, etc.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh" 2>/dev/null || {
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RESET='\033[0m'
  log_info() { echo -e "${GREEN}[INFO]${RESET} $*"; }
  log_success() { echo -e "${GREEN}[OK]${RESET} $*"; }
  log_warning() { echo -e "${YELLOW}[WARN]${RESET} $*"; }
  log_error() { echo -e "${RED}[ERR]${RESET} $*"; }
}

PASS=0; FAIL=0; WARN=0
check_pass() { echo -e "  \033[0;32m✓ $1\033[0m"; PASS=$((PASS+1)); }
check_fail() { echo -e "  \033[0;31m✗ $1\033[0m"; FAIL=$((FAIL+1)); }
check_warn() { echo -e "  \033[1;33m⚠ $1\033[0m"; WARN=$((WARN+1)); }

lint_scripts() {
  echo "=== Lint: bash -n + 700 /boot + snapper ==="
  local f failed=0
  for f in "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR"/lib/*.sh; do
    if ! bash -n "$f" 2>&1; then
      check_fail "syntax $f"
      failed=1
    else
      check_pass "syntax $(basename "$f")"
    fi
  done
  # Bare /boot checks (should be sudo) - exclude comments and this debug script's own grep
  local bare_boot
  bare_boot=$(rg -n "\[ -f /boot|\[ -d /boot|\[\[ -f /boot|\[\[ -d /boot" --glob '*.sh' "$SCRIPT_DIR" 2>&1 | grep -v "sudo test" | grep "/boot" | grep -v "debug.sh" | grep -v "# " | grep -v "#.*\[ -f" || true)
  if [[ -n "$bare_boot" ]]; then
    check_fail "bare [ -f /boot without sudo still present"
    echo "$bare_boot" | sed 's/^/    /'
  else
    check_pass "no bare /boot [ -f without sudo (700 OK)"
  fi
  # snapper QUARTERLY present - single source in common.sh is correct (deduplicated)
  if grep -q "TIMELINE_LIMIT_QUARTERLY" "$SCRIPT_DIR/common.sh" 2>/dev/null; then
    check_pass "snapper QUARTERLY handled (single source common.sh)"
  else
    check_fail "QUARTERLY missing in common.sh"
  fi
  # Check dated entry handling
  if grep -q "Dated archinstall entry detected" "$SCRIPT_DIR/bootloader_config.sh"; then
    check_pass "dated systemd-boot smart handling present"
  else
    check_fail "dated handling missing"
  fi
  # Check privileged_write
  if grep -q "privileged_write" "$SCRIPT_DIR/common.sh" && grep -q "privileged_write" "$SCRIPT_DIR/bootloader_config.sh"; then
    check_pass "privileged_write 700 handling present"
  else
    check_warn "privileged_write not fully wired"
  fi
  [[ $failed -eq 0 ]] || return 1
}

verify_install() {
  echo "=== Verify: post-install checks (VM) ==="
  echo "-- Bootloader --"
  local bl
  bl=$(detect_bootloader 2>/dev/null || echo "unknown")
  echo "  bootloader: $bl"
  if [[ "$bl" == "systemd-boot" ]]; then
    if sudo test -f /boot/loader/loader.conf 2>/dev/null; then
      check_pass "loader.conf exists (sudo, 700 OK)"
      sudo grep -q "^timeout 3" /boot/loader/loader.conf 2>/dev/null && check_pass "timeout 3" || check_fail "timeout 3 missing"
      sudo grep -q "^console-mode max" /boot/loader/loader.conf 2>/dev/null && check_pass "console-mode max" || check_fail "console-mode max missing (was #console-mode keep)"
    else
      # Check via privileged helper
      if sudo ls /boot/loader/ 2>&1 | grep -q loader.conf; then check_warn "loader.conf sudo ls found but sudo test -f failed"; else check_fail "loader.conf not found (700?)"; fi
    fi
    local entries_dir
    entries_dir=$(find_systemd_boot_entries_dir 2>/dev/null || echo "")
    if [[ -n "$entries_dir" ]]; then
      local entries
      entries=$(sudo find "$entries_dir" -maxdepth 1 -name "*.conf" ! -name "*fallback*" 2>/dev/null | tr '\n' ' ')
      echo "  entries: $entries"
      # Check dated handling
      local dated
      dated=$(sudo find "$entries_dir" -name "*[0-9][0-9][0-9][0-9]-*_*.conf" 2>/dev/null || true)
      if [[ -n "$dated" ]]; then
        echo "  dated entries: $dated"
        # Check that dated entry has managed params (e.g. amd_pstate if AMD)
        local opts
        opts=$(sudo grep "^options " "$dated" 2>/dev/null | head -n1 || true)
        if echo "$opts" | grep -q "root="; then check_pass "dated entry has root="; else check_fail "dated entry missing root="; fi
        if ls /sys/devices/system/cpu/amd_pstate &>/dev/null; then
          echo "$opts" | grep -q "amd_pstate" && check_pass "amd_pstate=active in dated entry" || check_warn "amd_pstate not in dated entry (may be UKI, check /etc/kernel/cmdline)"
        fi
      else
        check_pass "no dated entries (already renamed to linux.conf or UKI)"
      fi
      # Check cmdline consistency if UKI
      if is_uki_system 2>/dev/null; then
        echo "  UKI system - checking /etc/kernel/cmdline"
        sudo test -f /etc/kernel/cmdline 2>/dev/null && check_pass "/etc/kernel/cmdline exists" || check_fail "UKI but no /etc/kernel/cmdline"
        sudo cat /etc/kernel/cmdline 2>/dev/null | grep -q "root=" && check_pass "UKI cmdline has root=" || check_fail "UKI cmdline rootless"
        sudo cat /proc/cmdline 2>/dev/null | grep -q "amd_pstate" && log_info "  cmdline has amd_pstate (AMD)" || true
      fi
    else
      check_warn "no systemd-boot entries dir found"
    fi
  elif [[ "$bl" == "grub" ]]; then
    grep -q 'GRUB_TIMEOUT="3"' /etc/default/grub 2>/dev/null && check_pass "GRUB_TIMEOUT 3" || check_fail "GRUB_TIMEOUT not 3"
  elif [[ "$bl" == "limine" ]]; then
    local esp
    esp=$(findmnt -n -o TARGET -t vfat 2>/dev/null | head -1 || findmnt -n -o TARGET /boot 2>/dev/null || echo "/boot")
    local lconf
    lconf=$(sudo find "$esp" /boot -name "limine.conf" 2>/dev/null | head -1 || echo "")
    if [[ -n "$lconf" ]] && sudo test -f "$lconf" 2>/dev/null; then
      check_pass "limine.conf found: $lconf"
      sudo grep -q "interface_branding: Arch Linux" "$lconf" 2>/dev/null && check_pass "Limine theme Arch Linux" || check_fail "Limine theme not applied"
      sudo grep -q "term_palette:" "$lconf" 2>/dev/null && check_pass "Limine term_palette present" || check_fail "Limine palette missing"
      if sudo test -f "$esp/background.png" 2>/dev/null || sudo test -f "/boot/background.png" 2>/dev/null; then
        check_pass "Limine wallpaper background.png on ESP"
      else
        check_warn "Limine wallpaper not found on ESP (color-only theme OK)"
      fi
      sudo grep -q "wallpaper: boot" "$lconf" 2>/dev/null && check_pass "Limine wallpaper: boot(): entry present" || check_warn "Limine wallpaper line missing (color-only OK)"
    else
      check_fail "limine.conf not found"
    fi
  else
    check_warn "unknown bootloader $bl"
  fi

  echo "-- Snapper / Btrfs-Assistant --"
  if is_btrfs_system 2>/dev/null; then
    check_pass "btrfs root"
    if pacman -Q snapper &>/dev/null 2>&1 || command -v snapper &>/dev/null; then
      check_pass "snapper installed"
      if [[ -f /etc/snapper/configs/root ]]; then
        sudo grep -q 'TIMELINE_LIMIT_DAILY="1"' /etc/snapper/configs/root 2>/dev/null && check_pass "TIMELINE_LIMIT_DAILY 1" || check_fail "TIMELINE DAILY not 1"
        sudo grep -q 'TIMELINE_LIMIT_QUARTERLY="0"' /etc/snapper/configs/root 2>/dev/null && check_pass "QUARTERLY 0" || check_fail "QUARTERLY not 0 (btrfs-assistant stale)"
        sudo grep -q 'NUMBER_LIMIT="8"' /etc/snapper/configs/root 2>/dev/null && check_pass 'NUMBER_LIMIT 8' || check_fail 'NUMBER_LIMIT not 8 (was 50)'
        sudo grep -q 'TIMELINE_LIMIT_HOURLY="0"' /etc/snapper/configs/root 2>/dev/null && check_pass "HOURLY 0" || check_warn "HOURLY not 0"
      else
        check_warn "no /etc/snapper/configs/root (snapper not configured)"
      fi
      pacman -Q snap-pac &>/dev/null && check_pass "snap-pac installed" || check_warn "snap-pac not installed"
      pacman -Q btrfs-assistant &>/dev/null && check_pass "btrfs-assistant installed" || check_warn "btrfs-assistant not installed (headless maybe OK)"
      systemctl is-active --quiet snapper-timeline.timer 2>/dev/null && check_pass "snapper-timeline.timer active" || check_warn "snapper-timeline.timer not active"
      systemctl is-active --quiet snapper-cleanup.timer 2>/dev/null && check_pass "snapper-cleanup.timer active" || check_warn "snapper-cleanup.timer not active"
      systemctl is-active --quiet snapper-boot.timer 2>/dev/null && check_pass "snapper-boot.timer active" || check_warn "snapper-boot.timer not active (fallback snapper-boot-snapshot.service?)"
      local snap_cnt
      snap_cnt=$(sudo snapper -c root list 2>/dev/null | awk 'NR>2' | wc -l | tr -d ' ')
      echo "  snapshots: $snap_cnt (should be 0 after maintenance clean, or <=8)"
      if [[ "$snap_cnt" -eq 0 ]]; then check_pass "no snapshots (clean post-install)"; elif [[ "$snap_cnt" -le 8 ]]; then check_pass "snapshots <=8 (Number limit)"; else check_warn "snapshots $snap_cnt >8 (cleanup not yet run)"; fi
    else
      check_warn "snapper not installed (btrfs but no snapper - optional)"
    fi
  else
    check_pass "not btrfs (ext4) - snapper not needed"
  fi

  echo "-- Services / Firewall --"
  systemctl is-active --quiet cronie.service 2>/dev/null && check_pass "cronie active" || check_fail "cronie not active"
  systemctl is-active --quiet fstrim.timer 2>/dev/null && check_pass "fstrim.timer active" || check_warn "fstrim.timer not active"
  if command -v ufw &>/dev/null; then
    sudo ufw status 2>/dev/null | grep -q "Status: active" && check_pass "UFW active" || check_fail "UFW not active"
    sudo ufw status 2>/dev/null | grep -qE "22/tcp|22\s|OpenSSH" && check_pass "UFW ssh allowed" || check_warn "UFW ssh not allowed (try: sudo ufw allow 22/tcp && sudo ufw allow OpenSSH)"
  elif systemctl is-active --quiet firewalld 2>/dev/null; then
    check_pass "firewalld active"
  else
    check_warn "no firewall active"
  fi
  if pacman -Q portainer &>/dev/null 2>&1 || sudo docker ps -a 2>/dev/null | grep -q portainer; then
    sudo ufw status 2>/dev/null | grep -q "8000" && check_pass "Portainer UFW 8000" || check_warn "Portainer UFW 8000 not open (deferred?)"
  fi

  echo "-- System --"
  pacman -Q amd-ucode &>/dev/null || pacman -Q intel-ucode &>/dev/null && check_pass "microcode installed" || check_warn "microcode not installed"
  pacman -Q linux-headers &>/dev/null && check_pass "linux-headers installed" || check_warn "headers missing"
  [[ -f /etc/kernel/cmdline ]] && sudo cat /etc/kernel/cmdline 2>/dev/null | grep -q "quiet" && check_pass "/etc/kernel/cmdline has quiet" || true
  # Maintenance backups should be cleaned
  if [[ -d /var/tmp/archinstaller_backups ]]; then check_warn "archinstaller_backups still exists (failures kept?)"; else check_pass "no stale archinstaller_backups"; fi
  local bak_cnt
  bak_cnt=$(sudo find /boot -name "*.backup.*" 2>/dev/null | wc -l | tr -d ' ')
  [[ "$bak_cnt" -eq 0 ]] && check_pass "no .backup in /boot" || check_warn "$bak_cnt .backup in /boot (kept for debugging?)"
  bak_cnt=$(find "$HOME" -maxdepth 2 -name "*.backup.*" 2>/dev/null | wc -l | tr -d ' ')
  [[ "$bak_cnt" -eq 0 ]] && check_pass "no .backup in HOME" || check_warn "$bak_cnt .backup in HOME"

  echo ""
  echo "Summary: $PASS pass, $WARN warn, $FAIL fail"
  if [[ $FAIL -eq 0 ]]; then
    echo -e "\033[0;32mAll critical checks passed - archinstaller job correct\033[0m"
    return 0
  else
    echo -e "\033[0;31m$FAIL critical failures - check log /var/tmp/archinstaller.log\033[0m"
    return 1
  fi
}

case "${1:-verify}" in
  --lint|lint) lint_scripts ;;
  --verify|verify) verify_install ;;
  *) echo "Usage: $0 [--lint|--verify]"; echo "  --lint   check scripts for 700/btrfs bugs"; echo "  --verify run in VM after install"; verify_install ;;
esac
