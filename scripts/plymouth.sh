#!/bin/bash
set -uo pipefail

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Override progress bar to be minimalist, showing only the percentage.

# Use different variable names to avoid conflicts
PLYMOUTH_ERRORS=()

# ======= Plymouth Setup Steps =======

# ======= Kernel Detection Function =======


set_plymouth_theme() {
  local theme="bgrt"

  # Fix the double slash issue in bgrt theme if it exists
  local bgrt_config="/usr/share/plymouth/themes/bgrt/bgrt.plymouth"
  if [ -f "$bgrt_config" ]; then
    # Fix the double slash in ImageDir path
    if grep -q "ImageDir=/usr/share/plymouth/themes//spinner" "$bgrt_config"; then
      sudo sed -i 's|ImageDir=/usr/share/plymouth/themes//spinner|ImageDir=/usr/share/plymouth/themes/spinner|g' "$bgrt_config"
      log_success "Fixed double slash in bgrt theme configuration"
    fi
  fi

  # Try to set the bgrt theme
  if plymouth-set-default-theme -l | grep -qw "$theme"; then
    if sudo plymouth-set-default-theme -R "$theme" 2>/dev/null; then
      log_success "Set plymouth theme to '$theme'."
      return 0
    else
      log_warning "Failed to set '$theme' theme. Trying fallback themes..."
    fi
  else
    log_warning "Theme '$theme' not found in available themes."
  fi

  # Fallback to spinner theme (which bgrt depends on anyway)
  local fallback_theme="spinner"
  if plymouth-set-default-theme -l | grep -qw "$fallback_theme"; then
    if sudo plymouth-set-default-theme -R "$fallback_theme" 2>/dev/null; then
      log_success "Set plymouth theme to fallback '$fallback_theme'."
      return 0
    fi
  fi

  # Last resort: use the first available theme
  local first_theme
  first_theme=$(plymouth-set-default-theme -l | head -n1)
  if [ -n "$first_theme" ]; then
    if sudo plymouth-set-default-theme -R "$first_theme" 2>/dev/null; then
      log_success "Set plymouth theme to first available theme: '$first_theme'."
    else
      log_error "Failed to set any plymouth theme"
      return 1
    fi
  else
    log_error "No plymouth themes available"
    return 1
  fi
}

