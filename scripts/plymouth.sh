#!/bin/bash
set -uo pipefail

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Use different variable names to avoid conflicts
PLYMOUTH_ERRORS=()

# ======= Plymouth Setup Steps =======
enable_plymouth_hook() {
  local mkinitcpio_conf="/etc/mkinitcpio.conf"
  if ! grep -q "plymouth" "$mkinitcpio_conf"; then
    sudo sed -i 's/^HOOKS=\(.*\)keyboard \(.*\)/HOOKS=\1plymouth keyboard \2/' "$mkinitcpio_conf"
    log_success "Added plymouth hook to mkinitcpio.conf."
  else
    log_warning "Plymouth hook already present in mkinitcpio.conf."
  fi
}

# ======= Kernel Detection Function =======
get_installed_kernel_types() {
  local kernel_types=()
  pacman -Q linux &>/dev/null && kernel_types+=("linux")
  pacman -Q linux-lts &>/dev/null && kernel_types+=("linux-lts")
  pacman -Q linux-zen &>/dev/null && kernel_types+=("linux-zen")
  pacman -Q linux-hardened &>/dev/null && kernel_types+=("linux-hardened")
  echo "${kernel_types[@]}"
}

rebuild_initramfs() {
  local kernel_types
  kernel_types=($(get_installed_kernel_types))
  
  if [ "${#kernel_types[@]}" -eq 0 ]; then
    log_warning "No supported kernel types detected. Rebuilding only for 'linux'."
    sudo mkinitcpio -p linux
    return
  fi
  
  echo -e "${CYAN}Detected kernels: ${kernel_types[*]}${RESET}"
  
  local total=${#kernel_types[@]}
  local current=0
  
  for kernel in "${kernel_types[@]}"; do
    ((current++))
    print_progress "$current" "$total" "Rebuilding initramfs for $kernel"
    
    if sudo mkinitcpio -p "$kernel" >/dev/null 2>&1; then
      print_status " [OK]" "$GREEN"
      log_success "Rebuilt initramfs for $kernel"
    else
      print_status " [FAIL]" "$RED"
      log_error "Failed to rebuild initramfs for $kernel"
    fi
  done
  
  echo -e "\n${GREEN}✓ Initramfs rebuild completed for all kernels${RESET}\n"
}

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
  # Detect bootloader
  if [ -d /boot/loader ] || [ -d /boot/EFI/systemd ]; then
    # systemd-boot logic (existing)
    local boot_entries_dir="/boot/loader/entries"
    if [ ! -d "$boot_entries_dir" ]; then
      log_warning "Boot entries directory not found. Skipping kernel parameter addition."
      return
    fi
    local boot_entries=()
    while IFS= read -r -d '' entry; do
      boot_entries+=("$entry")
    done < <(find "$boot_entries_dir" -name "*.conf" -print0 2>/dev/null)
    if [ ${#boot_entries[@]} -eq 0 ]; then
      log_warning "No boot entries found. Skipping kernel parameter addition."
      return
    fi
    echo -e "${CYAN}Found ${#boot_entries[@]} boot entries${RESET}"
    local total=${#boot_entries[@]}
    local current=0
    local modified_count=0
    for entry in "${boot_entries[@]}"; do
      ((current++))
      local entry_name=$(basename "$entry")
      print_progress "$current" "$total" "Adding splash to $entry_name"
      if ! grep -q "splash" "$entry"; then
        if sudo sed -i '/^options / s/$/ splash/' "$entry"; then
          print_status " [OK]" "$GREEN"
          log_success "Added 'splash' to $entry_name"
          ((modified_count++))
        else
          print_status " [FAIL]" "$RED"
          log_error "Failed to add 'splash' to $entry_name"
        fi
      else
        print_status " [SKIP] Already has splash" "$YELLOW"
        log_warning "'splash' already set in $entry_name"
      fi
    done
    echo -e "\n${GREEN}✓ Kernel parameters updated for all boot entries (${modified_count} modified)${RESET}\n"
  elif [ -d /boot/grub ] || [ -f /etc/default/grub ]; then
    # GRUB logic
    if grep -q 'splash' /etc/default/grub; then
      log_warning "'splash' already present in GRUB_CMDLINE_LINUX_DEFAULT."
    else
      sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="splash /' /etc/default/grub
      log_success "Added 'splash' to GRUB_CMDLINE_LINUX_DEFAULT."
      sudo grub-mkconfig -o /boot/grub/grub.cfg
      log_success "Regenerated grub.cfg after adding 'splash'."
    fi
  else
    log_warning "No supported bootloader detected for kernel parameter addition."
  fi
}

print_summary() {
  echo -e "\n${CYAN}========= PLYMOUTH SUMMARY =========${RESET}"
  if [ ${#PLYMOUTH_ERRORS[@]} -eq 0 ]; then
    echo -e "${GREEN}Plymouth configured successfully!${RESET}"
  else
    echo -e "${RED}Some configuration steps failed:${RESET}"
    for err in "${PLYMOUTH_ERRORS[@]}"; do
      echo -e "  - ${YELLOW}$err${RESET}"
    done
  fi
  echo -e "${CYAN}====================================${RESET}"
}

# ======= Main =======
main() {
  # Print simple banner (no figlet)
  echo -e "${CYAN}=== Plymouth Configuration ===${RESET}"

  run_step "Adding plymouth hook to mkinitcpio.conf" enable_plymouth_hook
  run_step "Rebuilding initramfs for all kernels" rebuild_initramfs
  run_step "Setting Plymouth theme" set_plymouth_theme
  run_step "Adding 'splash' to all kernel parameters" add_kernel_parameters

  print_summary
}

main "$@"