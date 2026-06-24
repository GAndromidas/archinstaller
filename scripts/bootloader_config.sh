#!/bin/bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# ===== SHARED PLYMOUTH KERNEL PARAMETERS =====
# Defined once here — used by all bootloader-specific functions below
PLYMOUTH_PARAMS="quiet loglevel=0 rd.udev.log_level=0 rd.systemd.show_status=false systemd.show_status=false splash plymouth.ignore-serial-consoles vt.global_cursor_default=0"
LIMINE_PARAMS="$PLYMOUTH_PARAMS nowatchdog"

# --- Bootloader and Btrfs detection ---
BOOTLOADER=$(detect_bootloader)
IS_BTRFS=$(is_btrfs_system && echo "true" || echo "false")

# ============================================================================
# PART 1: PLYMOUTH CONFIGURATION
# ============================================================================

set_plymouth_theme() {
  local theme="spinner"

  # Fix known double-slash bug in bgrt theme if installed
  local bgrt_config="/usr/share/plymouth/themes/bgrt/bgrt.plymouth"
  if [ -f "$bgrt_config" ]; then
    if grep -q "ImageDir=/usr/share/plymouth/themes//spinner" "$bgrt_config"; then
      sudo sed -i 's|ImageDir=/usr/share/plymouth/themes//spinner|ImageDir=/usr/share/plymouth/themes/spinner|g' "$bgrt_config"
      log_success "Fixed double slash in bgrt theme configuration"
    fi
  fi

  if plymouth-set-default-theme -l | grep -qw "$theme"; then
    if sudo plymouth-set-default-theme "$theme" 2>/dev/null; then
      log_success "Set plymouth theme to '$theme'."
      return 0
    else
      log_warning "Failed to set '$theme' theme. Trying fallback themes..."
    fi
  else
    log_warning "Theme '$theme' not found in available themes."
  fi

  local fallback_theme="bgrt"
  if plymouth-set-default-theme -l | grep -qw "$fallback_theme"; then
    if sudo plymouth-set-default-theme "$fallback_theme" 2>/dev/null; then
      log_success "Set plymouth theme to fallback '$fallback_theme'."
      return 0
    fi
  fi

  local first_theme
  first_theme=$(plymouth-set-default-theme -l | head -n1)
  if [ -n "$first_theme" ]; then
    if sudo plymouth-set-default-theme "$first_theme" 2>/dev/null; then
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

enable_plymouth_services() {
  local services=(
    plymouth-start.service
    plymouth-quit.service
    plymouth-quit-wait.service
  )

  for svc in "${services[@]}"; do
    if sudo systemctl enable "$svc" &>/dev/null; then
      log_success "Enabled $svc"
    else
      log_warning "Failed to enable $svc (may already be enabled or masked)"
    fi
  done
}

# For UKI systems: configure loader.conf for clean boot logo display
configure_uki_boot_logo() {
  step "Configuring UKI boot logo display"

  local loader_conf=""
  for f in "/boot/loader/loader.conf" "/efi/loader/loader.conf" "/boot/efi/loader/loader.conf"; do
    if [ -f "$f" ]; then
      loader_conf="$f"
      break
    fi
  done

  if [[ -f "$loader_conf" ]]; then
    if ! grep -q "console-mode" "$loader_conf"; then
      echo "console-mode max" | sudo tee -a "$loader_conf" >/dev/null
      log_success "Set console-mode to max for better display"
    fi

    if grep -q "timeout" "$loader_conf"; then
      sudo sed -i 's/^timeout.*/timeout 3/' "$loader_conf"
    else
      echo "timeout 3" | sudo tee -a "$loader_conf" >/dev/null
      log_success "Set bootloader timeout to 3 seconds for logo display"
    fi

    if grep -q "^options" "$loader_conf"; then
      log_info "Removing kernel parameters from loader.conf (should be in /etc/kernel/cmdline for UKI)"
      sudo sed -i '/^options.*/d' "$loader_conf"
      log_success "Removed kernel parameters from loader.conf"
    fi
  else
    log_warning "systemd-boot loader.conf not found — creating basic configuration"
    local loader_dir
    local entries_dir
    entries_dir=$(find_systemd_boot_entries_dir)
    if [ -n "$entries_dir" ]; then
      loader_dir="$(dirname "$entries_dir")"
    else
      loader_dir="/boot/loader"
    fi
    loader_conf="$loader_dir/loader.conf"
    sudo mkdir -p "$loader_dir"
    cat << EOF | sudo tee "$loader_conf" >/dev/null
timeout 3
console-mode max
EOF
    log_success "Created loader.conf for UKI"
  fi
}

# Write Plymouth kernel params to /etc/kernel/cmdline (for UKI systems).
# Must be called BEFORE the single mkinitcpio rebuild so params are baked in.
write_uki_cmdline_params() {
  local cmdline_file="/etc/kernel/cmdline"

  local existing_cmdline=""
  if [[ -f "$cmdline_file" ]]; then
    existing_cmdline=$(cat "$cmdline_file" 2>/dev/null || echo "")
  fi

  local needs_update=false
  for param in $PLYMOUTH_PARAMS; do
    if [[ "$existing_cmdline" != *"$param"* ]]; then
      needs_update=true
      break
    fi
  done

  if [[ "$needs_update" = true ]]; then
    if [[ -f "$cmdline_file" ]]; then
      sudo cp "$cmdline_file" "${cmdline_file}.backup.$(date +%Y%m%d_%H%M%S)"
      log_info "Backed up existing $cmdline_file"
    fi

    local new_cmdline="$existing_cmdline"
    new_cmdline=$(echo "$new_cmdline" | sed 's/quiet//g; s/loglevel=[^ ]*//g; s/rd\.udev\.log_level=[^ ]*//g; s/rd\.systemd\.show_status=[^ ]*//g; s/systemd\.show_status=[^ ]*//g')
    new_cmdline=$(echo "$new_cmdline" | sed 's/  */ /g; s/^ *//; s/ *$//')
    new_cmdline="$new_cmdline $PLYMOUTH_PARAMS"
    new_cmdline=$(echo "$new_cmdline" | sed 's/^ *//;s/ *$//')

    echo "$new_cmdline" | sudo tee "$cmdline_file" >/dev/null
    log_success "Updated $cmdline_file with Plymouth parameters"
    log_info "Parameters: $new_cmdline"
  else
    log_info "All UKI kernel parameters already present in $cmdline_file"
  fi
}

# Check if Plymouth is fully configured (idempotency check)
is_plymouth_configured() {
  if is_uki_system; then
    if [[ -f /etc/kernel/cmdline ]]; then
      local cmdline_content=$(cat /etc/kernel/cmdline 2>/dev/null || echo "")
      for param in $PLYMOUTH_PARAMS; do
        if [[ "$cmdline_content" != *"$param"* ]]; then
          return 1
        fi
      done
      return 0
    fi
    return 1
  fi

  # Traditional system checks
  local plymouth_hook_present=false
  if grep -q "plymouth" /etc/mkinitcpio.conf 2>/dev/null && ! grep -q "sd-plymouth" /etc/mkinitcpio.conf 2>/dev/null; then
    plymouth_hook_present=true
  fi

  local plymouth_theme_set=false
  if plymouth-set-default-theme 2>/dev/null | grep -qv "^$"; then
    plymouth_theme_set=true
  fi

  local splash_parameter_set=false
  case "$BOOTLOADER" in
    "systemd-boot")
      local entries_dir
      entries_dir=$(find_systemd_boot_entries_dir)
      if [[ -n "$entries_dir" ]]; then
        local all_ok=true
        for entry in "$entries_dir"/*.conf; do
          [ -f "$entry" ] || continue
          if ! grep -q "splash" "$entry" 2>/dev/null || \
             ! grep -q "loglevel=0" "$entry" 2>/dev/null || \
             ! grep -q "systemd.show_status=false" "$entry" 2>/dev/null; then
            all_ok=false; break
          fi
        done
        if [ "$all_ok" = true ]; then splash_parameter_set=true; fi
      fi
      ;;
    "grub")
      if grep -q "splash" /etc/default/grub 2>/dev/null && \
         grep -q "loglevel=0" /etc/default/grub 2>/dev/null && \
         grep -q "systemd.show_status=false" /etc/default/grub 2>/dev/null; then
        splash_parameter_set=true
      fi
      ;;
    "limine")
      local limine_config
      limine_config=$(find_limine_config)
      if [ -n "$limine_config" ] && \
         grep -q "splash" "$limine_config" 2>/dev/null && \
         grep -q "loglevel=0" "$limine_config" 2>/dev/null && \
         grep -q "systemd.show_status=false" "$limine_config" 2>/dev/null; then
        splash_parameter_set=true
      fi
      ;;
  esac

  [ "$plymouth_hook_present" = true ] && [ "$plymouth_theme_set" = true ] && [ "$splash_parameter_set" = true ]
}

# Install console font (no rebuild — merged into the single mkinitcpio call below)
install_console_font() {
  run_step "Installing console font" sudo pacman -S --noconfirm --needed terminus-font
  run_step "Configuring /etc/vconsole.conf" bash -c "(grep -q '^FONT=' /etc/vconsole.conf 2>/dev/null && sudo sed -i 's/^FONT=.*/FONT=ter-v16n/' /etc/vconsole.conf) || echo 'FONT=ter-v16n' | sudo tee -a /etc/vconsole.conf >/dev/null"
}

