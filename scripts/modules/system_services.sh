#!/bin/bash
set -uo pipefail

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

setup_firewall_and_services() {
  step "Setting up firewall and services"

  # First handle firewall setup - prefer firewalld if available, otherwise use UFW
  if [[ "$FIREWALL_PREFERENCE" = "firewalld" ]] || command -v firewalld >/dev/null 2>&1; then
    run_step "Configuring Firewalld" configure_firewalld
  else
    run_step "Configuring UFW" configure_ufw
  fi

  # Configure user groups
  run_step "Configuring user groups" configure_user_groups

  # Then handle services
  run_step "Enabling system services" enable_services

  # Safe SSH hardening (drop-in, verified, reload-only)
  run_step "Applying SSH hardening" harden_sshd

  # Plymouth theme/hooks/initramfs belong to archinstall — only the kernel
  # splash params (step 6) are managed here.
}

# Safe SSH hardening via a drop-in (settings live in sshd_config.d, so
# distro updates and user edits can't conflict). Only settings with zero
# lockout risk: root keeps key auth (prohibit-password), regular users and
# password auth are untouched, fail2ban already handles brute force.
# If the main sshd_config lost its `Include sshd_config.d/*.conf` line the
# drop-in is silently ignored — detected via `sshd -T`, repaired by
# restoring that single Include line (backup + validation + rollback).
# Every write is validated with `sshd -t`, and the daemon is reloaded
# (not restarted) so active sessions survive.
harden_sshd() {
  step "Applying safe SSH hardening"

  if ! command -v sshd &>/dev/null; then
    log_info "openssh not installed — skipping SSH hardening"
    return 0
  fi

  local dropin_dir="/etc/ssh/sshd_config.d"
  local dropin="$dropin_dir/10-archinstaller-hardening.conf"
  local created_by_us=false
  [[ -f "$dropin" ]] || created_by_us=true

  local want_permit="prohibit-password"
  local effective=""
  effective=$(sudo sshd -T 2>/dev/null | awk '$1=="permitrootlogin" {print $2; exit}' || true)
  if [[ "${effective,,}" == "${want_permit,,}" ]]; then
    log_info "SSH hardening already in effect (PermitRootLogin $effective) — nothing to do"
    return 0
  fi

  sudo mkdir -p "$dropin_dir" 2>/dev/null || true
  # Backup an existing drop-in we didn't create; ours is regenerated.
  if [[ "$created_by_us" == false ]]; then
    sudo cp "$dropin" "${dropin}.backup.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
  fi
  if ! printf '%s\n' \
    "# Managed by archinstaller — safe SSH hardening (drop-in, sshd_config untouched)" \
    "PermitRootLogin prohibit-password" \
    "MaxAuthTries 3" \
    "LoginGraceTime 60" \
    "MaxStartups 10:30:60" \
    "ClientAliveInterval 300" \
    "ClientAliveCountMax 2" | sudo tee "$dropin" >/dev/null; then
    log_warning "Failed to write $dropin — skipping SSH hardening"
    return 0
  fi

  # Arch's sshd_config ships `Include sshd_config.d/*.conf`; on a system
  # where it was removed the drop-in is silently ignored — detect that via
  # the effective config and repair it by restoring the Include line itself
  # (one line at the top, so drop-in values are first-obtained and win;
  # existing directives are untouched). Backup + sshd -t + rollback.
  if ! sudo sshd -t 2>&1 | tee -a "$INSTALL_LOG" >/dev/null; then
    log_warning "sshd config test failed after hardening — rolling back"
    if [[ "$created_by_us" == true ]]; then
      sudo rm -f "$dropin" 2>/dev/null || true
    fi
    return 0
  fi
  effective=$(sudo sshd -T 2>/dev/null | awk '$1=="permitrootlogin" {print $2; exit}' || true)
  if [[ "${effective,,}" != "${want_permit,,}" ]]; then
    log_warning "Drop-in ignored (no Include directive?) — restoring Include in sshd_config"
    if harden_sshd_restore_include; then
      effective=$(sudo sshd -T 2>/dev/null | awk '$1=="permitrootlogin" {print $2; exit}' || true)
    fi
  fi
  if [[ "${effective,,}" != "${want_permit,,}" ]]; then
    log_warning "SSH hardening still not in effect — leaving $dropin in place (check Include in /etc/ssh/sshd_config)"
    return 0
  fi

  if sudo systemctl reload sshd.service 2>&1 | tee -a "$INSTALL_LOG" >/dev/null; then
    log_success "SSH hardening applied and reloaded (root password login off, key auth unaffected)"
  else
    log_warning "Hardening written but sshd reload failed — takes effect on next restart"
  fi
}

# Restore the `Include sshd_config.d/*.conf` line at the top of the main
# sshd_config when it is missing (drop-in silently ignored otherwise).
# Idempotent: no-op when an active Include already exists. Backup +
# `sshd -t` validation with rollback on failure. Returns 0 when an active
# Include is in place afterwards, 1 otherwise.
harden_sshd_restore_include() {
  local main="/etc/ssh/sshd_config"
  if sudo grep -qE '^[[:space:]]*Include[[:space:]].*sshd_config\.d' "$main" 2>/dev/null; then
    log_info "Include for sshd_config.d already present in $main"
    return 0
  fi
  sudo cp "$main" "${main}.backup.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || {
    log_warning "Failed to back up $main — leaving sshd_config untouched"
    return 1
  }
  local tmp
  tmp=$(mktemp /tmp/sshd_config.XXXXXX) || return 1
  {
    echo "# Added by archinstaller — enables sshd_config.d drop-ins (managed)"
    echo "Include /etc/ssh/sshd_config.d/*.conf"
    echo ""
    sudo cat "$main" 2>/dev/null
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  if ! sudo cp "$tmp" "$main" 2>/dev/null; then
    log_warning "Failed to write $main — leaving sshd_config untouched"
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp"
  if sudo sshd -t 2>&1 | tee -a "$INSTALL_LOG" >/dev/null; then
    log_success "Restored Include in $main — drop-in is now active"
    return 0
  fi
  log_warning "sshd config test failed after Include restore — rolling back"
  local latest_backup
  latest_backup=$(ls -t "${main}.backup."* 2>/dev/null | head -1 || true)
  [[ -n "$latest_backup" ]] && sudo cp "$latest_backup" "$main" 2>/dev/null || true
  return 1
}

# Detect effective sshd port (sshd -T is authoritative, fallback to
# /etc/ssh/sshd_config, then 22). Used so firewall rules never lock out
# remote sessions on a custom port.
get_sshd_port() {  local port=""
  if command -v sshd &>/dev/null; then
    port=$(sudo sshd -T 2>/dev/null | awk '$1=="port" {print $2; exit}')
  fi
  if [[ ! "$port" =~ ^[0-9]+$ ]]; then
    port=$(sudo awk 'tolower($1)=="port" {print $2; exit}' /etc/ssh/sshd_config 2>/dev/null || true)
  fi
  if [[ ! "$port" =~ ^[0-9]+$ ]]; then
    port=22
  fi
  echo "$port"
}

configure_firewalld() {
  local ssh_port
  ssh_port=$(get_sshd_port)
  # Start and enable firewalld
  sudo systemctl start firewalld
  sudo systemctl enable firewalld

  # Allow SSH BEFORE setting default zone to drop — otherwise a remote
  # session is disconnected mid-install between the two commands.
  if ! sudo firewall-cmd --list-all 2>/dev/null | grep -qE "${ssh_port}/tcp|service: ssh"; then
    sudo firewall-cmd --add-service=ssh --permanent >>"$INSTALL_LOG" 2>&1 || true
    if [[ "$ssh_port" != "22" ]]; then
      sudo firewall-cmd --add-port="${ssh_port}/tcp" --permanent >>"$INSTALL_LOG" 2>&1 || true
    fi
    sudo firewall-cmd --reload >>"$INSTALL_LOG" 2>&1 || true
    log_success "SSH (port ${ssh_port}) allowed through Firewalld before lockdown."
  else
    log_warning "SSH is already allowed. Skipping SSH service configuration."
  fi

  # Set default zone to drop — deny incoming, allow outgoing, explicit allow for services
  sudo firewall-cmd --set-default-zone=drop
  log_success "Default zone set to drop (incoming denied, outgoing allowed)"

  # Check if KDE Connect is installed
  if pacman -Q kdeconnect &>/dev/null; then
    # Allow specific ports for KDE Connect
    sudo firewall-cmd --add-port=1714-1764/udp --permanent
    sudo firewall-cmd --add-port=1714-1764/tcp --permanent
    sudo firewall-cmd --reload
    log_success "KDE Connect ports allowed through Firewalld."
  else
    log_warning "KDE Connect is not installed. Skipping KDE Connect service configuration."
  fi

  # Portainer ports (8000,9443) - ensure open even if installed before firewall (programs.sh defers)
  if sudo docker ps -a 2>/dev/null | grep -q portainer || pacman -Q portainer &>/dev/null || [[ -f /var/tmp/archinstaller_portainer_ports_pending ]] || sudo docker images 2>/dev/null | grep -q portainer; then
    if ! sudo firewall-cmd --list-ports 2>/dev/null | grep -q "8000/tcp"; then
      sudo firewall-cmd --add-port=8000/tcp --permanent >>"$INSTALL_LOG" 2>&1 || true
      sudo firewall-cmd --add-port=9443/tcp --permanent >>"$INSTALL_LOG" 2>&1 || true
      sudo firewall-cmd --reload >>"$INSTALL_LOG" 2>&1 || true
      log_success "Opened ports 8000,9443/tcp in firewalld for Portainer (deferred)."
    fi
    rm -f /var/tmp/archinstaller_portainer_ports_pending 2>/dev/null || true
  fi
}