add_kernel_parameters() {
  # Detect bootloader using the centralized function
  local BOOTLOADER=$(detect_bootloader)
  
  case "$BOOTLOADER" in
    "systemd-boot")
      # systemd-boot logic with consistent options
      local boot_entries_dir="/boot/loader/entries"
      if [ ! -d "$boot_entries_dir" ]; then
        log_warning "Boot entries directory not found. Skipping kernel parameter addition."
        return
      fi
      
      # Find all kernel entries (excluding fallback)
      local kernel_entries=()
      while IFS= read -r -d '' entry; do
        kernel_entries+=("$entry")
      done < <(find "$boot_entries_dir" -name "*.conf" ! -name "*fallback*" -print0 2>/dev/null)
      
      if [ ${#kernel_entries[@]} -eq 0 ]; then
        log_warning "No kernel entries found. Skipping kernel parameter addition."
        return
      fi
      
      echo -e "${CYAN}Found ${#kernel_entries[@]} systemd-boot kernel entries${RESET}"
      
      # Use the first entry as the standard for options
      local standard_entry="${kernel_entries[0]}"
      local standard_options=$(grep "^options " "$standard_entry" | sed 's/^options //' || echo "")
      
      if [[ -z "$standard_options" ]]; then
        log_warning "No options found in standard entry: $(basename "$standard_entry")"
        return
      fi
      
      # Add splash to standard options if not already present
      if [[ "$standard_options" != *"splash"* ]]; then
        standard_options="$standard_options splash"
        log_info "Adding 'splash' to standard options"
      else
        log_info "'splash' already present in standard options"
      fi
      
      # Update all entries to have the same options with splash
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
          
          log_success "Updated options in $entry_name with splash"
          ((updated_count++))
        else
          log_info "Options already consistent in $entry_name"
        fi
      done
      
      if [[ $updated_count -gt 0 ]]; then
        echo -e "\\n${GREEN}Kernel parameters updated consistently for all entries (${updated_count} modified)${RESET}\\n"
      else
        echo -e "\\n${GREEN}All kernel entries already have consistent options with splash${RESET}\\n"
      fi
      ;;
    "grub")
      # GRUB logic
      if grep -q 'splash' /etc/default/grub; then
        log_warning "'splash' already present in GRUB_CMDLINE_LINUX_DEFAULT."
      else
        sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="splash /' /etc/default/grub
        log_success "Added 'splash' to GRUB_CMDLINE_LINUX_DEFAULT."
        sudo grub-mkconfig -o /boot/grub/grub.cfg
        log_success "Regenerated grub.cfg after adding 'splash'."
      fi
      ;;
    "limine")
      # Limine logic
      local limine_config=""
      limine_config=$(find_limine_config)
      
      if [ -z "$limine_config" ]; then
        log_warning "limine.conf not found in any location. Skipping kernel parameter addition for Limine."
        return
      fi
      
      log_info "Adding 'splash' parameter to Limine bootloader..."
      
      # Validate format compatibility
      if ! grep -q "^[[:space:]]*cmdline:" "$limine_config"; then
        log_warning "limine.conf not in modern format - cannot add Plymouth support"
        return
      fi
      
      local modified_count=0
      
      # Add splash parameter if missing
      if grep "^[[:space:]]*cmdline:" "$limine_config" | grep -qv "splash"; then
        sudo sed -i '/^[[:space:]]*cmdline:/ { /splash/! s/$/ splash/ }' "$limine_config"
        ((modified_count++))
        log_success "Added 'splash' to Limine cmdline parameters"
      else
        log_info "Splash parameter already present in Limine configuration"
      fi
      
      # Add quiet parameter if missing for better Plymouth experience
      if grep "^[[:space:]]*cmdline:" "$limine_config" | grep -qv "quiet"; then
        sudo sed -i '/^[[:space:]]*cmdline:/ { /quiet/! s/splash/quiet splash/ }' "$limine_config"
        ((modified_count++))
        log_success "Added 'quiet' to Limine cmdline parameters"
      fi
      
      # Add nowatchdog parameter if missing for Plymouth compatibility
      if grep "^[[:space:]]*cmdline:" "$limine_config" | grep -qv "nowatchdog"; then
        sudo sed -i '/^[[:space:]]*cmdline:/ { /nowatchdog/! s/$/ nowatchdog/ }' "$limine_config"
        ((modified_count++))
        log_success "Added 'nowatchdog' to Limine cmdline parameters"
      fi
      
      if [ $modified_count -gt 0 ]; then
        log_success "Plymouth configuration added to Limine bootloader ($modified_count changes)"
      else
        log_info "Plymouth parameters already present in Limine configuration"
      fi
      ;;
  esac
}

