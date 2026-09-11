#!/bin/bash

# yay.sh - Install yay AUR helper
# This script installs yay, which is required for AUR package installation
set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"

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
      log_warning "pacman attempt $attempt failed, retrying..."
      sleep 1
    fi
  done
  if [[ $pacman_ok -eq 0 ]]; then
    log_error "Failed to install base-devel, git, or go. Cannot proceed with yay installation."
    return 1
  fi

  # Create temporary directory for building. Distinctive prefix (not a bare
  # mktemp default) so maintenance.sh can safely glob-match and clean up any
  # leftovers if the build is ever interrupted before the trap below runs
  # (e.g. killed process, power loss) — without risking touching unrelated
  # /tmp/tmp.* directories from other processes.
  local temp_dir
  temp_dir=$(mktemp -d /tmp/archinstaller-yay-build.XXXXXXXX) || { log_error "Failed to create temporary directory for yay build"; return 1; }

  local orig_dir; orig_dir=$(pwd)
  local cleanup_tempdir
  cleanup_tempdir() { cd "$orig_dir" 2>/dev/null || true; rm -rf "$temp_dir"; }
  trap cleanup_tempdir RETURN

  cd "$temp_dir" || { log_error "Failed to change to temporary directory"; return 1; }

  # Clone yay repository
  ui_info "Cloning yay repository..."
  if git clone https://aur.archlinux.org/yay.git . 2>&1 | tee -a "$INSTALL_LOG"; then
    log_success "yay repository cloned successfully"
  else
    log_error "Failed to clone yay repository"
    return 1
  fi

  # Build yay. Deliberately build-only (-s, not -si): Arch's default
  # makepkg.conf has `debug` in OPTIONS, so a plain `-si` here would also
  # build AND auto-install a yay-debug package nobody asked for (extra
  # download size, no use for it without gdb work on yay itself). Building
  # separately lets us install only the real package below.
  ui_info "Building yay..."
  echo -e "${THEME_TEXT}Please enter your sudo password to build and install yay:${RESET}"
  sudo -v
  if makepkg -s --noconfirm --needed 2>&1 | tee -a "$INSTALL_LOG"; then
    log_success "yay built successfully"
  else
    log_error "Failed to build yay"
    return 1
  fi

  # Install only the real yay package — explicitly exclude any -debug
  # package tarball that makepkg produced alongside it.
  ui_info "Installing yay..."
  local pkg_files=()
  while IFS= read -r -d '' f; do
    pkg_files+=("$f")
  done < <(find . -maxdepth 1 -name 'yay-[0-9]*.pkg.tar.*' ! -name '*-debug-*' -print0)

  if [[ ${#pkg_files[@]} -eq 0 ]]; then
    log_error "yay build succeeded but no installable package file was found"
    return 1
  fi

  if sudo pacman -U --noconfirm --needed "${pkg_files[@]}" 2>&1 | tee -a "$INSTALL_LOG"; then
    log_success "yay installed successfully"
  else
    log_error "Failed to install yay package"
    return 1
  fi

  # Verify installation
  ui_info "Verifying yay installation..."
  if command -v yay &>/dev/null; then
    log_success "yay installation verified"
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

  # Import GPG keys for makepkg (reduces AUR build key errors; failures are non-fatal).
  # Key 0xEA33F3A8DE0F8D6E is the `yay` upstream release signing key
  # (Jguer) used to verify yay source tarballs built via makepkg.
  ui_info "Importing GPG keys..."
  gpg --keyserver keyserver.ubuntu.com --recv-keys 0xEA33F3A8DE0F8D6E 2>/dev/null || log_debug "GPG key import skipped/failed (non-fatal)"

  # Clean up
  ui_info "Cleaning up temporary files..."
  cleanup_tempdir
  trap - RETURN
}

# Execute yay installation
if [[ "${DRY_RUN:-false}" == true ]]; then
  ui_info "Dry-run: this installation module would run here."
  exit 0
fi
install_yay