configure_ufw() {
  local ssh_port
  ssh_port=$(get_sshd_port)
  # Install UFW if not present
  if ! command -v ufw >/dev/null 2>&1; then
    install_packages_quietly ufw
    log_success "UFW installed successfully."
  fi

  # Allow SSH BEFORE enabling — enabling first with deny-incoming would
  # disconnect remote sessions before the allow rule is added.
  # Port rule is authoritative on Arch. The OpenSSH app profile
  # only exists where the distro ships it (e.g. Ubuntu) — Arch's ufw has no
  # /etc/ufw/applications.d entry for it, so probe first to avoid
  # "Could not find a profile matching 'OpenSSH'" noise in the log/summary.
  sudo ufw allow "${ssh_port}/tcp" >>"$INSTALL_LOG" 2>&1 || true
  if sudo ufw app list 2>/dev/null | grep -qi openssh; then
    sudo ufw allow OpenSSH >>"$INSTALL_LOG" 2>&1 || true
  fi

  # Enable UFW ( --force avoids "Proceed with operation (y|n)?" hang under dashboard_run where stdout is to log)
  sudo ufw --force enable
  sudo systemctl enable --now ufw 2>/dev/null || true

  # Set default policies
  sudo ufw default deny incoming
  log_success "Default policy set to deny all incoming connections."

  sudo ufw default allow outgoing
  log_success "Default policy set to allow all outgoing connections."

  # Verify and log (port-aware: custom sshd ports must verify, not just 22)
  if sudo ufw status 2>/dev/null | grep -qE "${ssh_port}/tcp|${ssh_port}\s|OpenSSH"; then
    log_success "SSH (port ${ssh_port}) allowed through UFW."
  else
    # Fallback try ssh alias
    sudo ufw allow ssh >>"$INSTALL_LOG" 2>&1 || true
    if sudo ufw status 2>/dev/null | grep -qE "22|ssh|OpenSSH|${ssh_port}"; then
      log_success "SSH allowed through UFW."
    else
      log_warning "UFW ssh rule may not be active - check sudo ufw status"
    fi
  fi

  # Check if KDE Connect is installed
  if pacman -Q kdeconnect &>/dev/null; then
    # Allow specific ports for KDE Connect. `ufw allow` exits 0 even when
    # the underlying iptables multiport extension warns/fails (confirmed
    # via two real install logs on a VM kernel missing that module) — ufw
    # still records the rule to /etc/ufw/user.rules regardless, it just
    # may not apply live immediately. So the exit code alone isn't a
    # reliable success signal here; check the actual output text too.
    local kdeconnect_ok=true kdeconnect_out
    kdeconnect_out=$(sudo ufw allow 1714:1764/udp 2>&1)
    echo "$kdeconnect_out" >>"$INSTALL_LOG"
    echo "$kdeconnect_out" | grep -qiE 'invalid port|not supported' && kdeconnect_ok=false
    kdeconnect_out=$(sudo ufw allow 1714:1764/tcp 2>&1)
    echo "$kdeconnect_out" >>"$INSTALL_LOG"
    echo "$kdeconnect_out" | grep -qiE 'invalid port|not supported' && kdeconnect_ok=false
    if [[ "$kdeconnect_ok" == true ]]; then
      log_success "KDE Connect ports opened in firewall"
    else
      log_warning "KDE Connect firewall rule recorded but the live kernel firewall rejected it (missing multiport module) — it will apply automatically once that module is available (e.g. after a reboot). Check $INSTALL_LOG for details."
    fi
  fi

  # Portainer ports (8000,9443) - ensure open even if installed before firewall (programs.sh defers)
  if sudo docker ps -a 2>/dev/null | grep -q portainer || pacman -Q portainer &>/dev/null || [[ -f /var/tmp/archinstaller_portainer_ports_pending ]] || sudo docker images 2>/dev/null | grep -q portainer; then
    if ! sudo ufw status 2>/dev/null | grep -q "8000/tcp"; then
      sudo ufw allow 8000/tcp >>"$INSTALL_LOG" 2>&1 || true
      sudo ufw allow 9443/tcp >>"$INSTALL_LOG" 2>&1 || true
      log_success "Opened ports 8000,9443/tcp in UFW for Portainer (deferred)."
    fi
    rm -f /var/tmp/archinstaller_portainer_ports_pending 2>/dev/null || true
  fi
}

configure_user_groups() {
  step "Configuring user groups"

  # render covers /dev/dri/renderD* (VA-API/hardware decode); video alone is
  # not enough there, and logind ACLs don't cover every consumer.
  local groups=("wheel" "video" "render" "storage" "optical" "scanner" "lp" "rfkill")

  for group in "${groups[@]}"; do
    if getent group "$group" >/dev/null; then
      if ! groups "$USER" | grep -q "\b$group\b"; then
        sudo usermod -aG "$group" "$USER"
        log_success "Added $USER to $group group"
      fi
    fi
  done
}

# Snapper integration: compat wrapper — single source lives in common.sh
# setup_snapshot_stack (handles snapper AND timeshift, skips when neither
# is installed). Kept so existing callers keep working.
setup_snapper_integration() {
  setup_snapshot_stack "${1:-true}"
}

# Snapshot schedule for snapper: compat wrapper around common.sh
# snapper_enable_timers (ArchWiki timeline + cleanup + boot). Keeps the
# legacy fallback (custom boot service when stock timer is missing) and the
# migration away from the old custom daily timer. No-op without snapper.
configure_snapper_schedule() {
  if ! pacman -Q snapper &>/dev/null; then
    return 0
  fi
  if ! is_btrfs_system 2>/dev/null; then
    return 0
  fi
  if snapper_enable_timers; then
    :
  else
    log_warning "Failed to enable snapper-boot.timer, trying fallback custom service"
    # Fallback: keep custom boot service for compatibility if stock timer missing
    sudo tee /etc/systemd/system/snapper-boot-snapshot.service >/dev/null <<'EOF'
[Unit]
Description=Snapper snapshot at boot
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/bin/snapper -c root create --description boot --cleanup-algorithm number

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload 2>/dev/null || true
    sudo systemctl enable --now snapper-boot-snapshot.service >>"$INSTALL_LOG" 2>&1 || log_warning "Fallback boot service failed"
  fi
  # Clean up old custom daily timer if it exists (migrating to timeline)
  if [[ -f /etc/systemd/system/snapper-daily-snapshot.timer ]]; then
    sudo systemctl disable --now snapper-daily-snapshot.timer 2>/dev/null || true
    log_info "Migrated from custom snapper-daily-snapshot.timer to snapper-timeline.timer"
  fi
  # Monthly scrub for bit-rot detection — snapper stack only, never with timeshift
  enable_btrfs_scrub_timer
}

# Ensure the machine has working network management after reboot.
# archinstall installs NetworkManager only when its own network_config asks
# for it — a minimal/custom install can otherwise reboot with no network at
# all. Never fights an existing manager: systemd-networkd (enabled or
# active) is left alone, and iwd+NetworkManager coexist fine.
ensure_network_manager() {
  step "Ensuring network management (NetworkManager)"

  if systemctl is-enabled --quiet NetworkManager.service 2>/dev/null; then
    log_info "NetworkManager already enabled — nothing to do"
    return 0
  fi
  if systemctl is-enabled --quiet systemd-networkd.service 2>/dev/null \
    || systemctl is-active --quiet systemd-networkd.service 2>/dev/null; then
    log_info "systemd-networkd is managing the network — leaving NetworkManager alone"
    return 0
  fi

  if ! pacman -Q networkmanager &>/dev/null 2>&1; then
    log_info "No network manager active — installing NetworkManager..."
    if ! install_packages_quietly networkmanager; then
      log_warning "Failed to install networkmanager — reboot may have no network"
      return 0
    fi
  fi
  if sudo systemctl enable --now NetworkManager.service 2>&1 | tee -a "$INSTALL_LOG" >/dev/null; then
    log_success "NetworkManager enabled"
  else
    log_warning "Failed to enable NetworkManager"
  fi
}

# Single power-manager policy: exactly one userspace power manager active,
# decided in one place. Priority: an already-installed tlp wins (whoever
# installed it meant it), else power-profiles-daemon, else auto-cpufreq.
# Server mode wants none (kernel defaults). Losers are disabled, never
# removed — removal could strand dependencies. Idempotent.
ensure_single_power_manager() {
  step "Applying power-manager policy (exactly one active)"

  local winner=""
  if [[ "${INSTALL_MODE:-}" == "server" ]]; then
    log_info "Server mode — no userspace power manager (kernel defaults)"
  elif pacman -Q tlp &>/dev/null 2>&1; then
    winner="tlp.service"
  elif pacman -Q power-profiles-daemon &>/dev/null 2>&1; then
    winner="power-profiles-daemon.service"
  elif pacman -Q auto-cpufreq &>/dev/null 2>&1; then
    winner="auto-cpufreq.service"
  else
    log_info "No power manager installed — using kernel defaults"
    return 0
  fi

  local svc
  for svc in tlp.service power-profiles-daemon.service auto-cpufreq.service; do
    if [[ -n "$winner" && "$svc" == "$winner" ]]; then
      if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
        log_info "$svc already enabled (policy winner) — nothing to do"
      elif sudo systemctl enable --now "$svc" 2>&1 | tee -a "$INSTALL_LOG" >/dev/null; then
        log_success "$svc enabled (policy winner)"
      else
        log_warning "Failed to enable $svc"
      fi
    elif systemctl is-enabled --quiet "$svc" 2>/dev/null; then
      if sudo systemctl disable --now "$svc" 2>&1 | tee -a "$INSTALL_LOG" >/dev/null; then
        log_info "$svc disabled (conflicts with ${winner:-kernel defaults})"
      fi
    fi
  done
}

