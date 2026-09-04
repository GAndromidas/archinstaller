#!/bin/bash
set -uo pipefail

# ============================================================================
# System Services Configuration - Main Orchestrator
# ============================================================================
# Coordinates firewall, GPU, laptop, AMD P-State, and other system services.
# Sources modularized service scripts from scripts/services/ directory.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Source modularized service modules
# Each module should export its configuration functions
if [[ -f "$SCRIPT_DIR/services/firewall.sh" ]]; then
  source "$SCRIPT_DIR/services/firewall.sh"
  FIREWALL_MODULE_LOADED=true
else
  FIREWALL_MODULE_LOADED=false
fi

if [[ -f "$SCRIPT_DIR/services/gpu.sh" ]]; then
  source "$SCRIPT_DIR/services/gpu.sh"
  GPU_MODULE_LOADED=true
else
  GPU_MODULE_LOADED=false
fi

# Fall back to original system_services.sh if modularized versions aren't available
if [[ "$FIREWALL_MODULE_LOADED" != true ]] || [[ "$GPU_MODULE_LOADED" != true ]]; then
  log_warning "Some service modules not found - falling back to original system_services.sh"
  source "$SCRIPT_DIR/system_services.sh.original"
  exit $?
fi

# ============================================================================
# MAIN SYSTEM SERVICES ORCHESTRATION
# ============================================================================

setup_firewall_and_services() {
  step "Setting up firewall and system services"

  # Firewall setup (UFW or Firewalld)
  run_step "Configuring firewall" configure_firewall_service

  # Configure user groups (audio, video, input, games, kvm, libvirt, docker)
  run_step "Configuring user groups" configure_user_groups

  # Enable system services
  run_step "Enabling system services" enable_services
}

# Configure user groups for multimedia and system access
configure_user_groups() {
  step "Configuring user groups"

  local username="$(whoami)"
  local groups=("audio" "video" "input" "games" "kvm" "libvirt" "docker")

  for group in "${groups[@]}"; do
    if grep -q "^$group:" /etc/group; then
      if ! id -nG "$username" | grep -qw "$group"; then
        sudo usermod -aG "$group" "$username"
        log_info "Added $username to $group group"
      fi
    fi
  done

  log_success "User groups configured"
}

# Enable essential system services
enable_services() {
  step "Enabling system services"

  local services=(
    "bluetooth"
    "avahi-daemon"
    "cups"
  )

  for service in "${services[@]}"; do
    if systemctl list-units --all | grep -q "$service"; then
      sudo systemctl enable "$service" 2>/dev/null || true
      log_info "Enabled $service"
    fi
  done

  log_success "System services enabled"
}

# GPU driver setup (uses modularized gpu.sh)
setup_gpu_drivers() {
  if [[ "$GPU_MODULE_LOADED" == true ]]; then
    detect_and_install_gpu_drivers
  else
    log_warning "GPU module not available"
  fi
}

# Main entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  setup_firewall_and_services "$@"
fi
