#!/bin/bash
# =============================================================================
# Unified Package Manager Module for LinuxInstaller
# =============================================================================

# Import required functions from common.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Install packages with clean progress indicators and enhanced error handling
install_packages_with_progress() {
    local packages=("$@")
    local total=${#packages[@]}
    local current=0
    local installed=()
    local failed=()
    local skipped=()

    if [ $total -eq 0 ]; then
        log_warn "No packages provided to install"
        return 0
    fi

    log_info "Installing $total packages..."

    for pkg in "${packages[@]}"; do
        ((current++))

        # Validate package name
        if ! validate_package_name "$pkg"; then
            failed+=("$pkg")
            continue
        fi

        # Check if already installed
        if is_package_installed "$pkg"; then
            skipped+=("$pkg")
            continue
        fi

        # Show progress
        if supports_gum; then
            gum spin --title "Installing $pkg ($current/$total)..." -- \
                install_single_package "$pkg" || failed+=("$pkg")
        else
            echo "Installing $pkg ($current/$total)..."
            install_single_package "$pkg" || failed+=("$pkg")
        fi

        if [ $? -eq 0 ]; then
            installed+=("$pkg")
            # Track installed packages in state
            state_update "pkg_$pkg" "installed"
            state_update "packages_installed" "${INSTALL_STATE["packages_installed"]}$pkg "
        fi
    done

    # Show installation summary
    if [ ${#installed[@]} -gt 0 ]; then
        log_success "Successfully installed: ${installed[*]}"
    fi
    if [ ${#skipped[@]} -gt 0 ]; then
        log_info "Skipped (already installed): ${skipped[*]}"
    fi
    if [ ${#failed[@]} -gt 0 ]; then
        log_error "Failed to install: ${failed[*]}"
    fi

    # Return success if at least some packages were installed
    [ ${#installed[@]} -gt 0 ]
}

# Install a single package with error handling
install_single_package() {
    local pkg="$1"

    # Validate package name
    if ! validate_package_name "$pkg"; then
        return 1
    fi

    # Install based on distribution
    case "$DISTRO_ID" in
        "arch")
            pacman -S --noconfirm --needed "$pkg"
            ;;
        "fedora")
            dnf install -y "$pkg"
            ;;
        "debian"|"ubuntu")
            DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"
            ;;
        *)
            log_error "Unsupported distribution for package installation: $DISTRO_ID"
            return 1
            ;;
    esac
}

# Check if a package is installed on the current system
is_package_installed() {
    local pkg="$1"
    local distro="${DISTRO_ID:-}"

    # Validate package name
    if ! validate_package_name "$pkg"; then
        return 1
    fi

    case "$distro" in
        "arch")
            pacman -Q "$pkg" >/dev/null 2>&1
            ;;
        "fedora")
            rpm -q "$pkg" >/dev/null 2>&1
            ;;
        "debian"|"ubuntu")
            dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'
            ;;
        *)
            return 1
            ;;
    esac
}

# Check if a package exists in repository (secure implementation)
package_exists() {
    local pkg="$1"
    local distro="${DISTRO_ID:-}"

    # Validate package name
    if ! validate_package_name "$pkg"; then
        return 1
    fi

    case "$distro" in
        "arch")
            pacman -Si "$pkg" >/dev/null 2>&1
            ;;
        "fedora")
            dnf info "$pkg" >/dev/null 2>&1
            ;;
        "debian"|"ubuntu")
            apt-cache show "$pkg" >/dev/null 2>&1
            ;;
        *)
            return 1
            ;;
    esac
}

