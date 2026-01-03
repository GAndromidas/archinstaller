#!/bin/bash

# Enhanced Distro Detection and Package Manager Abstraction
# Respects distribution defaults and supports all target distributions

# Detect Linux distribution and set package manager variables with enhanced fallbacks
detect_distro() {
    if [ ! -f /etc/os-release ]; then
        log_error "Cannot detect distribution - /etc/os-release not found"
        return 1
    fi

    . /etc/os-release

    # Enhanced mapping with better fallbacks for all target distributions
    case "$ID" in
        "arch"|"archlinux"|"manjaro"|"endeavouros"|"cachyos")
            DISTRO_ID="arch"
            PKG_MANAGER="pacman"
            PKG_INSTALL="pacman -S --needed"
            PKG_REMOVE="pacman -Rns"
            PKG_UPDATE="pacman -Syu"
            PKG_NOCONFIRM="--noconfirm"
            PKG_CLEAN="pacman -Sc --noconfirm"
            FIREWALL_DEFAULT="ufw"
            PACKAGE_UNIVERSAL="flatpak"
            ;;
        "fedora"|"centos"|"rhel"|"rocky"|"almalinux"|"nobara")
            DISTRO_ID="fedora"
            PKG_MANAGER="dnf"
            PKG_INSTALL="dnf install"
            PKG_REMOVE="dnf remove"
            PKG_UPDATE="dnf upgrade"
            PKG_NOCONFIRM="-y"
            PKG_CLEAN="dnf clean all"
            FIREWALL_DEFAULT="firewalld"
            PACKAGE_UNIVERSAL="flatpak"
            ;;
        "debian"|"ubuntu"|"linuxmint"|"pop"|"zorin"|"kali")
            DISTRO_ID="debian"
            PKG_MANAGER="apt"
            PKG_INSTALL="apt-get install"
            PKG_REMOVE="apt-get remove"
            PKG_UPDATE="apt-get update && apt-get upgrade -yq"
            PKG_NOCONFIRM="-y"
            PKG_CLEAN="apt-get clean"
            FIREWALL_DEFAULT="ufw"
            PACKAGE_UNIVERSAL="flatpak"
            ;;
        *)
            log_warn "Unknown distribution: $ID"
            log_info "Attempting to detect package manager..."
            if command -v pacman >/dev/null; then
                DISTRO_ID="arch"
                PKG_MANAGER="pacman"
                PKG_INSTALL="pacman -S --needed"
                PKG_REMOVE="pacman -Rns"
                PKG_UPDATE="pacman -Syu"
                PKG_NOCONFIRM="--noconfirm"
                PKG_CLEAN="pacman -Sc --noconfirm"
                FIREWALL_DEFAULT="ufw"
                PACKAGE_UNIVERSAL="flatpak"
            elif command -v dnf >/dev/null; then
                DISTRO_ID="fedora"
                PKG_MANAGER="dnf"
                PKG_INSTALL="dnf install"
                PKG_REMOVE="dnf remove"
                PKG_UPDATE="dnf upgrade"
                PKG_NOCONFIRM="-y"
                PKG_CLEAN="dnf clean all"
                FIREWALL_DEFAULT="firewalld"
                PACKAGE_UNIVERSAL="flatpak"
            elif command -v apt >/dev/null; then
                DISTRO_ID="debian"
                PKG_MANAGER="apt"
                PKG_INSTALL="apt-get install"
                PKG_REMOVE="apt-get remove"
                PKG_UPDATE="apt-get update && apt-get upgrade -yq"
                PKG_NOCONFIRM="-y"
                PKG_CLEAN="apt-get clean"
                FIREWALL_DEFAULT="ufw"
                PACKAGE_UNIVERSAL="flatpak"
            else
                log_error "Cannot determine package manager for $ID"
                return 1
            fi
            ;;
    esac

    # Set distribution-specific defaults
    case "$DISTRO_ID" in
        "arch")
            # Arch and derivatives use UFW by default, not firewalld
            FIREWALL_DEFAULT="ufw"
            PACKAGE_UNIVERSAL="flatpak"
            ;;
        "fedora")
            # Fedora and derivatives use firewalld by default
            FIREWALL_DEFAULT="firewalld"
            PACKAGE_UNIVERSAL="flatpak"
            ;;
        "debian")
            # Debian/Ubuntu and derivatives use UFW by default
            FIREWALL_DEFAULT="ufw"
            PACKAGE_UNIVERSAL="flatpak"
            # Override for Ubuntu specifically if needed
            if [ "$ID" = "ubuntu" ]; then
                PACKAGE_UNIVERSAL="snap"
            fi
            ;;
    esac

    # Export all variables
    export DISTRO_ID PKG_MANAGER PKG_INSTALL PKG_REMOVE PKG_UPDATE PKG_NOCONFIRM PKG_CLEAN
    # Export PRETTY_NAME only if it exists
    if [ -n "${PRETTY_NAME:-}" ]; then
        export PRETTY_NAME
    fi
    export FIREWALL_DEFAULT PACKAGE_UNIVERSAL

    log_info "Distribution detected: $DISTRO_ID (${PRETTY_NAME:-Unknown})"
    log_info "Package manager: $PKG_MANAGER"
    log_info "Default firewall: $FIREWALL_DEFAULT"
    log_info "Universal package manager: $PACKAGE_UNIVERSAL"
    return 0
}

