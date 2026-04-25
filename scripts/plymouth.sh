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
  
  # Check if this is a UKI system
  if is_uki_system; then
    # UKI system: configure /etc/kernel/cmdline and rebuild UKI
    step "Configuring kernel parameters for UKI system"
    
    local cmdline_file="/etc/kernel/cmdline"
    local uki_params="quiet loglevel=0 rd.udev.log_level=0 rd.systemd.show_status=false systemd.show_status=false"
    
    # Read existing cmdline if it exists
    local existing_cmdline=""
    if [[ -f "$cmdline_file" ]]; then
      existing_cmdline=$(cat "$cmdline_file" 2>/dev/null || echo "")
    fi
    
    # Check if all required parameters are already present
    local needs_update=false
    for param in $uki_params; do
      if [[ "$existing_cmdline" != *"$param"* ]]; then
        needs_update=true
        break
      fi
    done
    
    if [[ "$needs_update" = true ]]; then
      # Backup existing cmdline file
      if [[ -f "$cmdline_file" ]]; then
        sudo cp "$cmdline_file" "${cmdline_file}.backup.$(date +%Y%m%d_%H%M%S)"
        log_info "Backed up existing $cmdline_file"
      fi
      
      # Preserve existing system parameters and append quiet parameters at the end
      # This maintains the correct order: root, zswap, rootflags, rw, rootfstype, then quiet parameters
      local new_cmdline="$existing_cmdline"
      
      # Remove any existing quiet/loglevel parameters to avoid duplicates
      new_cmdline=$(echo "$new_cmdline" | sed 's/quiet//g; s/loglevel=[^ ]*//g; s/rd\.udev\.log_level=[^ ]*//g; s/rd\.systemd\.show_status=[^ ]*//g; s/systemd\.show_status=[^ ]*//g')
      
      # Clean up extra spaces
      new_cmdline=$(echo "$new_cmdline" | sed 's/  */ /g; s/^ *//; s/ *$//')
      
      # Append the UKI quiet parameters at the end
      new_cmdline="$new_cmdline $uki_params"
      # Clean up spaces again
      new_cmdline=$(echo "$new_cmdline" | sed 's/^ *//;s/ *$//')
      
      # Write the new cmdline
      echo "$new_cmdline" | sudo tee "$cmdline_file" >/dev/null
      log_success "Updated $cmdline_file with UKI parameters"
      log_info "Parameters: $new_cmdline"
      
      # Rebuild UKI to bake in the new parameters
      step "Rebuilding UKI with new kernel parameters"
      if sudo mkinitcpio -P >/dev/null 2>&1; then
        log_success "UKI rebuilt successfully with new kernel parameters"
        log_info "Kernel parameters are now baked into the UKI image"
      else
        log_error "Failed to rebuild UKI with mkinitcpio -P"
        return 1
      fi
    else
      log_info "All UKI kernel parameters already present in $cmdline_file"
    fi
    
    return 0
  fi
  
  # Traditional system: configure bootloader entries
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
        echo -e "\n${GREEN}Kernel parameters updated consistently for all entries (${updated_count} modified)${RESET}\n"
      else
        echo -e "\n${GREEN}All kernel entries already have consistent options with splash${RESET}\n"
      fi
      ;;
    "grub")
      # GRUB logic for traditional systems with Plymouth
      local grub_params="splash quiet loglevel=3 systemd.show_status=auto rd.udev.log_level=3"
      local grub_cmdline_current=""
      local needs_update=false
      
      # Get current GRUB_CMDLINE_LINUX_DEFAULT
      if [[ -f /etc/default/grub ]]; then
        grub_cmdline_current=$(grep "^GRUB_CMDLINE_LINUX_DEFAULT=" /etc/default/grub | sed 's/^GRUB_CMDLINE_LINUX_DEFAULT="//' | sed 's/"$//' || echo "")
      fi
      
      # Check if all Plymouth parameters are present
      for param in $grub_params; do
        if [[ "$grub_cmdline_current" != *"$param"* ]]; then
          needs_update=true
          break
        fi
      done
      
      if [[ "$needs_update" = true ]]; then
        # Backup existing GRUB config
        sudo cp /etc/default/grub "/etc/default/grub.backup.$(date +%Y%m%d_%H%M%S)"
        log_info "Backed up existing GRUB configuration"
        
        # Merge parameters with existing ones
        local new_cmdline="$grub_cmdline_current $grub_params"
        # Remove duplicates and clean up spaces
        new_cmdline=$(echo "$new_cmdline" | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/^ *//;s/ *$//')
        
        # Update GRUB configuration
        if grep -q "^GRUB_CMDLINE_LINUX_DEFAULT=" /etc/default/grub; then
          sudo sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$new_cmdline\"|" /etc/default/grub
        else
          echo "GRUB_CMDLINE_LINUX_DEFAULT=\"$new_cmdline\"" | sudo tee -a /etc/default/grub >/dev/null
        fi
        
        log_success "Updated GRUB_CMDLINE_LINUX_DEFAULT with Plymouth parameters"
        log_info "Parameters: $new_cmdline"
        
        # Regenerate GRUB configuration
        if sudo grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1; then
          log_success "Regenerated grub.cfg with Plymouth parameters"
        else
          log_error "Failed to regenerate grub.cfg"
          return 1
        fi
      else
        log_info "All Plymouth parameters already present in GRUB configuration"
      fi
      ;;
    "limine")
      # Limine logic for traditional systems with Plymouth
      local limine_config=""
      limine_config=$(find_limine_config)
      
      if [ -z "$limine_config" ]; then
        log_warning "limine.conf not found in any location. Skipping kernel parameter addition for Limine."
        return
      fi
      
      log_info "Adding Plymouth parameters to Limine bootloader..."
      
      # Validate format compatibility
      if ! grep -q "^[[:space:]]*cmdline:" "$limine_config"; then
        log_warning "limine.conf not in modern format - cannot add Plymouth support"
        return
      fi
      
      local limine_params="splash quiet loglevel=3 systemd.show_status=auto rd.udev.log_level=3 nowatchdog"
      local modified_count=0
      
      # Get current cmdline from limine.conf
      local current_cmdline=$(grep "^[[:space:]]*cmdline:" "$limine_config" | sed 's/^[[:space:]]*cmdline:[[:space:]]*//' || echo "")
      
      # Check if all Plymouth parameters are present
      local needs_update=false
      for param in $limine_params; do
        if [[ "$current_cmdline" != *"$param"* ]]; then
          needs_update=true
          break
        fi
      done
      
      if [[ "$needs_update" = true ]]; then
        # Backup existing limine config
        sudo cp "$limine_config" "${limine_config}.backup.$(date +%Y%m%d_%H%M%S)"
        log_info "Backed up existing limine.conf"
        
        # Merge parameters with existing ones
        local new_cmdline="$current_cmdline $limine_params"
        # Remove duplicates and clean up spaces
        new_cmdline=$(echo "$new_cmdline" | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/^ *//;s/ *$//')
        
        # Update limine configuration
        sudo sed -i "s|^[[:space:]]*cmdline:.*|cmdline: $new_cmdline|" "$limine_config"
        
        log_success "Updated Limine cmdline with Plymouth parameters"
        log_info "Parameters: $new_cmdline"
        ((modified_count++))
      else
        log_info "All Plymouth parameters already present in Limine configuration"
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
  # For UKI systems, Plymouth is not used - check UKI configuration instead
  if is_uki_system; then
    local uki_configured=false
    
    # Check if /etc/kernel/cmdline has proper parameters
    if [[ -f /etc/kernel/cmdline ]]; then
      local cmdline_content=$(cat /etc/kernel/cmdline 2>/dev/null || echo "")
      local required_params="quiet loglevel=0 rd.udev.log_level=0 rd.systemd.show_status=false systemd.show_status=false"
      local all_params_present=true
      
      for param in $required_params; do
        if [[ "$cmdline_content" != *"$param"* ]]; then
          all_params_present=false
          break
        fi
      done
      
      if [[ "$all_params_present" = true ]]; then
        uki_configured=true
      fi
    fi
    
    # For UKI systems, return true if UKI is properly configured
    if [[ "$uki_configured" = true ]]; then
      return 0
    else
      return 1
    fi
  fi
  
  # Traditional system: check Plymouth configuration
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
  
  # For UKI systems, kernel parameters are handled via /etc/kernel/cmdline, not loader.conf
  # Only configure basic bootloader settings that don't affect kernel parameters
  
  # Configure systemd-boot loader.conf for clean UKI boot (no kernel parameters here)
  local loader_conf="/boot/loader/loader.conf"
  if [[ -f "$loader_conf" ]]; then
    log_info "Configuring systemd-boot for clean UKI boot experience..."
    
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
      log_success "Set bootloader timeout to 3 seconds for logo display"
    fi
    
    # Remove any kernel parameters from loader.conf (they should be in /etc/kernel/cmdline for UKI)
    if grep -q "^options" "$loader_conf"; then
      log_info "Removing kernel parameters from loader.conf (should be in /etc/kernel/cmdline for UKI)"
      sudo sed -i '/^options.*/d' "$loader_conf"
      log_success "Removed kernel parameters from loader.conf - using /etc/kernel/cmdline instead"
    fi
    
  else
    log_warning "systemd-boot loader.conf not found - creating basic configuration"
    sudo mkdir -p /boot/loader
    cat << EOF | sudo tee "$loader_conf" >/dev/null
timeout 3
console-mode max
EOF
    log_success "Created systemd-boot configuration for UKI (no kernel parameters in loader.conf)"
  fi
  
  # Check UKI files and ensure they have proper boot parameters
  local uki_dirs=("/boot/efi/EFI/Linux" "/boot/EFI/Linux")
  local uki_found=false
  
  for uki_dir in "${uki_dirs[@]}"; do
    if [[ -d "$uki_dir" ]]; then
      local uki_files=("$uki_dir"/*.efi)
      if [[ ${#uki_files[@]} -gt 0 ]]; then
        log_info "Found UKI files in $(basename "$(dirname "$uki_dir")"): $(basename "${uki_files[0]}")"
        log_success "UKI boot logo configuration completed"
        log_info "The UKI embedded boot logo will display cleanly without text overlay"
        uki_found=true
        break
      else
        log_info "No UKI files found in $uki_dir"
      fi
    else
      log_info "UKI directory $uki_dir not found"
    fi
  done
  
  if [[ "$uki_found" = false ]]; then
    log_warning "No UKI files found in any standard location"
    log_info "Checked: /boot/efi/EFI/Linux and /boot/EFI/Linux"
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
