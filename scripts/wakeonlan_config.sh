#!/bin/bash
set -uo pipefail

# ============================================================================
# Wake-on-LAN Configuration for ArchInstaller
# Bare-metal desktops/servers only — always skipped in VMs and containers.
# Robust across NIC naming (enp*/eno*/ens*/eth*/enx*), USB adapters, and
# NetworkManager systems. Persistence via systemd service + udev rule
# (ethtool settings reset on link events/reboot without the udev rule)
# plus best-effort NetworkManager ethernet.wake-on-lan.
#
# Exit codes (see install.sh step 9):
#   0 = WoL enabled on >=1 interface
#   2 = graceful skip/warning (VM, container, laptop declined, no ethernet,
#       no WoL-capable NIC) — shows as warning in the dashboard, not failure
#   1 = real failure (ethtool install failed, enable failed)
# Set WOL_FORCE=1 to override the VM/container/laptop guards (testing only).
# ============================================================================

: "${INSTALL_LOG:=/var/tmp/archinstaller.log}"

# Get scripts directory (handles both direct execution and sourcing)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

# Color binding for prompt
BOLD="${THEME_TEXT_BOLD}"

# ---------------------------------------------------------------------------
# Helpers: TTY-safe output (dashboard_run redirects stdout/stderr to the log,
# so interactive text must go to /dev/tty explicitly)
# ---------------------------------------------------------------------------
_wol_has_tty() { { : </dev/tty >/dev/tty; } 2>/dev/null; }

# Print to TTY when available, otherwise stderr — never stdout, so functions
# whose output is captured via $(...) stay pure (single token on stdout).
wol_say() {
    if _wol_has_tty; then
        printf '%s\n' "$*" >/dev/tty 2>/dev/null || printf '%s\n' "$*" >&2
    else
        printf '%s\n' "$*" >&2
    fi
}

# ---------------------------------------------------------------------------
# Environment detection: VM / container / laptop
# NOTE: these are intentionally quiet on stdout (log_to_file only) because
# callers capture their stdout via $(...).
# ---------------------------------------------------------------------------

# Human-readable virt type for log messages (best effort, never fails)
wol_virt_name() {
    local v=""
    if command -v systemd-detect-virt &>/dev/null; then
        v=$(systemd-detect-virt 2>/dev/null || true)
        [[ -n "$v" && "$v" != "none" ]] && { echo "$v"; return 0; }
    fi
    if [[ -f /sys/class/dmi/id/product_name ]]; then
        cat /sys/class/dmi/id/product_name 2>/dev/null | tr -d '\0' || true
        return 0
    fi
    echo "virtualized"
}

# True when running inside a container (WoL is meaningless there)
wol_is_container() {
    if command -v systemd-detect-virt &>/dev/null && \
       systemd-detect-virt --container &>/dev/null; then
        return 0
    fi
    [[ -f /.dockerenv || -f /run/.containerenv ]] && return 0
    grep -qaE 'docker|lxc|kubepods|containerd' /proc/1/cgroup 2>/dev/null && return 0
    [[ -n "${container:-}" ]] && return 0
    return 1
}

# True on bare-metal hypervisor guests. systemd-detect-virt is authoritative;
# DMI strings, the hypervisor CPU flag, and virtio PCI devices corroborate.
# The shared is_vm() from common.sh is consulted last, with its known false
# positive (bare /sys/hypervisor dir exists on bare metal too) filtered out.
wol_is_vm() {
    if command -v systemd-detect-virt &>/dev/null && \
       systemd-detect-virt --vm &>/dev/null; then
        return 0
    fi
    # DMI checks (case-insensitive, hypervisor vendors only — generic
    # "To Be Filled By O.E.M." / "Microsoft Corporation" alone don't count)
    local dmi_blob=""
    dmi_blob="$(tr -d '\0' </sys/class/dmi/id/product_name 2>/dev/null || true) $(tr -d '\0' </sys/class/dmi/id/sys_vendor 2>/dev/null || true) $(tr -d '\0' </sys/class/dmi/id/bios_vendor 2>/dev/null || true)"
    if grep -qiE 'qemu|kvm|virtualbox|vmware|hyper-v|parallels|bhyve|xen|bochs' <<<"$dmi_blob" 2>/dev/null; then
        return 0
    fi
    # Hypervisor CPU flag is a strong x86 guest signal
    if grep -q '^flags.*\bhypervisor\b' /proc/cpuinfo 2>/dev/null; then
        return 0
    fi
    # Virtio / guest-agent PCI devices (KVM/QEMU guests almost always have one)
    if command -v lspci &>/dev/null && \
       lspci 2>/dev/null | grep -qiE 'virtio|virtualbox|vmware (svga|vmxnet|pvscsi)|hyper-v'; then
        return 0
    fi
    if declare -f is_vm &>/dev/null && is_vm 2>/dev/null; then
        # Filter the shared helper's false positive: an EMPTY /sys/hypervisor
        # directory exists on bare metal, while systemd reports "none".
        if [ -d /sys/hypervisor ] && [ -z "$(ls -A /sys/hypervisor 2>/dev/null)" ]; then
            local v=""
            v=$(systemd-detect-virt 2>/dev/null || true)
            if [[ "$v" == "none" ]]; then
                return 1
            fi
        fi
        return 0
    fi
    return 1
}