# Function to check if Plymouth is fully configured
is_plymouth_configured() {
  local plymouth_hook_present=false
  local plymouth_theme_set=false
  local splash_parameter_set=false

  # Check if plymouth hook is in mkinitcpio.conf
  if grep -q "plymouth" /etc/mkinitcpio.conf 2>/dev/null; then
    plymouth_hook_present=true
  fi

  # Check if a plymouth theme is set
  if plymouth-set-default-theme 2>/dev/null | grep -qv "^$"; then
    plymouth_theme_set=true
  fi

  # Check if splash parameter is set in bootloader config
  local BOOTLOADER=$(detect_bootloader)
  case "$BOOTLOADER" in
    "systemd-boot")
      if [ -d /boot/loader/entries ] && grep -q "splash" /boot/loader/entries/*.conf 2>/dev/null; then
        splash_parameter_set=true
      fi
      ;;
    "grub")
      if grep -q 'splash' /etc/default/grub 2>/dev/null; then
        splash_parameter_set=true
      fi
      ;;
    "limine")
      # Check all possible limine.conf locations (prefer /boot/limine/limine.conf)
      local limine_config=""
      local found_splash=false
      
      limine_config=$(find_limine_config)
      if [ -n "$limine_config" ] && grep -q "splash" "$limine_config" 2>/dev/null; then
        found_splash=true
      fi
      if [ "$found_splash" = true ]; then
        splash_parameter_set=true
      fi
      ;;
  esac

  # Return true if all components are configured
  if [ "$plymouth_hook_present" = true ] && [ "$plymouth_theme_set" = true ] && [ "$splash_parameter_set" = true ]; then
    return 0
  else
    return 1
  fi
}

# Function to configure UKI boot logo and hide text after logo
configure_uki_boot_logo() {
  step "Configuring UKI boot logo display"
  
  # Check if systemd-boot is being used
  if [[ ! -d /boot/loader ]]; then
    log_warning "systemd-boot loader directory not found - UKI boot logo configuration skipped"
    return 1
  fi
  
  # Configure systemd-boot loader.conf for clean UKI boot
  local loader_conf="/boot/loader/loader.conf"
  if [[ -f "$loader_conf" ]]; then
    log_info "Configuring systemd-boot for clean UKI boot experience..."
    
    # Ensure quiet mode is set to hide kernel messages
    if ! grep -q "options.*quiet" "$loader_conf"; then
      # Add quiet option if not present
      if grep -q "^options" "$loader_conf"; then
        sudo sed -i 's/^options.*/& quiet/' "$loader_conf"
      else
        echo "options quiet" | sudo tee -a "$loader_conf" >/dev/null
      fi
      log_success "Added quiet option to systemd-boot configuration"
    fi
    
    # Set console mode to hide text after boot logo
    if ! grep -q "console-mode" "$loader_conf"; then
      echo "console-mode max" | sudo tee -a "$loader_conf" >/dev/null
      log_success "Set console-mode to max for better display"
    fi
    
    # Ensure timeout is reasonable for boot logo display
    if grep -q "timeout" "$loader_conf"; then
      sudo sed -i 's/^timeout.*/timeout 3/' "$loader_conf"
    else
      echo "timeout 3" | sudo tee -a "$loader_conf" >/dev/null
    fi
    log_success "Set bootloader timeout to 3 seconds for logo display"
    
  else
    log_warning "systemd-boot loader.conf not found - creating basic configuration"
    sudo mkdir -p /boot/loader
    cat << EOF | sudo tee "$loader_conf" >/dev/null
timeout 3
console-mode max
options quiet
EOF
    log_success "Created systemd-boot configuration for UKI"
  fi
  
  # Check UKI files and ensure they have proper boot parameters
  local uki_dir="/boot/efi/EFI/Linux"
  if [[ -d "$uki_dir" ]]; then
    local uki_files=("$uki_dir"/*.efi)
    if [[ ${#uki_files[@]} -gt 0 ]]; then
      log_info "Found UKI files: $(basename "${uki_files[0]}")"
      log_success "UKI boot logo configuration completed"
      log_info "The UKI embedded boot logo will display cleanly without text overlay"
    else
      log_warning "No UKI files found in $uki_dir"
    fi
  else
    log_warning "UKI directory $uki_dir not found"
  fi
}

# ======= Main =======
main() {
  # Print simple banner (no figlet)
  echo -e "${CYAN}=== Plymouth Configuration ===${RESET}"

  # Check if this is a UKI system and configure UKI boot logo
  if is_uki_system; then
    ui_info "UKI (Unified Kernel Image) system detected"
    ui_info "Configuring UKI boot logo display for clean boot experience"
    ui_info "Skipping Plymouth installation - UKI provides its own boot logo"
    configure_uki_boot_logo
    ui_info "UKI boot logo configuration completed"
    ui_info "System will display boot logo cleanly without text overlay"
    return 0
  else
    ui_info "Traditional system detected - installing Plymouth for boot splash screen"
  fi

  # Check if plymouth is already fully configured
  if is_plymouth_configured; then
    log_success "Plymouth is already configured - skipping setup to save time"
    echo -e "${GREEN}Plymouth configuration detected:${RESET}"
    echo -e "  ✓ Plymouth hook present in mkinitcpio.conf"
    echo -e "  ✓ Plymouth theme is set"
    echo -e "  ✓ Splash parameter configured in bootloader"
    echo -e "${CYAN}To reconfigure Plymouth, edit /etc/mkinitcpio.conf manually${RESET}"
    return 0
  fi

  ui_info "Traditional system detected - installing Plymouth for boot splash screen"
  
  # Install Plymouth packages first
  step "Installing Plymouth packages"
  install_packages_quietly plymouth
  
  # Use the centralized function from common.sh
  run_step "Configuring Plymouth hook and rebuilding initramfs" configure_plymouth_hook_and_initramfs
  run_step "Setting Plymouth theme" set_plymouth_theme
  run_step "Adding 'splash' to all kernel parameters" add_kernel_parameters
}

main "$@"
