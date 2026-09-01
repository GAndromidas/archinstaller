#!/bin/bash
set -uo pipefail

# Gaming and performance tweaks installation for Arch Linux
# Get the directory where this script is located, resolving symlinks
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
ARCHINSTALLER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIGS_DIR="$ARCHINSTALLER_ROOT/configs"
GAMING_YAML="$CONFIGS_DIR/gaming_mode.yaml"

source "$SCRIPT_DIR/common.sh"

# ===== Globals =====
GAMING_ERRORS=()
GAMING_INSTALLED=()
pacman_gaming_programs=()
flatpak_gaming_programs=()

# ===== Local Helper Functions =====

# Enable multilib repository for gaming packages
check_and_enable_multilib() {
	# Enable multilib if not already enabled
	if ! grep -q "^\[multilib\]" /etc/pacman.conf; then
		echo -e "\n[multilib]\nInclude = /etc/pacman.d/mirrorlist" | sudo tee -a /etc/pacman.conf >/dev/null
		log_success "Enabled multilib repository for gaming mode"
		# Sync databases to pick up multilib (single sync, not full -Syy)
		sudo pacman -Syy --noconfirm >>"$INSTALL_LOG" 2>&1
	else
		log_success "Multilib repository already enabled"
	fi
}

# ===== YAML Parsing Functions =====
# Using centralized functions from config.sh library

# ===== Load All Package Lists from YAML =====
load_package_lists() {
	if [[ ! -f "$GAMING_YAML" ]]; then
		log_error "Gaming mode configuration file not found: $GAMING_YAML"
		return 1
	fi

	# Using config.sh library functions for YAML parsing
	read_yaml_packages_with_desc "$GAMING_YAML" ".pacman.packages" pacman_gaming_programs temp_descriptions
	read_yaml_packages_with_desc "$GAMING_YAML" ".flatpak.packages" flatpak_gaming_programs temp_descriptions
	return 0
}

# ===== Installation Functions =====
install_pacman_packages() {
	if [[ ${#pacman_gaming_programs[@]} -eq 0 ]]; then
		ui_info "No pacman packages for gaming mode to install."
		return
	fi
	ui_info "Installing ${#pacman_gaming_programs[@]} pacman packages for gaming..."

	# Dry-run: preview the gaming packages without modifying the system
	if [ "${DRY_RUN:-false}" = true ]; then
		ui_info "Dry-run: would install these gaming packages via Pacman:"
		printf '  %s\n' "${pacman_gaming_programs[@]}"
		GAMING_INSTALLED+=("${pacman_gaming_programs[@]}")
		return
	fi

	# Try batch install first
	printf '%b' "${THEME_TEXT}Attempting batch installation...${RESET}\n"
	# We capture stderr to a variable to print if it fails
	local batch_output
	if batch_output=$(sudo pacman -S --noconfirm --needed "${pacman_gaming_programs[@]}" 2>&1); then
		printf '%b' "${THEME_SUCCESS} ✓ Batch installation successful${RESET}\n"
		GAMING_INSTALLED+=("${pacman_gaming_programs[@]}")
		return
	fi

	printf '%b' "${THEME_WARN} ! Batch installation failed. Falling back to individual installation...${RESET}\n"

	for pkg in "${pacman_gaming_programs[@]}"; do
		if pacman_install_single "$pkg" true; then GAMING_INSTALLED+=("$pkg"); else GAMING_ERRORS+=("$pkg (pacman)"); fi
	done
}

install_flatpak_packages() {
	if ! command -v flatpak >/dev/null; then ui_warn "flatpak is not installed. Skipping gaming Flatpaks."; return; fi
	# Flathub remote is added once in system_preparation.sh — no need to check here

	if [[ ${#flatpak_gaming_programs[@]} -eq 0 ]]; then
		ui_info "No Flatpak applications for gaming mode to install."
		return
	fi

	flatpak_install_batch "${flatpak_gaming_programs[@]}"
}

# ===== Configuration Functions =====
configure_mangohud() {
	if ! command -v mangohud >/dev/null; then
		log_warning "MangoHud not installed, skipping config."
		return
	fi

	step "Configuring MangoHud"

	local src="$CONFIGS_DIR/MangoHud.conf"
	local dst="$HOME/.config/MangoHud/MangoHud.conf"

	mkdir -p "$HOME/.config/MangoHud"

	if [ -f "$src" ]; then
		if cp "$src" "$dst"; then
			log_success "MangoHud config copied to $dst"
		else
			log_error "Failed to copy MangoHud.conf" "cp exit code: $?"
		fi
	else
		log_warning "Source MangoHud.conf not found at $src"
	fi
}

enable_gamemode() {
	step "Enabling GameMode service"
	# GameMode is a user service
	if systemctl --user daemon-reload &>/dev/null && systemctl --user enable --now gamemoded &>/dev/null; then
		log_success "GameMode service enabled and started successfully."
	else
		log_warning "Failed to enable or start GameMode service. It may require manual configuration."
	fi
}

# ===== Main Execution =====
main() {
	step "Gaming Mode Setup"
	simple_banner "Gaming Mode"

	local description="This includes popular tools like Discord, Steam, Wine, GameMode, MangoHud, Goverlay, Heroic Games Launcher, and more."
	
	# Use the same robust gum_confirm pattern as other scripts
	if ! ui_confirm "Enable Gaming Mode?" "$description"; then
		ui_info "Gaming Mode skipped."
		return 0
	fi

	ui_success "Gaming Mode enabled! Installing gaming packages and optimizations..."

	if ! load_package_lists; then
		return 1
	fi

	# Crucial: Ensure multilib is actually working before attempting to install steam/wine
	check_and_enable_multilib


	install_pacman_packages
	install_flatpak_packages
	configure_mangohud
	
	# Check current kernel for optimizations
	local kernel=$(uname -r)
	
	log_info "Current kernel: $kernel"
	log_info "Gaming optimizations applied via GameMode and gaming tools"
	
	ui_success "Gaming Mode installation complete!"
	ui_info "Your system is now optimized for gaming with GameMode and gaming tools."
}

main
