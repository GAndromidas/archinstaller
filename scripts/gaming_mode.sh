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


# Install Arch Linux (linux-zen) for optimal gaming performance
install_zen_kernel() {
	# Check if Arch Linux (linux-zen) is already installed
	if pacman -Qi linux-zen &>/dev/null; then
		ui_info "Arch Linux (linux-zen) is already installed. Skipping installation."
		return 0
	fi
	
	ui_info "Installing Arch Linux (linux-zen) for optimal gaming performance..."
	
	if pacman_install_single "linux-zen" true; then
		GAMING_INSTALLED+=("linux-zen")
		log_success "Arch Linux (linux-zen) installed successfully"
		
		# Install headers for module compilation
		if pacman_install_single "linux-zen-headers" true; then
			GAMING_INSTALLED+=("linux-zen-headers")
		fi
		
		# Set Zen Kernel as default in bootloader
		configure_zen_kernel_default
		return 0
	else
		log_error "Failed to install Arch Linux (linux-zen)"
		GAMING_ERRORS+=("linux-zen")
		return 1
	fi
}

# Configure bootloader to use Arch Linux (linux-zen) as default
configure_zen_kernel_default() {
	# First check if Arch Linux (linux-zen) is actually installed
	if ! pacman -Qi linux-zen &>/dev/null; then
		ui_info "Arch Linux (linux-zen) not installed. Skipping bootloader configuration."
		return 0
	fi
	
	step "Configuring Arch Linux (linux-zen) as default boot entry"
	
	# Detect bootloader type using the same detection logic as bootloader_config.sh
	local BOOTLOADER=$(detect_bootloader)
	ui_info "Detected bootloader: $BOOTLOADER"
	
	if [[ "$BOOTLOADER" = "systemd-boot" ]]; then
		ui_info "Setting Arch Linux (linux-zen) as default in systemd-boot..."
		configure_systemd_boot_zen_default
	elif [[ "$BOOTLOADER" = "grub" ]]; then
		ui_info "Configuring GRUB for Arch Linux (linux-zen)..."
		configure_grub_zen
	elif [[ "$BOOTLOADER" = "limine" ]]; then
		ui_info "Configuring Limine for Arch Linux (linux-zen)..."
		configure_limine_zen
	else
		ui_warn "No supported bootloader detected. Manual configuration may be required."
	fi
}

# Configure systemd-boot to set Zen kernel as default in loader.conf
configure_systemd_boot_zen_default() {
	local loader_config="/boot/loader/loader.conf"
	
	if [ ! -f "$loader_config" ]; then
		log_warning "loader.conf not found, cannot set default kernel"
		return 1
	fi
	
	# Always create or update simple linux-zen.conf entry
	local zen_entry=$(configure_systemd_boot_zen)
	if [[ $? -ne 0 ]] || [[ -z "$zen_entry" ]]; then
		log_error "Failed to create Arch Linux (linux-zen) entry"
		return 1
	fi
	
	# Always use simple linux-zen.conf as default
	sudo sed -i '/^default /d' "$loader_config"
	echo "default linux-zen.conf" | sudo tee -a "$loader_config" >/dev/null
	
	log_success "Set Arch Linux (linux-zen) as default in systemd-boot loader.conf"
	ui_info "Arch Linux (linux-zen) will be used as default boot entry: linux-zen.conf"
}

# Configure systemd-boot for Arch Linux (linux-zen)
configure_systemd_boot_zen() {
	local entries_dir="/boot/loader/entries"
	
	ui_info "Creating Arch Linux (linux-zen) entry in: $entries_dir"
	
	# Find the best existing entry to copy from (handle both dated and simple names)
	local existing_entry=""
	local linux_entry=$(find "$entries_dir" -name "*linux.conf" ! -name "*fallback*" ! -name "*zen*" | head -1)
	local lts_entry=$(find "$entries_dir" -name "*linux-lts.conf" ! -name "*fallback*" ! -name "*zen*" | head -1)
	
	ui_info "Found linux entry: $linux_entry"
	ui_info "Found LTS entry: $lts_entry"
	
	# Prefer linux.conf over linux-lts.conf
	if [[ -f "$linux_entry" ]]; then
		existing_entry="$linux_entry"
	elif [[ -f "$lts_entry" ]]; then
		existing_entry="$lts_entry"
	else
		# Fallback to any non-fallback, non-zen entry
		existing_entry=$(find "$entries_dir" -name "*.conf" ! -name "*fallback*" ! -name "*zen*" | head -1)
	fi
	
	ui_info "Using existing entry: $existing_entry"
	
	if [[ -f "$existing_entry" ]]; then
		# Extract ALL parameters from existing entry
		local title=$(grep "^title " "$existing_entry" | sed 's/^title //')
		local linux=$(grep "^linux " "$existing_entry" | sed 's/^linux //')
		local initrd=$(grep "^initrd " "$existing_entry" | sed 's/^initrd //')
		local options=$(grep "^options " "$existing_entry" | sed 's/^options //')
		local machine_id=$(grep "^machine-id " "$existing_entry" | sed 's/^machine-id //' || echo "")
		
		# Always use simple filename: linux-zen.conf
		local zen_entry_file="$entries_dir/linux-zen.conf"
		
		ui_info "Creating linux-zen.conf with parameters from $(basename "$existing_entry")"
		
		# Create Arch Linux (linux-zen) entry with EXACT same parameters, just changing kernel files
		sudo tee "$zen_entry_file" > /dev/null << EOF
title   Arch Linux (linux-zen)
linux   /vmlinuz-linux-zen
initrd  /initramfs-linux-zen.img
options $options
EOF
		
		# Add machine-id if it existed in original
		if [[ -n "$machine_id" ]]; then
			echo "machine-id $machine_id" | sudo tee -a "$zen_entry_file" > /dev/null
		fi
		
		log_success "Created systemd-boot entry for Arch Linux (linux-zen) with exact same parameters as $(basename "$existing_entry")"
		ui_info "Arch Linux (linux-zen) entry created: $zen_entry_file"
		
		# Don't sync options - respect current configuration (including Plymouth splash)
		log_info "Respecting current kernel options (including Plymouth configuration)"
		
		# Return the full path for verification
		echo "$zen_entry_file"
		return 0
	else
		log_warning "Could not find existing boot entry to copy parameters from"
		return 1
	fi
}

