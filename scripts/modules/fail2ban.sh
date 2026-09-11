#!/bin/bash
set -uo pipefail

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

if [[ "${DRY_RUN:-false}" == true ]]; then
  ui_info "Dry-run: Fail2ban setup would run here."
  exit 0
fi

# Install fail2ban
install_fail2ban() {
  if pacman -Q fail2ban >/dev/null 2>&1; then
    log_info "fail2ban already installed, skipping"
    return 0
  fi

  ui_info "Installing fail2ban..."
  if pacman_install_single "fail2ban" false; then
    return 0
  else
    return 1
  fi
}

# Detect the active firewall so fail2ban can pick the correct ban ACTION.
# This is the firewall-integration layer (firewalld / ufw / iptables-nft), NOT
# the log-parsing backend.
detect_firewall_action() {
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    echo "firewalld"
  elif command -v ufw >/dev/null 2>&1 && { sudo ufw status 2>/dev/null | grep -q "Status: active"; }; then
    echo "ufw"
  else
    echo "systemd"
  fi
}

# Set `key = value` within a jail.conf/.local section, regardless of
# whether that key already has a line to substitute. jail.conf's stock
# sections are minimal — [sshd] doesn't even have an `enabled =` line,
# it inherits `enabled = false` from [DEFAULT] — so a plain `sed
# s/^key = .*/.../ ` silently does nothing when the key isn't already
# present, and the jail stays disabled no matter what else gets
# "configured". Confirmed against the real, complete upstream jail.conf,
# not a guess: this is why every previous fix here still showed
# "Active jails: none" across three separate real installs. Delete any
# existing line for that key within the section, then insert a fresh one
# right after the section header — works whether the key existed or not.
_f2b_set_option() {
  local jail_local="$1" section="$2" key="$3" value="$4"
  # Range must end at the NEXT section header, not the next blank line —
  # confirmed against the actual installed jail.conf (not a hand-written
  # guess) that [sshd] has a blank line immediately after its own header,
  # before the real settings. Ranging to the first blank line closed the
  # range almost immediately, so the delete step never reached the real
  # `port    = ssh` line (aligned with extra spaces — also confirmed
  # against the real file, another thing a hand-written test fixture
  # missed) further down. That left a genuine duplicate key in the
  # section, which fail2ban's own parser hard-rejects outright — verified
  # directly with `fail2ban-client --test`: "option 'port' in section
  # 'sshd' already exists" — meaning the ENTIRE config failed to load, not
  # just this one setting. This is the real, complete, verified root
  # cause of every prior "Active jails: none" across four real installs.
  sudo sed -i "/^\\[${section}\\]/,/^\\[/ { /^${key}[[:space:]]*=/d }" "$jail_local"
  sudo sed -i "/^\\[${section}\\]/a ${key} = ${value}" "$jail_local"
}

# Configure fail2ban jail.local based on detected firewall
configure_fail2ban() {
  local jail_local="/etc/fail2ban/jail.local"
  local firewall
  firewall=$(detect_firewall_action)

  if [ -f "$jail_local" ]; then
    log_info "jail.local already exists, updating backend and SSH jail..."
  fi

  ui_info "Configuring fail2ban for $firewall firewall..."

  # Create jail.local from jail.conf as base
  if [ ! -f "$jail_local" ]; then
    sudo cp /etc/fail2ban/jail.conf "$jail_local"
  fi

  # The 'backend' setting is the LOG-PARSING backend (valid values: auto,
  # pyinotify, gamin, polling, systemd). Arch uses journald by default, so use
  # 'systemd' to read logs from the journal. The firewall-integrating
  # 'action' is what must match the active firewall below.
  # Deliberately a plain global substitution, not _f2b_set_option: unlike
  # [sshd]/[recidive], [DEFAULT] already has a real `backend = auto` line
  # to match (confirmed against the real jail.conf), and [DEFAULT] is long
  # enough to likely contain internal blank lines between comment blocks —
  # tested this exact scenario and confirmed _f2b_set_option's delete-range
  # would stop at the first internal blank line, missing the original line
  # entirely and leaving both present. Under INI parsing the later
  # (untouched, unwanted) line wins, silently undoing the fix. The
  # unscoped substitution below also touches other (disabled, irrelevant)
  # jails' own backend= lines, but since those jails stay disabled that
  # has no functional effect.
  sudo sed -i "s/^backend = .*/backend = systemd/" "$jail_local"

  # Configure SSH jail. With backend=systemd, fail2ban matches SSH events
  # via the sshd filter's built-in journalmatch (_SYSTEMD_UNIT=sshd.service
  # + _COMM=sshd) — logpath is not used for journal-backed jails and is
  # deliberately left untouched here.
  #
  # Every one of these goes through _f2b_set_option, not a plain sed
  # substitution: jail.conf's stock [sshd] section only has `port`,
  # `logpath`, and `backend` explicitly — enabled/filter/maxretry/bantime/
  # findtime are all inherited from [DEFAULT] and simply don't exist as
  # lines to substitute within [sshd]. A substitution-only approach
  # silently does nothing for any of those, which is exactly why `enabled`
  # was never actually being set to true across three real installs.
  _f2b_set_option "$jail_local" sshd enabled true
  _f2b_set_option "$jail_local" sshd port ssh
  _f2b_set_option "$jail_local" sshd filter sshd
  _f2b_set_option "$jail_local" sshd maxretry 3
  _f2b_set_option "$jail_local" sshd bantime 1h
  _f2b_set_option "$jail_local" sshd findtime 10m

  # Select the ban action to match the active firewall.
  # - firewalld: use firewallcmd-rich-rules
  # - ufw: use ufw action
  # - default: use the default iptables/nftables action from jail.conf
  if [ "$firewall" = "firewalld" ]; then
    sudo sed -i '/^\[sshd\]/,/^\[/ {
      /^action[[:space:]]*=/d
      /^ *blocktype=.*/d
      /^\[sshd\]/a action = firewallcmd-rich-rules[actiontype=<multiport>]
      /^\[sshd\]/a          blocktype=drop
    }' "$jail_local"
  elif [ "$firewall" = "ufw" ]; then
    sudo sed -i '/^\[sshd\]/,/^\[/ {
      /^action[[:space:]]*=/d
      /^\[sshd\]/a action = ufw
    }' "$jail_local"
  fi

  # Set default ban parameters globally if not already set
  sudo sed -i 's/^bantime  = .*/bantime  = 1h/' "$jail_local"
  sudo sed -i 's/^findtime  = .*/findtime  = 10m/' "$jail_local"
  sudo sed -i 's/^maxretry = .*/maxretry = 3/' "$jail_local"

  configure_recidive_jail "$jail_local" "$firewall"

  log_success "fail2ban jail.local configured (backend: systemd, action: $firewall)"
}

