#!/bin/bash

# Script: install.sh
# Description: Script for setting up an Arch Linux system with various configurations and installations.
# Author: George Andromidas

# ASCII art
clear
echo -e "${CYAN}"
cat << "EOF"
    _             _     ___           _        _ _
   / \   _ __ ___| |__ |_ _|_ __  ___| |_ __ _| | | ___ _ __
  / _ \ | '__/ __| '_ \ | || '_ \/ __| __/ _` | | |/ _ \ '__|
 / ___ \| | | (__| | | || || | | \__ \ || (_| | | |  __/ |
/_/   \_\_|  \___|_| |_|___|_| |_|___/\__\__,_|_|_|\___|_|

EOF

# Function to print installation information
print_installation_info() {
    local action="$1"
    local package="$2"
    echo -e "${CYAN}${action} ${package}...${RESET}"
}

# Function to identify installed kernel types
get_installed_kernel_types() {
    local kernel_types=()

    # Check for standard kernel
    if pacman -Q linux &>/dev/null; then
        kernel_types+=("linux")
    fi

    # Check for LTS kernel
    if pacman -Q linux-lts &>/dev/null; then
        kernel_types+=("linux-lts")
    fi

    # Check for Zen kernel
    if pacman -Q linux-zen &>/dev/null; then
        kernel_types+=("linux-zen")
    fi

    # Check for Hardened kernel
    if pacman -Q linux-hardened &>/dev/null; then
        kernel_types+=("linux-hardened")
    fi

    echo "${kernel_types[@]}"
}

# Variables
KERNEL_HEADERS="linux-headers"  # Default to standard Linux headers
LOADER_DIR="/boot/loader"
ENTRIES_DIR="$LOADER_DIR/entries"
LOADER_CONF="/boot/loader/loader.conf"
CONFIGS_DIR="$HOME/archinstaller/configs"
SCRIPTS_DIR="$HOME/archinstaller/scripts"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
RESET='\033[0m'

# Function to print messages with different levels
log_message() {
    local level="$1"
    local message="$2"

    case "$level" in
        "info")
            echo -e "${CYAN}$message${RESET}"
            ;;
        "success")
            echo -e "${GREEN}$message${RESET}"
            ;;
        "warning")
            echo -e "${YELLOW}$message${RESET}"
            ;;
        "error")
            echo -e "${RED}$message${RESET}"
            ;;
        *)
            echo "Invalid log level"
            ;;
    esac
}

# Function to display menu and get user selection
show_menu() {
    while true; do
        echo -e "\n${CYAN}Please select an installation option:${RESET}"
        echo "1. Default Installation"
        echo "2. Minimal Installation"
        echo "3. Exit"
        read -p "Enter your choice (1-3): " choice

        case $choice in
            1)
                echo "Default installation selected."
                FLAG="-d"
                return 0
                ;;
            2)
                echo "Minimal installation selected."
                FLAG="-m"
                return 0
                ;;
            3)
                echo "Exiting installation."
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid option. Please try again.${RESET}"
                ;;
        esac
    done
}

