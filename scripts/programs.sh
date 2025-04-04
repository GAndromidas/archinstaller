#!/bin/bash

# Constants for commands
PACMAN_CMD="sudo pacman -S --needed --noconfirm"
REMOVE_CMD="sudo pacman -Rns --noconfirm"
AUR_INSTALL_CMD="yay -S --noconfirm"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

# Function to print messages with colors
print_info() { echo -e "${CYAN}$1${RESET}"; }
print_success() { echo -e "${GREEN}$1${RESET}"; }
print_warning() { echo -e "${YELLOW}$1${RESET}"; }
print_error() { echo -e "${RED}$1${RESET}"; }

# Function to handle errors
handle_error() {
    if [ $? -ne 0 ]; then
        print_error "$1"
        exit 1
    fi
}

# Function to detect desktop environment and set specific programs to install or remove
detect_desktop_environment() {
    case "$XDG_CURRENT_DESKTOP" in
        KDE)
            print_info "KDE detected."
            specific_install_programs=("${kde_install_programs[@]}")
            specific_remove_programs=("${kde_remove_programs[@]}")
            flatpak_install_function="install_flatpak_programs_kde"
            ;;
        GNOME)
            print_info "GNOME detected."
            specific_install_programs=("${gnome_install_programs[@]}")
            specific_remove_programs=("${gnome_remove_programs[@]}")
            flatpak_install_function="install_flatpak_programs_gnome"
            ;;
        COSMIC)
            print_info "Cosmic DE detected."
            specific_install_programs=("${cosmic_install_programs[@]}")
            specific_remove_programs=("${cosmic_remove_programs[@]}")
            flatpak_install_function="install_flatpak_programs_cosmic"
            ;;
        *)
            print_error "No KDE, GNOME, or Cosmic detected. Skipping DE-specific programs."
            specific_install_programs=()
            specific_remove_programs=()
            flatpak_install_function=""
            ;;
    esac
}

