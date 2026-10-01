#!/bin/bash
set -uo pipefail

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

if [[ "${DRY_RUN:-false}" == true ]]; then
  ui_info "Dry-run: System preparation would run here."
  exit 0
fi

# NOTE: Pacman behavior is left at distro defaults, except for the cosmetic
# Color + ILoveCandy display options. A forced ParallelDownloads value has
# been removed — it changes package-manager behavior for no functional
# reason. Only display settings (Color, ILoveCandy, VerbosePkgLists) and
# the required multilib repository are managed here.

check_prerequisites() {
  step "Checking system prerequisites"
  if [[ $EUID -eq 0 ]]; then
    log_error "Do not run this script as root. Please run as a regular user with sudo -n privileges."
    return 1
  fi
  
  # yq is now included in BASE_HELPER_UTILS and will be installed with helper utilities
  if ! command -v pacman >/dev/null; then
    log_error "This script is intended for Arch Linux systems with pacman."
    return 1
  fi

  # Check internet connection (robust: DNS + IP + getent, same as
  # check_system_compatibility — single-ping checks fail behind captive
  # portals / IPv6-only / flaky DNS and are not worth failing the run over)
  if ! ping -c 1 -W 5 archlinux.org &>/dev/null && ! ping -c 1 -W 5 8.8.8.8 &>/dev/null && ! getent hosts archlinux.org &>/dev/null; then
    log_error "No internet connection detected. Please check your network (cable/Wi-Fi and DNS - try: ping 8.8.8.8)."
    return 1
  fi

  log_success "Prerequisites OK."
}

configure_pacman() {
  step "Configuring pacman"

  # Ensure mirrorlist exists before any pacman operation
  generate_default_mirrorlist

  if grep -q "^#Color" /etc/pacman.conf; then
    sudo -n sed -i 's/^#Color/Color/' /etc/pacman.conf
    log_success "Uncommented Color setting"
  fi

  if grep -q "^#VerbosePkgLists" /etc/pacman.conf; then
    sudo -n sed -i 's/^#VerbosePkgLists/VerbosePkgLists/' /etc/pacman.conf
    log_success "Uncommented VerbosePkgLists setting"
  fi

  if grep -q "^ILoveCandy" /etc/pacman.conf; then
    log_info "ILoveCandy already enabled — skipping"
  elif grep -q "^#ILoveCandy" /etc/pacman.conf; then
    sudo -n sed -i 's/^#ILoveCandy/ILoveCandy/' /etc/pacman.conf
    log_success "Uncommented ILoveCandy setting"
  elif grep -q "^Color" /etc/pacman.conf; then
    sudo -n sed -i '/^Color/a ILoveCandy' /etc/pacman.conf
    log_success "Added ILoveCandy setting"
  else
    sudo -n sed -i "/^\[options\]/a ILoveCandy" /etc/pacman.conf
    log_success "Added ILoveCandy setting"
  fi

  enable_multilib_repo

  echo ""
}

