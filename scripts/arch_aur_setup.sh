#!/bin/bash
set -uo pipefail

# Enhanced Arch Linux AUR Setup Script
# Handles installation of yay AUR helper, mirror optimization, and proper package management

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
source "$SCRIPT_DIR/distro_check.sh"
source "$SCRIPT_DIR/package_manager.sh"

# Ensure we're on Arch Linux
if [ "$DISTRO_ID" != "arch" ]; then
    log_error "This script is for Arch Linux only"
    exit 1
fi

# Enhanced yay installation with proper user context and error handling
arch_install_aur_helper() {
    display_step "📦" "Installing AUR Helper (yay)"

    if command -v yay >/dev/null 2>&1; then
        log_info "yay is already installed"
        return 0
    fi

    # Install build dependencies first
    log_info "Installing build dependencies..."
    if ! install_packages_with_progress "base-devel" "git"; then
        log_error "Failed to install build dependencies"
        return 1
    fi

    # Create secure temporary directory
    local temp_dir
    temp_dir=$(mktemp -d)
    chmod 700 "$temp_dir"

    # Determine build user (never run as root)
    local build_user=""
    if [ "$EUID" -eq 0 ]; then
        if [ -n "${SUDO_USER:-}" ]; then
            build_user="$SUDO_USER"
        else
            # Fallback to first real user if SUDO_USER not set
            build_user=$(getent passwd 1000 | cut -d: -f1)
        fi
        if [ -z "${build_user:-}" ]; then
            log_error "Cannot determine user for AUR build"
            rm -rf "$temp_dir"
            return 1
        fi
        # Change ownership to build user
        chown "$build_user:$build_user" "$temp_dir"
        chmod 755 "$temp_dir"
    else
        build_user="$USER"
    fi

    # Clone and build yay
    log_info "Cloning yay repository..."
    cd "$temp_dir" || {
        log_error "Failed to change to temp directory"
        rm -rf "$temp_dir"
        return 1
    }

    if sudo -u "$build_user" git clone https://aur.archlinux.org/yay.git . >/dev/null 2>&1; then
        log_info "Building yay..."
        if sudo -u "$build_user" makepkg -si --noconfirm --needed >/dev/null 2>&1; then
            display_success "✓ yay installed successfully"

            # Clean up build files
            log_info "Cleaning up build files..."
            if [ "$EUID" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
                sudo -u "$build_user" rm -rf "/tmp/yay"* "/tmp/makepkg"* 2>/dev/null || true
            fi
            rm -rf /tmp/yay* /tmp/makepkg* 2>/dev/null || true
            log_success "Build files cleaned up"
        else
            log_error "Failed to build yay"
            cd - >/dev/null
            rm -rf "$temp_dir"
            return 1
        fi
    else
        log_error "Failed to clone yay repository"
        cd - >/dev/null
        rm -rf "$temp_dir"
        return 1
    fi

    cd - >/dev/null
    rm -rf "$temp_dir"

    # Verify yay installation
    if ! command -v yay >/dev/null 2>&1; then
        log_error "yay installation verification failed"
        return 1
    fi

    log_success "yay installation completed successfully"
    return 0
}

# Enhanced mirror optimization with country detection
update_mirrors_with_reflector() {
    display_step "🌐" "Optimizing Mirror List"

    if ! command -v reflector >/dev/null 2>&1; then
        log_error "reflector not found. Cannot update mirrors."
        log_info "Installing reflector..."
        if ! install_packages_with_progress "reflector"; then
            log_error "Failed to install reflector"
            return 1
        fi
    fi

    log_info "Finding fastest Arch Linux mirrors based on your location..."

    # Check internet connectivity
    if ! ping -c 1 -W 5 archlinux.org >/dev/null 2>&1; then
        log_warn "No internet connectivity, using existing mirror configuration"
        return 0
    fi

    log_info "Internet available, optimizing mirrors..."

    # Detect country for better mirror selection
    local country=""
    if country=$(curl -s --max-time 5 https://ipinfo.io/country 2>/dev/null | tr -d '\n' | tr -d '\r'); then
        if [ -n "$country" ] && [ "$country" != "null" ]; then
            log_info "Detected country: $country"
            if reflector --latest 10 --sort rate --age 24 --country "$country" --save /etc/pacman.d/mirrorlist --protocol https,http >/dev/null 2>&1; then
                log_success "Mirrorlist updated with country-specific mirrors"
            else
                log_warn "Failed to update mirrors with country detection, using global selection"
                if ! reflector --latest 10 --sort rate --age 24 --save /etc/pacman.d/mirrorlist --protocol https,http >/dev/null 2>&1; then
                    log_warn "Reflector failed, using existing mirrorlist"
                fi
            fi
        else
            log_info "Could not detect country, using global mirror selection"
            if ! reflector --latest 10 --sort rate --age 24 --save /etc/pacman.d/mirrorlist --protocol https,http >/dev/null 2>&1; then
                log_warn "Reflector failed, using existing mirrorlist"
            fi
        fi
    else
        log_info "Country detection failed, using global mirror selection"
        if ! reflector --latest 10 --sort rate --age 24 --save /etc/pacman.d/mirrorlist --protocol https,http >/dev/null 2>&1; then
            log_warn "Reflector failed, using existing mirrorlist"
        fi
    fi

    # Always update pacman database
    log_info "Updating pacman package database..."
    local sync_attempts=0
    local max_attempts=3

    while [ $sync_attempts -lt $max_attempts ]; do
        if pacman -Syy >/dev/null 2>&1; then
            log_success "Pacman database successfully synchronized"
            return 0
        else
            sync_attempts=$((sync_attempts + 1))
            log_warn "Pacman sync attempt $sync_attempts failed, retrying..."
            sleep 2
        fi
    done

    log_error "Failed to synchronize pacman database after $max_attempts attempts"
    log_warn "You may need to manually run: pacman -Syy"
    return 1
}

# Enhanced AUR package installation with proper user context
install_aur_packages_with_yay() {
    local packages=("$@")
    local installed=() skipped=() failed=()

    # Check if yay is available
    if ! command -v yay >/dev/null 2>&1; then
        log_error "yay not found, cannot install AUR packages"
        return 1
    fi

    # Determine build user
    local build_user=""
    if [ "$EUID" -eq 0 ]; then
        if [ -n "${SUDO_USER:-}" ]; then
            build_user="$SUDO_USER"
        else
            build_user=$(getent passwd 1000 | cut -d: -f1)
        fi
        if [ -z "${build_user:-}" ]; then
            log_error "Cannot determine user for AUR installation"
            return 1
        fi
    else
        build_user="$USER"
    fi

    for pkg in "${packages[@]}"; do
        pkg="$(echo "$pkg" | xargs)"

        # Check if already installed
        if is_package_installed "$pkg"; then
            skipped+=("$pkg")
            continue
        fi

        log_info "Installing AUR package: $pkg"
        if sudo -u "$build_user" yay -S --noconfirm --needed "$pkg" >/dev/null 2>&1; then
            installed+=("$pkg")
        else
            failed+=("$pkg")
        fi
    done

    # Show installation summary
    if [ ${#installed[@]} -gt 0 ]; then
        log_success "Successfully installed AUR packages: ${installed[*]}"
    fi
    if [ ${#skipped[@]} -gt 0 ]; then
        log_info "Skipped (already installed): ${skipped[*]}"
    fi
    if [ ${#failed[@]} -gt 0 ]; then
        log_error "Failed to install AUR packages: ${failed[*]}"
    fi

    return $([ ${#failed[@]} -eq 0 ] && echo 0 || echo 1)
}

# Enhanced cleanup function
cleanup_yay_setup() {
    log_info "Cleaning up AUR setup..."

    # Remove yay-debug if installed
    if pacman -Q yay-debug >/dev/null 2>&1; then
        if pacman -Rns --noconfirm yay-debug >/dev/null 2>&1; then
            log_success "Successfully removed yay-debug"
        else
            log_warn "Failed to remove yay-debug"
        fi
    else
        log_info "yay-debug not installed"
    fi

    # Clean up any remaining temp directories
    log_info "Cleaning up temporary files..."
    rm -rf /tmp/yay* /tmp/makepkg* 2>/dev/null || true
    log_success "Temporary files cleaned up"
}

# Enhanced main execution with better error handling
arch_main_config() {
    display_step "🔧" "Setting up Arch Linux AUR Environment"

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Would setup AUR environment"
        return 0
    fi

    # Install yay AUR helper
    if ! arch_install_aur_helper; then
        log_error "Failed to install yay AUR helper"
        return 1
    fi

    # Update mirrors with reflector
    if ! update_mirrors_with_reflector; then
        log_warn "Mirror optimization failed, continuing with existing mirrors"
    fi

    # Cleanup temporary files
    cleanup_yay_setup

    log_success "Arch Linux AUR environment setup completed successfully"
    return 0
}

# Export functions for use by main installer
export -f arch_main_config
export -f arch_install_aur_helper
export -f update_mirrors_with_reflector
export -f install_aur_packages_with_yay
export -f cleanup_yay_setup

# Run main if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    arch_main_config
fi
