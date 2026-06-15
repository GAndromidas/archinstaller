#!/bin/bash
set -uo pipefail

# ============================================================================
# Package Management Library - Pacman, AUR, Flatpak operations
# ============================================================================

# Check if package is installed
is_package_installed() {
    local manager="$1"
    local pkg="$2"
    
    case "$manager" in
        pacman|aur)
            pacman -Q "$pkg" &>/dev/null
            ;;
        flatpak)
            flatpak list | grep -q "^$pkg" &>/dev/null
            ;;
    esac
}

# Install single package via pacman
pacman_install_single() {
    local pkg="$1"
    local verbose="${2:-false}"
    
    if [ "$verbose" = true ]; then
        printf "${THEME_TEXT}Installing Pacman package:${RESET} %-30s" "$pkg"
    fi
    
    local output
    if output=$(sudo pacman -S --noconfirm --needed "$pkg" 2>&1); then
        [ "$verbose" = true ] && printf "${THEME_SUCCESS} ✓ Success${RESET}\n"
        INSTALLED_PACKAGES+=("$pkg")
        return 0
    else
        [ "$verbose" = true ] && printf "${THEME_ERROR} ✗ Failed${RESET}\n"
        if [ "$verbose" = true ] || [[ "$output" == *"error:"* ]]; then
            echo "$output" | sed 's/^/    /'
        fi
        FAILED_PACKAGES+=("$pkg")
        return 1
    fi
}

# Install single package via AUR (yay)
yay_install_single() {
    local pkg="$1"
    local verbose="${2:-false}"
    
    if ! command -v yay &>/dev/null; then
        log_error "AUR helper (yay) not found"
        return 1
    fi
    
    if [ "$verbose" = true ]; then
        printf "${THEME_TEXT}Installing AUR package:${RESET} %-30s" "$pkg"
    fi
    
    local output
    if output=$(yay -S --noconfirm --needed "$pkg" 2>&1); then
        [ "$verbose" = true ] && printf "${THEME_SUCCESS} ✓ Success${RESET}\n"
        INSTALLED_PACKAGES+=("$pkg")
        return 0
    else
        [ "$verbose" = true ] && printf "${THEME_ERROR} ✗ Failed${RESET}\n"
        if [ "$verbose" = true ] || [[ "$output" == *"error:"* ]]; then
            echo "$output" | sed 's/^/    /'
        fi
        FAILED_PACKAGES+=("$pkg")
        return 1
    fi
}

# Install single package via Flatpak
flatpak_install_single() {
    local pkg="$1"
    local verbose="${2:-false}"
    
    if ! command -v flatpak &>/dev/null; then
        log_error "Flatpak not found"
        return 1
    fi
    
    if [ "$verbose" = true ]; then
        printf "${THEME_TEXT}Installing Flatpak app:${RESET} %-30s" "$pkg"
    fi
    
    local output
    if output=$(sudo flatpak install -y --noninteractive flathub "$pkg" 2>&1); then
        [ "$verbose" = true ] && printf "${THEME_SUCCESS} ✓ Success${RESET}\n"
        INSTALLED_PACKAGES+=("$pkg")
        return 0
    else
        [ "$verbose" = true ] && printf "${THEME_ERROR} ✗ Failed${RESET}\n"
        if [ "$verbose" = true ] || [[ "$output" == *"error:"* ]]; then
            echo "$output" | sed 's/^/    /'
        fi
        FAILED_PACKAGES+=("$pkg")
        return 1
    fi
}

# Generic package installer with error handling
install_package_generic() {
    local manager="$1"
    shift
    local packages=("$@")
    local failed=0
    
    for pkg in "${packages[@]}"; do
        local install_cmd=""
        local manager_name=""
        
        case "$manager" in
            pacman)
                install_cmd="sudo pacman -S --noconfirm --needed $pkg"
                manager_name="pacman"
                ;;
            aur)
                install_cmd="yay -S --noconfirm --needed $pkg"
                manager_name="AUR"
                ;;
            flatpak)
                install_cmd="sudo flatpak install --noninteractive -y $pkg"
                manager_name="Flatpak"
                ;;
        esac
        
        if [ "${DRY_RUN:-false}" = true ]; then
            ui_info "Dry-run: Would install $pkg"
            ui_info "  Would execute: $install_cmd"
            INSTALLED_PACKAGES+=("$pkg")
        else
            local error_output
            if error_output=$(eval "$install_cmd" 2>&1); then
                INSTALLED_PACKAGES+=("$pkg")
            else
                ui_error "Failed to install $pkg"
                FAILED_PACKAGES+=("$pkg")
                log_error "Failed to install $pkg via $manager_name"
                echo "$error_output" >> "$INSTALL_LOG"
                ((failed++))
            fi
        fi
    done
    
    if [ $failed -eq 0 ]; then
        ui_success "Package installation completed"
        return 0
    else
        ui_warn "Package installation completed with $failed failures"
        return 1
    fi
}

# Batch package installation with filtering
install_packages_batch() {
    local manager="$1"
    shift
    local packages=("$@")
    local total=${#packages[@]}
    
    if [ $total -eq 0 ]; then
        return 0
    fi
    
    # Filter out already installed packages
    local packages_to_install=()
    for pkg in "${packages[@]}"; do
        if ! is_package_installed "$manager" "$pkg"; then
            packages_to_install+=("$pkg")
        fi
    done
    
    local install_count=${#packages_to_install[@]}
    if [ $install_count -eq 0 ]; then
        ui_info "All $total packages already installed"
        return 0
    elif [ $install_count -lt $total ]; then
        ui_info "Installing $install_count/$total packages ($(($total - $install_count)) already installed)"
    else
        ui_info "Installing $install_count packages..."
    fi
    
    install_package_generic "$manager" "${packages_to_install[@]}"
}

# Remove package
remove_package() {
    local pkg="$1"
    local manager="${2:-pacman}"
    
    case "$manager" in
        pacman)
            sudo pacman -Rns --noconfirm "$pkg"
            ;;
        flatpak)
            sudo flatpak uninstall -y "$pkg"
            ;;
    esac
}

# Update system
update_system() {
    ui_info "Updating system packages..."
    if sudo pacman -Syu --noconfirm --overwrite="*"; then
        ui_success "System updated successfully"
    else
        ui_error "System update failed"
        return 1
    fi
    
    if command -v yay &>/dev/null; then
        ui_info "Updating AUR packages..."
        if yay -Syu --noconfirm; then
            ui_success "AUR packages updated successfully"
        else
            ui_warn "AUR update had some issues"
        fi
    fi
}

# Preload package lists for faster installation
preload_package_lists() {
    ui_info "Preloading package lists..."
    sudo pacman -Sy --noconfirm >/dev/null 2>&1
    if command -v yay >/dev/null; then
        yay -Sy --noconfirm >/dev/null 2>&1
    fi
}

# Enable multilib repository
enable_multilib() {
    if ! grep -q "^\[multilib\]" /etc/pacman.conf; then
        echo -e "\n[multilib]\nInclude = /etc/pacman.d/mirrorlist" | sudo tee -a /etc/pacman.conf >/dev/null
        ui_success "Enabled multilib repository"
        sudo pacman -Sy
    else
        ui_info "Multilib repository already enabled"
    fi
}
