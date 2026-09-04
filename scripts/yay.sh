#!/bin/bash

# yay.sh - Install yay-bin AUR helper (prebuilt, faster than yay)
# This script installs yay-bin, which provides yay for AUR package installation
set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

install_yay() {
  step "Installing yay-bin AUR helper (prebuilt)"

  # Check if yay is already installed (yay or yay-bin both provide yay)
  if command -v yay &>/dev/null; then
    log_success "yay is already installed"
    return 0
  fi
  if pacman -Q yay-bin &>/dev/null 2>&1; then
    log_success "yay-bin is already installed"
    return 0
  fi

  # Ensure base-devel and git are installed (yay-bin is prebuilt, no go needed - faster)
  log_info "Ensuring base-devel and git are installed (yay-bin, no go)..."
  if ! sudo -v; then
    log_error "Failed to refresh sudo credentials. Cannot proceed with yay installation."
    return 1
  fi
  local pacman_retries=3
  local pacman_ok=0
  for ((attempt = 1; attempt <= pacman_retries; attempt++)); do
    if sudo pacman -S --noconfirm --needed base-devel git 2>&1 | tee -a "$INSTALL_LOG"; then
      pacman_ok=1
      break
    fi
    if [[ $attempt -lt $pacman_retries ]]; then
      log_warning "pacman attempt $attempt failed, retrying..."
      sleep 1
    fi
  done
  if [[ $pacman_ok -eq 0 ]]; then
    log_error "Failed to install base-devel or git. Cannot proceed with yay-bin installation."
    return 1
  fi

  # Create temporary directory for building
  local temp_dir
  temp_dir=$(mktemp -d) || { log_error "Failed to create temporary directory for yay build"; return 1; }

  local orig_dir; orig_dir=$(pwd)
  local cleanup_tempdir
  cleanup_tempdir() { cd "$orig_dir" 2>/dev/null || true; rm -rf "$temp_dir"; }
  trap cleanup_tempdir RETURN

  cd "$temp_dir" || { log_error "Failed to change to temporary directory"; return 1; }

  # Clone yay-bin repository (prebuilt binary, faster than yay source, no go)
  ui_info "Cloning yay-bin repository..."
  if git clone https://aur.archlinux.org/yay-bin.git . 2>&1 | tee -a "$INSTALL_LOG"; then
    log_success "yay-bin repository cloned successfully"
  else
    log_error "Failed to clone yay-bin repository"
    return 1
  fi

  # Build yay-bin (installs prebuilt binary, no compilation)
  ui_info "Installing yay-bin (prebuilt)..."
  echo -e "${THEME_TEXT}Please enter your sudo password to install yay-bin:${RESET}"
  sudo -v
  if makepkg -si --noconfirm --needed 2>&1 | tee -a "$INSTALL_LOG"; then
    log_success "yay-bin installed successfully"
  else
    log_error "Failed to install yay-bin"
    return 1
  fi

  # Verify installation (yay-bin provides yay command)
  ui_info "Verifying yay installation..."
  if command -v yay &>/dev/null; then
    log_success "yay (yay-bin) installation verified"
  else
    log_error "yay installation verification failed"
    return 1
  fi

  # Configure yay for faster AUR builds
  ui_info "Configuring yay for optimal performance..."
  local yay_config_dir="$HOME/.config/yay"
  mkdir -p "$yay_config_dir"
  cat > "$yay_config_dir/config.json" << 'YAYEOF'
{
    "bottomup": true,
    "devel": false,
    "cleanAfter": false,
    "batchInstall": true
}
YAYEOF
  log_success "yay configured with BatchInstall=true for faster AUR builds"

  # Import GPG keys for makepkg (reduces AUR build key errors; failures are non-fatal)
  ui_info "Importing GPG keys..."
  gpg --keyserver keyserver.ubuntu.com --recv-keys 0xEA33F3A8DE0F8D6E 2>/dev/null || true

  # Clean up
  ui_info "Cleaning up temporary files..."
  cleanup_tempdir
  trap - RETURN
}

# Execute yay installation
install_yay