install_all_packages() {
  local packages_to_install=("${HELPER_UTILS[@]}")

  if [[ "${INSTALL_MODE:-}" == "server" ]]; then
    ui_info "Server mode: Filtering out desktop-specific helper utilities (bluetooth)..."
    local server_filtered_packages=()
    for pkg in "${packages_to_install[@]}"; do
      if [[ "$pkg" != "bluez-utils" ]]; then
        server_filtered_packages+=("$pkg")
      fi
    done
    packages_to_install=("${server_filtered_packages[@]}")
  fi

  local all_packages=(
    "${packages_to_install[@]}"
    zsh zsh-autosuggestions zsh-syntax-highlighting
    starship
  )

  step "Installing all packages"
  echo -e "${THEME_TEXT}Installing ${#all_packages[@]} total packages via Pacman (${#packages_to_install[@]} helper utilities + shell)...${RESET}"

  if [ "${DRY_RUN:-false}" = true ]; then
    ui_info "Dry-run: would install these packages via Pacman:"
    printf '  %s\n' "${all_packages[@]}"
    INSTALLED_PACKAGES+=("${all_packages[@]}")
    return 0
  fi

  printf '%b' "${THEME_TEXT}Attempting batch installation...${RESET}\n"
  if sudo -n pacman -S --noconfirm --needed "${all_packages[@]}" >>"$INSTALL_LOG" 2>&1; then
    printf '%b' "${THEME_SUCCESS} ✓ Batch installation successful${RESET}\n"
    INSTALLED_PACKAGES+=("${all_packages[@]}")
    return 0
  fi

  printf '%b' "${THEME_WARN} ! Batch installation failed. Falling back to individual installation...${RESET}\n"

  if [ ${#all_packages[@]} -eq 0 ]; then
    log_warning "No packages to install individually"
    return 0
  fi

  local total=${#all_packages[@]}
  local current=0
  local failed_packages=()

  for pkg in "${all_packages[@]}"; do
    if pacman -Q "$pkg" &>/dev/null; then
      log_to_file "$pkg already installed"
      INSTALLED_PACKAGES+=("$pkg")
      continue
    fi

    if sudo -n pacman -S --noconfirm --needed "$pkg" >>"$INSTALL_LOG" 2>&1; then
      log_success "$pkg installed successfully"
      INSTALLED_PACKAGES+=("$pkg")
    else
      log_error "Failed to install $pkg"
      failed_packages+=("$pkg")
    fi
  done

  echo -e "\n${THEME_SUCCESS}Package installation completed${RESET}"

  if [ ${#failed_packages[@]} -gt 0 ]; then
    echo -e "${THEME_WARN}Failed packages: ${failed_packages[*]}${RESET}"
    log_warning "Some packages failed to install. Continuing with installation..."
    # Return non-zero to indicate partial failure
    return 1
  fi

  echo ""
}

set_sudo_pwfeedback() {
  # Globs must expand as root (sudo -n sh -c): /etc/sudoers.d is 750, so a
  # user-expanded glob never matches and pwfeedback would be appended again
  # on every run.
  if ! sudo -n sh -c 'grep -q "^Defaults.*pwfeedback" /etc/sudoers /etc/sudoers.d/* 2>/dev/null'; then
    run_step "Enabling sudo -n password feedback" bash -c "echo 'Defaults env_reset,pwfeedback' | sudo -n EDITOR='tee -a' visudo"
  else
    log_warning "sudo -n pwfeedback already enabled. Skipping."
  fi
}

install_cpu_microcode() {
  step "Detecting CPU and installing appropriate microcode"
  # archinstall already installs the correct microcode at install time
  # (Installer._get_microcode) and deliberately installs NONE on VMs — so
  # this is a verify-only ensure, never a reinstall. Skip fast when the
  # package is already present, and never install ucode inside a VM guest.
  if is_vm 2>/dev/null; then
    log_info "VM guest detected — archinstall installs no microcode on VMs, skipping."
    return 0
  fi
  local pkg=""

  if grep -q "Intel" /proc/cpuinfo; then
    log_info "Intel CPU detected - ensuring intel-ucode (usually already installed by archinstall)"
    pkg="intel-ucode"
  elif grep -q "AMD" /proc/cpuinfo; then
    log_info "AMD CPU detected - ensuring amd-ucode (usually already installed by archinstall)"
    pkg="amd-ucode"
  else
    log_warning "Unable to determine CPU type. No microcode package will be installed."
  fi

  if [ -n "$pkg" ]; then
    if pacman -Q "$pkg" &>/dev/null; then
      log_info "$pkg already installed (provided by archinstall) — nothing to do"
    else
      if sudo -n pacman -S --noconfirm --needed "$pkg" >>"$INSTALL_LOG" 2>&1; then
        log_success "$pkg installed successfully"
        INSTALLED_PACKAGES+=("$pkg")
      else
        log_error "Failed to install $pkg"
      fi
    fi
  fi
}

install_kernel_headers_for_all() {
  step "Installing kernel headers for all installed kernels"
  local kernel_types=()
  mapfile -t kernel_types < <(get_installed_kernel_types)

  if [ "${#kernel_types[@]}" -eq 0 ]; then
    log_warning "No supported kernel types detected. Please check your system configuration."
    return
  fi

  echo -e "${THEME_TEXT}Detected kernels: ${kernel_types[*]}${RESET}"

  local total=${#kernel_types[@]}
  local current=0
  local header_packages=()

  for kernel in "${kernel_types[@]}"; do
    header_packages+=("${kernel}-headers")
  done

  # Try batch install first
  printf '%b' "${THEME_TEXT}Attempting batch installation for headers...${RESET}\n"
  if sudo -n pacman -S --noconfirm --needed "${header_packages[@]}" >>"$INSTALL_LOG" 2>&1; then
    printf '%b' "${THEME_SUCCESS} ✓ Batch installation successful${RESET}\n"
    INSTALLED_PACKAGES+=("${header_packages[@]}")
    return 0
  fi

  printf '%b' "${THEME_WARN} ! Batch installation failed. Falling back to individual installation...${RESET}\n"

  for kernel in "${kernel_types[@]}"; do
    local headers_package="${kernel}-headers"

    if pacman -Q "$headers_package" &>/dev/null; then
      log_to_file "$headers_package already installed"
    else
      if sudo -n pacman -S --noconfirm --needed "$headers_package" >>"$INSTALL_LOG" 2>&1; then
        log_success "$headers_package installed successfully"
        INSTALLED_PACKAGES+=("$headers_package")
      else
        log_error "Failed to install $headers_package"
      fi
    fi
  done

  echo -e "\\n${THEME_SUCCESS}Kernel headers installation completed${RESET}\\n"
}

# Fixed locale set: en_US (system default, already configured by archinstall
# via set_locale) + el_GR (Greece, archinstaller's extra). No geo-IP
# detection — external lookups are slow behind captive portals and
# nondeterministic across runs.
generate_locales() {
  step "Configuring system locales (en_US + el_GR)"

  # archinstall already uncomments the chosen sys_lang (normally en_US),
  # runs locale-gen and writes /etc/locale.conf — re-doing that is pure
  # overhead (locale-gen is slow). Only touch a locale line when it is
  # actually still commented, and only regenerate when something changed.
  # el_GR is archinstaller's own extra on top of the archinstall default.
  local changed=false
  local locale
  for locale in "en_US.UTF-8" "el_GR.UTF-8"; do
    if grep -q "^#${locale} UTF-8" /etc/locale.gen; then
      sudo -n sed -i "s/^#${locale} UTF-8/${locale} UTF-8/" /etc/locale.gen
      log_success "Enabled locale: $locale"
      changed=true
    elif grep -q "^${locale} UTF-8" /etc/locale.gen; then
      log_info "Locale already enabled by archinstall: $locale — skipping"
    else
      log_warning "Locale not found in /etc/locale.gen: $locale"
    fi
  done

  if [[ "$changed" == true ]]; then
    run_step "Regenerating locales" sudo -n locale-gen
  else
    log_info "Locales already configured — skipping locale-gen (no changes)"
  fi
}

# Execute system preparation in dependency order:
# 1. Prerequisites
# 2. Configure pacman (Color, ILoveCandy, VerbosePkgLists, multilib — distro download defaults kept)
# 3. Install the mirror ranking tool (rate-mirrors) so the ranking below works
# 4. Update mirrors FIRST so all subsequent downloads are fast
#    (update_system_mirrors syncs once with -Syy after ranking)
# 5. Full system update via update_system (single -Syu, no extra -Syy)
# 6. Install packages (benefits from fast mirrors + parallel downloads)
# 7. Remaining setup tasks
check_prerequisites
configure_pacman
# Install the mirror ranking tool (rate-mirrors) so ranking below works. It is
# also part of HELPER_UTILS, so this just ensures it exists before ranking.
if [ "${DRY_RUN:-false}" != true ]; then
  run_step "Installing mirror ranking tool" sudo -n pacman -S --noconfirm --needed rate-mirrors
fi
update_system_mirrors
# Pre-upgrade snapshot: on btrfs+snapper, checkpoint before the full -Syu
# so a bad upgrade is one rollback away. Best-effort, never fatal.
if command -v snapper &>/dev/null && findmnt -n -o FSTYPE / 2>/dev/null | grep -q btrfs; then
  if sudo -n snapper -c root create --description "pre-archinstaller-system-update" >>"$INSTALL_LOG" 2>&1; then
    log_success "Pre-update snapper snapshot created"
  else
    log_debug "Pre-update snapper snapshot skipped (no config or btrfs layout)"
  fi
fi
# update_system_mirrors already ran `pacman -Syy` after ranking, and
# update_system runs `pacman -Syu` (which syncs again) — no extra -Syy needed.
update_system
install_all_packages
set_sudo_pwfeedback
install_cpu_microcode
install_kernel_headers_for_all

# Add Flathub remote once upfront (used by programs.sh and gaming_mode.sh later)
if command -v flatpak >/dev/null 2>&1; then
  if ! sudo -n flatpak remote-list --system 2>/dev/null | grep -q flathub; then
    step "Adding Flathub remote"
    sudo -n flatpak remote-add --if-not-exists --system flathub https://dl.flathub.org/repo/flathub.flatpakrepo
    log_success "Flathub remote added"
  fi
fi

generate_locales
