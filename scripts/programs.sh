#!/bin/bash

export SUDO_ASKPASS=   # Force sudo to prompt in terminal, not via GUI

# ===== Colors for output =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

# ===== Globals =====
CURRENT_STEP=1
ERRORS=()
INSTALLED_PKGS=()
REMOVED_PKGS=()

# ===== Output Functions =====
step()   { echo -e "\n${CYAN}[$CURRENT_STEP] $1${RESET}"; ((CURRENT_STEP++)); }
log_success() { echo -e "${GREEN}[OK] $1${RESET}"; }
log_warning() { echo -e "${YELLOW}[WARN] $1${RESET}"; }
log_error()   { echo -e "${RED}[FAIL] $1${RESET}"; ERRORS+=("$1"); }

# ===== Program Lists =====
pacman_programs_default=(android-tools bat bleachbit btop cmatrix dosfstools expac firefox fwupd gamemode gnome-disk-utility hwinfo inxi lib32-gamemode lib32-mangohud mangohud net-tools noto-fonts-extra ntfs-3g samba sl speedtest-cli sshfs ttf-hack-nerd ttf-liberation unrar xdg-desktop-portal-gtk)
essential_programs_default=(discord filezilla gimp kdenlive libreoffice-fresh lutris obs-studio steam timeshift vlc wine)
pacman_programs_minimal=(android-tools bat bleachbit btop cmatrix dosfstools expac firefox fwupd gamemode gnome-disk-utility hwinfo inxi lib32-gamemode net-tools noto-fonts-extra ntfs-3g samba sl speedtest-cli sshfs ttf-hack-nerd ttf-liberation unrar xdg-desktop-portal-gtk)
essential_programs_minimal=(libreoffice-fresh timeshift vlc)
kde_install_programs=(gwenview kdeconnect kwalletmanager kvantum okular power-profiles-daemon python-pyqt5 python-pyqt6 qbittorrent spectacle)
kde_remove_programs=(htop)
gnome_install_programs=(celluloid dconf-editor gnome-tweaks gufw seahorse transmission-gtk)
gnome_remove_programs=(epiphany gnome-contacts gnome-maps gnome-music gnome-tour htop snapshot totem)
cosmic_install_programs=(power-profiles-daemon transmission-gtk)
cosmic_remove_programs=(htop)
yay_programs_default=(heroic-games-launcher-bin megasync-bin spotify stremio via-bin)
yay_programs_minimal=(stremio)

# ===== Helper Functions =====

is_package_installed() { command -v "$1" &>/dev/null || pacman -Q "$1" &>/dev/null; }

handle_error() { if [ $? -ne 0 ]; then log_error "$1"; return 1; fi; return 0; }

check_yay() { if ! command -v yay &>/dev/null; then log_error "yay (AUR helper) is not installed. Please install yay and rerun."; exit 1; fi; }

check_flatpak() {
  if ! command -v flatpak &>/dev/null; then
    log_error "flatpak is not installed. Please install flatpak and rerun."
    exit 1
  fi
  if ! flatpak remote-list | grep -q flathub; then
    step "Adding Flathub remote"
    flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
    handle_error "Failed to add Flathub remote."
  fi
  step "Updating Flatpak remotes"
  flatpak update -y
}

# ===== Unified Quiet Install Functions =====

install_pacman_quietly() {
  local pkgs=("$@")
  for pkg in "${pkgs[@]}"; do
    if pacman -Q "$pkg" &>/dev/null; then
      echo -e "${YELLOW}Installing: $pkg ... [SKIP] Already installed${RESET}"
      continue
    fi
    echo -ne "${CYAN}Installing: $pkg ...${RESET} "
    if sudo pacman -S --noconfirm --needed "$pkg" >/dev/null 2>&1; then
      echo -e "${GREEN}[OK]${RESET}"
      INSTALLED_PKGS+=("$pkg")
    else
      echo -e "${RED}[FAIL]${RESET}"
      log_error "Failed to install $pkg"
    fi
  done
}

