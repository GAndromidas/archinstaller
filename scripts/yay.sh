#!/bin/bash

# yay.sh - Install yay AUR helper
# This script installs yay, which is required for AUR package installation
set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

install_yay() {
  step "Installing yay AUR helper"

  # Check if yay is already installed
  if command -v yay &>/dev/null; then
    log_success "yay is already installed"
    return 0
  fi

  # Ensure base-devel, git, and go are installed (required for building yay)
  log_info "Ensuring base-devel, git, and go are installed..."
  if ! sudo -v; then
    log_error "Failed to refresh sudo credentials. Cannot proceed with yay installation."
    return 1
  fi
  local pacman_retries=3
  local pacman_ok=0
  for ((attempt = 1; attempt <= pacman_retries; attempt++)); do
    if sudo pacman -S --noconfirm --needed base-devel git go 2>&1 | tee -a "$INSTALL_LOG"; then
      pacman_ok=1
      break
    fi
    if [[ $attempt -lt $pacman_retries ]]; then
      log_warning "pacman attempt $attempt failed, retrying in 3 seconds..."
      sleep 3
    fi
  done
  if [[ $pacman_ok -eq 0 ]]; then
    log_error "Failed to install base-devel, git, or go. Cannot proceed with yay installation."
    return 1
  fi

  # Create temporary directory for building
  local temp_dir
  temp_dir=$(mktemp -d)
  cd "$temp_dir" || { log_error "Failed to create temporary directory"; return 1; }

  # Clone yay repository
  ui_info "Cloning yay repository..."
  if git clone https://aur.archlinux.org/yay.git . 2>&1 | tee -a "$INSTALL_LOG"; then
    log_success "yay repository cloned successfully"
  else
    log_error "Failed to clone yay repository"
    cd - >/dev/null && rm -rf "$temp_dir"
    return 1
  fi

  # Build yay
  ui_info "Building and installing yay..."
  echo -e "${THEME_TEXT}Please enter your sudo password to build and install yay:${RESET}"
  sudo -v
  if makepkg -si --noconfirm --needed 2>&1 | tee -a "$INSTALL_LOG"; then
    log_success "yay built and installed successfully"
  else
    log_error "Failed to build yay"
    cd - >/dev/null && rm -rf "$temp_dir"
    return 1
  fi

  # Verify installation
  ui_info "Verifying yay installation..."
  if command -v yay &>/dev/null; then
    log_success "yay installation verified"
  else
    log_error "yay installation verification failed"
    cd - >/dev/null && rm -rf "$temp_dir"
    return 1
  fi

  # Clean up
  ui_info "Cleaning up temporary files..."
  cd - >/dev/null && rm -rf "$temp_dir"
}

# Execute yay installation
install_yay