wol_is_laptop() {
    if declare -f is_laptop &>/dev/null && is_laptop 2>/dev/null; then
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Ethernet interface discovery
# Silent on stdout except for the final list (one name per line).
# ---------------------------------------------------------------------------
get_ethernet_interfaces() {
    local interfaces=()
    local path name iftype

    for path in /sys/class/net/*; do
        [ -e "$path" ] || continue
        name=$(basename "$path")

        # Skip loopback and common virtual/tunnel endpoints
        case "$name" in
            lo|veth*|docker*|br-*|virbr*|vmnet*|vboxnet*|wg*|tailscale*|tun*|tap*|zt*|ppp*|sl*)
                continue ;;
        esac

        # Must be ARPHRD_ETHER (type 1) — filters out Infiniband, loopback, etc.
        iftype=$(cat "$path/type" 2>/dev/null || echo "")
        [[ "$iftype" == "1" ]] || continue

        # Skip Wi-Fi (also type 1): wireless/ or phy80211 presence is decisive
        if [ -d "$path/wireless" ] || [ -d "$path/phy80211" ]; then
            continue
        fi

        # Prefer physical NICs (PCI/USB device symlink). Bonds/bridges/VLANs
        # have no device symlink — but keep them as last-resort candidates
        # only if NO physical NIC was found at all (handled below).
        if [ -L "$path/device" ]; then
            interfaces+=("$name")
        fi
    done

    # Fallback: no physical NIC via sysfs (odd drivers, renaming races) —
    # mirror the proven working-script approach and scan ip link names.
    if ((${#interfaces[@]} == 0)); then
        local candidate
        while IFS= read -r candidate; do
            [[ -n "$candidate" ]] || continue
            case "$candidate" in
                lo*|veth*|docker*|br-*|virbr*|vmnet*|vboxnet*|wg*|tailscale*|tun*|tap*|wlan*|wlp*|wwan*) continue ;;
            esac
            case "$candidate" in
                enp*|eno*|ens*|eth*|enx*|em*)
                    [ -d "/sys/class/net/$candidate/wireless" ] && continue
                    interfaces+=("$candidate") ;;
            esac
        done < <(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | cut -d'@' -f1 || true)
    fi

    ((${#interfaces[@]} == 0)) && return 1
    printf '%s\n' "${interfaces[@]}" | sort -u
}

# ---------------------------------------------------------------------------
# Fast, side-effect-free interface ranking (no ping, no `ip link set up`).
# Scoring: default route 50 + IPv4 address 20 + carrier 20 + operstate up 10.
# Prints the single best interface name. Never logs to stdout.
# ---------------------------------------------------------------------------
pick_best_interface() {
    local interfaces=("$@")
    ((${#interfaces[@]} == 0)) && return 1

    local best="" best_score=-1
    local iface score carrier oper

    for iface in "${interfaces[@]}"; do
        [[ -n "$iface" && -d "/sys/class/net/$iface" ]] || continue
        score=0

        if ip route show dev "$iface" 2>/dev/null | grep -q 'default'; then
            score=$((score + 50))
        fi
        if ip -o -4 addr show dev "$iface" 2>/dev/null | grep -q 'inet '; then
            score=$((score + 20))
        fi
        carrier=$(cat "/sys/class/net/$iface/carrier" 2>/dev/null || echo "")
        [[ "$carrier" == "1" ]] && score=$((score + 20))
        oper=$(cat "/sys/class/net/$iface/operstate" 2>/dev/null || echo "")
        [[ "$oper" == "up" ]] && score=$((score + 10))

        if ((score > best_score)); then
            best_score=$score
            best="$iface"
        fi
    done

    [[ -n "$best" ]] || return 1
    echo "$best"
}

# ---------------------------------------------------------------------------
# WoL capability / state
# ---------------------------------------------------------------------------
supports_wol() {
    local iface="$1"
    command -v ethtool &>/dev/null || return 1

    local ethtool_out
    ethtool_out=$(sudo ethtool "$iface" 2>/dev/null) || return 1

    # 'g' (magic packet) must be in the SUPPORTED modes, e.g.:
    #   Supports Wake-on: pumbg   /   Supports Wake-on: d
    local wol_support
    wol_support=$(printf '%s\n' "$ethtool_out" | sed -n 's/^[[:space:]]*Supports Wake-on:[[:space:]]*//p' | tr -d '[:space:]')
    [[ -n "$wol_support" ]] || return 1
    [[ "$wol_support" == *g* ]] || return 1
    return 0
}

current_wol() {
    local iface="$1"
    sudo ethtool "$iface" 2>/dev/null | sed -n 's/^[[:space:]]*Wake-on:[[:space:]]*//p' | tr -d '[:space:]'
}

# ---------------------------------------------------------------------------
# Persistence backends
# ---------------------------------------------------------------------------
wol_ethtool_path() {
    local p
    p=$(command -v ethtool 2>/dev/null || true)
    [[ -n "$p" ]] && { echo "$p"; return 0; }
    for p in /usr/bin/ethtool /sbin/ethtool; do
        [[ -x "$p" ]] && { echo "$p"; return 0; }
    done
    echo "/usr/bin/ethtool"
}

# systemd service: re-applies `wol g` on every boot (correct ordering —
# network-pre.target, no bogus Before=shutdown/ExecStop which never fire
# usefully for oneshot+RemainAfterExit units).
create_wol_service() {
    local iface="$1"
    local service_file="/etc/systemd/system/wol-${iface}.service"
    local ethtool_path
    ethtool_path=$(wol_ethtool_path)

    log_info "Creating systemd service for WoL on $iface"

    sudo tee "$service_file" >/dev/null <<EOF
[Unit]
Description=Enable Wake-on-LAN (magic packet) for $iface
After=network-pre.target
Wants=network-pre.target
Before=network.target

[Service]
Type=oneshot
ExecStart=${ethtool_path} -s ${iface} wol g
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    if [ ! -f "$service_file" ] && ! sudo test -f "$service_file" 2>/dev/null; then
        log_error "Failed to create service file: $service_file"
        ui_error "Failed to create WoL service file for $iface"
        return 1
    fi

    sudo systemctl daemon-reload 2>>"$INSTALL_LOG" || true
    if sudo systemctl enable "wol-${iface}.service" >>"$INSTALL_LOG" 2>&1; then
        log_success "Systemd service enabled for WoL on $iface"
    else
        log_error "Failed to enable systemd service for WoL on $iface"
        ui_error "Failed to enable persistent WoL service for $iface"
        return 1
    fi

    if systemctl is-enabled --quiet "wol-${iface}.service" 2>/dev/null; then
        log_success "Verified WoL service is enabled for $iface"
        return 0
    else
        log_error "WoL service verification failed for $iface"
        ui_error "WoL service verification failed for $iface"
        return 1
    fi
}

# udev rule: re-applies `wol g` whenever the NIC appears / link flaps.
# This is the fix for "works once, resets after reboot" — NetworkManager and
# the kernel reset Wake-on on link events without it.
create_wol_udev_rule() {
    local iface="$1"
    local rule_file="/etc/udev/rules.d/81-wol-${iface}.rules"
    local ethtool_path
    ethtool_path=$(wol_ethtool_path)

    log_info "Creating udev rule for WoL on $iface"
    sudo tee "$rule_file" >/dev/null <<EOF
# Wake-on-LAN (magic packet) persistence for $iface — managed by archinstaller
ACTION=="add", SUBSYSTEM=="net", NAME=="$iface", RUN+="$ethtool_path -s $iface wol g"
EOF

    if ! sudo test -f "$rule_file" 2>/dev/null; then
        log_error "Failed to create udev rule: $rule_file"
        return 1
    fi
    sudo udevadm control --reload-rules 2>>"$INSTALL_LOG" || true
    log_success "udev rule installed for WoL on $iface"
    return 0
}

# NetworkManager: stops NM from clearing Wake-on on connection activation.
# Best effort — succeeds silently, never fails the install.
apply_nm_wol() {
    local iface="$1"
    command -v nmcli &>/dev/null || return 0

    local conn
    conn=$(nmcli -t -f NAME,DEVICE connection show 2>/dev/null | awk -F: -v dev="$iface" '$2==dev {print $1; exit}')
    [[ -n "$conn" ]] || conn=$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | awk -F: -v dev="$iface" '$2==dev {print $1; exit}')
    [[ -n "$conn" ]] || return 0

    # NM 1.x uses 802-3-ethernet.wake-on-lan; newer docs alias ethernet.*.
    # Try both property paths; ignore failures (older NM).
    sudo nmcli connection modify "$conn" 802-3-ethernet.wake-on-lan magic >>"$INSTALL_LOG" 2>&1 || \
    sudo nmcli connection modify "$conn" ethernet.wake-on-lan magic >>"$INSTALL_LOG" 2>&1 || true
    log_info "NetworkManager WoL set to magic for connection '$conn' ($iface)"
    return 0
}