enable_services() {
  # Network first: a minimal archinstall may not have enabled any manager.
  ensure_network_manager

  # Ensure openssh is installed before trying to enable sshd
  if ! pacman -Q openssh &>/dev/null; then
    log_info "openssh not found — installing..."
    sudo pacman -S --noconfirm --needed openssh >>"$INSTALL_LOG" 2>&1 || log_warning "Failed to install openssh"
  fi

  # Server mode enables a minimal set of services, desktop mode adds extras.
  # Both paths continue to shared optimizations (memory, filesystem, storage, audio, kernel).
  if [[ "$INSTALL_MODE" == "server" ]]; then
    ui_info "Server mode: Enabling only essential services (cronie, sshd, etc.)."
    local services=(
      cronie.service
      fstrim.timer
      paccache.timer
      sshd.service
    )
    # Snapshot stack: whatever is installed (snapper and/or timeshift),
    # headless skips GUI packages. Skips cleanly when neither is present.
    # Queues timeshift-autosnap.timer when upstream ships one.
    TIMESHIFT_AUTOSNAP_TIMER=""
    setup_snapshot_stack false
    # Server policy: no userspace power manager (disables stragglers).
    ensure_single_power_manager
    if [[ -n "${TIMESHIFT_AUTOSNAP_TIMER:-}" ]]; then
      services+=("$TIMESHIFT_AUTOSNAP_TIMER")
      log_success "$TIMESHIFT_AUTOSNAP_TIMER will be enabled for automatic snapshots."
    fi
    step "Enabling the following system services:"
    for svc in "${services[@]}"; do
      echo -e "  - $svc"
    done
    # Enable each service individually to prevent one failure from blocking all others
    local server_failed=()
    for svc in "${services[@]}"; do
      if sudo systemctl enable --now "$svc" >>"$INSTALL_LOG" 2>&1; then
        log_success "$svc enabled successfully"
      else
        log_warning "Failed to enable $svc"
        server_failed+=("$svc")
      fi
    done
    if [ ${#server_failed[@]} -eq 0 ]; then
      log_success "All essential services enabled successfully."
    else
      log_warning "Some services failed to enable: ${server_failed[*]}"
    fi

    # Continue to shared optimizations (memory, filesystem, storage, audio, kernel)
  else

  local services=(
    cronie.service
    fstrim.timer
    paccache.timer
    sshd.service
  )

  # Printing (socket-activated) and firmware refresh — only when installed
  if pacman -Qi cups &>/dev/null 2>&1; then
    services+=(cups.socket)
    log_info "cups.socket will be enabled for printing."
  fi
  if pacman -Qi fwupd &>/dev/null 2>&1; then
    services+=(fwupd-refresh.timer)
    log_info "fwupd-refresh.timer will be enabled for firmware updates."
  fi

  # Bluetooth only when hardware exists (or probably exists, i.e. laptops) —
  # enabling it on BT-less desktops/VMs just logs warnings.
  if lsusb 2>/dev/null | grep -qi bluetooth || [ -d /sys/class/bluetooth ] || is_laptop; then
    services+=(bluetooth.service)
    log_info "Bluetooth hardware detected — bluetooth.service will be enabled."
  else
    log_info "No Bluetooth hardware detected — skipping bluetooth.service."
  fi

  # Check and configure virtualization guest integration (libvirt is used by virt-manager and gnome-boxes)
  if command -v virsh &>/dev/null || pacman -Q libvirt-daemon &>/dev/null 2>&1 || pacman -Q virt-manager &>/dev/null 2>&1 || pacman -Q gnome-boxes &>/dev/null 2>&1; then
    # Add user to libvirt group and enable service
    if groups "$USER" | grep -qE '\blibvirt\b'; then
      log_info "User already in libvirt group"
    elif sudo usermod -aG libvirt "$USER" 2>/dev/null; then
      log_success "Added user to libvirt group"
    else
      log_warning "Failed to add user to libvirt group"
    fi
    if systemctl is-enabled libvirtd &>/dev/null 2>&1; then
      log_info "libvirtd service already enabled"
    elif sudo systemctl enable --now libvirtd 2>/dev/null; then
      log_success "libvirtd service enabled"
    else
      log_warning "Failed to enable libvirtd service"
    fi
  fi

  # Conditionally add rustdesk.service if installed
  if pacman -Qi rustdesk-bin &>/dev/null || pacman -Qi rustdesk &>/dev/null || systemctl list-unit-files rustdesk.service &>/dev/null; then
    services+=(rustdesk.service)
    log_success "rustdesk.service will be enabled."
  else
    log_warning "rustdesk is not installed. Skipping rustdesk.service."
  fi

  # Conditionally add lactd.service if lact is installed (usually via Gaming
  # Mode on AMD). Never enabled when absent — install source doesn't matter.
  if pacman -Qi lact &>/dev/null 2>&1; then
    services+=(lactd.service)
    log_success "lactd.service will be enabled."
  else
    log_info "lact is not installed. Skipping lactd.service."
  fi

  # Conditionally add ananicy-cpp.service if installed (Gaming Mode only —
  # never installed otherwise, so absence means Gaming Mode was declined).
  if pacman -Qi ananicy-cpp &>/dev/null 2>&1; then
    services+=(ananicy-cpp.service)
    log_success "ananicy-cpp.service will be enabled."
  else
    log_info "ananicy-cpp is not installed. Skipping ananicy-cpp.service."
  fi

  # Power management is decided by the single policy in
  # ensure_single_power_manager (called below) — never append a power
  # manager to the bulk-enable list, or two managers could end up active.
  run_step "Applying power-manager policy" ensure_single_power_manager

  # Snapshot stack: whatever is installed (snapper and/or timeshift),
  # desktop includes GUI helpers. Skips cleanly when neither is present.
  # Queues timeshift-autosnap.timer when upstream ships one.
  TIMESHIFT_AUTOSNAP_TIMER=""
  setup_snapshot_stack true
  if [[ -n "${TIMESHIFT_AUTOSNAP_TIMER:-}" ]]; then
    services+=("$TIMESHIFT_AUTOSNAP_TIMER")
    log_success "$TIMESHIFT_AUTOSNAP_TIMER will be enabled for automatic snapshots."
  fi

  step "Enabling the following system services:"
  for svc in "${services[@]}"; do
    echo -e "  - $svc"
  done
  # Enable each service individually to prevent one failure from blocking all others
  local failed_services=()
  for svc in "${services[@]}"; do
    if sudo systemctl enable --now "$svc" >>"$INSTALL_LOG" 2>&1; then
      log_success "$svc enabled successfully"
    else
      log_warning "Failed to enable $svc"
      failed_services+=("$svc")
    fi
  done
  if [ ${#failed_services[@]} -eq 0 ]; then
    log_success "All services enabled successfully."
  else
    log_warning "Some services failed to enable: ${failed_services[*]}"
  fi

  # Verify services started correctly
  log_info "Verifying service status..."
  local verify_failed=()
  for svc in "${services[@]}"; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      log_success "$svc is active"
    elif systemctl is-enabled --quiet "$svc" 2>/dev/null; then
      log_warning "$svc is enabled but not running (may require reboot)"
    else
      log_warning "$svc failed to start or enable"
      verify_failed+=("$svc")
    fi
  done

  if [ ${#verify_failed[@]} -eq 0 ]; then
    log_success "All services verified successfully"
  else
    log_warning "Some services may need attention: ${verify_failed[*]}"
  fi
  fi
}

# NOTE: Plymouth theme, hooks and initramfs belong to archinstall and are
# intentionally not managed here. Only the kernel splash params from step 6
# apply. (configure_plymouth was removed.)

detect_and_install_gpu_drivers() {
  step "Detecting and installing graphics drivers"

  # archinstall's gfx-driver step already installs mesa plus the selected
  # vendor stack — so every install below is gap-fill only: skip any stack
  # whose packages are already present instead of reinstalling it.
  if pacman -Q mesa &>/dev/null 2>&1 && pacman -Q lib32-mesa &>/dev/null 2>&1; then
    log_info "Mesa base already installed by archinstall — skipping"
  else
    install_packages_quietly mesa lib32-mesa
  fi

  # Capture lspci once and test each vendor independently so:
  #  - an AMD-only box NEVER installs NVIDIA drivers, and
  #  - hybrid iGPU+dGPU boxes (e.g. AMD iGPU + NVIDIA dGPU) get BOTH sets.
  # The old if/elif chain installed exactly one vendor and mis-handled hybrids.
  local lspci_out
  lspci_out=$(lspci 2>/dev/null || true)

  local has_amd=false has_nvidia=false has_intel=false has_vm=false
  # "ati" was previously matched bare (vga.*ati) to catch old ATI-branded
  # cards — but "VGA compatible controller" is the standard lspci preamble
  # for nearly every GPU line on any system, and "compatible" contains
  # "ati" as a substring. That false-matched every vendor, including VMs
  # with no AMD hardware at all. AMD/Radeon already cover current and
  # recent hardware; ATI-branded cards are all a decade-plus old at this
  # point, so dropping the bare pattern loses effectively no real coverage.
  echo "$lspci_out" | grep -Eiq 'vga.*amd|3d.*amd|display.*amd|vga.*radeon|3d.*radeon|display.*radeon' && has_amd=true
  echo "$lspci_out" | grep -Eiq 'vga.*nvidia|3d.*nvidia|display.*nvidia' && has_nvidia=true
  echo "$lspci_out" | grep -Eiq 'vga.*intel|3d.*intel|display.*intel' && has_intel=true
  echo "$lspci_out" | grep -Eiq 'qxl|virtio.*gpu|vmware svga|cirrus|bochs' && has_vm=true

  if [[ "$has_amd" == true ]]; then
    echo -e "${THEME_TEXT}AMD GPU detected. Ensuring AMD drivers and Vulkan support...${RESET}"
    if pacman -Q xf86-video-amdgpu &>/dev/null 2>&1 && pacman -Q vulkan-radeon &>/dev/null 2>&1 && pacman -Q lib32-vulkan-radeon &>/dev/null 2>&1; then
      log_info "AMD driver stack already installed by archinstall — skipping"
    else
      install_packages_quietly xf86-video-amdgpu vulkan-radeon lib32-vulkan-radeon
      log_success "AMD drivers and Vulkan support installed"
    fi
    log_info "AMD GPU will use AMDGPU driver after reboot"
  fi

  if [[ "$has_nvidia" == true ]]; then
    echo -e "${THEME_TEXT}NVIDIA GPU detected. Ensuring NVIDIA drivers and Vulkan support...${RESET}"
    # Determine correct NVIDIA package set based on installed kernels
    local nvidia_packages=(nvidia-dkms nvidia-utils lib32-nvidia-utils vulkan-icd-loader lib32-vulkan-icd-loader)
    # Add nvidia-settings for GUI configuration
    nvidia_packages+=(nvidia-settings)
    local missing_nvidia=()
    local npkg
    for npkg in "${nvidia_packages[@]}"; do
      # archinstall installs nvidia-open for newer GPUs instead of
      # nvidia-dkms — either one satisfies the kernel-module slot.
      if [[ "$npkg" == "nvidia-dkms" ]] && { pacman -Q nvidia-dkms &>/dev/null 2>&1 || pacman -Q nvidia-open &>/dev/null 2>&1; }; then
        continue
      fi
      pacman -Q "$npkg" &>/dev/null 2>&1 || missing_nvidia+=("$npkg")
    done
    if [[ ${#missing_nvidia[@]} -eq 0 ]]; then
      log_info "NVIDIA driver stack already installed by archinstall — skipping"
    else
      install_packages_quietly "${missing_nvidia[@]}"
      log_success "NVIDIA drivers and Vulkan support installed"
    fi
    log_info "NVIDIA GPU will use proprietary driver after reboot"
    ensure_nvidia_initramfs_modules
  fi

  if [[ "$has_intel" == true ]]; then
    echo -e "${THEME_TEXT}Intel GPU detected. Ensuring Intel drivers and Vulkan support...${RESET}"
    if pacman -Q vulkan-intel &>/dev/null 2>&1 && pacman -Q lib32-vulkan-intel &>/dev/null 2>&1; then
      log_info "Intel driver stack already installed by archinstall — skipping"
    else
      install_packages_quietly vulkan-intel lib32-vulkan-intel
      log_success "Intel drivers and Vulkan support installed"
    fi
    log_info "Intel GPU will use i915 or xe driver after reboot"
  fi

  if [[ "$has_vm" == true ]]; then
    # Virtualized GPU (QXL / virtio-gpu / VMware / Cirrus / Bochs) — no 3D
    # acceleration required. xf86-video-vmware was removed from Arch's
    # official repos (broken against current mesa/llvm, upstream-unfixed —
    # confirmed via a real install log: "target not found:
    # xf86-video-vmware", and this is a widely-reported issue affecting
    # even the official archinstall tool, not specific to this project).
    # The generic `modesetting` driver, built into xorg-server itself,
    # already handles VMware SVGA and everything else here — no package
    # needed for it.
    echo -e "${THEME_TEXT}Virtualized GPU detected. Installing lightweight VM graphics drivers...${RESET}"
    local vm_packages=(xf86-video-qxl xf86-video-fbdev vulkan-swrast lib32-vulkan-swrast)
    local missing_vm=()
    local vpkg
    for vpkg in "${vm_packages[@]}"; do
      pacman -Q "$vpkg" &>/dev/null 2>&1 || missing_vm+=("$vpkg")
    done
    if [[ ${#missing_vm[@]} -eq 0 ]]; then
      log_info "VM graphics drivers already installed by archinstall — skipping"
    else
      install_packages_quietly "${missing_vm[@]}"
      log_success "VM graphics drivers installed"
    fi
    log_info "Virtualized/VM GPU detected — using guest drivers (QXL/VirtIO) plus the built-in modesetting driver for VMware/other virtual adapters"
  fi

  if [[ "$has_amd" == false && "$has_nvidia" == false && "$has_intel" == false && "$has_vm" == false ]]; then
    echo -e "${THEME_WARN}No recognizable GPU detected. Using basic Mesa drivers already installed.${RESET}"
    # In a VM without the above device IDs, still try the software rasterizer
    if pacman -Q vulkan-swrast &>/dev/null 2>&1 && pacman -Q lib32-vulkan-swrast &>/dev/null 2>&1; then
      log_info "Software rasterizer already installed — skipping"
    else
      install_packages_quietly vulkan-swrast lib32-vulkan-swrast
    fi
  fi

  # Verify GPU driver is loaded
  verify_gpu_driver
}

# Ensure NVIDIA DRM modules are in mkinitcpio MODULES for early KMS.
# Idempotent: adds missing tokens only, preserves existing ones.
# No rebuild here — bootloader step collects rebuilds; next kernel update
# also regenerates. Dracut systems are skipped (dracut auto-detects).
ensure_nvidia_initramfs_modules() {
  local mkconf="/etc/mkinitcpio.conf"
  [[ -f "$mkconf" ]] || { log_debug "No mkinitcpio.conf — skipping NVIDIA MODULES wiring"; return 0; }
  command -v mkinitcpio &>/dev/null || { log_debug "mkinitcpio not in use — skipping NVIDIA MODULES wiring"; return 0; }
  local needed=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)
  local line current missing=()
  line=$(grep -E '^MODULES=' "$mkconf" | head -1 || echo "")
  [[ -z "$line" ]] && { log_warning "No MODULES line in $mkconf — skipping NVIDIA wiring"; return 0; }
  current="$line"
  local m
  for m in "${needed[@]}"; do
    echo "$current" | grep -qw "$m" || missing+=("$m")
  done
  if [[ ${#missing[@]} -eq 0 ]]; then
    log_info "NVIDIA initramfs MODULES already present"
    return 0
  fi
  validate_config_file "$mkconf" >/dev/null 2>&1 || true
  local new_mods
  new_mods=$(echo "$current" | sed -E 's/^MODULES=\((.*)\)/\1/' | xargs)
  new_mods="$new_mods ${missing[*]}"
  new_mods=$(echo "$new_mods" | tr -s ' ')
  if sudo sed -i -E "s|^MODULES=.*|MODULES=($new_mods)|" "$mkconf" \
    && grep -E '^MODULES=' "$mkconf" | grep -qw "nvidia_drm"; then
    log_success "Added NVIDIA modules to mkinitcpio MODULES: ${missing[*]} (applies on next initramfs rebuild)"
  else
    log_warning "Failed to wire NVIDIA modules into $mkconf"
  fi
}

# Function to verify GPU driver is loaded correctly
verify_gpu_driver() {
  step "Verifying GPU driver installation"

  # Check which driver is in use (stderr suppressed: libkmodhelper errors
  # like "Unable to load libkmod resources" are harmless in VMs/containers
  # but clutter the log when lspci runs twice below)
  if lspci -k 2>/dev/null | grep -A 3 -iE 'vga|3d|display' | grep -iq 'Kernel driver in use'; then
    log_info "GPU driver status:"
    lspci -k 2>/dev/null | grep -A 3 -iE 'vga|3d|display' | grep -E 'VGA|3D|Display|Kernel driver'
    log_success "GPU driver is loaded and in use"
  else
    log_warning "Could not verify GPU driver status"
    log_info "Run 'lspci -k | grep -A 3 -iE \"vga|3d|display\"' after reboot to check driver"
  fi

  # Check for Vulkan support
  if command -v vulkaninfo >/dev/null 2>&1; then
    if vulkaninfo --summary &>/dev/null; then
      log_success "Vulkan support verified"
    else
      log_warning "Vulkan may not be properly configured"
    fi
  else
    log_info "Install vulkan-tools to verify Vulkan support: sudo pacman -S vulkan-tools"
  fi
}

# Install guest agents when this machine is itself a VM guest (copy-paste,
# dynamic resolution, host-guest communication). spice-vdagent is the SPICE
# clipboard/resolution agent — it only helps inside a SPICE guest (e.g. this
# installer running in a GNOME Boxes VM), which is why it is gated on is_vm()
# here rather than on gnome-boxes (host-side). The programs.yaml entry covers
# Standard hosts too (harmless on bare metal, needed for nested VMs).
install_vm_guest_agents() {
  is_vm 2>/dev/null || return 0

  step "Installing VM guest agents"

  local virt="unknown"
  virt=$(systemd-detect-virt 2>/dev/null || echo "unknown")

  case "$virt" in
    oracle)
      log_info "VirtualBox guest detected — installing guest utils"
      install_packages_quietly virtualbox-guest-utils
      if sudo systemctl enable --now vboxservice.service >>"$INSTALL_LOG" 2>&1; then
        log_success "vboxservice enabled (clipboard + shared folders)"
      else
        log_warning "Failed to enable vboxservice"
      fi
      ;;
    vmware)
      log_info "VMware guest detected — installing open-vm-tools"
      install_packages_quietly open-vm-tools
      if sudo systemctl enable --now vmtoolsd.service >>"$INSTALL_LOG" 2>&1; then
        log_success "vmtoolsd enabled (clipboard + dynamic resolution)"
      else
        log_warning "Failed to enable vmtoolsd"
      fi
      ;;
    *)
      # qemu/kvm (incl. GNOME Boxes SPICE sessions) and unknown hypervisors:
      # SPICE agent for clipboard/resolution + qemu agent for host comms.
      # Headless servers have no graphical clipboard, so they only need the
      # qemu agent.
      log_info "QEMU/KVM guest detected ($virt) — installing SPICE + qemu agents"
      if [[ "${INSTALL_MODE:-}" == "server" ]]; then
        install_packages_quietly qemu-guest-agent
      else
        install_packages_quietly spice-vdagent qemu-guest-agent
      fi
      # Arch ships qemu-guest-agent without an [Install] section, and the
      # service additionally needs a virtio guest-agent channel from the
      # host (GNOME Boxes doesn't add one by default). Best effort only:
      # SPICE clipboard/resolution works through spice-vdagentd regardless.
      if sudo systemctl enable --now qemu-guest-agent.service >>"$INSTALL_LOG" 2>&1; then
        log_success "qemu-guest-agent enabled"
      elif sudo systemctl start qemu-guest-agent.service >>"$INSTALL_LOG" 2>&1; then
        log_success "qemu-guest-agent started (no [Install] section — runs without enablement)"
      else
        log_info "qemu-guest-agent installed but not started (no guest-agent channel in this VM — add a virtio serial channel on the host if you need it; SPICE copy-paste is unaffected)"
      fi
      if [[ "${INSTALL_MODE:-}" != "server" ]]; then
        if sudo systemctl enable --now spice-vdagentd.service >>"$INSTALL_LOG" 2>&1; then
          log_success "spice-vdagentd enabled (seamless clipboard + dynamic resolution)"
        else
          log_warning "Failed to enable spice-vdagentd"
        fi
      fi
      ;;
  esac
  return 0
}

# Secure Boot signing maintenance: with SB active, a kernel/bootloader
# update that isn't signed leaves an unbootable system. archinstall can
# enroll sbctl, whose pacman hook signs future updates — this step verifies
# the current state and signs whatever the hook missed. Read-mostly and
# safe: never enrolls keys (a manual, one-time owner action), only signs
# with keys already enrolled on this machine.
ensure_sb_signing() {
  step "Checking Secure Boot signing"

  local sb_last=""
  sb_last=$(od -An -tu1 /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null | awk '{print $NF}' || true)
  if [[ "$sb_last" != "1" ]]; then
    log_info "Secure Boot not active — skipping signing maintenance"
    return 0
  fi
  if ! command -v sbctl &>/dev/null; then
    log_warning "Secure Boot is active but sbctl is not installed — kernel updates may stop booting until you install sbctl and enroll keys"
    return 0
  fi
  if ! sudo sbctl status 2>/dev/null | grep -qiE 'installed:\s*(yes|✓|true)'; then
    log_warning "sbctl present but keys are not enrolled — signing would do nothing; enroll manually with: sudo sbctl enroll-keys -m"
    return 0
  fi

  local verify_out=""
  if verify_out=$(sudo sbctl verify 2>&1); then
    log_success "Secure Boot: all files signed"
    return 0
  fi
  echo "$verify_out" >>"$INSTALL_LOG" 2>&1 || true
  log_info "Some files are unsigned — signing them with the enrolled keys..."
  local unsigned=""
  unsigned=$(echo "$verify_out" | grep -oE '✗ [^ ]+ is not signed' | awk '{print $2}' || true)
  if [[ -z "$unsigned" ]]; then
    log_warning "sbctl verify reported issues but no unsigned files could be parsed — run 'sudo sbctl verify' manually"
    return 0
  fi
  local f failed=0
  # shellcheck disable=SC2086
  for f in $unsigned; do
    if sudo sbctl sign --save "$f" 2>&1 | tee -a "$INSTALL_LOG" >/dev/null; then
      log_success "Signed $f"
    else
      log_warning "Failed to sign $f"
      failed=1
    fi
  done
  if [[ "$failed" -eq 0 ]]; then
    log_success "Secure Boot signing maintenance complete"
  fi
  return 0
}

# Append a kernel param to every base Limine cmdline line in one config
# file (snapshot entries belong to limine-snapper-sync and are skipped —
# it regenerates them from the base entries). Idempotent per line.
_hibernate_limine_file() {
  local conf="$1" param="$2"
  local lns
  lns=$(sudo grep -nE '^[[:space:]]*(kernel_)?cmdline:' "$conf" 2>/dev/null | cut -d: -f1 || true)
  [[ -z "$lns" ]] && return 0
  sudo cp "$conf" "${conf}.backup.$(date +%Y%m%d_%H%M%S)"
  local ln line patched=0
  for ln in $lns; do
    line=$(sudo sed -n "${ln}p" "$conf" 2>/dev/null || true)
    echo "$line" | grep -q '/\.snapshots' && continue
    echo "$line" | grep -qF "$param" && continue
    # sed -i rewrites the whole file in one go (small torn-write window on
    # FAT32); the limine mutex lives in bootloader_config.sh and is not
    # available here, so snapshot entries are left for the watcher.
    sudo sed -i "${ln}s|$| $param|" "$conf" && patched=$((patched + 1))
  done
  log_to_file "Limine $conf: appended resume param to $patched line(s)"
}

# Opt-in hibernation (resume from a swap partition). archinstall sets up
# zram swap by default, which cannot hibernate — so this only offers when
# a real swap partition exists. Default answer is No (also under --yes):
# it rebuilds the initramfs and touches bootloader entries. Everything is
# append-only and idempotent; any failure warns and never aborts the run.
setup_hibernation() {
  step "Hibernation (resume from swap) — optional"

  if is_vm 2>/dev/null; then
    log_info "VM guest detected — hibernation is meaningless here, skipping"
    return 0
  fi

  local swapdev
  swapdev=$(sudo blkid -t TYPE=swap -o device 2>/dev/null | head -1 || true)
  if [[ -z "$swapdev" ]]; then
    log_info "No swap partition found (zram-only?) — hibernation needs a swap partition, skipping"
    return 0
  fi
  if ! swapon --show=NAME --noheadings 2>/dev/null | grep -qxF "$swapdev" \
    && ! grep -qE "^[[:space:]]*$swapdev([[:space:]]|$)" /etc/fstab 2>/dev/null; then
    log_warning "Swap device $swapdev is neither active nor in fstab — skipping hibernation"
    return 0
  fi
  local swap_uuid
  swap_uuid=$(sudo blkid -s UUID -o value "$swapdev" 2>/dev/null || true)
  if [[ -z "$swap_uuid" ]]; then
    log_warning "Cannot determine UUID of $swapdev — skipping hibernation"
    return 0
  fi

  local ram_kb swap_kb
  ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  swap_kb=$(sudo blockdev --getsize64 "$swapdev" 2>/dev/null | awk '{print int($1/1024)}' || echo 0)
  if [[ "$swap_kb" -gt 0 && "$swap_kb" -lt "$ram_kb" ]]; then
    log_warning "Swap is smaller than RAM — hibernation may fail when memory is full"
  fi

  if ! ui_confirm "Enable hibernation (resume from swap)?" "Adds the resume hook, rebuilds the initramfs (slow, one-time), and appends resume=UUID=$swap_uuid to your bootloader entries. Swap: $swapdev." false; then
    log_info "Hibernation skipped by user"
    return 0
  fi

  local resume_param="resume=UUID=$swap_uuid"

  # 1. resume hook (mkinitcpio only).
  local mkconf="/etc/mkinitcpio.conf"
  if ! command -v mkinitcpio &>/dev/null || [[ ! -f "$mkconf" ]]; then
    log_warning "mkinitcpio not in use — add resume support manually for your initramfs generator"
    return 0
  fi
  if grep -qE '^HOOKS=.*\bresume\b' "$mkconf"; then
    log_info "resume hook already present — skipping hook edit"
  else
    validate_config_file "$mkconf" >/dev/null 2>&1 || true
    if grep -qE '^HOOKS=.*\bblock\b' "$mkconf"; then
      sudo sed -i -E 's/^(HOOKS=.*\bblock\b)/\1 resume/' "$mkconf"
    elif grep -qE '^HOOKS=.*\bfilesystems\b' "$mkconf"; then
      sudo sed -i -E 's/^(HOOKS=.*)\bfilesystems\b/\1resume filesystems/' "$mkconf"
    else
      sudo sed -i -E 's/^(HOOKS=\(.*)\)/\1 resume)/' "$mkconf"
    fi
    if grep -qE '^HOOKS=.*\bresume\b' "$mkconf"; then
      log_success "Added resume hook to mkinitcpio"
    else
      log_warning "Failed to add resume hook — aborting hibernation setup (bootloader untouched)"
      return 0
    fi
  fi

  # 2. Kernel param, per bootloader (append-only, idempotent).
  _hibernate_add_boot_param "$resume_param" || return 0

  # 3. Rebuild once so hook + params apply.
  log_info "Rebuilding initramfs with resume support (slow, one-time)..."
  if sudo mkinitcpio -P 2>&1 | tee -a "$INSTALL_LOG" >/dev/null; then
    log_success "Initramfs rebuilt — hibernation ready (test with: systemctl hibernate)"
  else
    log_warning "Initramfs rebuild failed — hibernation not active; re-run mkinitcpio -P manually"
  fi
  return 0
}

# Append one kernel param to the active bootloader's config (and regenerate
# where required). Never removes or replaces anything archinstall wrote.
_hibernate_add_boot_param() {
  local param="$1"
  local bl
  bl=$(detect_bootloader)

  # UKI systems boot from /etc/kernel/cmdline.
  if is_uki_system 2>/dev/null; then
    local cmdline_file="/etc/kernel/cmdline"
    local current=""
    if sudo test -f "$cmdline_file" 2>/dev/null; then
      current=$(sudo cat "$cmdline_file" 2>/dev/null || true)
    fi
    if echo " $current " | grep -qF " $param "; then
      log_info "resume param already in $cmdline_file"
    else
      [[ -n "$current" ]] && sudo cp "$cmdline_file" "${cmdline_file}.backup.$(date +%Y%m%d_%H%M%S)"
      if echo "${current:+$current }$param" | sudo tee "$cmdline_file" >/dev/null; then
        log_success "Added $param to $cmdline_file"
      else
        log_warning "Failed to update $cmdline_file"
        return 1
      fi
    fi
    return 0
  fi

  case "$bl" in
    systemd-boot)
      local entries_dir
      entries_dir=$(find_systemd_boot_entries_dir)
      if [[ -z "$entries_dir" ]]; then
        log_warning "No systemd-boot entries dir found — add $param manually"
        return 1
      fi
      local entry updated=0
      while IFS= read -r -d '' entry; do
        if sudo grep -q "^options " "$entry" 2>/dev/null; then
          sudo grep "^options " "$entry" 2>/dev/null | grep -qF "$param" && continue
          # shellcheck disable=SC2086
          if sudo sed -i "s|^options \(.*\)|options \1 $param|" "$entry"; then
            updated=$((updated + 1))
          fi
        fi
      done < <(sudo find "$entries_dir" -maxdepth 1 -name "*.conf" ! -name "*fallback*" -print0 2>/dev/null)
      log_success "Added resume param to $updated systemd-boot entries"
      ;;
    grub)
      local grub_config="/etc/default/grub"
      local current=""
      current=$(grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "$grub_config" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)
      if echo " $current " | grep -qF " $param "; then
        log_info "resume param already in GRUB_CMDLINE_LINUX_DEFAULT"
      else
        sudo cp "$grub_config" "${grub_config}.backup.$(date +%Y%m%d_%H%M%S)"
        local merged
        merged=$(echo "$current $param" | tr -s ' ' | sed 's/^ //; s/ $//')
        if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "$grub_config" 2>/dev/null; then
          sudo sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$merged\"|" "$grub_config"
        else
          echo "GRUB_CMDLINE_LINUX_DEFAULT=\"$merged\"" | sudo tee -a "$grub_config" >/dev/null
        fi
        if grep -qF "$param" "$grub_config" 2>/dev/null; then
          log_success "Added resume param to GRUB defaults"
        else
          log_warning "Failed to update $grub_config"
          return 1
        fi
      fi
      if sudo test -f /boot/grub/grub.cfg 2>/dev/null; then
        if sudo grub-mkconfig -o /boot/grub/grub.cfg 2>&1 | tee -a "$INSTALL_LOG" >/dev/null; then
          log_success "GRUB configuration regenerated with resume param"
        else
          log_warning "grub-mkconfig failed — resume param saved but not yet active"
        fi
      else
        log_warning "grub.cfg not found — resume param saved but GRUB not regenerated"
      fi
      ;;
    limine)
      local conf found_any=false
      while IFS= read -r conf; do
        [[ -z "$conf" ]] && continue
        found_any=true
        _hibernate_limine_file "$conf" "$param"
      done < <(sudo find /boot /efi /boot/efi -maxdepth 4 -name limine.conf 2>/dev/null || true)
      if [[ "$found_any" == true ]]; then
        log_success "Limine cmdlines updated with resume param"
      else
        log_warning "No limine.conf found — add $param manually"
        return 1
      fi
      ;;
    *)
      log_warning "Bootloader '$bl' resume params are manual — add $param to your kernel cmdline yourself"
      return 1
      ;;
  esac
  return 0
}

# NOTE: is_laptop() uses the cached version from system.sh (sourced via common.sh)

# NOTE: detect_cpu_vendor() uses the cached version from system.sh (sourced via common.sh)

# Function to install ACPI with smart compatibility handling
install_smart_acpi() {
  local acpi_mode=$(should_skip_acpi)
  
  case "$acpi_mode" in
    "minimal")
      log_info "Installing minimal ACPI support for legacy hardware"
      install_packages_quietly acpi
      # Only enable acpid service, don't start it automatically on legacy systems
      sudo systemctl enable acpid.service 2>/dev/null || true
      ;;
    "false")
      log_info "Installing full ACPI support for modern hardware"
      install_packages_quietly acpi acpid
      sudo systemctl enable acpid.service 2>/dev/null
      sudo systemctl start acpid.service 2>/dev/null
      ;;
    *)
      log_info "Skipping ACPI tools due to compatibility issues"
      ;;
  esac
}

# Function to check if ACPI should be skipped due to compatibility issues
should_skip_acpi() {
  local cpu_vendor=$(detect_cpu_vendor)
  local manufacturer=$(detect_laptop_manufacturer)
  local cpu_model=""
  local cpu_family=""
  
  # Get CPU model for specific checks
  cpu_model=$(grep "model name" /proc/cpuinfo | head -1 | cut -d':' -f2 | xargs)
  
  # Get CPU family for architecture detection
  cpu_family=$(grep "cpu family" /proc/cpuinfo | head -1 | cut -d':' -f2 | xargs)
  
  # Modern ACPI compatibility check - only skip truly problematic hardware
  
  # 1. Skip only for very old pre-Zen AMD CPUs (pre-2017)
  if [ "$cpu_vendor" = "amd" ]; then
    # Family 23+ is Zen 2 and newer. Guard against non-numeric values
    # (e.g. non-x86 or unusual /proc/cpuinfo output) to avoid comparison errors.
    if [[ "$cpu_family" =~ ^[0-9]+$ ]] && [ "$cpu_family" -lt "23" ]; then
      log_info "Legacy AMD CPU detected (family $cpu_family) - using minimal ACPI"
      echo "minimal"
      return 0
    fi
  fi
  
  # 2. Skip for very old Intel CPUs (pre-2015)
  if [ "$cpu_vendor" = "intel" ]; then
    local cpu_model_num=$(echo "$cpu_model" | grep -o '[0-9]\{3,4\}' | head -1)
    if [[ -n "$cpu_model_num" && "$cpu_model_num" =~ ^[0-9]+$ ]] && [ "$cpu_model_num" -lt "4000" ]; then
      log_info "Legacy Intel CPU detected (model $cpu_model_num) - using minimal ACPI"
      echo "minimal"
      return 0
    fi
  fi
  
  # 3. Check for known problematic legacy hardware (only very old models)
  case "$manufacturer" in
    hp)
      # Only skip for very old HP models with legacy APUs
      if [ "$cpu_vendor" = "amd" ]; then
        case "$cpu_model" in
          *"AMD A4"*|*"AMD A6"*|*"AMD A8"*|*"AMD A10"*|*"AMD E1"*|*"AMD E2"*|*"AMD A[4-6]"*)
            log_info "HP laptop with legacy AMD APU detected - using minimal ACPI"
            echo "minimal"
            return 0
            ;;
        esac
      fi
      ;;
    lenovo)
      # Only skip for very old ThinkPads with legacy hardware
      if [ "$cpu_vendor" = "amd" ] && echo "$cpu_model" | grep -q "AMD A[4-6]"; then
        log_info "Lenovo laptop with legacy AMD APU detected - using minimal ACPI"
        echo "minimal"
        return 0
      fi
      ;;
  esac
  
  # Default: ACPI is safe for modern hardware
  echo "false"
}

# Function to detect laptop manufacturer
detect_laptop_manufacturer() {
  local manufacturer="unknown"
  
  # Try DMI product name first
  if [ -f /sys/class/dmi/id/product_name ]; then
    local product_name=$(cat /sys/class/dmi/id/product_name 2>/dev/null | tr '[:upper:]' '[:lower:]')
    
    case "$product_name" in
      *lenovo*|*thinkpad*|*ideapad*|*legion*|*yoga*|*thinkbook*) manufacturer="lenovo" ;;
      *hp*|*hewlett*|*compaq*|*omen*|*pavilion*|*elitebook*|*spectre*|*envy*) manufacturer="hp" ;;
      *dell*|*latitude*|*precision*|*inspiron*|*xps*|*alienware*|*vostro*) manufacturer="dell" ;;
      *acer*|*aspire*|*predator*|*nitro*|*swift*|*spin*|*travelmate*) manufacturer="acer" ;;
      *asus*|*rog*|*zenbook*|*vivobook*|*tuf*|*proart*|*expertbook*) manufacturer="asus" ;;
      *msi*|*micro-star*|*ge*|*gt*|*gl*|*gf*|*creator*) manufacturer="msi" ;;
      *surface*|*microsoft*) manufacturer="microsoft" ;;
      *razer*|*blade*) manufacturer="razer" ;;
      *huawei*|*matebook*) manufacturer="huawei" ;;
      *xiaomi*|*redmibook*) manufacturer="xiaomi" ;;
      *lg*|*gram*) manufacturer="lg" ;;
      *samsung*|*galaxy*) manufacturer="samsung" ;;
      *framework*) manufacturer="framework" ;;
      *system76*|*oryp*|*galago*|*lemur*) manufacturer="system76" ;;
    esac
  fi
  
  # Fallback to DMI sys_vendor if product_name didn't work
  if [ "$manufacturer" = "unknown" ] && [ -f /sys/class/dmi/id/sys_vendor ]; then
    local sys_vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null | tr '[:upper:]' '[:lower:]')
    
    case "$sys_vendor" in
      *lenovo*) manufacturer="lenovo" ;;
      *hp*|*hewlett*) manufacturer="hp" ;;
      *dell*) manufacturer="dell" ;;
      *acer*) manufacturer="acer" ;;
      *asus*) manufacturer="asus" ;;
      *msi*|*micro-star*) manufacturer="msi" ;;
      *microsoft*) manufacturer="microsoft" ;;
      *razer*) manufacturer="razer" ;;
      *lg*) manufacturer="lg" ;;
      *samsung*) manufacturer="samsung" ;;
      *huawei*) manufacturer="huawei" ;;
      *xiaomi*) manufacturer="xiaomi" ;;
      *framework*) manufacturer="framework" ;;
      *system76*) manufacturer="system76" ;;
    esac
  fi
  
  echo "$manufacturer"
}

