#!/bin/bash

# Script: install.sh
# Description: Script for setting up an Arch Linux system with various configurations and installations.
# Author: George Andromidas

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

# New ASCII art and menu function
show_menu() {
    clear
    echo -e "${CYAN}"
    cat << "EOF"
    _             _     ___           _        _ _
   / \   _ __ ___| |__ |_ _|_ __  ___| |_ __ _| | | ___ _ __
  / _ \ | '__/ __| '_ \ | || '_ \/ __| __/ _` | | |/ _ \ '__|
 / ___ \| | | (__| | | || || | | \__ \ || (_| | | |  __/ |
/_/   \_\_|  \___|_| |_|___|_| |_|___/\__\__,_|_|_|\___|_|

EOF
    echo -e "${RESET}"
    echo "Welcome to ArchInstaller!"
    echo "------------------------"
    echo "1. Install default set of programs"
    echo "2. Install minimal set of programs"
    echo "3. Show help"
    echo "4. Exit"
    echo
    read -p "Please enter your choice (1-4): " choice

    case $choice in
        1)
            FLAG="-d"
            ;;
        2)
            FLAG="-m"
            ;;
        3)
            show_help
            exit 0
            ;;
        4)
            echo "Exiting ArchInstaller. Goodbye!"
            exit 0
            ;;
        *)
            echo "Invalid choice. Please try again."
            show_menu
            ;;
    esac
}

# Function to print messages with colors
print_info() {
    echo -e "${CYAN}$1${RESET}"
}

print_success() {
    echo -e "${GREEN}$1${RESET}"
}

print_warning() {
    echo -e "${YELLOW}$1${RESET}"
}

print_error() {
    echo -e "${RED}$1${RESET}"
}

# Function to display help information
show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -d, --default       Install default set of programs"
    echo "  -m, --minimal       Install minimal set of programs"
    echo "  -h, --help          Show this help message"
    echo ""
    echo "Description:"
    echo "  This script sets up an Arch Linux system by installing various packages,"
    echo "  configuring system settings, and installing necessary programs."
}

# Function to identify the installed Linux kernel type and install kernel headers
install_kernel_headers() {
    print_info "Identifying installed Linux kernel type..."

    if pacman -Q linux-zen &>/dev/null; then
        KERNEL_HEADERS="linux-zen-headers"
    elif pacman -Q linux-hardened &>/dev/null; then
        KERNEL_HEADERS="linux-hardened-headers"
    elif pacman -Q linux-lts &>/dev/null; then
        KERNEL_HEADERS="linux-lts-headers"
    fi

    print_info "Installing $KERNEL_HEADERS..."
    if sudo pacman -S --needed --noconfirm "$KERNEL_HEADERS"; then
        print_success "Kernel headers ($KERNEL_HEADERS) installed successfully."
    else
        print_error "Error: Failed to install kernel headers ($KERNEL_HEADERS)."
        exit 1
    fi
}

# Function to make Systemd-Boot silent
make_systemd_boot_silent() {
    print_info "Making Systemd-Boot silent..."
    
    # Detect installed kernel
    if pacman -Q linux-zen &>/dev/null; then
        kernel_name="linux-zen"
    elif pacman -Q linux-hardened &>/dev/null; then
        kernel_name="linux-hardened"
    elif pacman -Q linux-lts &>/dev/null; then
        kernel_name="linux-lts"
    else
        kernel_name="linux"
    fi
    
    linux_entry=$(find "$ENTRIES_DIR" -type f -name "*${kernel_name}.conf" ! -name '*fallback.conf' -print -quit)

    if [ -z "$linux_entry" ]; then
        print_error "Error: Linux entry not found for kernel: $kernel_name"
        exit 1
    fi

    sudo sed -i '/options/s/$/ quiet loglevel=3 systemd.show_status=auto rd.udev.log_level=3/' "$linux_entry" && \
    print_success "Silent boot options added to Linux entry: $(basename "$linux_entry")."
}

# Function to change loader.conf
change_loader_conf() {
    print_info "Changing loader.conf..."
    
    # Ensure default @saved is present
    if ! grep -q "^default @saved" "$LOADER_CONF"; then
        sudo sed -i '1i\default @saved' "$LOADER_CONF"
    fi
    
    # Update timeout and console-mode
    sudo sed -i 's/^timeout.*/timeout 3/' "$LOADER_CONF"
    sudo sed -i 's/^#console-mode.*/console-mode max/' "$LOADER_CONF"
    
    print_success "Loader configuration updated."
}