# Single orchestrator for all Plymouth + boot + font config
configure_plymouth() {
  # Skip Plymouth on headless/server systems
  if [[ "${INSTALL_MODE:-}" == "server" ]]; then
    log_info "Server mode — skipping Plymouth boot screen configuration"
    return 0
  fi

  # Idempotency: if already fully configured, skip
  if is_plymouth_configured; then
    log_success "Plymouth is already configured — skipping"
    return 0
  fi

  step "Installing Plymouth"
  install_packages_quietly plymouth

  # Add hook to mkinitcpio.conf (no rebuild yet)
  run_step "Configuring Plymouth hook" configure_plymouth_hook_and_initramfs "no-rebuild"

  # Set theme (no rebuild yet)
  run_step "Setting Plymouth theme" set_plymouth_theme

  # Install console font before the single rebuild so it's included
  install_console_font

  # Enable Plymouth services
  run_step "Enabling Plymouth systemd services" enable_plymouth_services

  # Write kernel params to /etc/kernel/cmdline (UKI systems only)
  if is_uki_system; then
    run_step "Writing kernel parameters for UKI" write_uki_cmdline_params
  fi

  # Configure UKI boot logo (only if UKI system is confirmed)
  if is_uki_system; then
    run_step "Configuring UKI boot logo" configure_uki_boot_logo
  fi

  # Single rebuild — includes hook + theme + font + for UKI: kernel params
  step "Rebuilding initramfs with Plymouth hook, theme, and console font"
  if ! sudo mkinitcpio -P >/dev/null 2>&1; then
    log_error "Failed to rebuild initramfs" "Run 'sudo mkinitcpio -P' manually to see errors"
    return 1
  fi
  log_success "Initramfs rebuilt successfully"
}