# Function to detect if this is a gaming laptop
detect_gaming_laptop() {
  local manufacturer="$1"
  local is_gaming=false
  
  if [ -f /sys/class/dmi/id/product_name ]; then
    local product_name=$(cat /sys/class/dmi/id/product_name 2>/dev/null | tr '[:upper:]' '[:lower:]')
    
    case "$product_name" in
      *legion*|*omen*|*predator*|*nitro*|*rog*|*tuf*|*alienware*|*ge*|*gt*|*gl*|*razer*|*blade*) is_gaming=true ;;
    esac
  fi
  
  echo "$is_gaming"
}

# Function to get laptop model information
get_laptop_model() {
  local model="unknown"
  
  if [ -f /sys/class/dmi/id/product_name ]; then
    model=$(cat /sys/class/dmi/id/product_name 2>/dev/null)
  elif [ -f /sys/class/dmi/id/product_version ]; then
    model=$(cat /sys/class/dmi/id/product_version 2>/dev/null)
  fi
  
  echo "$model"
}

# Function to detect if we should apply automatic optimizations
should_auto_optimize() {
  # Auto-optimize if:
  # 1. AUTO_LAPTOP_OPTS environment variable is set to "true"
  # 2. We're running in non-interactive mode (no gum available)
  # 3. User has previously enabled optimizations
  
  if [ "${AUTO_LAPTOP_OPTS:-false}" = "true" ]; then
    echo "true"
    return
  fi
  
  if ! command -v gum >/dev/null 2>&1; then
    # In non-interactive mode, ask once and remember the choice
    local config_file="$HOME/.config/archinstaller-laptop-opts"
    if [ -f "$config_file" ]; then
      cat "$config_file" 2>/dev/null
    else
      echo "false"  # Default to false in pure non-interactive mode
    fi
  else
    echo "false"  # Interactive mode - let user choose
  fi
}

