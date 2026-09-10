#!/bin/bash
# Post-reboot verification for archinstaller.
#
# Run this AFTER rebooting into the freshly installed system — it checks
# live, booted state (kernel params, loaded drivers, active services) that
# the install log genuinely cannot: the log only shows what happened during
# install, under installer-specific conditions (high load, no real boot
# cycle yet). This is what actually confirms the install worked, not just
# that commands were issued.
#
# Entirely read-only: no writes, no sudo actions beyond reading files that
# require it (e.g. ufw/fail2ban status). Safe to run any time, repeatedly.
#
# Usage: bash verify.sh [--verbose]

set -uo pipefail

VERBOSE=false
[[ "${1:-}" == "--verbose" || "${1:-}" == "-v" ]] && VERBOSE=true

if [ -t 1 ]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  BLUE='\033[0;34m'; MUTED='\033[0;2m'; BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; MUTED=''; BOLD=''; RESET=''
fi

PASS=0
WARN=0
FAIL=0

ok()   { printf "  ${GREEN}✓${RESET} %s\n" "$1"; PASS=$((PASS+1)); }
warn() { printf "  ${YELLOW}⚠${RESET} %s\n" "$1"; WARN=$((WARN+1)); }
bad()  { printf "  ${RED}✗${RESET} %s\n" "$1"; FAIL=$((FAIL+1)); }
info() { [[ "$VERBOSE" == true ]] && printf "  ${MUTED}·${RESET} %s\n" "$1"; }
section() { printf "\n${BOLD}${BLUE}── %s ──${RESET}\n" "$1"; }

section "Boot"

if [ -d /sys/firmware/efi ]; then
  ok "Booted via UEFI"
else
  warn "Booted via BIOS/legacy — expected on some systems, just noting it"
fi

cmdline=$(cat /proc/cmdline 2>/dev/null || echo "")
if [[ -n "$cmdline" ]]; then
  ok "Kernel command line is populated"
  info "cmdline: $cmdline"
  if [[ "$cmdline" != *"root="* ]]; then
    warn "No root= in /proc/cmdline — unusual, worth a second look if boot felt slow/odd"
  fi
else
  bad "Could not read /proc/cmdline"
fi

section "CPU & GPU drivers"

cpu_vendor="unknown"
grep -qi "GenuineIntel" /proc/cpuinfo 2>/dev/null && cpu_vendor="intel"
grep -qi "AuthenticAMD" /proc/cpuinfo 2>/dev/null && cpu_vendor="amd"
ok "CPU vendor: ${cpu_vendor}"

if [[ "$cpu_vendor" == "amd" ]] && [ -d /sys/devices/system/cpu/amd_pstate ]; then
  ok "amd_pstate driver active"
  scaling_driver=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null || echo "unknown")
  info "scaling_driver: $scaling_driver"
fi

if command -v lspci &>/dev/null; then
  gpu_lines=$(lspci -k 2>/dev/null | grep -A3 -iE 'vga|3d controller|display controller')
  if echo "$gpu_lines" | grep -qi "kernel driver in use"; then
    while IFS= read -r drv; do
      ok "GPU kernel driver in use: $drv"
    done < <(echo "$gpu_lines" | grep -i "kernel driver in use" | sed 's/.*: //' | sort -u)
  else
    warn "No GPU kernel driver reported by lspci -k — may still be fine (e.g. modesetting needs no listed driver on some setups)"
  fi
else
  info "lspci not available, skipping GPU driver check"
fi

section "Storage"

if command -v lsblk &>/dev/null; then
  while IFS= read -r dev; do
    [[ -z "$dev" ]] && continue
    sched_file="/sys/block/$dev/queue/scheduler"
    if [[ -r "$sched_file" ]]; then
      active=$(grep -oE '\[[a-z-]+\]' "$sched_file" 2>/dev/null | tr -d '[]')
      ok "/dev/$dev I/O scheduler: ${active:-unknown}"
    fi
  done < <(lsblk -dn -o NAME 2>/dev/null | grep -vE '^(loop|sr|zram)')
fi

if grep -qE '^\S+\s+/\s+btrfs' /proc/mounts 2>/dev/null; then
  ok "Root filesystem: btrfs"
  if command -v snapper &>/dev/null; then
    snap_count=$(sudo snapper -c root list 2>/dev/null | awk 'NR>2 && $1 ~ /^[0-9]+$/ {count++} END {print count+0}')
    if sudo snapper -c root list &>/dev/null; then
      # Not requiring a separate /.snapshots mountpoint deliberately: for
      # the common single-subvolume layout it's just a nested subvolume
      # inside the already-mounted root filesystem, with no separate mount
      # at all — confirmed via a real install where `mountpoint -q` failed
      # this check yet snapper had successfully created 19 snapshots in
      # the same run. What actually matters is whether snapper works.
      ok "Snapper is working (${snap_count:-0} existing snapshots)"
    else
      bad "'sudo snapper -c root list' failed — snapshots are not working. Check 'sudo btrfs subvolume list /' and /etc/fstab."
    fi
  fi