install_flatpak_quietly() {
  local pkgs=("$@")
  for pkg in "${pkgs[@]}"; do
    if flatpak list --app | grep -qw "$pkg"; then
      echo -e "${YELLOW}Flatpak: $pkg ... [SKIP] Already installed${RESET}"
      continue
    fi
    echo -ne "${CYAN}Flatpak: $pkg ...${RESET} "
    if flatpak install -y --noninteractive flathub "$pkg" >/dev/null 2>&1; then
      echo -e "${GREEN}[OK]${RESET}"
      INSTALLED_PKGS+=("$pkg (flatpak)")
    else
      echo -e "${RED}[FAIL]${RESET}"
      log_error "Failed to install Flatpak $pkg"
    fi
  done
}

install_aur_quietly() {
  local pkgs=("$@")
  for pkg in "${pkgs[@]}"; do
    if pacman -Q "$pkg" &>/dev/null; then
      echo -e "${YELLOW}AUR: $pkg ... [SKIP] Already installed${RESET}"
      continue
    fi
    echo -ne "${CYAN}AUR: $pkg ...${RESET} "
    if yay -S --noconfirm --needed "$pkg" >/dev/null 2>&1; then
      echo -e "${GREEN}[OK]${RESET}"
      INSTALLED_PKGS+=("$pkg (AUR)")
    else
      echo -e "${RED}[FAIL]${RESET}"
      log_error "Failed to install AUR $pkg"
    fi
  done
}

detect_desktop_environment() {
  case "$XDG_CURRENT_DESKTOP" in
    KDE)
      log_success "KDE detected."
      specific_install_programs=("${kde_install_programs[@]}")
      specific_remove_programs=("${kde_remove_programs[@]}")
      flatpak_install_function="install_flatpak_programs_kde"
      flatpak_minimal_function="install_flatpak_minimal_kde"
      ;;
    GNOME)
      log_success "GNOME detected."
      specific_install_programs=("${gnome_install_programs[@]}")
      specific_remove_programs=("${gnome_remove_programs[@]}")
      flatpak_install_function="install_flatpak_programs_gnome"
      flatpak_minimal_function="install_flatpak_minimal_gnome"
      ;;
    COSMIC)
      log_success "Cosmic DE detected."
      specific_install_programs=("${cosmic_install_programs[@]}")
      specific_remove_programs=("${cosmic_remove_programs[@]}")
      flatpak_install_function="install_flatpak_programs_cosmic"
      flatpak_minimal_function="install_flatpak_minimal_cosmic"
      ;;
    *)
      log_warning "No KDE, GNOME, or Cosmic detected."
      specific_install_programs=()
      specific_remove_programs=()
      log_warning "Falling back to minimal set for unsupported DE/WM."
      pacman_programs=("${pacman_programs_minimal[@]}")
      essential_programs=("${essential_programs_minimal[@]}")
      flatpak_install_function="install_flatpak_minimal_generic"
      flatpak_minimal_function="install_flatpak_minimal_generic"
      ;;
  esac
}

