#!/bin/bash
set -uo pipefail

# ============================================================================
# System Services Configuration - Firewall Module
# ============================================================================
# UFW and Firewalld configuration for Arch Linux and EndeavourOS

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

configure_firewall_service() {
  step "Configuring firewall (UFW/Firewalld)"

  # Auto-detect: prefer firewalld if available and not Arch, otherwise UFW
  local firewall="ufw"
  if command -v firewalld >/dev/null 2>&1 || [[ "$DISTRO" != "Arch" ]]; then
    firewall="firewalld"
  fi

  if [[ "$firewall" == "firewalld" ]]; then
    configure_firewalld
  else
    configure_ufw
  fi
}

configure_firewalld() {
  step "Configuring Firewalld"

  # Start and enable firewalld
  sudo systemctl start firewalld
  sudo systemctl enable firewalld

  # Set default zone to drop — deny incoming, allow outgoing
  sudo firewall-cmd --set-default-zone=drop
  log_success "Default zone set to drop (incoming denied, outgoing allowed)"

  # Allow SSH
  if ! sudo firewall-cmd --list-all | grep -q "22/tcp"; then
    sudo firewall-cmd --add-service=ssh --permanent
    sudo firewall-cmd --reload
    log_success "SSH allowed through Firewalld"
  fi

  # Check if KDE Connect is installed
  if pacman -Q kdeconnect &>/dev/null; then
    sudo firewall-cmd --add-port=1714-1764/udp --permanent
    sudo firewall-cmd --add-port=1714-1764/tcp --permanent
    sudo firewall-cmd --reload
    log_success "KDE Connect ports allowed (1714-1764)"
  fi

  # Portainer ports (8000, 9443)
  if sudo docker images 2>/dev/null | grep -q portainer || pacman -Q portainer &>/dev/null; then
    if ! sudo firewall-cmd --list-ports 2>/dev/null | grep -q "8000/tcp"; then
      sudo firewall-cmd --add-port=8000/tcp --permanent
      sudo firewall-cmd --add-port=9443/tcp --permanent
      sudo firewall-cmd --reload
      log_success "Portainer ports opened (8000, 9443)"
    fi
  fi
}

configure_ufw() {
  step "Configuring UFW (Uncomplicated Firewall)"

  # Install UFW if not present
  if ! command -v ufw >/dev/null 2>&1; then
    install_packages_quietly ufw
    log_success "UFW installed"
  fi

  # Enable UFW
  sudo ufw --force enable
  sudo systemctl enable --now ufw 2>/dev/null || true

  # Set default policies
  sudo ufw default deny incoming
  sudo ufw default allow outgoing
  log_success "Default policies set (deny incoming, allow outgoing)"

  # Allow SSH
  sudo ufw allow 22/tcp >>"$INSTALL_LOG" 2>&1 || true
  sudo ufw allow OpenSSH >>"$INSTALL_LOG" 2>&1 || true

  if sudo ufw status 2>/dev/null | grep -qE "22|ssh|OpenSSH"; then
    log_success "SSH allowed through UFW"
  fi

  # Allow KDE Connect if installed
  if pacman -Q kdeconnect &>/dev/null; then
    sudo ufw allow 1714:1764/udp >>"$INSTALL_LOG" 2>&1 || true
    sudo ufw allow 1714:1764/tcp >>"$INSTALL_LOG" 2>&1 || true
    log_success "KDE Connect ports allowed"
  fi

  # Allow Portainer ports if installed
  if sudo docker images 2>/dev/null | grep -q portainer; then
    sudo ufw allow 8000/tcp >>"$INSTALL_LOG" 2>&1 || true
    sudo ufw allow 9443/tcp >>"$INSTALL_LOG" 2>&1 || true
    log_success "Portainer ports allowed (8000, 9443)"
  fi
}
