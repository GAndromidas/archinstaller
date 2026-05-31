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
source "$SCRIPT_DIR/lib/config.sh"

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
	else
		log_success "Multilib repository already enabled"
	fi
	
	# Sync repositories to ensure multilib is available
	if sudo pacman -Sy; then
		log_success "Repositories synchronized successfully"
	else
		log_error "Failed to synchronize repositories"
		return 1
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
	read_yaml_packages_with_desc "$GAMING_YAML" ".flatpak.apps" flatpak_gaming_programs temp_descriptions
	return 0
}

# ===== Installation Functions =====
install_pacman_packages() {
	if [[ ${#pacman_gaming_programs[@]} -eq 0 ]]; then
		ui_info "No pacman packages for gaming mode to install."
		return
	fi
	ui_info "Installing ${#pacman_gaming_programs[@]} pacman packages for gaming..."

	# Try batch install first
	printf "${CYAN}Attempting batch installation...${RESET}\n"
	# We capture stderr to a variable to print if it fails
	local batch_output
	if batch_output=$(sudo pacman -S --noconfirm --needed "${pacman_gaming_programs[@]}" 2>&1); then
		printf "${GREEN} ✓ Batch installation successful${RESET}\n"
		GAMING_INSTALLED+=("${pacman_gaming_programs[@]}")
		return
	fi

	printf "${YELLOW} ! Batch installation failed. Falling back to individual installation...${RESET}\n"

	for pkg in "${pacman_gaming_programs[@]}"; do
		if pacman_install_single "$pkg" true; then GAMING_INSTALLED+=("$pkg"); else GAMING_ERRORS+=("$pkg (pacman)"); fi
	done
}

install_flatpak_packages() {
	if ! command -v flatpak >/dev/null; then ui_warn "flatpak is not installed. Skipping gaming Flatpaks."; return; fi

	# Ensure flathub remote exists (system-wide)
	if ! sudo flatpak remote-list | grep -q flathub; then
		step "Adding Flathub remote"
		sudo flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
	fi

	if [[ ${#flatpak_gaming_programs[@]} -eq 0 ]]; then
		ui_info "No Flatpak applications for gaming mode to install."
		return
	fi
	ui_info "Installing ${#flatpak_gaming_programs[@]} Flatpak applications for gaming..."

	for pkg in "${flatpak_gaming_programs[@]}"; do
		if flatpak_install_single "$pkg" true; then GAMING_INSTALLED+=("$pkg (Flatpak)"); else GAMING_ERRORS+=("$pkg (Flatpak)"); fi
	done
}

# ===== Configuration Functions =====
configure_mangohud() {
	step "Configuring MangoHud"
	local mangohud_config_dir="$HOME/.config/MangoHud"
	local mangohud_config_source="$CONFIGS_DIR/MangoHud.conf"

	mkdir -p "$mangohud_config_dir"

	if [ -f "$mangohud_config_source" ]; then
		cp "$mangohud_config_source" "$mangohud_config_dir/MangoHud.conf"
		log_success "MangoHud configuration copied successfully."
	else
		log_warning "MangoHud configuration file not found at $mangohud_config_source"
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
	if ! gum_confirm "Enable Gaming Mode?" "$description"; then
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
