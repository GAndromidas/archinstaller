#!/bin/bash
set -uo pipefail

# Gaming and performance tweaks installation for Arch Linux
# Get the directory where this script is located, resolving symlinks
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
ARCHINSTALLER_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIGS_DIR="$ARCHINSTALLER_ROOT/configs"
GAMING_YAML="$CONFIGS_DIR/gaming_mode.yaml"

source "$SCRIPT_DIR/../common.sh"

# ===== Globals =====
GAMING_ERRORS=()
GAMING_INSTALLED=()
pacman_gaming_programs=()
aur_gaming_programs=()
flatpak_gaming_programs=()

# ===== Local Helper Functions =====

# Enable multilib repository for gaming packages (shared implementation in
# common.sh — see enable_multilib_repo)
check_and_enable_multilib() {
	local was_enabled=false
	grep -q "^\[multilib\]" /etc/pacman.conf 2>/dev/null && was_enabled=true

	enable_multilib_repo

	if [[ "$was_enabled" == false ]]; then
		# Sync-only (no -u): the repo is brand-new so databases must refresh
		# before installs, but a second full system upgrade mid-run is waste.
		# This is the one legitimate bare -Sy — do not "fix" into -Syu.
		sudo -n pacman -Sy --noconfirm >>"$INSTALL_LOG" 2>&1
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
	read_yaml_packages_with_desc "$GAMING_YAML" ".aur.packages" aur_gaming_programs temp_descriptions
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
	# Capture output so batch failures are logged with context on fallback.
	local batch_output=""
	if batch_output=$(sudo -n pacman -S --noconfirm --needed "${pacman_gaming_programs[@]}" 2>&1); then
		printf '%b' "${THEME_SUCCESS} ✓ Batch installation successful${RESET}\n"
		GAMING_INSTALLED+=("${pacman_gaming_programs[@]}")
		return
	fi
	log_debug "Gaming batch install failed, falling back to per-package" "$batch_output"

	printf '%b' "${THEME_WARN} ! Batch installation failed. Falling back to individual installation...${RESET}\n"

	for pkg in "${pacman_gaming_programs[@]}"; do
		if pacman_install_single "$pkg" true; then GAMING_INSTALLED+=("$pkg"); else GAMING_ERRORS+=("$pkg (pacman)"); fi
	done
}