# Sync kernel options across all kernel entries to ensure consistency
sync_kernel_options() {
	local standard_options="$1"
	local entries_dir="/boot/loader/entries"
	
	ui_info "Syncing kernel options across all kernel entries..."
	
	# Find all kernel entries (excluding fallback)
	local kernel_entries=()
	while IFS= read -r -d $'\0' entry; do
		kernel_entries+=("$entry")
	done < <(find "$entries_dir" -name "*.conf" ! -name "*fallback*" -print0)
	
	local updated_count=0
	
	for entry in "${kernel_entries[@]}"; do
		local entry_name=$(basename "$entry")
		
		# Extract current options from the entry
		local current_options=$(grep "^options " "$entry" | sed 's/^options //' || echo "")
		
		# Only update if options are different
		if [[ "$current_options" != "$standard_options" ]]; then
			# Create a temporary file with updated options
			local temp_file=$(mktemp)
			
			# Copy all lines except options, then add new options
			grep -v "^options " "$entry" > "$temp_file"
			echo "options $standard_options" >> "$temp_file"
			
			# Replace the original file
			sudo mv "$temp_file" "$entry"
			
			log_success "Updated options in $entry_name"
			((updated_count++))
		else
			log_info "Options already consistent in $entry_name"
		fi
	done
	
	if [[ $updated_count -gt 0 ]]; then
		log_success "Synced kernel options in $updated_count entries"
		ui_info "All kernel entries now have identical options"
	else
		log_info "All kernel entries already have consistent options"
	fi
}

# Helper function to safely set GRUB configuration values
set_grub_config() {
    local key="$1"
    local value="$2"
    local grub_config="/etc/default/grub"
    
    if grep -q "^${key}=" "$grub_config" 2>/dev/null; then
        sudo sed -i "s/^${key}=.*/${key}=${value}/" "$grub_config"
    else
        echo "${key}=${value}" | sudo tee -a "$grub_config" >/dev/null
    fi
}

# Configure GRUB for Arch Linux (linux-zen) with Plymouth support
configure_grub_zen() {
	# GRUB automatically detects installed kernels, but we need to ensure Plymouth parameters are set
	if [[ -f "/etc/default/grub" ]]; then
		# Ensure GRUB is configured to save the default
		set_grub_config "GRUB_DEFAULT" "saved"
		set_grub_config "GRUB_SAVEDEFAULT" "true"
		
		# Ensure Plymouth parameters are set for all kernels including Arch Linux (linux-zen)
		set_grub_config "GRUB_CMDLINE_LINUX_DEFAULT" '"quiet splash loglevel=3 systemd.show_status=auto rd.udev.log_level=3 plymouth.ignore-serial-consoles"'
		
		# Enable submenu for additional kernels (linux-lts, linux-zen)
		set_grub_config "GRUB_DISABLE_SUBMENU" "notlinux"
		
		# Regenerate GRUB config to include Zen kernel with Plymouth support
		if sudo grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1; then
			log_success "GRUB configured for Arch Linux (linux-zen) with Plymouth support"
		else
			log_error "Failed to regenerate GRUB configuration"
		fi
	fi
}