# Function to enable asterisks for password in sudoers
enable_asterisks_sudo() {
    print_info "Enabling asterisks for password input in sudoers..."
    echo "Defaults env_reset,pwfeedback" | sudo EDITOR='tee -a' visudo && \
    print_success "Password feedback enabled in sudoers."
}

# Function to configure Pacman
configure_pacman() {
    print_info "Configuring Pacman..."
    sudo sed -i '
        /^#Color/s/^#//
        /^Color/a ILoveCandy
        /^#VerbosePkgLists/s/^#//
        s/^#ParallelDownloads = 5/ParallelDownloads = 10/
    ' /etc/pacman.conf && \
    print_success "Pacman configuration updated successfully."
}

# Function to update mirrorlist and modify reflector.conf
update_mirrorlist() {
    print_info "Updating Mirrorlist..."
    sudo pacman -S --needed --noconfirm reflector rsync

    sudo sed -i 's/^--latest .*/--latest 10/' /etc/xdg/reflector/reflector.conf
    sudo sed -i 's/^--sort .*/--sort rate/' /etc/xdg/reflector/reflector.conf
    print_success "reflector.conf updated successfully."

    sudo reflector --verbose --protocol https --latest 10 --sort rate --save /etc/pacman.d/mirrorlist && \
    sudo pacman -Syyy && \
    print_success "Mirrorlist updated successfully."
}

# Function to update the system
update_system() {
    print_info "Updating System..."
    sudo pacman -Syyu --noconfirm && \
    print_success "System updated successfully."
}

# Function to install Oh-My-ZSH and ZSH plugins
install_zsh() {
    print_info "Configuring ZSH..."
    sudo pacman -S --needed --noconfirm zsh
    yes | sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
    sleep 1

    git clone https://github.com/zsh-users/zsh-autosuggestions.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions
    sleep 1

    git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting
    print_success "ZSH configured successfully."
}

# Function to change shell to ZSH
change_shell_to_zsh() {
    print_info "Changing Shell to ZSH..."
    sudo chsh -s "$(which zsh)"
    chsh -s "$(which zsh)"
    print_success "Shell changed to ZSH."
}

# Function to move .zshrc
move_zshrc() {
    print_info "Copying .zshrc to Home Folder..."
    mv "$CONFIGS_DIR/.zshrc" "$HOME/" && \
    print_success ".zshrc copied successfully."
}

# Function to install starship and move starship.toml
install_starship() {
    print_info "Installing Starship prompt..."
    if curl -sS https://starship.rs/install.sh | sh -s -- -y; then
        print_success "Starship prompt installed successfully."
        mkdir -p "$HOME/.config"
        if [ -f "$CONFIGS_DIR/starship.toml" ]; then
            mv "$CONFIGS_DIR/starship.toml" "$HOME/.config/starship.toml"
            print_success "starship.toml moved to $HOME/.config/"
        else
            print_warning "starship.toml not found in $CONFIGS_DIR/"
        fi
    else
        print_error "Starship prompt installation failed."
    fi
}

# Function to configure locales
configure_locales() {
    print_info "Configuring Locales..."
    sudo sed -i 's/#el_GR.UTF-8 UTF-8/el_GR.UTF-8 UTF-8/' /etc/locale.gen
    sudo locale-gen && \
    print_success "Locales generated successfully."
}

# Function to install YAY
install_yay() {
    print_info "Installing YAY..."
    cd /tmp
    git clone https://aur.archlinux.org/yay.git
    cd yay
    makepkg -si --noconfirm
    cd ..
    rm -rf yay
    print_success "YAY installed successfully."
}