# Function to get manufacturer-specific optimizations
get_manufacturer_optimizations() {
  local manufacturer="$1"
  local is_gaming=$(detect_gaming_laptop "$manufacturer")
  local optimizations=()
  
  case "$manufacturer" in
    lenovo)
      if [ "$is_gaming" = "true" ]; then
        optimizations+=("Lenovo Legion gaming optimizations")
        optimizations+=("Lenovo Vantage alternative (lenovo-legion-tool)")
      else
        optimizations+=("ThinkPad function keys support")
        optimizations+=("Lenovo power management tweaks")
      fi
      optimizations+=("Lenovo ACPI support")
      ;;
    hp)
      if [ "$is_gaming" = "true" ]; then
        optimizations+=("HP Omen gaming optimizations")
      else
        optimizations+=("HP Pavilion/EliteBook optimizations")
      fi
      optimizations+=("HP function keys and hotkeys")
      optimizations+=("HP power management")
      ;;
    dell)
      if [ "$is_gaming" = "true" ]; then
        optimizations+=("Dell Alienware gaming features")
      else
        optimizations+=("Dell XPS performance tweaks")
      fi
      optimizations+=("Dell function keys support")
      optimizations+=("Dell power management")
      ;;
    acer)
      if [ "$is_gaming" = "true" ]; then
        optimizations+=("Acer Predator/Nitro gaming optimizations")
      else
        optimizations+=("Acer Swift/Spin optimizations")
      fi
      optimizations+=("Acer function keys")
      optimizations+=("Acer power management")
      ;;
    asus)
      if [ "$is_gaming" = "true" ]; then
        optimizations+=("ASUS ROG/TUF gaming features")
      else
        optimizations+=("ASUS ZenBook/VivoBook optimizations")
      fi
      optimizations+=("ASUS function keys support")
      optimizations+=("ASUS power management")
      ;;
    msi)
      if [ "$is_gaming" = "true" ]; then
        optimizations+=("MSI GE/GT/GL gaming optimizations")
      else
        optimizations+=("MSI Creator series optimizations")
      fi
      optimizations+=("MSI function keys")
      optimizations+=("MSI Dragon Center alternative")
      ;;
    razer)
      optimizations+=("Razer Blade gaming optimizations")
      optimizations+=("Razer Synapse alternative")
      optimizations+=("Razer function keys")
      ;;
    lg)
      optimizations+=("LG Gram ultra-light optimizations")
      optimizations+=("LG function keys")
      optimizations+=("LG power management")
      ;;
    samsung)
      optimizations+=("Samsung Galaxy Book optimizations")
      optimizations+=("Samsung function keys")
      optimizations+=("Samsung power management")
      ;;
    huawei)
      optimizations+=("Huawei MateBook optimizations")
      optimizations+=("Huawei function keys")
      optimizations+=("Huawei power management")
      ;;
    xiaomi)
      optimizations+=("Xiaomi Mi/RedmiBook optimizations")
      optimizations+=("Xiaomi function keys")
      optimizations+=("Xiaomi power management")
      ;;
    framework)
      optimizations+=("Framework laptop modular optimizations")
      optimizations+=("Framework function keys")
      optimizations+=("Framework power management")
      ;;
    system76)
      optimizations+=("System76 firmware optimizations")
      optimizations+=("System76 function keys")
      optimizations+=("System76 power management")
      ;;
    microsoft)
      optimizations+=("Microsoft Surface optimizations")
      optimizations+=("Surface pen and touch support")
      optimizations+=("Surface power management")
      ;;
    *)
      optimizations+=("Generic laptop optimizations")
      optimizations+=("Standard ACPI support")
      optimizations+=("Universal power management")
      ;;
  esac
  
  printf '%s\n' "${optimizations[@]}"
}

