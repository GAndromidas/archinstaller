#!/bin/bash
set -uo pipefail

# Security Configuration Module for LinuxInstaller
# Based on best practices from all installers

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
source "$SCRIPT_DIR/distro_check.sh"

# Security-specific package lists
SECURITY_ESSENTIALS=(
    fail2ban
)

SECURITY_ARCH=(
    ufw
    apparmor
)

SECURITY_FEDORA=(
    firewalld
    selinux-policy-targeted
)

SECURITY_DEBIAN=(
    ufw
    apparmor
    apparmor-profiles
    apparmor-utils
)

# =============================================================================
# FIREWALL CONFIGURATION SYSTEM
# =============================================================================

# Install and configure appropriate firewall for the distribution
security_configure_firewall() {
    display_step "🔥" "Configuring Firewall"

    # Get the appropriate firewall package for this distribution
    local firewall_pkg
    firewall_pkg=$(get_firewall_package)

    log_info "Installing $firewall_pkg for $DISTRO_ID..."

    # Install firewall package
    if ! install_packages_with_progress "$firewall_pkg"; then
        log_error "Failed to install $firewall_pkg"
        return 1
    fi

    # Configure firewall based on distribution
    case "$DISTRO_ID" in
        "arch"|"debian"|"ubuntu")
            configure_ufw_firewall
            ;;
        "fedora")
            configure_firewalld_firewall
            ;;
    esac

    log_success "Firewall configured successfully"
}

# Configure UFW (Ubuntu/Debian family)
configure_ufw_firewall() {
    log_info "Configuring UFW firewall..."

    # Reset UFW to defaults
    ufw --force reset >/dev/null 2>&1 || true

    # Set default policies
    ufw default deny incoming >/dev/null 2>&1
    ufw default allow outgoing >/dev/null 2>&1

    # Allow SSH (if on server, might want to restrict this)
    ufw allow ssh >/dev/null 2>&1

    # Allow essential services
    ufw allow 22/tcp    # SSH
    ufw allow 80/tcp    # HTTP
    ufw allow 443/tcp   # HTTPS

    # Allow KDE Connect if KDE is detected
    if [ "${XDG_CURRENT_DESKTOP:-}" = "KDE" ]; then
        ufw allow 1714:1764/udp >/dev/null 2>&1
        ufw allow 1714:1764/tcp >/dev/null 2>&1
        log_success "KDE Connect ports (1714-1764 UDP/TCP) allowed in UFW"
    fi

    # Enable UFW
    echo "y" | ufw enable >/dev/null 2>&1 || true

    # Enable logging
    ufw logging on >/dev/null 2>&1

    # Force enable without prompt, and ensure the ufw systemd service is enabled so rules persist across reboot
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl enable --now ufw >/dev/null 2>&1; then
            log_success "UFW enabled and will start on boot"
        else
            log_warn "Failed to enable ufw.service; firewall may not persist across reboot"
        fi
    fi

    log_success "UFW firewall configured"
    log_info "  - Default: deny incoming, allow outgoing"
    log_info "  - Allowed: SSH (22), HTTP (80), HTTPS (443)"
    if [ "${XDG_CURRENT_DESKTOP:-}" = "KDE" ]; then
        log_info "  - KDE Connect: 1714-1764 UDP/TCP"
    fi
}

# Configure firewalld (Fedora family)
configure_firewalld_firewall() {
    log_info "Configuring firewalld..."

    # Start and enable firewalld
    systemctl enable --now firewalld >/dev/null 2>&1

    # Set default zone to public
    firewall-cmd --set-default-zone=public --permanent >/dev/null 2>&1

    # Add essential services
    firewall-cmd --permanent --add-service=ssh >/dev/null 2>&1
    firewall-cmd --permanent --add-service=http >/dev/null 2>&1
    firewall-cmd --permanent --add-service=https >/dev/null 2>&1

    # Allow KDE Connect if KDE is detected
    if [ "${XDG_CURRENT_DESKTOP:-}" = "KDE" ]; then
        if firewall-cmd --permanent --add-service=kde-connect >/dev/null 2>&1; then
            log_success "KDE Connect service allowed in firewall"
        else
            # Fallback: manually allow KDE Connect ports
            firewall-cmd --permanent --add-port=1714-1764/udp >/dev/null 2>&1
            firewall-cmd --permanent --add-port=1714-1764/tcp >/dev/null 2>&1
            log_success "KDE Connect ports (1714-1764) allowed in firewall"
        fi
    fi

    # Reload firewalld
    firewall-cmd --reload >/dev/null 2>&1

    log_success "firewalld configured"
    log_info "  - Default zone: public"
    log_info "  - Allowed services: SSH, HTTP, HTTPS"
    if [ "${XDG_CURRENT_DESKTOP:-}" = "KDE" ]; then
        log_info "  - KDE Connect: 1714-1764 UDP/TCP"
    fi
}

# Configure fail2ban for all distributions
security_configure_fail2ban() {
    display_step "🔒" "Configuring Fail2ban"

    # Install fail2ban
    if ! install_packages_with_progress "fail2ban"; then
        log_error "Failed to install fail2ban"
        return 1
    fi

    # Create jail.local configuration
    local jail_config="/etc/fail2ban/jail.local"
    cat > "$jail_config" << EOF
[DEFAULT]
# Ban hosts for 1 hour
bantime = 3600

# A host is banned if it has generated "maxretry" during the last "findtime" seconds
findtime = 600

# Number of tries before a host gets banned
maxretry = 3

# Enable email notifications (if mail is configured)
destemail = root@localhost
sender = fail2ban@localhost
action = %(action_mw)s

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3

[sshd-ddos]
enabled = true
port = ssh
filter = sshd-ddos
logpath = /var/log/auth.log
maxretry = 2
EOF

    # Enable and start fail2ban
    systemctl enable --now fail2ban >/dev/null 2>&1

    log_success "Fail2ban configured"
    log_info "  - SSH brute force protection enabled"
    log_info "  - Ban time: 1 hour"
    log_info "  - Max retries: 3"
}