# Detect Desktop Environment with enhanced detection
detect_de() {
    # Detect Desktop Environment
    if [ "${XDG_CURRENT_DESKTOP:-}" = "" ]; then
        # Try to detect via installed packages or other env vars if not set
        case "$DISTRO_ID" in
        "arch")
            # Check for various desktop environments
            if pgrep -f "plasma" >/dev/null 2>&1; then
                XDG_CURRENT_DESKTOP="KDE"
            elif pgrep -f "gnome" >/dev/null 2>&1; then
                XDG_CURRENT_DESKTOP="GNOME:GNOME"
            elif pgrep -f "xfce" >/dev/null 2>&1; then
                XDG_CURRENT_DESKTOP="XFCE"
            elif pgrep -f "cinnamon" >/dev/null 2>&1; then
                XDG_CURRENT_DESKTOP="X-Cinnamon"
            elif pgrep -f "mate" >/dev/null 2>&1; then
                XDG_CURRENT_DESKTOP="MATE"
            elif pgrep -f "cosmic" >/dev/null 2>&1; then
                XDG_CURRENT_DESKTOP="pop:Cosmic"
            else
                XDG_CURRENT_DESKTOP="unknown"
            fi
            ;;
        "fedora")
            if rpm -q plasma-desktop >/dev/null 2>&1; then
                XDG_CURRENT_DESKTOP="KDE"
            elif rpm -q gnome-shell >/dev/null 2>&1; then
                XDG_CURRENT_DESKTOP="GNOME"
            elif rpm -q xfce4-session >/dev/null 2>&1; then
                XDG_CURRENT_DESKTOP="XFCE"
            elif rpm -q cinnamon >/dev/null 2>&1; then
                XDG_CURRENT_DESKTOP="X-Cinnamon"
            elif rpm -q mate-desktop >/dev/null 2>&1; then
                XDG_CURRENT_DESKTOP="MATE"
            elif rpm -q cosmic-session >/dev/null 2>&1; then
                XDG_CURRENT_DESKTOP="pop:Cosmic"
            else
                XDG_CURRENT_DESKTOP="unknown"
            fi
            ;;
        "debian")
            if dpkg -l | grep -q plasma-desktop; then
                XDG_CURRENT_DESKTOP="KDE"
            elif dpkg -l | grep -q gnome-shell; then
                XDG_CURRENT_DESKTOP="GNOME"
            elif dpkg -l | grep -q xfce4-session; then
                XDG_CURRENT_DESKTOP="XFCE"
            elif dpkg -l | grep -q cinnamon-desktop; then
                XDG_CURRENT_DESKTOP="X-Cinnamon"
            elif dpkg -l | grep -q mate-desktop; then
                XDG_CURRENT_DESKTOP="MATE"
            elif dpkg -l | grep -q cosmic-session; then
                XDG_CURRENT_DESKTOP="pop:Cosmic"
            else
                XDG_CURRENT_DESKTOP="unknown"
            fi
            ;;
        esac
    fi

    export XDG_CURRENT_DESKTOP
    log_info "Desktop Environment: ${XDG_CURRENT_DESKTOP:-None detected}"
    return 0
}