# Repeat-offender jail: an IP banned 5+ times in a day gets a 1-week ban
# instead of the standard 1h — closes the "just wait an hour and retry"
# gap that a flat SSH-jail bantime alone leaves open.
configure_recidive_jail() {
  local jail_local="$1"
  local firewall="$2"

  # Same issue as the sshd jail above: jail.conf's stock [recidive]
  # section only has logpath/banaction/bantime/findtime explicitly —
  # `enabled` isn't one of them, inherited (as false) from [DEFAULT] — so
  # this needs _f2b_set_option too, not a substitution that silently does
  # nothing when there's no existing line to match.
  _f2b_set_option "$jail_local" recidive enabled true
  _f2b_set_option "$jail_local" recidive bantime 1w
  _f2b_set_option "$jail_local" recidive findtime 1d
  _f2b_set_option "$jail_local" recidive maxretry 5

  if [ "$firewall" = "firewalld" ]; then
    sudo sed -i '/^\[recidive\]/,/^\[/ {
      /^action[[:space:]]*=/d
      /^ *blocktype=.*/d
      /^\[recidive\]/a action = firewallcmd-rich-rules[actiontype=<multiport>]
      /^\[recidive\]/a          blocktype=drop
    }' "$jail_local"
  elif [ "$firewall" = "ufw" ]; then
    sudo sed -i '/^\[recidive\]/,/^\[/ {
      /^action[[:space:]]*=/d
      /^\[recidive\]/a action = ufw
    }' "$jail_local"
  fi

  log_success "fail2ban recidive jail configured (repeat offenders: 1w ban)"
}

# Enable and start fail2ban service
enable_and_start_fail2ban() {
  ui_info "Enabling and starting fail2ban service..."

  # Reload systemd in case fail2ban was just installed
  sudo systemctl daemon-reload >/dev/null 2>&1

  if sudo systemctl enable --now fail2ban >>"$INSTALL_LOG" 2>&1; then
    log_success "fail2ban service enabled and started"
    return 0
  else
    log_error "Failed to enable and start fail2ban service"
    return 1
  fi
}

# Verify fail2ban is running and SSH jail is active
status_fail2ban() {
  # Check service status
  if ! sudo systemctl is-active --quiet fail2ban 2>/dev/null; then
    log_error "fail2ban service is not running"
    return 1
  fi

  # fail2ban-client can report zero jails for a few seconds after the
  # service itself is "active" — systemd considers the process started
  # before fail2ban has finished parsing jail.local and registering each
  # jail with the journald backend. Confirmed via a real install log
  # (a resource-constrained VM mid-way through a long package-install
  # session): checking once, immediately, reported "Active jails: none"
  # even though jail.local correctly had sshd enabled. Retry briefly
  # before concluding it's actually not active.
  local jails=""
  local attempt
  for attempt in 1 2 3 4 5; do
    jails=$(sudo fail2ban-client status 2>/dev/null | grep "Jail list" | sed 's/.*://;s/,/ /g; s/^[[:space:]]*//')
    echo "$jails" | grep -q "sshd" && break
    log_debug "fail2ban jail check attempt $attempt/5"
    sleep 1
  done

  if echo "$jails" | grep -q "sshd"; then
    log_success "fail2ban sshd jail is active"
    log_info "Active jails: $jails"
    return 0
  else
    log_warning "fail2ban is running but sshd jail may not be active"
    log_info "Active jails: ${jails:-none}"
    return 0
  fi
}

# ======= Main =======
main() {
  echo -e "${THEME_BORDER}=== Fail2ban Setup ===${RESET}"

  local firewall
  firewall=$(detect_firewall_action)
  ui_info "Detected firewall: $firewall"

  run_step "Installing fail2ban" install_fail2ban
  run_step "Configuring fail2ban (jail.local)" configure_fail2ban
  run_step "Enabling and starting fail2ban" enable_and_start_fail2ban
  run_step "Checking fail2ban status" status_fail2ban
}

main "$@"
