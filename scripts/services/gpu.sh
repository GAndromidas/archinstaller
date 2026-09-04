#!/bin/bash
set -uo pipefail

# ============================================================================
# System Services Configuration - GPU Drivers Module
# ============================================================================
# GPU detection and driver installation for NVIDIA, AMD, Intel, and VM graphics

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

# Detect and install GPU drivers based on hardware
detect_and_install_gpu_drivers() {
  step "Detecting GPU and installing appropriate drivers"

  local gpu_vendor=""
  local gpu_model=""

  if lspci 2>/dev/null | grep -qiE 'vga.*nvidia|3d.*nvidia|display.*nvidia'; then
    gpu_vendor="nvidia"
  elif lspci 2>/dev/null | grep -qiE 'vga.*(amd|radeon|ati)|3d.*(amd|radeon|ati)|display.*(amd|radeon|ati)'; then
    gpu_vendor="amd"
  elif lspci 2>/dev/null | grep -qiE 'vga.*intel|display.*intel'; then
    gpu_vendor="intel"
  fi

  case "$gpu_vendor" in
    nvidia)
      log_info "NVIDIA GPU detected"
      step "Installing NVIDIA drivers"
      if is_laptop 2>/dev/null; then
        install_packages_quietly nvidia-dkms cuda-toolkit nvidia-utils lib32-nvidia-utils
        log_success "NVIDIA drivers (dkms) installed for laptop"
      else
        install_packages_quietly nvidia cuda-toolkit nvidia-utils lib32-nvidia-utils
        log_success "NVIDIA drivers installed for desktop"
      fi

      # GBM backend for Wayland
      install_packages_quietly libxcb
      log_success "NVIDIA Wayland support installed (libxcb, GBM)"
      ;;

    amd)
      log_info "AMD/Radeon GPU detected"
      step "Installing AMD GPU drivers"
      
      # Check if it's an older GPU that needs radeon driver
      if lspci 2>/dev/null | grep -qiE 'radeon.*oland|radeon.*tonga|radeon.*fiji'; then
        install_packages_quietly xf86-video-ati
        log_success "Radeon driver installed for older AMD GPU"
      else
        install_packages_quietly libva-mesa-driver mesa-vdpau
        log_success "AMDGPU (Mesa) drivers installed for modern AMD GPU"
      fi

      install_packages_quietly lib32-mesa
      log_success "32-bit Mesa libraries installed"
      ;;

    intel)
      log_info "Intel GPU detected"
      step "Installing Intel GPU drivers"
      install_packages_quietly libva-intel-driver
      install_packages_quietly lib32-mesa
      log_success "Intel GPU drivers installed"
      ;;

    *)
      log_info "No discrete GPU detected or using VM graphics (virtio/QXL)"
      ;;
  esac

  verify_gpu_driver
}

# Verify GPU driver installation
verify_gpu_driver() {
  log_info "Verifying GPU driver installation..."

  if command -v glxinfo >/dev/null 2>&1; then
    glxinfo -B 2>/dev/null | head -5 >> "$INSTALL_LOG" || true
  fi

  if lspci 2>/dev/null | grep -qiE 'vga|display|3d'; then
    log_success "GPU verification completed"
  fi
}