# ---------------------------------------------------------------------------
# Enable WoL on one interface (ethtool now + all persistence backends)
# ---------------------------------------------------------------------------
enable_wol_interface() {
    local iface="$1"

    log_info "Enabling Wake-on-LAN on interface: $iface"

    if ! sudo ethtool -s "$iface" wol g >>"$INSTALL_LOG" 2>&1; then
        log_error "Failed to enable Wake-on-LAN on $iface via ethtool"
        ui_error "Failed to enable Wake-on-LAN on $iface"
        return 1
    fi
    log_success "Wake-on-LAN enabled on $iface via ethtool"

    # PCI PME wakeup (best effort — path varies by platform)
    local pci_dev=""
    pci_dev=$(readlink -f "/sys/class/net/$iface/device" 2>/dev/null | xargs basename 2>/dev/null || true)
    if [ -n "$pci_dev" ] && sudo test -f "/sys/bus/pci/devices/$pci_dev/power/wakeup" 2>/dev/null; then
        echo "enabled" | sudo tee "/sys/bus/pci/devices/$pci_dev/power/wakeup" >/dev/null 2>&1 || true
        log_info "PCI PME wakeup enabled for $pci_dev"
    fi

    apply_nm_wol "$iface" || true

    # Verify WoL actually stuck before writing persistence
    local wol_now
    wol_now=$(current_wol "$iface")
    if [[ "$wol_now" == *g* ]]; then
        log_success "Verified WoL is active on $iface (Wake-on: $wol_now)"
    else
        log_warning "WoL set but verification shows Wake-on: ${wol_now:-unknown} — continuing, persistence may still apply after reboot"
    fi

    local rc=0
    create_wol_service "$iface" || rc=1
    # udev rule is the critical reboot/link-flap persistence — failure here
    # is a warning, not fatal, as long as the systemd unit is in place.
    create_wol_udev_rule "$iface" || log_warning "udev persistence rule failed for $iface (systemd unit still active)"
    return "$rc"
}

