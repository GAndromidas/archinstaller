#!/bin/bash
set -uo pipefail

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Use different variable names to avoid conflicts
INSTALLED=()
ENABLED=()
CONFIGURED=()

# ======= Fail2ban Setup Steps =======
install_fail2ban() {
  if pacman -Q fail2ban >/dev/null 2>&1; then
    log_info "fail2ban already installed, skipping"
    return 0
  fi
  
  ui_info "Installing fail2ban..."
  if pacman_install_single "fail2ban" false; then
    INSTALLED+=("fail2ban")
    return 0
  else
    return 1
  fi
}

enable_and_start_fail2ban() {
  ui_info "Enabling and starting fail2ban service..."
  if sudo systemctl enable --now fail2ban >/dev/null 2>&1; then
    log_success "fail2ban service enabled and started"
    ENABLED+=("fail2ban")
    return 0
  else
    log_error "Failed to enable and start fail2ban service"
    return 1
  fi
}

configure_fail2ban() {
  local jail_local="/etc/fail2ban/jail.local"
  if [ ! -f "$jail_local" ]; then
    ui_info "Configuring fail2ban jail.local..."
    sudo cp /etc/fail2ban/jail.conf "$jail_local"
    sudo sed -i 's/^backend = auto/backend = systemd/' "$jail_local"
    sudo sed -i 's/^bantime  = 10m/bantime = 1h/' "$jail_local"
    sudo sed -i 's/^findtime  = 10m/findtime = 10m/' "$jail_local"
    sudo sed -i 's/^maxretry = 5/maxretry = 3/' "$jail_local"
    log_success "fail2ban jail.local configured"
    CONFIGURED+=("jail.local")
  else
    log_info "jail.local already exists, skipping configuration"
  fi
}

status_fail2ban() {
  if sudo systemctl status fail2ban --no-pager >/dev/null 2>&1; then
    log_success "fail2ban service is running"
    return 0
  else
    log_error "fail2ban service is not running"
    return 1
  fi
}

# ======= Main =======
main() {
  echo -e "${CYAN}=== Fail2ban Setup ===${RESET}"

  run_step "Installing fail2ban" install_fail2ban
  run_step "Enabling and starting fail2ban" enable_and_start_fail2ban
  run_step "Configuring fail2ban (jail.local)" configure_fail2ban
  run_step "Checking fail2ban status" status_fail2ban
}

main "$@"