install_aur_packages() {
	if [[ ${#aur_gaming_programs[@]} -eq 0 ]]; then
		ui_info "No AUR packages for gaming mode to install."
		return
	fi
	if ! command -v yay >/dev/null 2>&1; then
		ui_warn "yay is not installed. Skipping gaming AUR packages: ${aur_gaming_programs[*]}"
		local _mpkg
		for _mpkg in "${aur_gaming_programs[@]}"; do GAMING_ERRORS+=("$_mpkg (AUR — yay missing)"); done
		return
	fi
	ui_info "Installing ${#aur_gaming_programs[@]} AUR packages for gaming with yay..."

	# Dry-run: preview the AUR packages without modifying the system
	if [ "${DRY_RUN:-false}" = true ]; then
		ui_info "Dry-run: would install these gaming packages via yay (AUR):"
		printf '  %s\n' "${aur_gaming_programs[@]}"
		GAMING_INSTALLED+=("${aur_gaming_programs[@]}")
		return
	fi

	# Try batch install first
	printf '%b' "${THEME_TEXT}Attempting batch AUR installation...${RESET}\n"
	if yay -S --noconfirm --needed "${aur_gaming_programs[@]}" >>"$INSTALL_LOG" 2>&1; then
		printf '%b' "${THEME_SUCCESS} ✓ Batch AUR installation successful${RESET}\n"
		GAMING_INSTALLED+=("${aur_gaming_programs[@]}")
		return
	fi

	printf '%b' "${THEME_WARN} ! Batch AUR installation failed. Falling back to individual installation...${RESET}\n"

	for pkg in "${aur_gaming_programs[@]}"; do
		if yay_install_single "$pkg" true; then GAMING_INSTALLED+=("$pkg"); else GAMING_ERRORS+=("$pkg (AUR)"); fi
	done
}

install_flatpak_packages() {
	if ! command -v flatpak >/dev/null; then ui_warn "flatpak is not installed. Skipping gaming Flatpaks."; return; fi
	# Flathub remote is added once in system_preparation.sh — no need to check here

	if [[ ${#flatpak_gaming_programs[@]} -eq 0 ]]; then
		ui_info "No Flatpak applications for gaming mode to install."
		return
	fi

	if flatpak_install_batch "${flatpak_gaming_programs[@]}"; then
		GAMING_INSTALLED+=("${flatpak_gaming_programs[@]}")
	else
		GAMING_ERRORS+=("flatpak batch (see log for per-app results)")
	fi
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

enable_ananicy() {
	if ! pacman -Q ananicy-cpp &>/dev/null 2>&1; then
		log_info "ananicy-cpp not installed — skipping daemon setup."
		return 0
	fi
	step "Enabling Ananicy-Cpp daemon (auto NICe)"
	if sudo -n systemctl enable --now ananicy-cpp.service >>"$INSTALL_LOG" 2>&1; then
		log_success "ananicy-cpp enabled — process priorities are now managed automatically (CachyOS rules)."
	else
		log_warning "Failed to enable ananicy-cpp.service. Enable manually with: sudo -n systemctl enable --now ananicy-cpp.service"
	fi
	return 0
}

# True when an AMD GPU is present (LACT only drives AMDGPU)
is_amd_gpu() {
	lspci 2>/dev/null | grep -Eiq 'vga.*amd|3d.*amd|display.*amd|vga.*radeon|3d.*radeon'
}

# Drop AMD-only packages on non-AMD systems instead of installing dead weight
filter_gpu_specific_packages() {
	local filtered=()
	local pkg
	for pkg in "${pacman_gaming_programs[@]}"; do
		if [[ "$pkg" == "lact" ]] && ! is_amd_gpu && ! is_vm; then
			log_info "No AMD GPU detected — skipping lact (AMDGPU-only)."
			continue
		fi
		filtered+=("$pkg")
	done
	pacman_gaming_programs=("${filtered[@]}")
}

enable_lact() {
	if ! is_amd_gpu; then
		return 0
	fi
	if ! command -v lact &>/dev/null; then
		log_info "lact not installed — skipping daemon setup."
		return 0
	fi
	step "Enabling LACT daemon (AMD GPU control)"
	if sudo -n systemctl enable --now lactd >>"$INSTALL_LOG" 2>&1; then
		log_success "lactd enabled — open LACT to manage fan curves, clocks and power limits."
	else
		log_warning "Failed to enable lactd. Enable manually with: sudo -n systemctl enable --now lactd"
	fi
}

# ===== Main Execution =====
main() {
	step "Gaming Mode Setup"
	simple_banner "Gaming Mode"

	local description="This includes popular tools like Discord, Steam, Wine, Ananicy-Cpp, MangoHud, Goverlay, LACT (AMD GPU control), Heroic Games Launcher, and more."
	
	# Uses ui_confirm (lib/ui.sh), which handles both the gum and
	# plain-text-fallback confirmation paths.
	# Exit 2 = declined: the installer records SKIPPED (not COMPLETED) so a
	# later re-run offers Gaming Mode again.
	if ! ui_confirm "Enable Gaming Mode?" "$description"; then
		ui_info "Gaming Mode skipped — re-run the installer anytime to enable it."
		return 2
	fi

	ui_success "Gaming Mode enabled! Installing gaming packages and optimizations..."

	if ! load_package_lists; then
		return 1
	fi

	# Crucial: Ensure multilib is actually working before attempting to install steam/wine
	check_and_enable_multilib

	# LACT is AMDGPU-only — drop it on NVIDIA/Intel/VM systems
	filter_gpu_specific_packages

	# Flatpak shares no lock with pacman/yay, so it runs in parallel with
	# the pacman+AUR installs instead of waiting behind them. The background
	# job can't touch parent arrays — its exit code travels via a file and
	# counts merge after wait. All output stays in the install log.
	# Falls back to the sequential path when mktemp fails, flatpak is
	# missing, or the list is empty (those cases keep their skip messages).
	local _flatpak_rc_file="" _flatpak_pid=""
	if command -v flatpak &>/dev/null && [[ ${#flatpak_gaming_programs[@]} -gt 0 ]]; then
		_flatpak_rc_file=$(mktemp /tmp/archinstaller_gaming_flatpak.XXXXXX 2>/dev/null || echo "")
	fi
	if [[ -n "$_flatpak_rc_file" ]]; then
		( flatpak_install_batch "${flatpak_gaming_programs[@]}" >>"$INSTALL_LOG" 2>&1; echo "$?" > "$_flatpak_rc_file" ) &
		_flatpak_pid=$!
	fi
	install_pacman_packages
	install_aur_packages
	if [[ -n "$_flatpak_pid" ]]; then
		wait "$_flatpak_pid"
		local _flatpak_rc=1
		_flatpak_rc=$(cat "$_flatpak_rc_file" 2>/dev/null || echo 1)
		rm -f "$_flatpak_rc_file"
		if [[ "$_flatpak_rc" -eq 0 ]]; then
			GAMING_INSTALLED+=("${flatpak_gaming_programs[@]}")
		else
			GAMING_ERRORS+=("flatpak batch (see log for per-app results)")
		fi
	else
		install_flatpak_packages
	fi
	configure_mangohud
	enable_ananicy
	enable_lact
	
	# Check current kernel for optimizations
	local kernel=$(uname -r)
	
	log_info "Current kernel: $kernel"
	log_info "Gaming optimizations applied via Ananicy-Cpp and gaming tools"

	if [ ${#GAMING_ERRORS[@]} -gt 0 ]; then
		ui_warn "Gaming Mode completed with ${#GAMING_ERRORS[@]} failure(s): ${GAMING_ERRORS[*]}"
	else
		ui_success "Gaming Mode installation complete!"
		ui_info "Your system is now optimized for gaming with Ananicy-Cpp and gaming tools."
	fi
}

if [[ "${DRY_RUN:-false}" == true ]]; then
  ui_info "Dry-run: this installation module would run here."
  exit 0
fi
main