# Configure AppArmor (Debian/Ubuntu family)
security_configure_apparmor() {
    if [ "$DISTRO_ID" != "fedora" ]; then
        display_step "🛡️" "Configuring AppArmor"

        # Install AppArmor packages
        if ! install_packages_with_progress "apparmor" "apparmor-utils"; then
            log_warn "Failed to install AppArmor"
            return 1
        fi

        # Enable AppArmor
        if systemctl enable --now apparmor >/dev/null 2>&1; then
            log_success "AppArmor enabled and started"

            # Load default profiles
            apparmor_parser -q /etc/apparmor.d/* >/dev/null 2>&1 || true
            log_success "AppArmor profiles loaded"
        else
            log_warn "Failed to enable AppArmor"
        fi

        log_success "AppArmor configured"
        log_info "  - Mandatory Access Control enabled"
    fi
}

# Configure SELinux (Fedora family)
security_configure_selinux() {
    if [ "$DISTRO_ID" = "fedora" ]; then
        display_step "🛡️" "Configuring SELinux"

        # Install SELinux packages
        if ! install_packages_with_progress "selinux-policy-targeted"; then
            log_warn "Failed to install SELinux"
            return 1
        fi

        # Set SELinux to enforcing mode
        setenforce 1 2>/dev/null || true

        log_success "SELinux configured"
        log_info "  - Enforcing mode enabled"
    fi
}

# Configure SSH server security settings
security_configure_ssh() {
    display_step "🔐" "Configuring SSH Security"

    if [ -f /etc/ssh/sshd_config ]; then
        log_info "Configuring SSH security settings..."

        # Apply security settings
        sed -i 's/^#PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config 2>/dev/null || true
        sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config 2>/dev/null || true
        sed -i 's/^#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config 2>/dev/null || true
        sed -i 's/^#MaxAuthTries 6/MaxAuthTries 3/' /etc/ssh/sshd_config 2>/dev/null || true
        sed -i 's/^#ClientAliveInterval 0/ClientAliveInterval 300/' /etc/ssh/sshd_config 2>/dev/null || true
        sed -i 's/^#ClientAliveCountMax 3/ClientAliveCountMax 2/' /etc/ssh/sshd_config 2>/dev/null || true

        # Restart SSH service
        if systemctl restart sshd >/dev/null 2>&1; then
            log_success "SSH configuration applied"
        else
            log_warn "Failed to restart SSH service"
        fi
    fi
}

# Configure user group memberships for system access
security_configure_user_groups() {
    display_step "👥" "Configuring User Groups"

    # Add user to essential groups
    local groups=("input" "video" "storage")

    # Sudo group difference
    if [ "$DISTRO_ID" == "debian" ] || [ "$DISTRO_ID" == "ubuntu" ]; then
        groups+=("sudo")
    else
        groups+=("wheel")
    fi

    # Docker group check
    if command -v docker >/dev/null; then groups+=("docker"); fi

    log_info "Adding user to groups: ${groups[*]}"
    for group in "${groups[@]}"; do
        if getent group "$group" >/dev/null; then
            if ! id -nG "$USER" | grep -qw "$group"; then
                usermod -aG "$group" "$USER"
                log_success "Added user to group: $group"
            else
                log_info "User already in group: $group"
            fi
        else
            log_warn "Group does not exist: $group"
        fi
    done
}

# Install security packages for all distributions
security_install_packages() {
    display_step "🔒" "Installing Security Packages"

    # Install security essential packages
    if [ ${#SECURITY_ESSENTIALS[@]} -gt 0 ]; then
        install_packages_with_progress "${SECURITY_ESSENTIALS[@]}"
    fi

    # Install distribution-specific security packages
    case "$DISTRO_ID" in
        "arch")
            if [ ${#SECURITY_ARCH[@]} -gt 0 ]; then
                install_packages_with_progress "${SECURITY_ARCH[@]}"
            fi
            ;;
        "fedora")
            if [ ${#SECURITY_FEDORA[@]} -gt 0 ]; then
                install_packages_with_progress "${SECURITY_FEDORA[@]}"
            fi
            ;;
        "debian"|"ubuntu")
            if [ ${#SECURITY_DEBIAN[@]} -gt 0 ]; then
                install_packages_with_progress "${SECURITY_DEBIAN[@]}"
            fi
            ;;
    esac
}

# =============================================================================
# MAIN SECURITY CONFIGURATION FUNCTION
# =============================================================================

security_main_config() {
    log_info "Starting security configuration..."

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Would configure security features"
        return
    fi

    security_install_packages

    security_configure_fail2ban

    security_configure_firewall

    security_configure_apparmor

    security_configure_selinux

    security_configure_ssh

    security_configure_user_groups

    log_success "Security configuration completed"
}

# Export functions for use by main installer
export -f security_main_config
export -f security_install_packages
export -f security_configure_fail2ban
export -f security_configure_firewall
export -f security_configure_apparmor
export -f security_configure_selinux
export -f security_configure_ssh
export -f security_configure_user_groups
export -f configure_ufw_firewall
export -f configure_firewalld_firewall