elif grep -qE '^\S+\s+/\s+ext4' /proc/mounts 2>/dev/null; then
  ok "Root filesystem: ext4"
  if command -v tune2fs &>/dev/null; then
    root_dev=$(findmnt -n -o SOURCE / 2>/dev/null)
    reserved=$(sudo tune2fs -l "$root_dev" 2>/dev/null | awk -F': ' '/Reserved block count/{print $2}')
    info "Reserved blocks: ${reserved:-unknown}"
  fi
fi

section "Security"

if command -v ufw &>/dev/null; then
  if sudo ufw status 2>/dev/null | grep -q "^Status: active"; then
    ok "UFW is active"
  else
    bad "UFW is installed but not active"
  fi
elif command -v firewall-cmd &>/dev/null; then
  if sudo firewall-cmd --state 2>/dev/null | grep -q "running"; then
    ok "Firewalld is active"
  else
    bad "Firewalld is installed but not running"
  fi
else
  warn "No firewall found (ufw/firewalld)"
fi

if systemctl is-active --quiet fail2ban 2>/dev/null; then
  jails=$(sudo fail2ban-client status 2>/dev/null | grep "Jail list" | sed 's/.*://;s/,/ /g; s/^[[:space:]]*//')
  if [[ -n "$jails" ]]; then
    ok "fail2ban active, jails: $jails"
    if echo "$jails" | grep -qw sshd; then
      ok "sshd jail is active"
    else
      bad "sshd jail is NOT in the active jail list — SSH is not protected"
    fi
  else
    bad "fail2ban is running but reports zero active jails — check 'sudo fail2ban-client status' and /etc/fail2ban/jail.local"
  fi
elif systemctl list-unit-files fail2ban.service &>/dev/null; then
  bad "fail2ban is installed but not running"
else
  info "fail2ban not installed — skipping"
fi

section "Networking"

if command -v ethtool &>/dev/null; then
  wol_checked=false
  for iface in /sys/class/net/*; do
    ifname=$(basename "$iface")
    [[ "$ifname" == "lo" ]] && continue
    [[ -d "$iface/wireless" ]] && continue
    if ethtool "$ifname" 2>/dev/null | grep -q "Supports Wake-on"; then
      wol_checked=true
      wol_now=$(ethtool "$ifname" 2>/dev/null | awk -F': ' '/Wake-on/{print $2; exit}')
      if [[ "$wol_now" == "g" ]]; then
        ok "Wake-on-LAN enabled on $ifname (Wake-on: g)"
      else
        warn "$ifname supports Wake-on-LAN but it's currently '$wol_now', not 'g' — check the wol-$ifname.service / udev rule"
      fi
    fi
  done
  [[ "$wol_checked" == false ]] && info "No Wake-on-LAN-capable wired interface found — expected on laptops/Wi-Fi-only systems"
else
  info "ethtool not available, skipping Wake-on-LAN check"
fi

section "Shell & tools"

current_shell=$(getent passwd "${USER:-$(whoami)}" 2>/dev/null | cut -d: -f7)
if [[ "$current_shell" == *zsh* ]]; then
  ok "Default shell is zsh"
else
  warn "Default shell is '$current_shell', not zsh — log out and back in if you just installed, or check 'chsh -l'"
fi
if command -v starship &>/dev/null; then ok "Starship prompt installed"; else warn "Starship not found"; fi

if command -v yay &>/dev/null; then
  ok "yay (AUR helper) installed"
else
  warn "yay not found"
fi

if pacman -Q steam &>/dev/null || pacman -Q gamemode &>/dev/null; then
  section "Gaming"
  if command -v gamemoded &>/dev/null; then ok "GameMode installed"; else warn "gamemode package present but gamemoded not found"; fi
  pacman -Q steam &>/dev/null && ok "Steam installed"
  pacman -Q lib32-vulkan-icd-loader &>/dev/null && ok "32-bit Vulkan loader present (multilib working)"
fi

echo ""
printf "${BOLD}── Summary: ${GREEN}%d passed${RESET}${BOLD}, ${YELLOW}%d warnings${RESET}${BOLD}, ${RED}%d failed${RESET}${BOLD} ──${RESET}\n" "$PASS" "$WARN" "$FAIL"
echo ""
if [[ "$FAIL" -gt 0 ]]; then
  echo "Some checks failed — worth investigating before considering this a clean install."
  exit 1
elif [[ "$WARN" -gt 0 ]]; then
  echo "No failures, but a few things worth a look above."
  exit 0
else
  echo "Everything checked out."
  exit 0
fi