# Remove one or more packages silently with improved error handling
remove_pkg() {
    if [ $# -eq 0 ]; then
        log_warn "remove_pkg: No packages provided to remove."
        return 1
    fi

    # Check if packages are installed and validate names
    local valid_packages=()
    for pkg in "$@"; do
        if ! validate_package_name "$pkg"; then
            continue
        fi
        if ! is_package_installed "$pkg"; then
            continue
        fi
        valid_packages+=("$pkg")
    done

    if [ ${#valid_packages[@]} -eq 0 ]; then
        return 0
    fi

    log_info "Removing package(s): ${valid_packages[*]}"
    local remove_status

    if [ "$DISTRO_ID" = "debian" ] || [ "$DISTRO_ID" = "ubuntu" ]; then
        DEBIAN_FRONTEND=noninteractive $PKG_REMOVE $PKG_NOCONFIRM "${valid_packages[@]}"
        remove_status=$?
    else
        $PKG_REMOVE $PKG_NOCONFIRM "${valid_packages[@]}"
        remove_status=$?
    fi

    if [ $remove_status -ne 0 ]; then
        log_error "Failed to remove package(s): ${valid_packages[*]}."
        log_error "This may leave your system in an inconsistent state."
        log_error "You may need to manually remove these packages or fix dependencies."
        return 1
    else
        log_success "Successfully removed: ${valid_packages[*]}"
    fi
}

# Update system packages silently
update_system() {
    log_info "Updating system packages..."
    local update_status=0

    if [ "$DISTRO_ID" = "debian" ] || [ "$DISTRO_ID" = "ubuntu" ]; then
        # Run apt-get update and apt-get upgrade separately
        DEBIAN_FRONTEND=noninteractive apt-get update -qq || update_status=$?
        if [ $update_status -eq 0 ]; then
            DEBIAN_FRONTEND=noninteractive apt-get upgrade -yq || update_status=$?
        fi
    else
        $PKG_UPDATE $PKG_NOCONFIRM >/dev/null 2>&1
        update_status=$?
    fi

    if [ $update_status -ne 0 ]; then
        log_error "System update failed."
    else
        log_success "System updated successfully."
    fi
}

# Resolve package name across different distributions
resolve_package_name() {
    local pkg="$1"
    local mapped="$pkg"

    if [ "$DISTRO_ID" != "arch" ]; then
        case "$pkg" in
            pacman-contrib|expac|yay|mkinitcpio) echo ""; return ;;
        esac
    fi

    if [ "$DISTRO_ID" == "debian" ]; then
        case "$pkg" in
            base-devel) mapped="build-essential" ;;
            cronie) mapped="cron" ;;
            bluez-utils) mapped="bluez" ;;
            openssh) mapped="openssh-server" ;;
            docker) mapped="docker.io" ;;
        esac
    elif [ "$DISTRO_ID" == "fedora" ]; then
        case "$pkg" in
            base-devel) mapped="@development-tools" ;;
            cronie) mapped="cronie" ;;
            openssh) mapped="openssh-server" ;;
        esac
    fi

    echo "$mapped"
}