remove_programs() {
  step "Removing DE-specific programs"
  if [ ${#specific_remove_programs[@]} -eq 0 ]; then
    log_success "No specific programs to remove."
    return
  fi
  for program in "${specific_remove_programs[@]}"; do
    if is_package_installed "$program"; then
      sudo pacman -Rns --noconfirm "$program" &>/dev/null
      if handle_error "Failed to remove $program."; then
        log_success "$program removed."
        REMOVED_PKGS+=("$program")
      fi
    else
      log_warning "$program not found. Skipping removal."
    fi
  done
}

install_pacman_programs() {
  step "Installing Pacman programs"
  echo -e "${CYAN}=== Programs Installing ===${RESET}"

  local pkgs=("${pacman_programs[@]}" "${essential_programs[@]}")
  if [ "${#specific_install_programs[@]}" -gt 0 ]; then
    pkgs+=("${specific_install_programs[@]}")
  fi

  install_pacman_quietly "${pkgs[@]}"
}

install_aur_packages() {
  step "Installing AUR packages"
  if [ ${#yay_programs[@]} -eq 0 ]; then
    log_success "No AUR packages to install."
    return
  fi

  echo -e "${CYAN}=== AUR Installing ===${RESET}"

  install_aur_quietly "${yay_programs[@]}"
}

install_flatpak_programs_list() {
  local flatpaks=("$@")
  install_flatpak_quietly "${flatpaks[@]}"
}

install_flatpak_programs_kde() {
  step "Installing Flatpak programs for KDE"
  local flatpaks=(
    io.github.shiftey.Desktop
    it.mijorus.gearlever
    net.davidotek.pupgui2
  )
  install_flatpak_programs_list "${flatpaks[@]}"
}

install_flatpak_programs_gnome() {
  step "Installing Flatpak programs for GNOME"
  local flatpaks=(
    com.mattjakeman.ExtensionManager
    io.github.shiftey.Desktop
    it.mijorus.gearlever
    com.vysp3r.ProtonPlus
  )
  install_flatpak_programs_list "${flatpaks[@]}"
}

install_flatpak_programs_cosmic() {
  step "Installing Flatpak programs for Cosmic"
  local flatpaks=(
    io.github.shiftey.Desktop
    it.mijorus.gearlever
    com.vysp3r.ProtonPlus
    dev.edfloreshz.CosmicTweaks
  )
  install_flatpak_programs_list "${flatpaks[@]}"
}

install_flatpak_minimal_kde() {
  step "Installing minimal Flatpak programs for KDE"
  local flatpaks=(
    it.mijorus.gearlever
  )
  install_flatpak_programs_list "${flatpaks[@]}"
}

install_flatpak_minimal_gnome() {
  step "Installing minimal Flatpak programs for GNOME"
  local flatpaks=(
    com.mattjakeman.ExtensionManager
    it.mijorus.gearlever
  )
  install_flatpak_programs_list "${flatpaks[@]}"
}

install_flatpak_minimal_cosmic() {
  step "Installing minimal Flatpak programs for Cosmic"
  local flatpaks=(
    it.mijorus.gearlever
    dev.edfloreshz.CosmicTweaks
  )
  install_flatpak_programs_list "${flatpaks[@]}"
}

install_flatpak_minimal_generic() {
  step "Installing minimal Flatpak programs (generic DE/WM)"
  local flatpaks=(
    it.mijorus.gearlever
  )
  install_flatpak_programs_list "${flatpaks[@]}"
}

print_summary() {
  echo -e "\n${CYAN}======= PROGRAMS SUMMARY =======${RESET}"
  if [ ${#INSTALLED_PKGS[@]} -gt 0 ]; then
    echo -e "${GREEN}Installed:${RESET} ${INSTALLED_PKGS[*]}"
  else
    echo -e "${YELLOW}No new packages were installed.${RESET}"
  fi
  if [ ${#REMOVED_PKGS[@]} -gt 0 ]; then
    echo -e "${RED}Removed:${RESET} ${REMOVED_PKGS[*]}"
  else
    echo -e "${GREEN}No packages were removed.${RESET}"
  fi
  if [ ${#ERRORS[@]} -gt 0 ]; then
    echo -e "${RED}Errors:${RESET}"
    for err in "${ERRORS[@]}"; do
      echo -e "  - ${YELLOW}$err${RESET}"
    done
  else
    echo -e "${GREEN}All steps completed successfully!${RESET}"
  fi
  echo -e "${CYAN}===============================${RESET}"
}

# ===== MAIN LOGIC =====

if [[ "$1" == "-d" ]]; then
  INSTALL_MODE="default"
  pacman_programs=("${pacman_programs_default[@]}")
  essential_programs=("${essential_programs_default[@]}")
  yay_programs=("${yay_programs_default[@]}")
elif [[ "$1" == "-m" ]]; then
  INSTALL_MODE="minimal"
  pacman_programs=("${pacman_programs_minimal[@]}")
  essential_programs=("${essential_programs_minimal[@]}")
  yay_programs=("${yay_programs_minimal[@]}")
else
  echo -e "${RED}Error: You must run this script with -d (default) or -m (minimal) flag. Example: ./programs.sh -d${RESET}"
  exit 1
fi

check_yay
check_flatpak
detect_desktop_environment
remove_programs
install_pacman_programs

if [[ "$INSTALL_MODE" == "default" ]]; then
  if [ -n "$flatpak_install_function" ]; then
    $flatpak_install_function
  else
    log_warning "No Flatpak install function for your DE."
  fi
else
  if [ -n "$flatpak_minimal_function" ]; then
    $flatpak_minimal_function
  else
    install_flatpak_minimal_generic
  fi
fi

install_aur_packages
print_summary