# Function to install programs
install_programs() {
    print_info "Installing Programs..."
    local total_programs=$(grep -c '^[^#]' "$SCRIPTS_DIR/programs.sh")
    local current_program=0

    while IFS= read -r line; do
        if [[ $line =~ ^[^#] ]]; then
            ((current_program++))
            local percentage=$((current_program * 100 / total_programs))
            display_progress $percentage
            eval "$line" >/dev/null 2>&1
        fi
    done < "$SCRIPTS_DIR/programs.sh"

    echo  # Move to the next line after the progress bar
    print_success "Programs installed successfully."
}

# Function to display a single progress bar
display_progress() {
    local width=50
    local percentage=$1
    local filled=$(( (percentage * width + 50) / 100 ))
    local empty=$((width - filled))
    printf "\rProgress: [%s%s] %d%%" "$(printf '#%.0s' $(seq 1 $filled))" "$(printf ' %.0s' $(seq 1 $empty))" "$percentage"
}

# Function to enable services
enable_services() {
    print_info "Enabling Services..."
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
        if systemctl list-unit-files | grep -q "^$service"; then
            sudo systemctl enable --now "$service"
            print_success "$service enabled."
        else
            print_warning "$service is not installed."
        fi
    done
}

# Function to create fastfetch config
create_fastfetch_config() {
    print_info "Creating fastfetch config..."
    fastfetch --gen-config && \
    print_success "fastfetch config created successfully."

    print_info "Copying fastfetch config from repository to ~/.config/fastfetch/..."
    cp "$CONFIGS_DIR/config.jsonc" "$HOME/.config/fastfetch/config.jsonc" && \
    print_success "fastfetch config copied successfully."
}

# Function to configure firewall
configure_firewall() {
    print_info "Configuring Firewall..."

    if command -v firewall-cmd > /dev/null 2>&1; then
        print_info "Using firewalld for firewall configuration."

        commands=()

        # Check if SSH is already allowed
        if ! sudo firewall-cmd --permanent --list-services | grep -q "\bssh\b"; then
            commands+=("sudo firewall-cmd --permanent --add-service=ssh")
        else
            print_warning "SSH is already allowed. Skipping SSH service configuration."
        fi

        # Check if KDE Connect is installed
        if pacman -Q kdeconnect &>/dev/null; then
            commands+=("sudo firewall-cmd --permanent --add-service=kdeconnect")
        else
            print_warning "KDE Connect is not installed. Skipping kdeconnect service configuration."
        fi

        # Reload firewall configuration
        commands+=("sudo firewall-cmd --reload")

        # Execute commands
        for cmd in "${commands[@]}"; do
            eval "$cmd"
        done

        print_success "Firewall configured successfully."

    else
        print_error "Firewalld not found. Please install firewalld."
        return 1
    fi
}

# Function to install and configure Fail2ban
install_and_configure_fail2ban() {
    print_info "Do you want to install and configure Fail2ban? (Y/n)"

    read -rp "" confirm_fail2ban

    # Convert input to lowercase for case-insensitive comparison
    confirm_fail2ban="${confirm_fail2ban,,}"

    # Handle empty input (Enter pressed)
    if [[ -z "$confirm_fail2ban" ]]; then
        confirm_fail2ban="y"  # Apply "yes" if Enter is pressed
    fi

    # Validate input
    while [[ ! "$confirm_fail2ban" =~ ^(y|n)$ ]]; do
        read -rp "Invalid input. Please enter 'Y' to install Fail2ban or 'n' to skip: " confirm_fail2ban
        confirm_fail2ban="${confirm_fail2ban,,}"
    done

    if [[ "$confirm_fail2ban" == "y" ]]; then
        print_info "Installing and configuring Fail2ban..."
        local total_steps=3
        local current_step=0

        # Step 1: Install Fail2ban
        ((current_step++))
        display_progress $((current_step * 100 / total_steps))
        sudo pacman -S --needed --noconfirm fail2ban >/dev/null 2>&1

        # Step 2: Configure Fail2ban
        ((current_step++))
        display_progress $((current_step * 100 / total_steps))
        (cd "$SCRIPTS_DIR" && ./fail2ban.sh) >/dev/null 2>&1

        # Step 3: Final step (e.g., enabling service)
        ((current_step++))
        display_progress $((current_step * 100 / total_steps))
        sudo systemctl enable --now fail2ban >/dev/null 2>&1

        echo  # Move to the next line after the progress bar
        print_success "Fail2ban installed and configured successfully."
    else
        print_warning "Fail2ban installation and configuration skipped."
    fi
}

# Function to install and configure Virt-Manager
install_and_configure_virt_manager() {
    print_info "Do you want to install and configure Virt-Manager? (Y/n)"

    read -rp "" confirm_virt_manager

    # Convert input to lowercase for case-insensitive comparison
    confirm_virt_manager="${confirm_virt_manager,,}"

    # Handle empty input (Enter pressed)
    if [[ -z "$confirm_virt_manager" ]]; then
        confirm_virt_manager="y"  # Apply "yes" if Enter is pressed
    fi

    # Validate input
    while [[ ! "$confirm_virt_manager" =~ ^(y|n)$ ]]; do
        read -rp "Invalid input. Please enter 'Y' to install Virt-Manager or 'n' to skip: " confirm_virt_manager
        confirm_virt_manager="${confirm_virt_manager,,}"
    done

    if [[ "$confirm_virt_manager" == "y" ]]; then
        print_info "Installing and configuring Virt-Manager..."
        local total_steps=$(grep -c '^[^#]' "$SCRIPTS_DIR/virt_manager.sh")
        local current_step=0

        while IFS= read -r line; do
            if [[ $line =~ ^[^#] ]]; then
                ((current_step++))
                local percentage=$((current_step * 100 / total_steps))
                display_progress $percentage
                eval "$line" >/dev/null 2>&1
            fi
        done < "$SCRIPTS_DIR/virt_manager.sh"

        echo  # Move to the next line after the progress bar
        print_success "Virt-Manager installed and configured successfully."
    else
        print_warning "Virt-Manager installation and configuration skipped."
    fi
}

# Function to prompt for DaVinci Resolve installation
install_davinci_resolve() {
    print_info "Do you want to install DaVinci Resolve? (Y/n)"

    read -rp "" confirm_davinci

    # Convert input to lowercase for case-insensitive comparison
    confirm_davinci="${confirm_davinci,,}"

    # Handle empty input (Enter pressed)
    if [[ -z "$confirm_davinci" ]]; then
        confirm_davinci="y"  # Apply "yes" if Enter is pressed
    fi

    # Validate input
    while [[ ! "$confirm_davinci" =~ ^(y|n)$ ]]; do
        read -rp "Invalid input. Please enter 'Y' to install DaVinci Resolve or 'n' to skip: " confirm_davinci
        confirm_davinci="${confirm_davinci,,}"
    done

    if [[ "$confirm_davinci" == "y" ]]; then
        print_info "Installing DaVinci Resolve..."
        local total_steps=$(grep -c '^[^#]' "$SCRIPTS_DIR/davinci_resolve.sh")
        local current_step=0

        while IFS= read -r line; do
            if [[ $line =~ ^[^#] ]]; then
                ((current_step++))
                local percentage=$((current_step * 100 / total_steps))
                display_progress $percentage
                eval "$line" >/dev/null 2>&1
            fi
        done < "$SCRIPTS_DIR/davinci_resolve.sh"

        echo  # Move to the next line after the progress bar
        print_success "DaVinci Resolve installed successfully."
    else
        print_warning "DaVinci Resolve installation skipped."
    fi
}

# Function to clear unused packages and cache
clear_unused_packages_cache() {
    print_info "Clearing Unused Packages and Cache..."
    sudo pacman -Rns $(pacman -Qdtq) --noconfirm
    sudo pacman -Sc --noconfirm
    yay -Sc --noconfirm
    rm -rf ~/.cache/* && sudo paccache -r
    print_success "Unused packages and cache cleared successfully."
}

# Function to delete the archinstaller folder
delete_archinstaller_folder() {
    print_info "Deleting Archinstaller Folder..."
    sudo rm -rf "$HOME/archinstaller" && \
    print_success "Archinstaller folder deleted successfully."
}

# Function to reboot system
reboot_system() {
    print_info "Rebooting System..."
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
        print_info "Rebooting now..."
        sudo reboot
    else
        print_warning "Reboot canceled. You can reboot manually later by typing 'sudo reboot'."
    fi
}

# Function to detect bootloader
detect_bootloader() {
    if [ -d "/sys/firmware/efi" ] && [ -d "/boot/loader" ]; then
        print_info "systemd-boot detected."
        return 0
    else
        print_info "GRUB detected or no bootloader detected."
        return 1
    fi
}

# Function to install GRUB theme
install_grub_theme() {
    print_info "Installing GRUB theme..."
    cd /tmp
    git clone https://github.com/ChrisTitusTech/Top-5-Bootloader-Themes
    cd Top-5-Bootloader-Themes
    sudo ./install.sh
    cd ..
    rm -rf Top-5-Bootloader-Themes
    print_success "GRUB theme installed successfully."
}

# Main script
show_menu

install_kernel_headers

if detect_bootloader; then
    make_systemd_boot_silent
    change_loader_conf
else
    install_grub_theme
fi

enable_asterisks_sudo
configure_pacman
update_mirrorlist
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