# Function to remove programs
remove_programs() {
    if [ ${#specific_remove_programs[@]} -eq 0 ]; then
        print_info "No specific programs to remove."
    else
        print_info "Removing Programs..."
        for program in "${specific_remove_programs[@]}"; do
            if command -v "$program" &> /dev/null; then
                $REMOVE_CMD "$program"
                handle_error "Failed to remove $program. Continuing..."
                print_success "$program removed successfully."
            else
                print_warning "$program not found. Skipping removal."
            fi
        done
    fi
}

# Function to check if a package is installed
is_package_installed() {
    command -v "$1" &> /dev/null
}

# Function to install programs via pacman
install_pacman_programs() {
    print_info "Installing Pacman Programs..."
    for program in "${pacman_programs[@]}" "${essential_programs[@]}" "${specific_install_programs[@]}"; do
        if ! is_package_installed "$program"; then
            $PACMAN_CMD "$program"
            handle_error "Failed to install $program. Exiting..."
            print_success "$program installed successfully."
        else
            print_warning "$program is already installed. Skipping installation."
        fi
    done
}

# Function to install Flatpak programs
install_flatpak_programs() {
    if [ -n "$flatpak_install_function" ]; then
        print_info "Installing Flatpak Programs..."
        for package in "${flatpak_packages[@]}"; do
            print_info "Checking if $package is installed..."
            if ! is_package_installed "$package"; then
                print_info "Attempting to install $package..."
                sudo flatpak install -y flathub "$package" || {
                    print_error "Failed to install Flatpak program $package. Exiting..."
                    exit 1
                }
                print_success "$package installed successfully."
            else
                print_warning "$package is already installed. Skipping installation."
            fi
        done
    else
        print_info "No Flatpak installation function defined for the detected desktop environment."
    fi
}

# Function to check if yay is installed
check_yay() {
    if ! command -v yay &> /dev/null; then
        print_error "Error: yay is not installed. Please install yay and try again."
        exit 1
    fi
}

# Function to install AUR packages
install_aur_packages() {
    print_info "Installing AUR Packages..."
    for package in "${yay_programs[@]}"; do
        if ! is_package_installed "$package"; then
            $AUR_INSTALL_CMD "$package"
            handle_error "Failed to install AUR package $package. Exiting..."
            print_success "$package installed successfully."
        else
            print_warning "$package is already installed. Skipping installation."
        fi
    done
}

# Function to check for GRUB and Btrfs, and install grub-btrfs if found
check_grub_btrfs() {
    if command -v grub-install &> /dev/null; then
        if mount | grep -q 'btrfs'; then
            print_info "Btrfs detected. Installing grub-btrfs..."
            $PACMAN_CMD grub-btrfs
            handle_error "Failed to install grub-btrfs. Exiting..."
            print_success "grub-btrfs installed successfully."
        else
            print_warning "Btrfs not detected. Skipping grub-btrfs installation."
        fi
    else
        print_error "GRUB not installed. Skipping grub-btrfs installation."
    fi
}

# Function to install all AMD drivers and Vulkan packages
install_amd_drivers() {
    if lspci | grep -i "amd" &> /dev/null; then
        print_info "AMD GPU detected. Installing all AMD Drivers and Vulkan Packages..."
        local amd_driver_packages=(
            xf86-video-amdgpu        # AMD GPU driver
            mesa                      # OpenGL implementation
            vulkan-radeon             # Vulkan driver for AMD GPUs
            lib32-vulkan-radeon       # 32-bit Vulkan driver for AMD GPUs
            vulkan-icd-loader         # Vulkan Installable Client Driver loader
            lib32-mesa                # 32-bit Mesa library
        )
        
        for package in "${amd_driver_packages[@]}"; do
            if ! command -v "$package" &> /dev/null; then
                print_info "Installing $package..."
                $PACMAN_CMD "$package"
                handle_error "Failed to install $package. Exiting..."
                print_success "$package installed successfully."
            else
                print_warning "$package is already installed. Skipping installation."
            fi
        done
    else
        print_warning "No AMD GPU detected. Skipping AMD drivers installation."
    fi
}

# Programs to install using pacman (Default option)
pacman_programs_default=(
    android-tools
    bat
    bleachbit
    btop
    bluez-utils
    cmatrix
    dmidecode
    dosfstools
    expac
    firefox
    fwupd
    gamemode
    gnome-disk-utility
    hwinfo
    inxi
    lib32-gamemode
    lib32-mangohud
    mangohud
    net-tools
    noto-fonts-extra
    ntfs-3g
    samba
    sl
    speedtest-cli
    sshfs
    ttf-hack-nerd
    ttf-liberation
    unrar
    wget
    xdg-desktop-portal-gtk
)

essential_programs_default=(
    discord
    filezilla
    gimp
    kdenlive
    libreoffice-fresh
    lutris
    obs-studio
    steam
    telegram-desktop
    timeshift
    vlc
    wine
)

# Programs to install using pacman (Minimal option)
pacman_programs_minimal=(
    android-tools
    bat
    bleachbit
    btop
    bluez-utils
    cmatrix
    dmidecode
    dosfstools
    expac
    firefox
    fwupd
    gnome-disk-utility
    hwinfo
    inxi
    net-tools
    noto-fonts-extra
    ntfs-3g
    samba
    sl
    speedtest-cli
    sshfs
    ttf-hack-nerd
    ttf-liberation
    unrar
    wget
    xdg-desktop-portal-gtk
)

essential_programs_minimal=(
    libreoffice-fresh
    timeshift
    vlc
)

# KDE-specific programs to install using pacman
kde_install_programs=(
    gwenview
    kdeconnect
    kwalletmanager
    kvantum
    okular
    power-profiles-daemon
    python-pyqt5
    python-pyqt6
    qbittorrent
    spectacle
)

# KDE-specific programs to remove using pacman
kde_remove_programs=(
    htop
)

# GNOME-specific programs to install using pacman
gnome_install_programs=(
    celluloid
    dconf-editor
    gnome-tweaks
    gufw
    seahorse
    transmission-gtk
)

# GNOME-specific programs to remove using pacman
gnome_remove_programs=(
    epiphany
    gnome-contacts
    gnome-maps
    gnome-music
    gnome-tour
    htop
    snapshot
    totem
)

# Cosmic-specific programs to install using pacman
cosmic_install_programs=(
    power-profiles-daemon
    transmission-gtk
)

# Cosmic-specific programs to remove using pacman
cosmic_remove_programs=(
    htop
)

# Flatpak programs to install for KDE (Default)
install_flatpak_programs_kde() {
    print_info "Installing Flatpak Programs for KDE..."
    flatpak_packages=(
        io.github.shiftey.Desktop
        it.mijorus.gearlever
        net.davidotek.pupgui2
    )
    for package in "${flatpak_packages[@]}"; do
        sudo flatpak install -y flathub "$package"
    done
    print_success "Flatpak Programs for KDE installed successfully."
}

# Flatpak programs to install for GNOME (Default)
install_flatpak_programs_gnome() {
    print_info "Installing Flatpak Programs for GNOME..."
    flatpak_packages=(
        com.mattjakeman.ExtensionManager
        io.github.shiftey.Desktop
        it.mijorus.gearlever
        com.vysp3r.ProtonPlus
    )
    for package in "${flatpak_packages[@]}"; do
        sudo flatpak install -y flathub "$package"
    done
    print_success "Flatpak Programs for GNOME installed successfully."
}

# Flatpak programs to install for Cosmic (Default)
install_flatpak_programs_cosmic() {
    print_info "Installing Flatpak Programs for Cosmic..."
    flatpak_packages=(
        io.github.shiftey.Desktop
        it.mijorus.gearlever
        com.vysp3r.ProtonPlus
        dev.edfloreshz.CosmicTweaks
    )
    for package in "${flatpak_packages[@]}"; do
        sudo flatpak install -y flathub "$package"
    done
    print_success "Flatpak Programs for Cosmic installed successfully."
}

# Minimal Flatpak programs for KDE
install_flatpak_minimal_kde() {
    print_info "Installing Minimal Flatpak Programs for KDE..."
    flatpak_packages=(
        it.mijorus.gearlever
    )
    for package in "${flatpak_packages[@]}"; do
        sudo flatpak install -y flathub "$package"
    done
    print_success "Minimal Flatpak Programs for KDE installed successfully."
}

# Minimal Flatpak programs for GNOME
install_flatpak_minimal_gnome() {
    print_info "Installing Minimal Flatpak Programs for GNOME..."
    flatpak_packages=(
        com.mattjakeman.ExtensionManager
        it.mijorus.gearlever
    )
    for package in "${flatpak_packages[@]}"; do
        sudo flatpak install -y flathub "$package"
    done
    print_success "Minimal Flatpak Programs for GNOME installed successfully."
}

# Minimal Flatpak programs for Cosmic
install_flatpak_minimal_cosmic() {
    print_info "Installing Minimal Flatpak Programs for Cosmic..."
    flatpak_packages=(
        it.mijorus.gearlever
        dev.edfloreshz.CosmicTweaks
    )
    for package in "${flatpak_packages[@]}"; do
        sudo flatpak install -y flathub "$package"
    done
    print_success "Minimal Flatpak Programs for Cosmic installed successfully."
}

# AUR Packages to install (Default option)
yay_programs_default=(
    heroic-games-launcher-bin
    megasync-bin
    spotify
    stremio
    teamviewer
    via-bin
)

# Main script
# Get the flag from command line argument
FLAG="$1"

# Set programs to install based on installation mode
case "$FLAG" in
    "-d")
        installation_mode="default"
        pacman_programs=("${pacman_programs_default[@]}")
        essential_programs=("${essential_programs_default[@]}")
        
        # Prompt for yay programs installation with default 'y'
        read -p "Do you want to install AUR packages? (y/n, default is 'y'): " install_yay
        install_yay=${install_yay:-y}  # Default to 'y' if empty
        if [[ "$install_yay" == "y" ]]; then
            yay_programs=("${yay_programs_default[@]}")
        else
            yay_programs=()  # Set to empty if not installing
        fi
        ;;
    "-m")
        installation_mode="minimal"
        pacman_programs=("${pacman_programs_minimal[@]}")
        essential_programs=("${essential_programs_minimal[@]}")
        ;;
    *)
        print_error "Invalid flag. Exiting."
        exit 1
        ;;
esac

# Check for yay
check_yay

# Detect desktop environment
detect_desktop_environment

# Check for GRUB and Btrfs, and install grub-btrfs if found
check_grub_btrfs

# Remove specified programs
remove_programs

# Install specified programs via pacman
install_pacman_programs

# Install Flatpak programs
if [[ "$installation_mode" == "default" ]]; then
    if [ -n "$flatpak_install_function" ]; then
        $flatpak_install_function  # Call the appropriate Flatpak installation function
    else
        print_info "No Flatpak installation function defined for the detected desktop environment."
    fi
else
    if [[ "$XDG_CURRENT_DESKTOP" == "KDE" ]]; then
        install_flatpak_minimal_kde
    elif [[ "$XDG_CURRENT_DESKTOP" == "GNOME" ]]; then
        install_flatpak_minimal_gnome
    elif [[ "$XDG_CURRENT_DESKTOP" == "COSMIC" ]]; then
        install_flatpak_minimal_cosmic
    fi
fi

# Install AUR packages
install_aur_packages

# Install all AMD drivers and Vulkan packages
install_amd_drivers