# Function to report RAM size. The kernel's default vm.swappiness is left
# untouched: automatic RAM-based swappiness/vfs_cache_pressure tuning has
# been removed — modern kernels already page-cache and swap sensibly, and a
# static sysctl guess cannot beat that across workloads. Reporting only.
detect_memory_size() {
  step "Detecting system memory"

  # Get total RAM in GB
  local ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  local ram_gb=$((ram_kb / 1024 / 1024))

  log_info "Total system memory: ${ram_gb}GB (using kernel default vm.swappiness — no custom sysctl written)"
  log_success "Memory detection complete (no tuning applied)"
}

# Function to detect filesystem type and apply optimizations
detect_filesystem_type() {
  step "Detecting filesystem type and applying optimizations"

  local root_fs=$(findmnt -no FSTYPE /)
  log_info "Root filesystem: $root_fs"

  case "$root_fs" in
    ext4)
      log_info "ext4 detected - applying ext4 optimizations"
      # Set reserved blocks to 1% (default is 5%)
      local root_device=$(findmnt -no SOURCE /)
      if [ -n "$root_device" ]; then
        sudo tune2fs -m 1 "$root_device" 2>/dev/null && log_success "Reduced ext4 reserved blocks to 1%"
      fi
      ;;
    xfs)
      log_info "XFS detected - XFS is already well-optimized"
      log_success "XFS filesystem detected (no additional optimization needed)"
      ;;
    f2fs)
      log_info "F2FS detected - optimized for flash storage"
      log_success "F2FS filesystem detected (flash-optimized)"
      ;;
    btrfs)
      log_success "Btrfs detected - advanced filesystem features available"
      ;;
    *)
      log_info "Filesystem: $root_fs (using default optimizations)"
      ;;
  esac

  # Check for LUKS encryption
  if lsblk -o NAME,FSTYPE | grep -q crypto_LUKS; then
    log_info "LUKS encryption detected (periodic TRIM is handled by fstrim.timer when enabled)"
  fi
}