# ---------------------------------------------------------------------------
# Misc helpers
# ---------------------------------------------------------------------------
get_interface_mac() {
    local iface="$1"
    local mac=""
    mac=$(cat "/sys/class/net/$iface/address" 2>/dev/null || true)
    if [[ -z "$mac" ]]; then
        mac=$(ip link show "$iface" 2>/dev/null | awk '/link\/ether/ {print $2}' | head -1 || true)
    fi
    printf '%s' "$mac"
}

show_wol_status() {
    local interfaces=()
    mapfile -t interfaces < <(get_ethernet_interfaces 2>/dev/null || true)

    if ((${#interfaces[@]} == 0)); then
        ui_info "No ethernet interfaces found"
        return 1
    fi

    echo -e "${THEME_TEXT}Wake-on-LAN Status:${RESET}"
    echo -e "${THEME_WARN}==================${RESET}"

    local iface mac_addr wol_status wol_cur
    for iface in "${interfaces[@]}"; do
        mac_addr=$(get_interface_mac "$iface")
        wol_status="Unknown"

        if supports_wol "$iface"; then
            wol_cur=$(current_wol "$iface")
            if [[ "$wol_cur" == *g* ]]; then
                wol_status="${THEME_SUCCESS}Enabled${RESET}"
            else
                wol_status="${THEME_WARN}Disabled${RESET}"
            fi
        else
            wol_status="${THEME_ERROR}Not Supported${RESET}"
        fi

        echo -e "${THEME_TEXT}Interface: ${RESET}$iface"
        echo -e "${THEME_TEXT}MAC Address: ${RESET}${mac_addr:-N/A}"
        echo -e "${THEME_TEXT}WoL Status: ${RESET}$wol_status"
        echo -e "${THEME_WARN}------------------${RESET}"
    done
}

# Prompt for interface selection.
# All interaction on /dev/tty (dashboard hides stdout); ONLY the final token
# (iface name, ALL, or SKIP) goes to stdout for $(...) capture.
prompt_interface_selection() {
    local interfaces=("$@")
    local best_iface="" choices=()
    best_iface=$(pick_best_interface "${interfaces[@]}" 2>/dev/null || true)

    wol_say ""
    wol_say "Multiple ethernet interfaces detected:"
    wol_say ""

    local i=1 iface mac_addr tag carrier
    for iface in "${interfaces[@]}"; do
        mac_addr=$(get_interface_mac "$iface")
        tag="[standby]"
        if [[ "$iface" == "$best_iface" ]]; then
            tag="[PRIMARY - default route/link]"
        else
            carrier=$(cat "/sys/class/net/$iface/carrier" 2>/dev/null || echo "")
            [[ "$carrier" == "1" ]] && tag="[link detected]"
        fi
        if ! supports_wol "$iface" 2>/dev/null; then
            tag="$tag [no WoL support]"
        fi
        wol_say "$i) $iface $tag"
        wol_say "   MAC: ${mac_addr:-N/A}"
        wol_say ""
        choices+=("$iface")
        i=$((i + 1))
    done

    wol_say "a) Configure ALL WoL-capable interfaces"
    wol_say "s) Skip Wake-on-LAN configuration"
    wol_say ""

    local choice selected_iface
    while true; do
        if _wol_has_tty; then
            printf '%b' "${BOLD}Select option [1-${#interfaces[@]}, a, s]:${RESET} " >/dev/tty 2>/dev/null || true
            read -r choice </dev/tty || choice=""
        else
            printf '%b' "${BOLD}Select option [1-${#interfaces[@]}, a, s]:${RESET} " >&2
            read -r choice || choice=""
        fi

        case "$choice" in
            [0-9]*)
                if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#interfaces[@]} ]; then
                    selected_iface="${choices[$((choice - 1))]}"
                    wol_say ""
                    wol_say "Selected interface: $selected_iface"
                    echo "$selected_iface"
                    return 0
                else
                    wol_say "Invalid selection. Please try again."
                fi
                ;;
            a|A)
                wol_say ""
                wol_say "Configuring ALL WoL-capable ethernet interfaces"
                echo "ALL"
                return 0
                ;;
            s|S)
                wol_say ""
                wol_say "Wake-on-LAN configuration skipped"
                echo "SKIP"
                return 0
                ;;
            *)
                wol_say "Invalid option. Please try again."
                ;;
        esac
    done
}