# Function to install kernel headers for all detected kernel types
install_kernel_headers_for_all() {
    log_message "info" "Identifying installed Linux kernel types..."

    # Get installed kernel types
    kernel_types=($(get_installed_kernel_types))

    # Install headers for each detected kernel
    for kernel in "${kernel_types[@]}"; do
        headers_package="${kernel}-headers"
        print_installation_info "Installing" "$headers_package"  # Updated call
        if sudo pacman -S --needed --noconfirm "$headers_package"; then
            log_message "success" "$headers_package installed successfully."
        else
            log_message "error" "Error: Failed to install $headers_package."
        fi
    done

    if [ ${#kernel_types[@]} -eq 0 ]; then
        log_message "warning" "No supported kernel types detected. Please check your system configuration."
    fi
}

# Function to make Systemd-Boot silent for all installed kernels
make_systemd_boot_silent() {
    log_message "info" "Making Systemd-Boot silent for all installed kernels..."

    # Get installed kernel types
    kernel_types=($(get_installed_kernel_types))

    # Loop through each kernel type and modify its entry
    for kernel in "${kernel_types[@]}"; do
        linux_entry=$(find "$ENTRIES_DIR" -type f -name "*${kernel}.conf" ! -name '*fallback.conf' -print -quit)

        if [ -z "$linux_entry" ]; then
            log_message "warning" "Warning: Linux entry not found for kernel: $kernel"
            continue
        fi

        # Add silent boot options
        if sudo sed -i '/options/s/$/ quiet loglevel=3 systemd.show_status=auto rd.udev.log_level=3/' "$linux_entry"; then
            log_message "success" "Silent boot options added to Linux entry: $(basename "$linux_entry")."
        else
            log_message "error" "Error: Failed to modify Linux entry: $(basename "$linux_entry")."
        fi
    done
}

# Function to change loader.conf
change_loader_conf() {
    log_message "info" "Changing loader.conf..."

    # Ensure default @saved is present
    if ! grep -q "^default @saved" "$LOADER_CONF"; then
        sudo sed -i '1i\default @saved' "$LOADER_CONF"
    fi

    # Update timeout and console-mode
    sudo sed -i 's/^timeout.*/timeout 3/' "$LOADER_CONF"
    sudo sed -i 's/^#console-mode.*/console-mode max/' "$LOADER_CONF"

    log_message "success" "Loader configuration updated."
}

# Function to remove fallback entries from systemd-boot
remove_fallback_entries() {
    log_message "info" "Removing fallback entries from systemd-boot..."

    # Find and remove all fallback entries
    for entry in "$ENTRIES_DIR"/*fallback.conf; do
        if [ -f "$entry" ]; then
            sudo rm "$entry" && \
            log_message "success" "Removed fallback entry: $(basename "$entry")."
        fi
    done

    log_message "info" "All fallback entries removed."
}

# Function to enable asterisks for password in sudoers
enable_asterisks_sudo() {
    log_message "info" "Enabling asterisks for password input in sudoers..."
    echo "Defaults env_reset,pwfeedback" | sudo EDITOR='tee -a' visudo && \
    log_message "success" "Password feedback enabled in sudoers."
}

# Function to configure Pacman
configure_pacman() {
    log_message "info" "Configuring Pacman..."
    sudo sed -i '
        /^#Color/s/^#//
        /^Color/a ILoveCandy
        /^#VerbosePkgLists/s/^#//
        s/^#ParallelDownloads = 5/ParallelDownloads = 10/
    ' /etc/pacman.conf && \
    log_message "success" "Pacman configuration updated successfully."
}

# Function to update mirrorlist and modify reflector.conf
update_mirrorlist() {
    log_message "info" "Updating Mirrorlist..."
    sudo pacman -S --needed --noconfirm reflector rsync

    sudo sed -i 's/^--latest .*/--latest 10/' /etc/xdg/reflector/reflector.conf
    sudo sed -i 's/^--sort .*/--sort rate/' /etc/xdg/reflector/reflector.conf
    log_message "success" "reflector.conf updated successfully."

    sudo reflector --verbose --protocol https --latest 10 --sort rate --save /etc/pacman.d/mirrorlist && \
    sudo pacman -Syyy && \
    log_message "success" "Mirrorlist updated successfully."
}

# Function to install dependencies
install_dependencies() {
    log_message "info" "Installing Dependencies..."
    
    # List of dependencies to install
    dependencies=("figlet" "curl" "git" "fastfetch" "reflector" "rsync" "openssh" "base-devel" "pacman-contrib" "eza" "zoxide" "fzf")  # Add more packages as needed

    # Install each dependency
    for package in "${dependencies[@]}"; do
        print_installation_info "Installing" "$package"  # Updated call
        if sudo pacman -S --needed --noconfirm "$package"; then
            log_message "success" "$package installed successfully."
        else
            log_message "error" "Failed to install $package."
        fi
    done
}

# Function to update the system
update_system() {
    log_message "info" "Updating System..."
    sudo pacman -Syyu --noconfirm && \
    log_message "success" "System updated successfully."
}

# Function to install Oh-My-ZSH and ZSH plugins
install_zsh() {
    log_message "info" "Configuring ZSH..."
    sudo pacman -S --needed --noconfirm zsh
    yes | sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
    sleep 1

    git clone https://github.com/zsh-users/zsh-autosuggestions.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions
    sleep 1

    git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting
    log_message "success" "ZSH configured successfully."
}

# Function to change shell to ZSH
change_shell_to_zsh() {
    log_message "info" "Changing Shell to ZSH..."
    sudo chsh -s "$(which zsh)"
    chsh -s "$(which zsh)"
    log_message "success" "Shell changed to ZSH."
}

# Function to move .zshrc
move_zshrc() {
    log_message "info" "Copying .zshrc to Home Folder..."
    mv "$CONFIGS_DIR/.zshrc" "$HOME/" && \
    log_message "success" ".zshrc copied successfully."
}

# Function to install Starship and move starship.toml
install_starship() {
    log_message "info" "Installing Starship prompt..."
    
    # Install Starship via pacman
    if sudo pacman -S --needed --noconfirm starship; then
        log_message "success" "Starship prompt installed successfully."
        mkdir -p "$HOME/.config"
        
        # Move starship.toml to the appropriate location
        if [ -f "$CONFIGS_DIR/starship.toml" ]; then
            mv "$CONFIGS_DIR/starship.toml" "$HOME/.config/starship.toml"
            log_message "success" "starship.toml moved to $HOME/.config/"
        else
            log_message "warning" "starship.toml not found in $CONFIGS_DIR/"
        fi
    else
        log_message "error" "Starship prompt installation failed."
    fi
}

# Function to configure locales
configure_locales() {
    log_message "info" "Configuring Locales..."
    sudo sed -i 's/#el_GR.UTF-8 UTF-8/el_GR.UTF-8 UTF-8/' /etc/locale.gen
    sudo locale-gen && \
    log_message "success" "Locales generated successfully."
}

# Function to install YAY
install_yay() {
    log_message "info" "Installing YAY..."
    cd /tmp
    git clone https://aur.archlinux.org/yay.git
    cd yay
    makepkg -si --noconfirm
    cd ..
    rm -rf yay
    log_message "success" "YAY installed successfully."
}

# Function to install programs
install_programs() {
    log_message "info" "Installing Programs..."
    (cd "$SCRIPTS_DIR" && ./programs.sh "$FLAG") && \
    log_message "success" "Programs installed successfully."
}

# Function to enable a service if it exists
enable_service() {
    local service="$1"
    if systemctl list-unit-files | grep -q "^$service"; then
        sudo systemctl enable --now "$service"
        log_message "success" "$service enabled."
    else
        log_message "warning" "$service is not installed."
    fi
}

# Function to enable services
enable_services() {
    log_message "info" "Enabling Services..."
    local services=(
        "bluetooth"
        "cronie"
        "firewalld"
        "fstrim.timer"
        "paccache.timer"
        "reflector.service"
        "reflector.timer"
        "sshd"
        "teamviewerd.service"
    )

    for service in "${services[@]}"; do
        enable_service "$service"  # Call the helper function
    done
}

# Function to create fastfetch config
create_fastfetch_config() {
    log_message "info" "Creating fastfetch config..."
    fastfetch --gen-config && \
    log_message "success" "fastfetch config created successfully."

    log_message "info" "Copying fastfetch config from repository to ~/.config/fastfetch/..."
    cp "$CONFIGS_DIR/config.jsonc" "$HOME/.config/fastfetch/config.jsonc" && \
    log_message "success" "fastfetch config copied successfully."
}

# Function to configure firewall
configure_firewall() {
    log_message "info" "Configuring Firewall..."

    if command -v firewall-cmd > /dev/null 2>&1; then
        log_message "info" "Using firewalld for firewall configuration."

        commands=()

        # Check if SSH is already allowed
        if ! sudo firewall-cmd --permanent --list-services | grep -q "\bssh\b"; then
            commands+=("sudo firewall-cmd --permanent --add-service=ssh")
        else
            log_message "warning" "SSH is already allowed. Skipping SSH service configuration."
        fi

        # Check if KDE Connect is installed
        if pacman -Q kdeconnect &>/dev/null; then
            commands+=("sudo firewall-cmd --permanent --add-service=kdeconnect")
        else
            log_message "warning" "KDE Connect is not installed. Skipping kdeconnect service configuration."
        fi

        # Reload firewall configuration
        commands+=("sudo firewall-cmd --reload")

        # Execute commands
        for cmd in "${commands[@]}"; do
            eval "$cmd"
        done

        log_message "success" "Firewall configured successfully."

    else
        log_message "error" "Firewalld not found. Please install firewalld."
        return 1
    fi
}

# Function to prompt for user confirmation
confirm_action() {
    local message="$1"
    echo -e "${MAGENTA}${message} (Y/n)${RESET}"
    read -rp "" confirm

    # Convert input to lowercase for case-insensitive comparison
    confirm="${confirm,,}"

    # Handle empty input (Enter pressed)
    if [[ -z "$confirm" ]]; then
        confirm="y"  # Apply "yes" if Enter is pressed
    fi

    # Validate input
    while [[ ! "$confirm" =~ ^(y|n)$ ]]; do
        read -rp "Invalid input. Please enter 'Y' to confirm or 'n' to cancel: " confirm
        confirm="${confirm,,}"
    done

    [[ "$confirm" == "y" ]]
}

# Function to install and configure Fail2ban
install_and_configure_fail2ban() {
    echo -e "${CYAN}"
    figlet "Fail2Ban"
    echo -e "${NC}"

    if confirm_action "Do you want to install and configure Fail2ban?"; then
        log_message "info" "Installing Fail2ban..."
        if sudo pacman -S --needed --noconfirm fail2ban; then
            log_message "success" "Fail2ban installed successfully."
            log_message "info" "Configuring Fail2ban..."
            (cd "$SCRIPTS_DIR" && ./fail2ban.sh) && \
            log_message "success" "Fail2ban configured successfully."
        else
            log_message "error" "Failed to install Fail2ban."
        fi
    else
        log_message "warning" "Fail2ban installation and configuration skipped."
    fi
}

# Function to install and configure Virt-Manager
install_and_configure_virt_manager() {
    echo -e "${CYAN}"
    figlet "Virt Manager"
    echo -e "${NC}"

    if confirm_action "Do you want to install and configure Virt-Manager?"; then
        log_message "info" "Installing Virt-Manager..."
        (cd "$SCRIPTS_DIR" && ./virt_manager.sh) && \
        log_message "success" "Virt-Manager configured successfully."
    else
        log_message "warning" "Virt-Manager installation and configuration skipped."
    fi
}

# Function to prompt for DaVinci Resolve installation
install_davinci_resolve() {
    echo -e "${CYAN}"
    figlet "Davinci Resolve"
    echo -e "${NC}"

    if confirm_action "Do you want to install DaVinci Resolve?"; then
        log_message "info" "Installing DaVinci Resolve..."
        (cd "$SCRIPTS_DIR" && ./davinci_resolve.sh) && \
        log_message "success" "DaVinci Resolve installed successfully."
    else
        log_message "warning" "DaVinci Resolve installation skipped."
    fi
}

# Function to clear unused packages and cache
clear_unused_packages_cache() {
    log_message "info" "Clearing Unused Packages and Cache..."
    sudo pacman -Rns $(pacman -Qdtq) --noconfirm
    sudo pacman -Sc --noconfirm
    yay -Sc --noconfirm
    rm -rf ~/.cache/* && sudo paccache -r
    log_message "success" "Unused packages and cache cleared successfully."
}

# Function to delete the archinstaller folder
delete_archinstaller_folder() {
    log_message "info" "Deleting Archinstaller Folder..."
    sudo rm -rf "$HOME/archinstaller" && \
    log_message "success" "Archinstaller folder deleted successfully."
}

# Function to reboot system
reboot_system() {
    log_message "info" "Rebooting System..."
    printf "${YELLOW}Do you want to reboot now? (Y/n)${RESET} "

    read -rp "" confirm_reboot

    # Convert input to lowercase for case-insensitive comparison
    confirm_reboot="${confirm_reboot,,}"

    # Handle empty input (Enter pressed)
    if [[ -z "$confirm_reboot" ]]; then
        confirm_reboot="y"  # Apply "yes" if Enter is pressed
    fi

    # Validate input
    while [[ ! "$confirm_reboot" =~ ^(y|n)$ ]]; do
        read -rp "Invalid input. Please enter 'Y' to reboot now or 'n' to cancel: " confirm_reboot
        confirm_reboot="${confirm_reboot,,}"
    done

    if [[ "$confirm_reboot" == "y" ]]; then
        log_message "info" "Rebooting now..."
        sudo reboot
    else
        log_message "warning" "Reboot canceled. You can reboot manually later by typing 'sudo reboot'."
    fi
}

# Function to detect bootloader
detect_bootloader() {
    if [ -d "/sys/firmware/efi" ] && [ -d "/boot/loader" ]; then
        log_message "info" "systemd-boot detected."
        return 0
    else
        log_message "info" "GRUB detected or no bootloader detected."
        return 1
    fi
}

# Function to install GRUB theme
install_grub_theme() {
    log_message "info" "Installing GRUB theme..."
    cd /tmp
    git clone https://github.com/ChrisTitusTech/Top-5-Bootloader-Themes
    cd Top-5-Bootloader-Themes
    sudo ./install.sh
    cd ..
    rm -rf Top-5-Bootloader-Themes
    log_message "success" "GRUB theme installed successfully."
}

# Main script
# Show menu and get user selection
show_menu

# Main script execution
install_kernel_headers_for_all

if detect_bootloader; then
    make_systemd_boot_silent
    change_loader_conf
    remove_fallback_entries
else
    install_grub_theme
fi

enable_asterisks_sudo
configure_pacman
update_mirrorlist
install_dependencies
update_system
install_zsh
change_shell_to_zsh
move_zshrc
install_starship
configure_locales
install_yay
install_programs
enable_services
create_fastfetch_config
configure_firewall
install_and_configure_fail2ban
install_and_configure_virt_manager
install_davinci_resolve
clear_unused_packages_cache
delete_archinstaller_folder
reboot_system
