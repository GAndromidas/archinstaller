#!/bin/bash
set -uo pipefail

# ============================================================================
# Bootloader Configuration Orchestrator
# ============================================================================
# Central entry point for bootloader configuration that coordinates:
# - Kernel parameter generation (common.sh)
# - Bootloader-specific config (grub.sh, systemd.sh, limine.sh)
# - Resumable state tracking via install.sh's STATE_FILE mechanism

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"
source "$SCRIPT_DIR/common.sh"

# Detect bootloader (already done by common.sh via detect_bootloader)
BOOTLOADER=$(detect_bootloader)
export BOOTLOADER

# ============================================================================
# BOOTLOADER ORCHESTRATION
# ============================================================================

configure_bootloader() {
  step "Configuring $BOOTLOADER bootloader with unified kernel parameters"

  case "$BOOTLOADER" in
    grub)
      log_info "Detected GRUB bootloader"
      if [[ -f "$SCRIPT_DIR/grub.sh" ]]; then
        source "$SCRIPT_DIR/grub.sh"
        configure_grub_bootloader
      else
        log_error "GRUB configuration module not found at $SCRIPT_DIR/grub.sh"
        return 1
      fi
      ;;
    systemd-boot)
      log_info "Detected systemd-boot bootloader"
      if [[ -f "$SCRIPT_DIR/systemd.sh" ]]; then
        source "$SCRIPT_DIR/systemd.sh"
        configure_systemd_boot
      else
        log_error "systemd-boot configuration module not found at $SCRIPT_DIR/systemd.sh"
        return 1
      fi
      ;;
    limine)
      log_info "Detected Limine bootloader"
      if [[ -f "$SCRIPT_DIR/limine.sh" ]]; then
        source "$SCRIPT_DIR/limine.sh"
        configure_limine_bootloader
      else
        log_error "Limine configuration module not found at $SCRIPT_DIR/limine.sh"
        return 1
      fi
      ;;
    *)
      log_error "Unknown or unsupported bootloader: $BOOTLOADER"
      return 1
      ;;
  esac

  # Unified post-configuration for all bootloaders
  if [[ "$NEEDS_INITRAMFS_REBUILD" == true ]]; then
    run_step "Rebuilding initramfs for UKI/kernel changes" rebuild_initramfs
  fi

  log_success "Bootloader configuration completed for $BOOTLOADER"
}

# Rebuild initramfs (deferred and run once at end of bootloader config)
rebuild_initramfs() {
  log_info "Rebuilding initramfs (mkinitcpio) - this may take a minute..."
  if sudo mkinitcpio -P >> "$INSTALL_LOG" 2>&1; then
    log_success "Initramfs rebuilt successfully"
  else
    log_error "Initramfs rebuild failed - check $INSTALL_LOG for details"
    return 1
  fi
}

# Main entry point when sourced from install.sh
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # Direct execution (for testing)
  configure_bootloader "$@"
fi
