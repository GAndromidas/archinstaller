#!/bin/bash
set -uo pipefail

# VM guest agents — single source of truth (extracted from
# scripts/modules/system_services.sh). Best-effort installs for the
# hypervisor in use; all starts time-boxed so a missing host channel
# (e.g. no virtio serial in GNOME Boxes) can never stall the install.
# No side effects on source.

if ! declare -f install_vm_guest_agents >/dev/null 2>&1; then
# Install guest agents when this machine is itself a VM guest (copy-paste,
# dynamic resolution, host-guest communication). spice-vdagent is the SPICE
# clipboard/resolution agent — it only helps inside a SPICE guest (e.g. this
# installer running in a GNOME Boxes VM), which is why it is gated on is_vm()
# here rather than on gnome-boxes (host-side). The programs.yaml entry covers
# Standard hosts too (harmless on bare metal, needed for nested VMs).
install_vm_guest_agents() {
  is_vm 2>/dev/null || return 0

  step "Installing VM guest agents"

  local virt="unknown"
  virt=$(systemd-detect-virt 2>/dev/null || echo "unknown")

  case "$virt" in
    oracle)
      log_info "VirtualBox guest detected — installing guest utils"
      install_packages_quietly virtualbox-guest-utils
      if timeout 30 sudo -n systemctl enable --now vboxservice.service >>"$INSTALL_LOG" 2>&1; then
        log_success "vboxservice enabled (clipboard + shared folders)"
      else
        log_warning "Failed to enable vboxservice"
      fi
      ;;
    vmware)
      log_info "VMware guest detected — installing open-vm-tools"
      install_packages_quietly open-vm-tools
      if timeout 30 sudo -n systemctl enable --now vmtoolsd.service >>"$INSTALL_LOG" 2>&1; then
        log_success "vmtoolsd enabled (clipboard + dynamic resolution)"
      else
        log_warning "Failed to enable vmtoolsd"
      fi
      ;;
    *)
      # qemu/kvm (incl. GNOME Boxes SPICE sessions) and unknown hypervisors:
      # SPICE agent for clipboard/resolution + qemu agent for host comms.
      # Headless servers have no graphical clipboard, so they only need the
      # qemu agent.
      log_info "QEMU/KVM guest detected ($virt) — installing SPICE + qemu agents"
      if [[ "${INSTALL_MODE:-}" == "server" ]]; then
        install_packages_quietly qemu-guest-agent
      else
        install_packages_quietly spice-vdagent qemu-guest-agent
      fi
      # Arch ships qemu-guest-agent without an [Install] section (enable
      # always fails), and start blocks ~90s per attempt when the host
      # provides no virtio channel (GNOME Boxes default). Start-only,
      # time-boxed: rc=124 means channel-less, which is harmless.
      if timeout 20 sudo -n systemctl start qemu-guest-agent.service >>"$INSTALL_LOG" 2>&1; then
        log_success "qemu-guest-agent started (no [Install] section — runs without enablement)"
      else
        log_info "qemu-guest-agent installed but not started (no guest-agent channel in this VM — add a virtio serial channel on the host if you need it; SPICE copy-paste is unaffected)"
      fi
      if [[ "${INSTALL_MODE:-}" != "server" ]]; then
        if timeout 30 sudo -n systemctl enable --now spice-vdagentd.service >>"$INSTALL_LOG" 2>&1; then
          log_success "spice-vdagentd enabled (seamless clipboard + dynamic resolution)"
        else
          log_warning "Failed to enable spice-vdagentd"
        fi
      fi
      ;;
  esac
  return 0
}
fi
