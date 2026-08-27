#!/bin/bash
set -uo pipefail

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Detect which firewall is active and return its fail2ban backend
detect_firewall_backend() {
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    echo "firewalld"
  elif command -v ufw >/dev/null 2>&1 && systemctl is-active --quiet ufw 2>/dev/null; then
    echo "ufw"
  else
    echo "systemd"
  fi
}

# Install fail2ban
install_fail2ban() {
  if pacman -Q fail2ban >/dev/null 2>&1; then
    log_info "fail2ban already installed, skipping"
    return 0
  fi

  ui_info "Installing fail2ban..."
  if pacman_install_single "fail2ban" false; then
    return 0
  else
    return 1
  fi
}

# Configure fail2ban jail.local based on detected firewall
configure_fail2ban() {
  local jail_local="/etc/fail2ban/jail.local"
  local backend
  backend=$(detect_firewall_backend)

  if [ -f "$jail_local" ]; then
    log_info "jail.local already exists, updating backend and SSH jail..."
  fi

  ui_info "Configuring fail2ban for $backend firewall..."

  # Create jail.local from jail.conf as base
  if [ ! -f "$jail_local" ]; then
    sudo cp /etc/fail2ban/jail.conf "$jail_local"
  fi

  # Set backend based on firewall type
  # - firewalld: fail2ban has native firewalld support
  # - ufw: uses systemd journal backend
  # - systemd: fallback for any firewall
  sudo sed -i "s/^backend = .*/backend = $backend/" "$jail_local"

  # Configure SSH jail
  sudo sed -i '/^\[sshd\]/,/^$/ {
    s/^enabled = .*/enabled = true/
    s/^port = .*/port = ssh/
    s/^filter = .*/filter = sshd/
    s/^logpath = .*/logpath = \/var\/log\/auth.log/
    s/^maxretry = .*/maxretry = 3/
    s/^bantime = .*/bantime = 1h/
    s/^findtime = .*/findtime = 10m/
  }' "$jail_local"

  # For firewalld backend, use firewallcmd-rich-rules action
  # For ufw/systemd, use the default iptables or nftables action
  if [ "$backend" = "firewalld" ]; then
    sudo sed -i '/^\[sshd\]/,/^$/ {
      s/^action = .*/action = firewallcmd-rich-rules[actiontype=<multiport>]\n          blocktype=drop/
    }' "$jail_local"
  fi

  # Set default ban parameters globally if not already set
  sudo sed -i 's/^bantime  = .*/bantime  = 1h/' "$jail_local"
  sudo sed -i 's/^findtime  = .*/findtime  = 10m/' "$jail_local"
  sudo sed -i 's/^maxretry = .*/maxretry = 3/' "$jail_local"

  log_success "fail2ban jail.local configured (backend: $backend)"
}

# Enable and start fail2ban service
enable_and_start_fail2ban() {
  ui_info "Enabling and starting fail2ban service..."

  # Reload systemd in case fail2ban was just installed
  sudo systemctl daemon-reload >/dev/null 2>&1

  if sudo systemctl enable --now fail2ban >>"$INSTALL_LOG" 2>&1; then
    log_success "fail2ban service enabled and started"
    return 0
  else
    log_error "Failed to enable and start fail2ban service"
    return 1
  fi
}

# Verify fail2ban is running and SSH jail is active
status_fail2ban() {
  # Check service status
  if ! sudo systemctl is-active --quiet fail2ban 2>/dev/null; then
    log_error "fail2ban service is not running"
    return 1
  fi

  # Check if sshd jail is in the list
  local jails
  jails=$(sudo fail2ban-client status 2>/dev/null | grep "Jail list" | sed 's/.*://;s/,/ /g; s/^[[:space:]]*//')
  if echo "$jails" | grep -q "sshd"; then
    log_success "fail2ban sshd jail is active"
    log_info "Active jails: $jails"
    return 0
  else
    log_warning "fail2ban is running but sshd jail may not be active"
    log_info "Active jails: ${jails:-none}"
    return 0
  fi
}

# ======= Main =======
main() {
  echo -e "${THEME_BORDER}=== Fail2ban Setup ===${RESET}"

  local backend
  backend=$(detect_firewall_backend)
  ui_info "Detected firewall backend: $backend"

  run_step "Installing fail2ban" install_fail2ban
  run_step "Configuring fail2ban (jail.local)" configure_fail2ban
  run_step "Enabling and starting fail2ban" enable_and_start_fail2ban
  run_step "Checking fail2ban status" status_fail2ban
}

main "$@"