# Confirm on /dev/tty (gum_confirm writes to captured stdout, so it cannot
# be used for prompts whose caller captures stdout — use this instead).
wol_confirm_tty() {
    local question="${1:-Continue?}"
    local answer=""
    local prompt_text="Y/n"
    if _wol_has_tty; then
        while true; do
            printf '%s [%s]: ' "$question" "$prompt_text" >/dev/tty 2>/dev/null || printf '%s [%s]: ' "$question" "$prompt_text" >&2
            read -r answer </dev/tty || { return 1; }
            case "${answer,,}" in
                ""|y|yes) return 0 ;;
                n|no) return 1 ;;
                *) wol_say "Please answer Y (yes) or N (no)." ;;
            esac
        done
    else
        # No TTY (redirected test): decline non-essential prompts by default
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
configure_wakeonlan() {
    ui_info "Configuring Wake-on-LAN..."

    # --- Guard 1: containers can never WoL ---------------------------------
    if wol_is_container; then
        if [[ "${WOL_FORCE:-0}" == "1" ]]; then
            log_warning "Container detected but WOL_FORCE=1 — continuing anyway (testing only)"
        else
            ui_info "Container environment detected - Wake-on-LAN skipped (bare-metal only)"
            log_info "Container detected - WoL configuration skipped"
            return 2
        fi
    fi

    # --- Guard 2: virtual machines get no WoL (bare metal only) ------------
    if wol_is_vm; then
        if [[ "${WOL_FORCE:-0}" == "1" ]]; then
            log_warning "VM detected ($(wol_virt_name)) but WOL_FORCE=1 — continuing anyway (testing only)"
        else
            ui_info "Virtual machine ($(wol_virt_name)) detected - Wake-on-LAN skipped (bare-metal only)"
            ui_info "Wake-on-LAN requires physical NIC firmware support unavailable in VMs"
            log_info "VM detected ($(wol_virt_name)) - WoL configuration skipped"
            return 2
        fi
    fi

    # --- Guard 3: laptops — offer opt-in instead of silent skip -------------
    if wol_is_laptop; then
        if [[ "${WOL_FORCE:-0}" == "1" ]]; then
            log_info "Laptop detected but WOL_FORCE=1 — configuring anyway"
        else
            ui_info "Laptop system detected - Wake-on-LAN is usually only useful on desktops/servers"
            if ! wol_confirm_tty "Enable Wake-on-LAN on this laptop anyway?"; then
                ui_info "Wake-on-LAN configuration skipped (laptop)"
                log_info "Laptop detected, user declined - WoL configuration skipped"
                return 2
            fi
            log_info "Laptop detected, user opted in - continuing WoL configuration"
        fi
    fi

    # --- Ensure ethtool ------------------------------------------------------
    if ! command -v ethtool &>/dev/null; then
        ui_info "Installing ethtool for Wake-on-LAN support..."
        if declare -f install_packages_batch &>/dev/null; then
            if install_packages_batch "pacman" "ethtool"; then
                ui_success "ethtool installed successfully"
                log_info "ethtool installed for WoL support"
            else
                ui_error "Failed to install ethtool"
                return 1
            fi
        else
            if sudo pacman -S --noconfirm --needed ethtool >>"$INSTALL_LOG" 2>&1; then
                ui_success "ethtool installed successfully"
                log_info "ethtool installed for WoL support"
            else
                ui_error "Failed to install ethtool"
                return 1
            fi
        fi
    fi

    # --- Discover ethernet interfaces ----------------------------------------
    local interfaces=()
    mapfile -t interfaces < <(get_ethernet_interfaces 2>/dev/null || true)

    if ((${#interfaces[@]} == 0)); then
        ui_info "No wired ethernet interfaces found - Wake-on-LAN configuration skipped"
        ui_info "(Wi-Fi-only system: WoL over wireless is not supported by this step)"
        log_info "No ethernet interfaces found - WoL configuration skipped"
        return 2
    fi

    ui_info "Found ${#interfaces[@]} ethernet interface(s): ${interfaces[*]}"

    local best_iface=""
    best_iface=$(pick_best_interface "${interfaces[@]}" 2>/dev/null || true)
    if [ -n "$best_iface" ]; then
        ui_success "Detected primary interface: $best_iface"
    else
        ui_warn "No interface currently has link/route — will configure by selection"
    fi

    # --- Pre-check WoL capability ---------------------------------------------
    local capable=()
    local iface
    for iface in "${interfaces[@]}"; do
        if supports_wol "$iface"; then
            capable+=("$iface")
        fi
    done

    if ((${#capable[@]} == 0)); then
        ui_warn "No interfaces support Wake-on-LAN (magic-packet mode 'g' not advertised)"
        ui_info "This is expected in VMs or with drivers lacking WoL firmware support"
        log_info "No WoL-capable interfaces among: ${interfaces[*]}"
        return 2
    fi

    # --- Selection -------------------------------------------------------------
    local selection=""
    if ((${#interfaces[@]} == 1)); then
        selection="${interfaces[0]}"
        ui_info "Auto-selecting single interface: $selection"
    elif ((${#capable[@]} == 1)) && ((${#interfaces[@]} > 1)); then
        # Only one NIC can actually do WoL — no point prompting across all.
        selection="${capable[0]}"
        ui_info "Only one WoL-capable interface found — auto-selecting: $selection"
    else
        selection=$(prompt_interface_selection "${interfaces[@]}")

        if [[ "$selection" == "SKIP" ]]; then
            log_info "User chose to skip WoL configuration"
            return 2
        fi
    fi

    # --- Configure --------------------------------------------------------------
    local targets=()
    if [[ "$selection" == "ALL" ]]; then
        targets=("${capable[@]}")
    else
        targets=("$selection")
    fi

    local success_count=0 fail_count=0 skipped_count=0
    for iface in "${targets[@]}"; do
        ui_info "Processing interface: $iface"

        if ! supports_wol "$iface"; then
            ui_warn "Interface $iface does not support Wake-on-LAN (magic packet) - skipping"
            skipped_count=$((skipped_count + 1))
            continue
        fi

        if enable_wol_interface "$iface"; then
            success_count=$((success_count + 1))

            local mac_addr=""
            mac_addr=$(get_interface_mac "$iface")
            if [ -n "$mac_addr" ]; then
                ui_success "MAC address for $iface: $mac_addr"
                ui_info "Use this MAC address to send Wake-on-LAN (magic packet) to this machine"
            fi
        else
            fail_count=$((fail_count + 1))
        fi
    done

    if [ "$success_count" -gt 0 ]; then
        ui_success "Wake-on-LAN configured successfully on $success_count interface(s)"
        ui_info "Persistence: systemd unit + udev rule (+ NetworkManager where present)"
        ui_info "NOTE: also enable 'Power On by PCI-E / Wake on LAN' in the system BIOS/UEFI"

        echo ""
        show_wol_status

        # MAC cheat-sheet to TTY too — dashboard hides stdout, and the user
        # needs these MACs on another machine to actually wake this host.
        if _wol_has_tty; then
            {
                echo ""
                echo "Wake-on-LAN MAC addresses (use to wake this machine):"
                for iface in "${targets[@]}"; do
                    if [[ "$(current_wol "$iface" 2>/dev/null)" == *g* ]]; then
                        echo "  $iface: $(get_interface_mac "$iface")"
                    fi
                done
            } >/dev/tty 2>/dev/null || true
        fi
        return 0
    elif [ "$fail_count" -gt 0 ]; then
        ui_error "Wake-on-LAN configuration failed on $fail_count interface(s)"
        return 1
    else
        ui_warn "No interfaces support Wake-on-LAN"
        return 2
    fi
}

# Function to disable Wake-on-LAN (for cleanup)
disable_wakeonlan() {
    ui_info "Disabling Wake-on-LAN..."

    local interfaces=()
    mapfile -t interfaces < <(get_ethernet_interfaces 2>/dev/null || true)

    local iface service_file rule_file
    for iface in "${interfaces[@]}"; do
        if sudo ethtool -s "$iface" wol d 2>/dev/null; then
            ui_info "Wake-on-LAN disabled on $iface"
        fi

        # Best-effort NetworkManager revert
        if command -v nmcli &>/dev/null; then
            local conn=""
            conn=$(nmcli -t -f NAME,DEVICE connection show 2>/dev/null | awk -F: -v dev="$iface" '$2==dev {print $1; exit}')
            if [[ -n "$conn" ]]; then
                sudo nmcli connection modify "$conn" 802-3-ethernet.wake-on-lan ignore >>"$INSTALL_LOG" 2>&1 || true
            fi
        fi

        service_file="/etc/systemd/system/wol-${iface}.service"
        if sudo test -f "$service_file" 2>/dev/null; then
            sudo systemctl disable "wol-${iface}.service" 2>/dev/null || true
            sudo rm -f "$service_file"
            ui_info "Removed WoL service for $iface"
        fi

        rule_file="/etc/udev/rules.d/81-wol-${iface}.rules"
        if sudo test -f "$rule_file" 2>/dev/null; then
            sudo rm -f "$rule_file"
            ui_info "Removed WoL udev rule for $iface"
        fi
    done

    sudo systemctl daemon-reload 2>/dev/null || true
    sudo udevadm control --reload-rules 2>/dev/null || true
    ui_success "Wake-on-LAN disabled on all interfaces"
}

# Export functions for external use
export -f configure_wakeonlan
export -f disable_wakeonlan
export -f show_wol_status

# Main execution — runs on source like every other step script, so the
# installer can execute this step via dashboard_run (output hidden in the
# log, interactive prompts on /dev/tty). Exit codes: 0 ok, 2 graceful
# skip/warning (VM, container, laptop declined, no ethernet, no WoL-capable
# NIC), anything else = failure.
configure_wakeonlan