# ============================================================================
# PART 2: BOOTLOADER-SPECIFIC KERNEL PARAMETERS
# ============================================================================

# --- systemd-boot kernel parameters (traditional only) ---
add_systemd_boot_kernel_params() {
  if is_uki_system; then
    log_info "UKI system — kernel parameters baked into UKI image, skipping boot entries"
    return 0
  fi

  if [[ "${INSTALL_MODE:-}" == "server" ]]; then
    log_info "Server mode — skipping Plymouth kernel parameters for systemd-boot"
    return 0
  fi

  local boot_entries_dir
  boot_entries_dir=$(find_systemd_boot_entries_dir)
  if [ -z "$boot_entries_dir" ]; then
    log_warning "Boot entries directory not found. Skipping kernel parameter addition for systemd-boot."
    return 0
  fi

  local modified_count=0
  local entries_found=0

  while IFS= read -r -d $'\0' entry; do
    ((entries_found++))
    local entry_name=$(basename "$entry")

    local needs_update=false
    if ! grep -q "splash" "$entry" || ! grep -q "quiet" "$entry" || ! grep -q "loglevel=0" "$entry" || ! grep -q "systemd.show_status=false" "$entry" || ! grep -q "rd.udev.log_level=0" "$entry"; then
      needs_update=true
    fi

    if [ "$needs_update" = true ]; then
      sudo sed -i 's/quiet//g; s/loglevel=[^ ]*//g; s/systemd\.show_status=[^ ]*//g; s/rd\.udev\.log_level=[^ ]*//g; s/rd\.systemd\.show_status=[^ ]*//g' "$entry"
      sudo sed -i 's/  */ /g; s/^ *//; s/ *$//' "$entry"

      if sudo sed -i "/^options / s|\$| $PLYMOUTH_PARAMS|" "$entry"; then
        log_success "Updated kernel parameters in $entry_name"
        ((modified_count++))
      else
        log_error "Failed to add kernel parameters to $entry_name"
      fi
    else
      log_info "All kernel parameters already present in $entry_name — skipping."
    fi
  done < <(find "$boot_entries_dir" -name "*.conf" ! -name "*fallback.conf" -print0)

  if [ "$entries_found" -eq 0 ]; then
    log_warning "No systemd-boot entries found to modify."
  elif [ "$modified_count" -gt 0 ]; then
    log_success "Kernel parameters updated for $modified_count systemd-boot entries."
  else
    log_info "No systemd-boot entries needed parameter updates."
  fi
  return 0
}