# Function to report storage type and current I/O scheduler. The kernel and
# block layer already select the appropriate default scheduler per device,
# so nothing is forced here (no /sys writes, no persistent udev rules):
# automatic scheduler forcing has been removed. Reporting only.
detect_storage_type() {
  step "Detecting storage type and I/O scheduler"

  # Get all block devices (exclude loop, ram, etc.)
  local devices=()
  while IFS= read -r device; do
    devices+=("$device")
  done < <(lsblk -d -n -o NAME,TYPE | grep disk | awk '{print $1}')

  for device in "${devices[@]}"; do
    local rota
    rota=$(cat "/sys/block/$device/queue/rotational" 2>/dev/null || echo "1")
    local device_type=""
    local current_sched="unknown"

    # Determine device type for reporting only
    if [[ "$device" == nvme* ]]; then
      device_type="NVMe SSD"
    elif [ "$rota" = "0" ]; then
      device_type="SATA SSD"
    else
      device_type="HDD"
    fi

    if [ -f "/sys/block/$device/queue/scheduler" ]; then
      current_sched=$(grep -oE '\[[a-z-]+\]' "/sys/block/$device/queue/scheduler" 2>/dev/null | tr -d '[]' || echo "unknown")
    fi

    log_info "Device /dev/$device: $device_type (kernel-selected scheduler: $current_sched)"
  done

  log_success "Storage detection complete (scheduler left at kernel default)"
}

# Function to detect audio system
detect_audio_system() {
  step "Detecting audio system"

  if systemctl --user is-active --quiet pipewire 2>/dev/null || systemctl is-active --quiet pipewire 2>/dev/null; then
    log_success "PipeWire audio system detected"
    # archinstall's audio_config already installs the full PipeWire set
    # (pipewire pipewire-alsa pipewire-jack pipewire-pulse
    # gst-plugin-pipewire libpulse wireplumber) — only fill gaps instead
    # of reinstalling the whole stack.
    local missing_audio=()
    local apkg
    for apkg in pipewire-alsa pipewire-jack pipewire-pulse; do
      pacman -Q "$apkg" &>/dev/null 2>&1 || missing_audio+=("$apkg")
    done
    if [[ ${#missing_audio[@]} -eq 0 ]]; then
      log_info "PipeWire compatibility packages already installed by archinstall — skipping"
    else
      install_packages_quietly "${missing_audio[@]}"
      log_success "PipeWire compatibility packages installed (${missing_audio[*]})"
    fi
  elif systemctl --user is-active --quiet pulseaudio 2>/dev/null || pgrep -x pulseaudio >/dev/null 2>&1; then
    log_success "PulseAudio audio system detected"
    # Ensure PulseAudio bluetooth support
    if pacman -Q bluez &>/dev/null; then
      install_packages_quietly pulseaudio-bluetooth
      log_success "PulseAudio Bluetooth support installed"
    fi
  else
    log_info "No audio system detected or not running yet"
    log_info "PipeWire is recommended for modern systems"
  fi
}

# Function to detect kernel type
detect_kernel_type() {
  step "Detecting installed kernel type"

  local kernel=$(uname -r)
  local kernel_type="linux"

  if [[ "$kernel" == *"-lts"* ]]; then
    kernel_type="linux-lts"
    log_success "Running linux-lts kernel (Long Term Support)"
    log_info "LTS kernel focuses on stability"
  elif [[ "$kernel" == *"-zen"* ]]; then
    kernel_type="Arch Linux (linux-zen)"
    log_success "Running linux-zen kernel (Performance)"
    log_info "Zen kernel optimized for desktop/gaming performance"
  elif [[ "$kernel" == *"-hardened"* ]]; then
    kernel_type="linux-hardened"
    log_success "Running linux-hardened kernel (Security)"
    log_info "Hardened kernel focuses on security"
  else
    log_success "Running standard linux kernel"
    log_info "Standard kernel provides balanced performance"
  fi

  # Apply kernel-specific optimizations
  case "$kernel_type" in
    "Arch Linux (linux-zen)")
      # Gaming/desktop optimizations already in place
      log_info "Arch Linux (linux-zen) already optimized for low latency"
      ;;
    linux-lts)
      # Stability focused
      log_info "LTS kernel - maximum stability"
      ;;
    linux-hardened)
      # Security-focused - minimal changes
      log_info "Hardened kernel - security optimizations active"
      ;;
    *)
      ;;
  esac
}

# Function to check battery status
check_battery_status() {
  step "Checking battery status"

  if [ -d /sys/class/power_supply/BAT0 ] || [ -d /sys/class/power_supply/BAT1 ]; then
    local battery_path="/sys/class/power_supply/BAT0"
    [ ! -d "$battery_path" ] && battery_path="/sys/class/power_supply/BAT1"

    if [ -d "$battery_path" ]; then
      local status=$(cat "$battery_path/status" 2>/dev/null || echo "Unknown")
      local capacity=$(cat "$battery_path/capacity" 2>/dev/null || echo "Unknown")

      log_info "Battery Status: $status"
      log_info "Battery Capacity: ${capacity}%"

      if [ "$status" = "Discharging" ] && [ "$capacity" -lt 30 ]; then
        log_warning "Battery level is low (${capacity}%)"
        log_warning "Consider plugging in AC adapter for installation"
        log_info "Installation may take 20-30 minutes"

        if ! ui_confirm "Continue on battery power?" "The battery is low. Connecting AC power is recommended." false; then
          log_error "Installation cancelled - please connect AC adapter"
          exit 1
        fi
      elif [ "$status" = "Charging" ] || [ "$status" = "Full" ]; then
        log_success "Battery is charging or full - safe to proceed"
      fi
    fi
  else
    log_info "No battery detected (desktop system or AC only)"
  fi
}

# Shared WMI vendor setup: install ACPI (smart), load <vendor>-wmi for
# function keys, enable acpid. Thin table-driven helper so the six vendor
# functions below don't each carry a copy of the same 10 lines.
setup_wmi_vendor() {
  local label="$1" module="$2"
  log_info "Installing ${label}-specific tools..."
  install_smart_acpi
  if [[ -n "$module" ]]; then
    sudo modprobe "$module" 2>/dev/null || true
    if lsmod | grep -q "${module//-/_}"; then
      log_success "${label} WMI module loaded for function key support"
    else
      log_warning "${label} WMI module not available - function keys may not work properly"
    fi
  fi
  sudo systemctl enable acpid.service 2>/dev/null || true
  sudo systemctl start acpid.service 2>/dev/null || true
}

# Function to setup Intel-specific laptop optimizations
setup_intel_laptop_optimizations() {
  step "Configuring Intel-specific laptop optimizations"

  # Install thermald for Intel thermal management
  log_info "Installing thermald for Intel thermal management..."
  install_packages_quietly thermald

  # Enable and start thermald
  sudo systemctl enable thermald.service 2>/dev/null
  sudo systemctl start thermald.service 2>/dev/null

  if systemctl is-active --quiet thermald.service; then
    log_success "thermald is active for thermal management"
  else
    log_warning "thermald may require a reboot"
  fi

  # Check if Intel P-State driver is available
  if [ -d /sys/devices/system/cpu/intel_pstate ]; then
    log_success "Intel P-State driver detected - kernel will manage CPU power"
  else
    log_info "Using ACPI CPUfreq driver for CPU power management"
  fi

  log_success "Intel-specific optimizations completed"
}

# Function to setup Lenovo-specific optimizations
setup_lenovo_optimizations() {
  step "Configuring Lenovo-specific optimizations"

  # Install Lenovo-specific tools
  if command -v yay >/dev/null 2>&1; then
    log_info "Installing lenovo-legion-tool for Lenovo laptops..."
    install_aur_quietly lenovo-legion-tool
    
    # Install ThinkPad firmware tools if detected
    if grep -qi "thinkpad" /sys/class/dmi/id/product_name 2>/dev/null; then
      log_info "Installing ThinkPad-specific tools..."
      install_packages_quietly acpi_call
      install_aur_quietly thinkfan
      # tlp conflicts with power-profiles-daemon; only install if it is not present
      if ! pacman -Q power-profiles-daemon &>/dev/null && ! pacman -Q auto-cpufreq &>/dev/null; then
        install_packages_quietly tlp
      else
        log_warning "Skipping tlp: power-profiles-daemon/auto-cpufreq already detected"
      fi
    fi
  else
    # Install ACPI with smart compatibility handling
    install_smart_acpi
  fi

  # Configure Lenovo function keys
  log_info "Configuring Lenovo function keys..."
  if [ -f /sys/devices/platform/thinkpad_acpi/hotkey_all_mask ]; then
    sudo modprobe thinkpad_acpi 2>/dev/null
    log_success "ThinkPad ACPI driver loaded"
  fi

  # Enable services
  sudo systemctl enable acpid.service 2>/dev/null
  sudo systemctl start acpid.service 2>/dev/null

  log_success "Lenovo optimizations completed"
}

# Function to setup HP-specific optimizations
setup_hp_optimizations() {
  step "Configuring HP-specific optimizations"

  if command -v yay >/dev/null 2>&1; then
    # Install HP Omen gaming tools if detected
    if grep -qi "omen" /sys/class/dmi/id/product_name 2>/dev/null; then
      log_info "Installing HP Omen gaming optimizations..."
      install_aur_quietly omen-monitors
    fi
  fi

  setup_wmi_vendor "HP" "hp-wmi"

  log_success "HP optimizations completed"
}

