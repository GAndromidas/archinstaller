#!/bin/bash
set -uo pipefail

# Pacman, AUR, and Flatpak install/remove helpers

# Run a package-manager command with a couple of retries for transient
# failures — a locked pacman db (another process/timer still holding it) or
# a flaky mirror/network blip are common on real hardware right after boot,
# and are not worth failing the whole install over. Anything else (missing
# package, signature failure, etc.) is returned as-is on first attempt.
if ! declare -f run_with_retry >/dev/null 2>&1; then
run_with_retry() {
    local max_attempts=3
    local delay=3
    local attempt=1
    local output rc

    while :; do
        output=$("$@" 2>&1)
        rc=$?
        if [ "$rc" -eq 0 ]; then
            printf '%s' "$output"
            return 0
        fi

        # Only retry errors that are actually transient.
        if [[ "$output" != *"could not lock database"* ]] && \
           [[ "$output" != *"failed to synchronize"* ]] && \
           [[ "$output" != *"failed retrieving file"* ]] && \
           [[ "$output" != *"Could not resolve host"* ]] && \
           [[ "$output" != *"Connection timed out"* ]]; then
            printf '%s' "$output"
            return "$rc"
        fi

        if [ "$attempt" -ge "$max_attempts" ]; then
            printf '%s' "$output"
            return "$rc"
        fi

        log_debug "Transient package-manager error (attempt $attempt/$max_attempts) — retrying in ${delay}s" "$output"
        sleep "$delay"
        attempt=$((attempt + 1))
        delay=$((delay * 2))
    done
}
fi

if ! declare -f is_package_installed >/dev/null 2>&1; then
is_package_installed() {
    local manager="$1"
    local pkg="$2"

    case "$manager" in
        pacman|aur)
            pacman -Q "$pkg" &>/dev/null
            ;;
        flatpak)
            flatpak list --app --columns=application 2>/dev/null | grep -qxF "$pkg"
            ;;
    esac
}
fi

if ! declare -f pacman_install_single >/dev/null 2>&1; then
pacman_install_single() {
    local pkg="$1"
    local verbose="${2:-false}"

    if [ "$verbose" = true ]; then
        printf '%b' "${THEME_TEXT}Installing Pacman package:${RESET} %-30s" "$pkg"
    fi

    local output
    if output=$(run_with_retry sudo pacman -S --noconfirm --needed "$pkg"); then
        [ "$verbose" = true ] && printf '%b' "${THEME_SUCCESS} ✓ Success${RESET}\n"
        INSTALLED_PACKAGES+=("$pkg")
        return 0
    else
        [ "$verbose" = true ] && printf '%b' "${THEME_ERROR} ✗ Failed${RESET}\n"
        if [ "$verbose" = true ] || [[ "$output" == *"error:"* ]]; then
            while IFS= read -r line; do printf '    %s\n' "$line"; done <<<"$output"
        fi
        FAILED_PACKAGES+=("$pkg")
        return 1
    fi
}
fi

if ! declare -f yay_install_single >/dev/null 2>&1; then
yay_install_single() {
    local pkg="$1"
    local verbose="${2:-false}"

    if ! command -v yay &>/dev/null; then
        log_error "AUR helper (yay) not found"
        return 1
    fi

    if [ "$verbose" = true ]; then
        printf '%b' "${THEME_TEXT}Installing AUR package:${RESET} %-30s" "$pkg"
    fi

    local output
    if output=$(run_with_retry yay -S --noconfirm --needed "$pkg"); then
        [ "$verbose" = true ] && printf '%b' "${THEME_SUCCESS} ✓ Success${RESET}\n"
        INSTALLED_PACKAGES+=("$pkg")
        return 0
    else
        [ "$verbose" = true ] && printf '%b' "${THEME_ERROR} ✗ Failed${RESET}\n"
        if [ "$verbose" = true ] || [[ "$output" == *"error:"* ]]; then
            while IFS= read -r line; do printf '    %s\n' "$line"; done <<<"$output"
        fi
        FAILED_PACKAGES+=("$pkg")
        return 1
    fi
}
fi