# --- systemd-boot ---
configure_boot() {
  local entries_dir
  entries_dir=$(find_systemd_boot_entries_dir)
  local loader_conf=""
  if [ -n "$entries_dir" ]; then
    loader_conf="$(dirname "$entries_dir")/loader.conf"
  fi

  run_step "Renaming dated kernel entries to simple format" rename_dated_kernel_entries
  run_step "Adding kernel parameters to systemd-boot entries" add_systemd_boot_kernel_params

  if [ -n "$loader_conf" ] && [ -f "$loader_conf" ]; then
    set_loader_config "timeout" "3"
    set_loader_config "console-mode" "max"
    ui_info "Set timeout to 3s and console-mode to max (optimal settings)"
  else
    log_warning "loader.conf not found. Skipping loader.conf configuration for systemd-boot."
  fi

  run_step "Checking kernel options consistency" check_kernel_options_consistency
}

# Check kernel options consistency and only sync if necessary
check_kernel_options_consistency() {
  local entries_dir
  entries_dir=$(find_systemd_boot_entries_dir)
  if [ -z "$entries_dir" ]; then
    log_warning "No boot entries directory found, skipping consistency check."
    return 0
  fi

  ui_info "Checking kernel options consistency..."

  local kernel_entries=()
  while IFS= read -r -d $'\0' entry; do
    kernel_entries+=("$entry")
  done < <(find "$entries_dir" -name "*.conf" ! -name "*fallback*" -print0)

  if [[ ${#kernel_entries[@]} -eq 0 ]]; then
    log_warning "No kernel entries found to check"
    return 0
  fi

  if [[ ${#kernel_entries[@]} -eq 1 ]]; then
    log_info "Only one kernel entry found — consistency check not needed"
    return 0
  fi

  local options_list=()
  local entry_names=()

  for entry in "${kernel_entries[@]}"; do
    local entry_name=$(basename "$entry")
    local current_options=$(grep "^options " "$entry" | sed 's/^options //' || echo "")
    options_list+=("$current_options")
    entry_names+=("$entry_name")
  done

  local first_options="${options_list[0]}"
  local consistent=true

  for i in "${!options_list[@]}"; do
    if [[ "${options_list[$i]}" != "$first_options" ]]; then
      consistent=false
      break
    fi
  done

  if [[ "$consistent" == true ]]; then
    log_success "All kernel entries already have consistent options"
    log_info "Common options: $first_options"
    if [[ "$first_options" == *"splash"* ]]; then
      log_info "Plymouth splash parameter detected and consistent across entries"
    fi
  else
    log_warning "Inconsistent kernel options detected across entries"
    log_info "Options vary between entries — this may cause boot issues"
    for i in "${!entry_names[@]}"; do
      log_info "${entry_names[$i]}: ${options_list[$i]}"
    done

    if command -v gum >/dev/null 2>&1; then
      echo ""
      gum style --foreground "$GUM_WARN" "Kernel options are inconsistent across entries"
      gum style --foreground "$GUM_TEXT" "This may cause boot issues or Plymouth display problems"
      echo ""
      if gum confirm "Sync all kernel entries to use the same options?"; then
        sync_all_kernel_options
      else
        log_warning "Kernel options left inconsistent — manual review recommended"
      fi
    else
      log_warning "Inconsistent kernel options detected — auto-syncing for system stability"
      sync_all_kernel_options
    fi
  fi
}

# Sync kernel options across all kernel entries
sync_all_kernel_options() {
  local entries_dir
  entries_dir=$(find_systemd_boot_entries_dir)
  if [ -z "$entries_dir" ]; then
    log_warning "No boot entries directory found, skipping sync."
    return 0
  fi

  ui_info "Syncing kernel options across all entries..."

  local kernel_entries=()
  while IFS= read -r -d $'\0' entry; do
    kernel_entries+=("$entry")
  done < <(find "$entries_dir" -name "*.conf" ! -name "*fallback*" -print0)

  if [[ ${#kernel_entries[@]} -eq 0 ]]; then
    log_warning "No kernel entries found to sync"
    return 0
  fi

  local standard_entry="${kernel_entries[0]}"
  local standard_options=$(grep "^options " "$standard_entry" | sed 's/^options //' || echo "")

  if [[ -z "$standard_options" ]]; then
    log_warning "No options found in standard entry: $(basename "$standard_entry")"
    return 1
  fi

  ui_info "Using options from $(basename "$standard_entry") as standard"
  log_info "Standard options: $standard_options"

  local updated_count=0

  for entry in "${kernel_entries[@]}"; do
    local entry_name=$(basename "$entry")

    if [[ "$entry" == "$standard_entry" ]]; then
      continue
    fi

    local current_options=$(grep "^options " "$entry" | sed 's/^options //' || echo "")

    if [[ "$current_options" != "$standard_options" ]]; then
      local temp_file=$(mktemp)
      grep -v "^options " "$entry" > "$temp_file"
      echo "options $standard_options" >> "$temp_file"
      sudo mv "$temp_file" "$entry"
      log_success "Synced options in $entry_name"
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

# Rename dated kernel entries to simple format (archinstall compatibility)
rename_dated_kernel_entries() {
  local entries_dir
  entries_dir=$(find_systemd_boot_entries_dir)

  if [ -z "$entries_dir" ]; then
    log_warning "Boot entries directory not found. Skipping entry renaming."
    return 0
  fi

  ui_info "Checking for dated kernel entries to rename to simple format..."

  local renamed_count=0

  local dated_entries=()
  while IFS= read -r -d '' entry; do
    dated_entries+=("$entry")
  done < <(find "$entries_dir" -name "*[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_*.conf" ! -name "*fallback*" -print0 2>/dev/null)

  if [[ ${#dated_entries[@]} -eq 0 ]]; then
    log_info "No dated kernel entries found — entries already in simple format"
    return 0
  fi

  check_renaming_conflicts "${dated_entries[@]}"

  for dated_entry in "${dated_entries[@]}"; do
    local entry_name=$(basename "$dated_entry")

    if [[ "$entry_name" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_(.*)\.conf$ ]]; then
      local kernel_type="${BASH_REMATCH[1]}"
      local simple_name="${kernel_type}.conf"
      local simple_path="$entries_dir/$simple_name"

      if [[ -f "$simple_path" ]]; then
        log_warning "Simple entry $simple_name already exists, skipping rename of $entry_name"
        continue
      fi

      if ! validate_kernel_entry "$dated_entry"; then
        log_warning "Invalid kernel entry $entry_name, skipping rename"
        continue
      fi

      if sudo mv "$dated_entry" "$simple_path"; then
        log_success "Renamed $entry_name to $simple_name"
        ((renamed_count++))
        update_loader_conf_references "$entry_name" "$simple_name"
      else
        log_error "Failed to rename $entry_name to $simple_name"
      fi
    else
      log_warning "Entry $entry_name doesn't match expected date pattern, skipping"
    fi
  done

  if [[ $renamed_count -gt 0 ]]; then
    log_success "Renamed $renamed_count dated kernel entries to simple format"
    ui_info "All kernel entries now use simple naming (linux.conf, linux-lts.conf, etc.)"
  else
    log_info "No entries needed renaming"
  fi
}

check_renaming_conflicts() {
  local entries_dir
  entries_dir=$(find_systemd_boot_entries_dir)
  [ -z "$entries_dir" ] && return 0
  local conflicts_found=false

  for dated_entry in "$@"; do
    local entry_name=$(basename "$dated_entry")

    if [[ "$entry_name" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_(.*)\.conf$ ]]; then
      local kernel_type="${BASH_REMATCH[1]}"
      local simple_name="${kernel_type}.conf"
      local simple_path="$entries_dir/$simple_name"

      if [[ -f "$simple_path" ]]; then
        log_warning "Conflict: Both $entry_name and $simple_name exist"
        conflicts_found=true
      fi
    fi
  done

  if [[ "$conflicts_found" == true ]]; then
    log_warning "Renaming conflicts detected — some entries may not be renamed"
  fi
}

validate_kernel_entry() {
  local entry="$1"

  if ! grep -q "^title " "$entry"; then
    log_warning "Entry $(basename "$entry") missing title field"
    return 1
  fi

  if ! grep -q "^linux " "$entry"; then
    log_warning "Entry $(basename "$entry") missing linux field"
    return 1
  fi

  if ! grep -q "^initrd " "$entry"; then
    log_warning "Entry $(basename "$entry") missing initrd field"
    return 1
  fi

  if ! grep -q "^options " "$entry"; then
    log_warning "Entry $(basename "$entry") missing options field"
    return 1
  fi

  return 0
}

update_loader_conf_references() {
  local old_name="$1"
  local new_name="$2"
  local loader_config=""
  for f in "/boot/loader/loader.conf" "/efi/loader/loader.conf" "/boot/efi/loader/loader.conf"; do
    if [ -f "$f" ]; then
      loader_config="$f"
      break
    fi
  done

  if [[ -z "$loader_config" ]]; then
    return 0
  fi

  if grep -q "^default $old_name$" "$loader_config"; then
    sudo sed -i "s|^default $old_name$|default $new_name|" "$loader_config"
    log_success "Updated loader.conf reference: $old_name -> $new_name"
  fi
}

# --- GRUB configuration ---
configure_grub() {
    step "Configuring GRUB"

    if is_uki_system; then
      log_info "UKI system — kernel parameters baked into UKI image"
      ui_info "UKI system detected — kernel parameters configured via /etc/kernel/cmdline"
      return 0
    fi

    # Traditional system: configure GRUB
    set_grub_config "GRUB_TIMEOUT" "3"
    ui_info "Set GRUB timeout to 3 seconds (optimal setting)"

    step "Configuring GRUB: set saved entry as default"
    set_grub_config "GRUB_DEFAULT" "saved"
    ui_info "Set saved entry as default boot entry"

    set_grub_config "GRUB_SAVEDEFAULT" "true"

    if [[ "${INSTALL_MODE:-}" != "server" ]]; then
      local grub_cmdline_current=""
      if [[ -f /etc/default/grub ]]; then
        grub_cmdline_current=$(grep "^GRUB_CMDLINE_LINUX_DEFAULT=" /etc/default/grub | sed 's/^GRUB_CMDLINE_LINUX_DEFAULT="//' | sed 's/"$//' || echo "")
      fi
      local merged_cmdline="$grub_cmdline_current $PLYMOUTH_PARAMS"
      merged_cmdline=$(echo "$merged_cmdline" | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/^ *//;s/ *$//')
      set_grub_config "GRUB_CMDLINE_LINUX_DEFAULT" "\"$merged_cmdline\""
      ui_info "Merged Plymouth-compatible kernel parameters"
    fi

    set_grub_config "GRUB_DISABLE_SUBMENU" "notlinux"
    set_grub_config "GRUB_GFXMODE" "auto"
    set_grub_config "GRUB_GFXPAYLOAD_LINUX" "keep"

    KERNELS=($(ls /boot/vmlinuz-* 2>/dev/null | sed 's|/boot/vmlinuz-||g'))
    if [[ ${#KERNELS[@]} -eq 0 ]]; then
        log_error "No kernels found in /boot."
        return 1
    fi

    MAIN_KERNEL=""
    SECONDARY_KERNELS=()
    for k in "${KERNELS[@]}"; do
        [[ "$k" == "linux" ]] && MAIN_KERNEL="$k"
        [[ "$k" != "linux" && "$k" != "fallback" && "$k" != "rescue" ]] && SECONDARY_KERNELS+=("$k")
    done
    [[ -z "$MAIN_KERNEL" ]] && MAIN_KERNEL="${KERNELS[0]}"

    local grub_config="/etc/default/grub"
    local grub_cfg="/boot/grub/grub.cfg"
    local backup_grub_config="${grub_config}.backup.$(date +%Y%m%d_%H%M%S)"

    if [ -f "$grub_config" ]; then
        cp "$grub_config" "$backup_grub_config" || true
    fi

    if [ -f "$grub_config" ]; then
        ui_info "Regenerating GRUB configuration..."
        if sudo grub-mkconfig -o "$grub_cfg" >/dev/null 2>&1; then
            log_success "GRUB configuration regenerated successfully"
        else
            log_error "grub-mkconfig failed"
            if [ -f "$backup_grub_config" ]; then
                sudo mv "$backup_grub_config" "$grub_config" || true
            fi
            return 1
        fi
    else
        log_warning "GRUB config file not found, skipping regeneration"
        return 1
    fi

    if pacman -Qi linux-zen &>/dev/null; then
        log_success "GRUB configured with Arch Linux (linux-zen) as default"
    else
        log_success "GRUB configured to remember the last chosen boot entry."
    fi
}

# --- Limine Bootloader Configuration ---
configure_limine_basic() {
  step "Configuring Limine bootloader"

  if is_uki_system; then
    log_info "UKI system — kernel parameters baked into UKI image"
    ui_info "UKI system detected — kernel parameters configured via /etc/kernel/cmdline"
    return 0
  fi

  local limine_config="/boot/limine.conf"

  log_info "Creating idempotent Limine configuration at: $limine_config"

  if [ -f "$limine_config" ]; then
    log_info "Backing up existing limine.conf..."
    sudo cp "$limine_config" "${limine_config}.backup.$(date +%Y%m%d_%H%M%S)"
  fi

  local root_uuid=""
  root_uuid=$(findmnt -n -o UUID / 2>/dev/null || echo "")

  if [ -z "$root_uuid" ]; then
    log_error "Could not determine root UUID"
    return 1
  fi

  local cmdline="root=UUID=$root_uuid rw"

  if [[ "${INSTALL_MODE:-}" != "server" ]]; then
    cmdline="$cmdline $LIMINE_PARAMS"
    ui_info "Using Plymouth-compatible kernel parameters for Limine"
  fi

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

  local limine_tmp=$(mktemp)
  {
    cat << EOF
# Limine Bootloader Configuration
# Generated by archinstaller on $(date)
# Root UUID: $root_uuid
# Filesystem: $root_fstype

timeout: 3
interface_resolution: 1024x768

EOF

    local kernels_added=()

    if pacman -Qi linux-zen &>/dev/null; then
      if [[ -f "/boot/vmlinuz-linux-zen" ]] && [[ -f "/boot/initramfs-linux-zen.img" ]]; then
        cat << EOF
Arch Linux (linux-zen)
protocol: linux
path: boot():/vmlinuz-linux-zen
cmdline: $cmdline
module_path: boot():/initramfs-linux-zen.img
EOF
        kernels_added+=("zen")
        ui_info "Added Arch Linux (linux-zen) entry to Limine"
      fi
    fi

    if [[ -f "/boot/vmlinuz-linux" ]] && [[ -f "/boot/initramfs-linux.img" ]]; then
      cat << EOF

Arch Linux
protocol: linux
path: boot():/vmlinuz-linux
cmdline: $cmdline
module_path: boot():/initramfs-linux.img
EOF
      kernels_added+=("standard")
      ui_info "Added standard kernel entry to Limine"
    fi

    if [[ -f "/boot/vmlinuz-linux-lts" ]] && [[ -f "/boot/initramfs-linux-lts.img" ]]; then
      cat << EOF

Arch Linux (LTS)
protocol: linux
path: boot():/vmlinuz-linux-lts
cmdline: $cmdline
module_path: boot():/initramfs-linux-lts.img
EOF
    fi

    local windows_found=false
    for disk in /dev/sda1 /dev/sdb1 /dev/sdc1 /dev/nvme0n1p1 /dev/nvme1n1p1; do
      if [ -b "$disk" ] && sudo file -s "$disk" 2>/dev/null | grep -q "NTFS"; then
        cat << EOF

/Windows
protocol: chainloader
path: chainloader():$disk
driver: chainloader
EOF
        log_success "Added Windows entry: $disk"
        windows_found=true
        break
      fi
    done

    if [ "$windows_found" = false ]; then
      log_info "No Windows partition detected"
    fi

  } > "$limine_tmp"
  sudo mv "$limine_tmp" "$limine_config"

  if pacman -Qi linux-zen &>/dev/null; then
    log_success "Limine configured with Arch Linux (linux-zen) prioritized"
  else
    log_success "Idempotent Limine configuration completed"
  fi
  log_info "Configuration file: $limine_config"
  log_info "Kernels configured: ${kernels_added[*]}"
  log_info "Limine bootloader configured successfully"
}

# ============================================================================
# PART 3: HELPER FUNCTIONS
# ============================================================================

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

set_loader_config() {
    local key="$1"
    local value="$2"
    local loader_config=""
    for f in "/boot/loader/loader.conf" "/efi/loader/loader.conf" "/boot/efi/loader/loader.conf"; do
      if [ -f "$f" ]; then
        loader_config="$f"
        break
      fi
    done

    if [ -z "$loader_config" ]; then
        log_warning "loader.conf not found, cannot set configuration"
        return 1
    fi

    if grep -q "^[#]*${key}[[:space:]]" "$loader_config" 2>/dev/null; then
        sudo sed -i "s/^[#]*${key}[[:space:]].*/${key} ${value}/" "$loader_config"
    else
        echo "${key} ${value}" | sudo tee -a "$loader_config" >/dev/null
    fi
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

# Phase 1: Configure Plymouth (install, hook, theme, font, services, rebuild)
configure_plymouth

# Phase 2: Bootloader-specific configuration (kernel params + bootloader settings)
if [ "$BOOTLOADER" = "grub" ]; then
    configure_grub
elif [ "$BOOTLOADER" = "systemd-boot" ]; then
    configure_boot
elif [ "$BOOTLOADER" = "limine" ]; then
    configure_limine_basic
else
    log_warning "No bootloader detected or bootloader is unsupported. Defaulting to systemd-boot configuration."
    configure_boot
fi