# Install packages intelligently with dependency checking
install_packages_intelligent() {
    local packages=("$@")
    local to_install=()

    # Check what's already installed
    for pkg in "${packages[@]}"; do
        if ! is_package_installed "$pkg"; then
            to_install+=("$pkg")
        fi
    done

    # Group packages by type for parallel installation
    local native_packages=()
    local aur_packages=()

    for pkg in "${to_install[@]}"; do
        if package_exists "$pkg"; then
            native_packages+=("$pkg")
        elif [ "$DISTRO_ID" = "arch" ]; then
            aur_packages+=("$pkg")
        fi
    done

    # Install in parallel where possible
    if [ ${#native_packages[@]} -gt 0 ]; then
        install_packages_with_progress "${native_packages[@]}" &
    fi

    if [ ${#aur_packages[@]} -gt 0 ]; then
        install_aur_packages "${aur_packages[@]}" &
    fi

    wait # Wait for all background jobs

    # Return success if any packages were installed
    [ ${#to_install[@]} -gt 0 ]
}

# Install AUR packages with proper user context
install_aur_packages() {
    local packages=("$@")
    local installed=() skipped=() failed=()

    # Check if yay is available
    if ! command -v yay >/dev/null 2>&1; then
        log_warn "yay not found, skipping AUR packages: ${packages[*]}"
        return 0
    fi

    # Determine which user to run yay as (never as root)
    local yay_user=""
    if [ "$EUID" -eq 0 ]; then
        if [ -n "${SUDO_USER:-}" ]; then
            yay_user="$SUDO_USER"
        else
            # Fallback to first real user if SUDO_USER not set
            yay_user=$(getent passwd 1000 | cut -d: -f1)
        fi
        if [ -z "${yay_user:-}" ]; then
            log_error "Cannot determine user for AUR package installation"
            return 1
        fi
    else
        yay_user="$USER"
    fi

    for pkg in "${packages[@]}"; do
        pkg="$(echo "$pkg" | xargs)"

        echo "• Installing $pkg"
        if sudo -u "$yay_user" yay -S --noconfirm "$pkg" >/dev/null 2>&1; then
            installed+=("$pkg")
        else
            failed+=("$pkg")
        fi
    done

    # Show installation summary
    if [ ${#installed[@]} -gt 0 ]; then
        log_success "Successfully installed AUR packages: ${installed[*]}"
    fi
    if [ ${#failed[@]} -gt 0 ]; then
        log_error "Failed to install AUR packages: ${failed[*]}"
    fi
}

# Install Flatpak packages with individual tracking
install_flatpak_packages() {
    local packages=("$@")
    local installed=() skipped=() failed=()

    # Ensure flatpak is installed
    if ! command -v flatpak >/dev/null 2>&1; then
        log_info "Installing Flatpak..."
        install_packages_with_progress "flatpak"
    fi

    # Add Flathub remote if not exists
    if ! flatpak remote-list 2>/dev/null | grep -q flathub; then
        log_info "Adding Flathub remote..."
        flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo >/dev/null 2>&1
    fi

    for pkg in "${packages[@]}"; do
        pkg="$(echo "$pkg" | xargs)"

        # Check if flatpak is already installed
        if flatpak list 2>/dev/null | grep -q "^${pkg}\s"; then
            skipped+=("$pkg")
            continue
        fi

        echo "• Installing $pkg"
        if flatpak install flathub -y "$pkg" >/dev/null 2>&1; then
            installed+=("$pkg")
        else
            failed+=("$pkg")
        fi
    done

    # Show installation summary
    if [ ${#installed[@]} -gt 0 ]; then
        log_success "Successfully installed Flatpak packages: ${installed[*]}"
    fi
    if [ ${#skipped[@]} -gt 0 ]; then
        log_info "Skipped (already installed): ${skipped[*]}"
    fi
    if [ ${#failed[@]} -gt 0 ]; then
        log_error "Failed to install Flatpak packages: ${failed[*]}"
    fi
}

# Install Snap packages
install_snap_packages() {
    local packages=("$@")
    local installed=() skipped=() failed=()

    for pkg in "${packages[@]}"; do
        pkg="$(echo "$pkg" | xargs)"

        echo "• Installing $pkg"
        if snap install "$pkg" >/dev/null 2>&1; then
            installed+=("$pkg")
        else
            failed+=("$pkg")
        fi
    done

    # Show installation summary
    if [ ${#installed[@]} -gt 0 ]; then
        log_success "Successfully installed Snap packages: ${installed[*]}"
    fi
    if [ ${#failed[@]} -gt 0 ]; then
        log_error "Failed to install Snap packages: ${failed[*]}"
    fi
}

# Remove duplicate packages while preserving order
deduplicate_packages() {
    local -a packages=("$@")
    if [ ${#packages[@]} -gt 1 ]; then
        declare -A _seen_pkgs
        local _deduped=()
        for pkg in "${packages[@]}"; do
            if [ -n "$pkg" ] && [ -z "${_seen_pkgs[$pkg]:-}" ]; then
                _deduped+=("$pkg")
                _seen_pkgs[$pkg]=1
            fi
        done
        # Replace packages with deduplicated list
        printf "%s\n" "${_deduped[@]}"
        unset _seen_pkgs
    else
        printf "%s\n" "${packages[@]}"
    fi
}

# Export all functions for use by other modules
export -f install_packages_with_progress
export -f install_single_package
export -f is_package_installed
export -f package_exists
export -f remove_pkg
export -f update_system
export -f resolve_package_name
export -f install_packages_intelligent
export -f install_aur_packages
export -f install_flatpak_packages
export -f install_snap_packages
export -f deduplicate_packages
```
</tool_response>