if ! declare -f flatpak_install_single >/dev/null 2>&1; then
flatpak_install_single() {
    local pkg="$1"
    local verbose="${2:-false}"

    if ! command -v flatpak &>/dev/null; then
        log_error "Flatpak not found"
        return 1
    fi

    if [ "$verbose" = true ]; then
        printf '%b' "${THEME_TEXT}Installing Flatpak app:${RESET} %-30s" "$pkg"
    fi

    local output
    if output=$(sudo flatpak install -y --noninteractive flathub "$pkg" 2>&1); then
        [ "$verbose" = true ] && printf '%b' "${THEME_SUCCESS} ✓ Success${RESET}\n"
        INSTALLED_PACKAGES+=("$pkg")
        return 0
    else
        [ "$verbose" = true ] && printf '%b' "${THEME_ERROR} ✗ Failed${RESET}\n"
        if [ "$verbose" = true ] || [[ "$output" == *"error:"* ]]; then
            while IFS= read -r line; do printf '    %s\n' "$line"; done <<<"$output"
        fi
        FAILED_PACKAGES+=("$pkg")
        return 1
    fi
}
fi

# Faster than installing one-by-one
if ! declare -f flatpak_install_batch >/dev/null 2>&1; then
flatpak_install_batch() {
    local packages=("$@")
    local total=${#packages[@]}

    if [ "$total" -eq 0 ]; then
        return 0
    fi

    if ! command -v flatpak &>/dev/null; then
        log_error "Flatpak not found"
        return 1
    fi

    ui_info "Installing $total Flatpak applications..."

    if [ "${DRY_RUN:-false}" = true ]; then
        ui_info "Dry-run: would install these Flatpak applications:"
        printf '  %s\n' "${packages[@]}"
        INSTALLED_PACKAGES+=("${packages[@]}")
        return 0
    fi

    # Try batch install first (flatpak supports multiple app IDs)
    local output
    if output=$(sudo flatpak install -y --noninteractive flathub "${packages[@]}" 2>&1); then
        ui_success "Flatpak batch installation successful ($total apps)"
        INSTALLED_PACKAGES+=("${packages[@]}")
        return 0
    fi

    # Fallback: install one by one (some apps may not be available)
    ui_warn "Batch install had failures, trying individually..."
    local failed=0
    for pkg in "${packages[@]}"; do
        if flatpak_install_single "$pkg" true; then
            : # flatpak_install_single already records successful packages.
        else
            ((failed++))
        fi
    done

    if [ "$failed" -gt 0 ]; then
        ui_warn "$failed Flatpak app(s) failed to install"
        return 1
    fi
    return 0
}
fi

if ! declare -f install_package_generic >/dev/null 2>&1; then
install_package_generic() {
    local manager="$1"
    shift
    local packages=("$@")
    local failed=0

    for pkg in "${packages[@]}"; do
        local manager_name=""

        case "$manager" in
            pacman)
                manager_name="pacman"
                ;;
            aur)
                manager_name="AUR"
                ;;
            flatpak)
                manager_name="Flatpak"
                ;;
        esac

        if [ "${DRY_RUN:-false}" = true ]; then
            ui_info "Dry-run: Would install $pkg via $manager_name"
            INSTALLED_PACKAGES+=("$pkg")
        else
            local error_output install_result=1
            case "$manager" in
                pacman)
                    error_output=$(run_with_retry sudo pacman -S --noconfirm --needed "$pkg") && install_result=0
                    ;;
                aur)
                    error_output=$(run_with_retry yay -S --noconfirm --needed "$pkg") && install_result=0
                    ;;
                flatpak)
                    error_output=$(sudo flatpak install -y --noninteractive flathub "$pkg" 2>&1) && install_result=0
                    ;;
            esac

            if [ "$install_result" -eq 0 ]; then
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

    if [ "$failed" -eq 0 ]; then
        ui_success "Package installation completed"
        return 0
    else
        ui_warn "Package installation completed with $failed failures"
        return 1
    fi
}
fi

if ! declare -f install_packages_batch >/dev/null 2>&1; then
install_packages_batch() {
    local manager="$1"
    shift
    local packages=("$@")
    local total=${#packages[@]}

    if [ "$total" -eq 0 ]; then
        return 0
    fi

    local packages_to_install=()
    for pkg in "${packages[@]}"; do
        if ! is_package_installed "$manager" "$pkg"; then
            packages_to_install+=("$pkg")
        fi
    done

    local install_count=${#packages_to_install[@]}
    if [ "$install_count" -eq 0 ]; then
        ui_info "All $total packages already installed"
        return 0
    elif [ "$install_count" -lt "$total" ]; then
        ui_info "Installing $install_count/$total packages ($((total - install_count)) already installed)"
    else
        ui_info "Installing $install_count packages..."
    fi

    install_package_generic "$manager" "${packages_to_install[@]}"
}
fi

if ! declare -f remove_package >/dev/null 2>&1; then
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
fi

if ! declare -f update_system >/dev/null 2>&1; then
update_system() {
    ui_info "Updating system packages..."
    if sudo pacman -Syu --noconfirm; then
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
fi