# Setup package providers respecting distribution defaults
setup_package_providers() {
    # Determine primary and backup universal package manager
    case "$DISTRO_ID" in
        "ubuntu")
            # Ubuntu uses Snap by default, but we'll respect user choice
            PRIMARY_UNIVERSAL_PKG="snap"
            BACKUP_UNIVERSAL_PKG="flatpak"
            ;;
        "arch"|"fedora"|"debian")
            # Other distributions prefer Flatpak
            PRIMARY_UNIVERSAL_PKG="flatpak"
            BACKUP_UNIVERSAL_PKG="none"
            ;;
    esac

    # Server mode uses native packages only
    if [ "${INSTALL_MODE:-default}" = "server" ]; then
        PRIMARY_UNIVERSAL_PKG="native"
        BACKUP_UNIVERSAL_PKG="native"
    fi

    export PRIMARY_UNIVERSAL_PKG BACKUP_UNIVERSAL_PKG
}

# Define common utility packages for all distros
define_common_packages() {
    # Common packages that exist across all distributions
    COMMON_UTILS="bc curl git rsync fzf fastfetch eza zoxide"

    # Distribution-specific packages
    case "$DISTRO_ID" in
        "arch")
            HELPER_UTILS=($COMMON_UTILS base-devel bluez-utils cronie openssh pacman-contrib plymouth flatpak)
            FIREWALL_PACKAGE="ufw"
            ;;
        "fedora")
            HELPER_UTILS=($COMMON_UTILS @development-tools bluez cronie openssh-server plymouth flatpak)
            FIREWALL_PACKAGE="firewalld"
            ;;
        "debian")
            HELPER_UTILS=($COMMON_UTILS build-essential bluez cron openssh-server plymouth flatpak)
            FIREWALL_PACKAGE="ufw"
            ;;
    esac

    export HELPER_UTILS FIREWALL_PACKAGE
}

# Resolve package name across different distributions
resolve_package_name() {
    local pkg="$1"
    local mapped="$pkg"

    # Skip AUR packages for non-Arch distributions
    if [ "$DISTRO_ID" != "arch" ]; then
        case "$pkg" in
            pacman-contrib|expac|yay|mkinitcpio) echo ""; return ;;
        esac
    fi

    # Distribution-specific package name mappings
    case "$DISTRO_ID" in
        "debian")
            case "$pkg" in
                base-devel) mapped="build-essential" ;;
                cronie) mapped="cron" ;;
                bluez-utils) mapped="bluez" ;;
                openssh) mapped="openssh-server" ;;
                docker) mapped="docker.io" ;;
            esac
            ;;
        "fedora")
            case "$pkg" in
                base-devel) mapped="@development-tools" ;;
                cronie) mapped="cronie" ;;
                openssh) mapped="openssh-server" ;;
            esac
            ;;
    esac

    echo "$mapped"
}

# Get appropriate firewall package for the distribution
get_firewall_package() {
    case "$DISTRO_ID" in
        "arch"|"debian") echo "ufw" ;;
        "fedora") echo "firewalld" ;;
        *) echo "ufw" ;;
    esac
}

# Get appropriate universal package manager
get_universal_package_manager() {
    case "$DISTRO_ID" in
        "ubuntu") echo "snap" ;;
        *) echo "flatpak" ;;
    esac
}

# Check if distribution uses systemd
uses_systemd() {
    [ -d /run/systemd ]
}

# Check if distribution supports AUR (Arch-based only)
supports_aur() {
    [ "$DISTRO_ID" = "arch" ]
}

# Check if distribution uses traditional SysV init
uses_sysv_init() {
    [ -d /etc/init.d ] && [ ! -d /run/systemd ]
}

# Export all functions for use by other modules
export -f detect_distro
export -f detect_de
export -f setup_package_providers
export -f define_common_packages
export -f resolve_package_name
export -f get_firewall_package
export -f get_universal_package_manager
export -f uses_systemd
export -f supports_aur
export -f uses_sysv_init