# Configure Limine bootloader for Arch Linux (linux-zen) with Plymouth support
configure_limine_zen() {
	local limine_config="/boot/limine.conf"
	
	# Get root filesystem information
	local root_uuid=""
	root_uuid=$(findmnt -n -o UUID / 2>/dev/null || echo "")
	
	if [[ -z "$root_uuid" ]]; then
		log_error "Could not determine root UUID for Limine configuration"
		return 1
	fi
	
	# Build kernel command line with Plymouth support
	local cmdline="root=UUID=$root_uuid rw quiet splash loglevel=3 systemd.show_status=auto rd.udev.log_level=3 plymouth.ignore-serial-consoles"
	
	# Add filesystem-specific options
	local root_fstype=$(findmnt -n -o FSTYPE / 2>/dev/null || echo "")
	case "$root_fstype" in
		btrfs)
			local root_subvol=$(findmnt -n -o OPTIONS / | grep -o 'subvol=[^,]*' | cut -d= -f2 || echo "/@")
			cmdline="$cmdline rootflags=subvol=$root_subvol"
			;;
		ext4)
			cmdline="$cmdline rootflags=relatime"
			;;
	esac
	
	# Check if Arch Linux (linux-zen) is installed
	if [[ -f "/boot/vmlinuz-linux-zen" ]] && [[ -f "/boot/initramfs-linux-zen.img" ]]; then
		# Add Arch Linux (linux-zen) entry to existing or new limine.conf
		if [[ -f "$limine_config" ]]; then
			# Check if Arch Linux (linux-zen) entry already exists
			if grep -q "vmlinuz-linux-zen" "$limine_config"; then
				log_info "Arch Linux (linux-zen) entry already exists in limine.conf"
				return 0
			fi
			
			# Append Arch Linux (linux-zen) entry to existing config
			cat << EOF | sudo tee -a "$limine_config" > /dev/null

/Arch Linux (Zen Kernel)
protocol: linux
path: boot():/vmlinuz-linux-zen
cmdline: $cmdline
module_path: boot():/initramfs-linux-zen.img
EOF
		else
			# Create new limine.conf with Arch Linux (linux-zen) as default
			cat << EOF | sudo tee "$limine_config" > /dev/null
# Limine Bootloader Configuration
# Generated by archinstaller

timeout: 3
interface_resolution: 1024x768

/Arch Linux (Zen Kernel)
protocol: linux
path: boot():/vmlinuz-linux-zen
cmdline: $cmdline
module_path: boot():/initramfs-linux-zen.img

EOF
			
			# Add Arch Linux kernel entry as fallback
			if [[ -f "/boot/vmlinuz-linux" ]] && [[ -f "/boot/initramfs-linux.img" ]]; then
				cat << EOF | sudo tee -a "$limine_config" > /dev/null
/Arch Linux
protocol: linux
path: boot():/vmlinuz-linux
cmdline: $cmdline
module_path: boot():/initramfs-linux.img
EOF
			fi
		fi
		
		log_success "Added Arch Linux (linux-zen) entry to Limine bootloader with Plymouth support"
	else
		log_warning "Arch Linux (linux-zen) not found in /boot. Skipping Limine Arch Linux (linux-zen) configuration."
	fi
}

# ===== YAML Parsing Functions =====

ensure_yq() {
	if ! command -v yq &>/dev/null; then
		ui_info "yq is required for YAML parsing. Installing..."
		if ! pacman_install_single "yq" true; then
			log_error "Failed to install yq. Please install it manually: sudo pacman -S yq"
			return 1
		fi
	fi
	return 0
}

read_yaml_packages() {
	local yaml_file="$1"
	local yaml_path="$2"
	local -n packages_array="$3"

	packages_array=()
	# Descriptions are not used in this script, but are part of the YAML structure
	local descriptions_array=()

	local yq_output
	yq_output=$(yq -r "$yaml_path[] | [.name, .description] | @tsv" "$yaml_file" 2>/dev/null)

	if [[ $? -eq 0 && -n "$yq_output" ]]; then
		while IFS=$'\t' read -r name description; do
			[[ -z "$name" ]] && continue
			packages_array+=("$name")
			descriptions_array+=("$description")
		done <<<"$yq_output"
	fi
}

# ===== Load All Package Lists from YAML =====
load_package_lists() {
	if [[ ! -f "$GAMING_YAML" ]]; then
		log_error "Gaming mode configuration file not found: $GAMING_YAML"
		return 1
	fi

	if ! ensure_yq; then
		return 1
	fi

	read_yaml_packages "$GAMING_YAML" ".pacman.packages" pacman_gaming_programs
	read_yaml_packages "$GAMING_YAML" ".flatpak.apps" flatpak_gaming_programs
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

	# Install Zen Kernel for optimal gaming performance
	install_zen_kernel

	install_pacman_packages
	install_flatpak_packages
	configure_mangohud
	encase "$kernel_type" in
    "Arch Linux (linux-zen)")
      # Gaming/desktop optimizations already in place
      log_info "Arch Linux (linux-zen) already optimized for low latency"
      ;;
    linux-hardened)
      # Security-focused - minimal changes
      ;;
    *)
      # Standard kernel - apply gaming optimizations
      ;;
	esac
	
	ui_success "Gaming Mode installation complete!"
	ui_info "Your system is now optimized for gaming with Arch Linux (linux-zen) (if installed), GameMode, and gaming tools."
}

main