# Function to setup Dell-specific optimizations
setup_dell_optimizations() {
  step "Configuring Dell-specific optimizations"

  if command -v yay >/dev/null 2>&1; then
    # Install Dell XPS tools if detected
    if grep -qi "xps" /sys/class/dmi/id/product_name 2>/dev/null; then
      log_info "Installing Dell XPS optimizations..."
      install_aur_quietly dell-xps-firmware
    fi
  fi

  setup_wmi_vendor "Dell" "dell-wmi"

  log_success "Dell optimizations completed"
}

# Function to setup Acer-specific optimizations
setup_acer_optimizations() {
  step "Configuring Acer-specific optimizations"

  if command -v yay >/dev/null 2>&1; then
    # Install Acer Nitro gaming tools if detected
    if grep -qi "nitro\|predator" /sys/class/dmi/id/product_name 2>/dev/null; then
      log_info "Installing Acer gaming optimizations..."
      install_aur_quietly acer-nitro-optimizer
    fi
  fi

  setup_wmi_vendor "Acer" "acer-wmi"

  log_success "Acer optimizations completed"
}

# Function to setup ASUS-specific optimizations
setup_asus_optimizations() {
  step "Configuring ASUS-specific optimizations"

  if command -v yay >/dev/null 2>&1; then
    # Install ASUS ROG gaming tools if detected
    if grep -qi "rog\|zenbook" /sys/class/dmi/id/product_name 2>/dev/null; then
      log_info "Installing ASUS ROG/ZenBook optimizations..."
      install_aur_quietly asusctl
      install_aur_quietly supergfxctl
    fi
  fi

  setup_wmi_vendor "ASUS" "asus-wmi"

  log_success "ASUS optimizations completed"
}

# Function to setup MSI-specific optimizations
setup_msi_optimizations() {
  step "Configuring MSI-specific optimizations"

  if command -v yay >/dev/null 2>&1; then
    # Install MSI gaming tools
    log_info "Installing MSI gaming optimizations..."
    install_aur_quietly msi-ec
    install_aur_quietly msi-per-keyboard
  fi

  setup_wmi_vendor "MSI" "msi-wmi"

  log_success "MSI optimizations completed"
}

# Function to setup AMD-specific laptop optimizations
setup_amd_laptop_optimizations() {
  step "Configuring AMD-specific laptop optimizations"

  # Configure smart AMD P-State based on gaming mode presence
  configure_smart_amd_pstate

  log_success "AMD-specific optimizations completed"
}

# AMD P-State status reporting. The amd_pstate driver itself is enabled via
# the kernel cmdline (amd_pstate=active, set in bootloader_config.sh for
# capable AMD CPUs) and the kernel/hardware-managed frequency scaling picks
# the governor — no userspace service forces a governor here (automatic
# governor forcing has been removed). Reporting only.
configure_smart_amd_pstate() {
  local cpu_vendor=$(grep -m1 'vendor_id' /proc/cpuinfo | awk '{print $3}')

  if [[ "$cpu_vendor" != "AuthenticAMD" ]]; then
    log_info "Non-AMD CPU detected - skipping AMD P-State check"
    return 0
  fi

  if [ -d /sys/devices/system/cpu/amd_pstate ]; then
    local scaling_driver
    scaling_driver=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null || echo "unknown")
    local scaling_governor
    scaling_governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "unknown")
    log_success "AMD P-State driver active (driver: $scaling_driver, governor: $scaling_governor — kernel-managed)"
  else
    log_info "AMD CPU without amd_pstate driver (older Ryzen or ACPI CPUfreq in use) — kernel defaults apply"
  fi
}

# Function to setup laptop optimizations
setup_laptop_optimizations() {
  if ! is_laptop; then
    log_info "Desktop system detected. Skipping laptop optimizations."
    return 0
  fi

  step "Laptop detected - Configuring laptop optimizations"
  log_success "Laptop hardware detected"

  # Enhanced detection
  local cpu_vendor=$(detect_cpu_vendor)
  local manufacturer=$(detect_laptop_manufacturer)
  local laptop_model=$(get_laptop_model)
  local is_gaming=$(detect_gaming_laptop "$manufacturer")
  local should_auto=$(should_auto_optimize)
  
  log_info "CPU Vendor: ${cpu_vendor^^}"
  log_info "Laptop Manufacturer: ${manufacturer^^}"
  log_info "Laptop Model: $laptop_model"
  
  if [ "$is_gaming" = "true" ]; then
    log_info "Gaming laptop detected - will apply gaming-specific optimizations"
  fi

  # Get manufacturer-specific optimizations. mapfile (not unquoted `$(...)`
  # inside an array literal) preserves each line as one element — the
  # optimization strings are multi-word ("ThinkPad function keys support"),
  # and plain word-splitting would break each one into several bullets.
  local manufacturer_opts=()
  mapfile -t manufacturer_opts < <(get_manufacturer_optimizations "$manufacturer")

  # Determine if we should enable optimizations
  local enable_laptop_opts=false
  
  if [ "$should_auto" = "true" ]; then
    # Automatic mode - enable optimizations without prompting
    enable_laptop_opts=true
    log_info "Auto-optimization mode enabled - applying laptop optimizations"
  elif command -v gum >/dev/null 2>&1; then
    # Interactive mode with gum
    echo ""
    gum style --foreground "$GUM_WARN" "Laptop-specific optimizations available for ${manufacturer^^} $laptop_model:"
    gum style --margin "0 2" --foreground "$GUM_TEXT" "CPU-specific optimizations (${cpu_vendor^^})"
    
    # Show manufacturer-specific optimizations
    for opt in "${manufacturer_opts[@]}"; do
      gum style --margin "0 2" --foreground "$GUM_TEXT" "$opt"
    done
    
    echo ""
    ( exec </dev/tty >/dev/tty 2>/dev/tty; gum style --foreground "$GUM_WARN" "Tip: Set AUTO_LAPTOP_OPTS=true to skip this prompt in future" </dev/tty )
    if ui_confirm "Enable laptop optimizations?" "These settings are tailored to the detected laptop hardware."; then
      enable_laptop_opts=true
    fi
  else
    # Non-interactive mode
    echo ""
    echo -e "${THEME_WARN}Laptop-specific optimizations available for ${manufacturer^^} $laptop_model:${RESET}"
    echo -e "  \u2022 CPU-specific optimizations (${cpu_vendor^^})"
    
    # Show manufacturer-specific optimizations
    for opt in "${manufacturer_opts[@]}"; do
      echo -e "  \u2022 $opt"
    done
    
    echo ""
    echo -e "${THEME_TEXT}Tip: Set AUTO_LAPTOP_OPTS=true to enable optimizations automatically${RESET}"
    # Prompt is written to /dev/tty because dashboard_run redirects this step's
    # stdout/stderr to the install log.
    printf '%b' "${THEME_SECONDARY}Enable laptop optimizations? [Y/n]: ${RESET}" > /dev/tty
    read -r response < /dev/tty || response=""
    response=${response,,}
    if [[ "$response" != "n" && "$response" != "no" ]]; then
      enable_laptop_opts=true
      # Remember the choice for future runs
      mkdir -p "$HOME/.config"
      echo "true" > "$HOME/.config/archinstaller-laptop-opts"
    else
      mkdir -p "$HOME/.config"
      echo "false" > "$HOME/.config/archinstaller-laptop-opts"
    fi
  fi

  if [ "$enable_laptop_opts" = false ]; then
    log_info "Laptop optimizations skipped by user"
    return 0
  fi

  # Apply CPU-specific optimizations
  case "$cpu_vendor" in
    intel)
      setup_intel_laptop_optimizations
      ;;
    amd)
      setup_amd_laptop_optimizations
      ;;
    *)
      log_info "Unknown CPU vendor - using kernel defaults for power management"
      ;;
  esac

  # Apply manufacturer-specific optimizations
  case "$manufacturer" in
    lenovo)
      setup_lenovo_optimizations
      ;;
    hp)
      setup_hp_optimizations
      ;;
    dell)
      setup_dell_optimizations
      ;;
    acer)
      setup_acer_optimizations
      ;;
    asus)
      setup_asus_optimizations
      ;;
    msi)
      setup_msi_optimizations
      ;;
    *)
      log_info "Unknown or unsupported manufacturer - applying generic optimizations"
      # Install ACPI with smart compatibility handling
      install_smart_acpi
      ;;
  esac

  # Re-apply the single power-manager policy last: vendor setup above may
  # have installed tlp (ThinkPads), which outranks the PPD enabled earlier.
  ensure_single_power_manager

  # Show summary
  show_laptop_summary
}

# Continue setup_laptop_optimizations function
show_laptop_summary() {
  # Display battery information
  step "Battery information"
  if [ -d /sys/class/power_supply/BAT0 ]; then
    local battery_status=$(cat /sys/class/power_supply/BAT0/status 2>/dev/null || echo "Unknown")
    local battery_capacity=$(cat /sys/class/power_supply/BAT0/capacity 2>/dev/null || echo "Unknown")
    log_info "Battery Status: $battery_status"
    log_info "Battery Capacity: ${battery_capacity}%"
  fi

  echo ""
  log_success "Laptop optimizations completed successfully"
  echo ""
  echo -e "${THEME_TEXT}Laptop features configured:${RESET}"
  echo -e "  • Kernel-based power management (automatic)"
  case "$cpu_vendor" in
    intel)
      echo -e "  • Intel thermald (thermal management)"
      if [ -d /sys/devices/system/cpu/intel_pstate ]; then
        echo -e "  • Intel P-State driver (efficient CPU scaling)"
      fi
      ;;
    amd)
      if [ -d /sys/devices/system/cpu/amd_pstate ]; then
        echo -e "  • AMD P-State driver (Ryzen 5000+ efficient scaling)"
      else
        echo -e "  • ACPI CPUfreq driver (Ryzen 1st-4th gen)"
      fi
      ;;
  esac
  echo ""
  echo -e "${THEME_WARN}Tips:${RESET}"
  if [ "$cpu_vendor" = "intel" ]; then
    echo -e "  • Thermal status: ${THEME_SECONDARY}sudo systemctl status thermald${RESET}"
  fi
  echo ""
}

# Execute all service and maintenance steps
if [[ "${DRY_RUN:-false}" == true ]]; then
  ui_info "Dry-run: this installation module would run here."
  exit 0
fi
setup_firewall_and_services
detect_and_install_gpu_drivers
install_vm_guest_agents
check_battery_status
detect_memory_size
detect_filesystem_type
detect_storage_type
detect_audio_system
detect_kernel_type
ensure_sb_signing
setup_laptop_optimizations
setup_hibernation
