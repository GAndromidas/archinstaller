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
  elif command -v ufw >/dev/null 2>&1 && { sudo -n ufw status 2>/dev/null | grep -q "Status: active"; }; then
    echo "ufw"
  else
    echo "systemd"
  fi
}

# Set multiple `key = value` pairs within one jail.conf/.local section in
# a SINGLE pass (one awk invocation per section instead of two seds per
# key — 3 file rewrites total instead of ~20). Semantics are the per-key
# setter's, proven across real installs: jail.conf's stock sections are
# minimal ([sshd] doesn't even have an `enabled =` line, it inherits
# `enabled = false` from [DEFAULT]), so plain `s/^key = .../` substitution
# silently does nothing when the key has no line yet and the jail stays
# disabled ("Active jails: none"). Instead, every existing line for a
# managed key inside the section — from `[section]` to the NEXT section
# header, blank lines included (stock [sshd] has a blank line right after
# its header, before the real aligned `port    = ssh` line; ranging to the
# first blank line missed it and left a duplicate key, which fail2ban's
# parser hard-rejects: "option 'port' in section 'sshd' already exists") —
# is deleted, then fresh `key = value` lines are written right after the
# section header. Idempotent: re-runs delete what the previous run inserted
# and write it back identically. Usage:
#   _f2b_set_options file section "key=value" ["key=value" ...]
_f2b_set_options() {
  local jail_local="${1:-}" section="${2:-}"
  [[ -n "$jail_local" && -n "$section" && $# -ge 3 ]] || return 1
  shift 2
  local joined="" pair
  for pair in "$@"; do
    [[ "$pair" == *=* ]] || return 1
    joined+="${joined:+$'\n'}$pair"
  done
  local tmp
  tmp=$(mktemp /tmp/f2b_set.XXXXXX) || return 1
  # tmp + cp (not a direct rewrite): cp into the existing file truncates in
  # place, preserving mode/ownership; the -s guard means a failed/empty awk
  # pass can never blank the jail config.
  sudo -n awk -v section="$section" -v joined="$joined" '
    BEGIN {
      n = split(joined, kv, "\n")
      for (i = 1; i <= n; i++) {
        eq = index(kv[i], "=")  # first = splits key from value
        k[i] = substr(kv[i], 1, eq - 1)
        v[i] = substr(kv[i], eq + 1)
      }
      in_sec = 0
    }
    /^\[.*\]/ {
      hdr = $0
      sub(/^\[/, "", hdr); sub(/\].*$/, "", hdr)
      if (hdr == section) {
        in_sec = 1
        print
        for (i = 1; i <= n; i++) print k[i] " = " v[i]
      } else {
        in_sec = 0
        print
      }
      next
    }
    {
      if (!in_sec) { print; next }
      line = $0
      sub(/^[ \t]+/, "", line)
      managed = 0
      for (i = 1; i <= n; i++) {
        if (substr(line, 1, length(k[i])) == k[i] && \
            substr(line, length(k[i]) + 1) ~ /^[ \t]*=/) { managed = 1; break }
      }
      if (!managed) print
    }
  ' "$jail_local" > "$tmp" || { rm -f "$tmp"; return 1; }
  [[ -s "$tmp" ]] || { rm -f "$tmp"; return 1; }
  sudo -n cp "$tmp" "$jail_local" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
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
    sudo -n cp /etc/fail2ban/jail.conf "$jail_local"
  fi

  # The 'backend' setting is the LOG-PARSING backend (valid values: auto,
  # pyinotify, gamin, polling, systemd). Arch uses journald by default, so use
  # 'systemd' to read logs from the journal. The firewall-integrating
  # 'action' is what must match the active firewall below.
  # Deliberately a plain global substitution, not _f2b_set_options: unlike
  # [sshd]/[recidive], [DEFAULT] already has a real `backend = auto` line
  # to match (confirmed against the real jail.conf), so substitution works
  # here in one pass for the whole file. The unscoped substitution also
  # touches other (disabled, irrelevant) jails' own backend= lines, but
  # since those jails stay disabled that has no functional effect.
  sudo -n sed -i "s/^backend = .*/backend = systemd/" "$jail_local"

  # Configure SSH jail. With backend=systemd, fail2ban matches SSH events
  # via the sshd filter's built-in journalmatch (_SYSTEMD_UNIT=sshd.service
  # + _COMM=sshd) — logpath is not used for journal-backed jails and is
  # deliberately left untouched here.
  #
  # Every one of these goes through _f2b_set_options, not a plain sed
  # substitution: jail.conf's stock [sshd] section only has `port`,
  # `logpath`, and `backend` explicitly — enabled/filter/maxretry/bantime/
  # findtime are all inherited from [DEFAULT] and simply don't exist as
  # lines to substitute within [sshd]. A substitution-only approach
  # silently does nothing for any of those, which is exactly why `enabled`
  # was never actually being set to true across three real installs.
  _f2b_set_options "$jail_local" sshd \
    "enabled=true" "port=ssh" "filter=sshd" \
    "maxretry=3" "bantime=1h" "findtime=10m"

  # Select the ban action to match the active firewall.
  # - firewalld: use firewallcmd-rich-rules
  # - ufw: use ufw action
  # - default: use the default iptables/nftables action from jail.conf
  if [ "$firewall" = "firewalld" ]; then
    _f2b_set_options "$jail_local" sshd \
      "action=firewallcmd-rich-rules[actiontype=<multiport>]" "blocktype=drop"
  elif [ "$firewall" = "ufw" ]; then
    _f2b_set_options "$jail_local" sshd "action=ufw"
  fi

  # Set default ban parameters globally if not already set
  sudo -n sed -i 's/^bantime  = .*/bantime  = 1h/' "$jail_local"
  sudo -n sed -i 's/^findtime  = .*/findtime  = 10m/' "$jail_local"
  sudo -n sed -i 's/^maxretry = .*/maxretry = 3/' "$jail_local"

  configure_recidive_jail "$jail_local" "$firewall"

  log_success "fail2ban jail.local configured (backend: systemd, action: $firewall)"
}

# Repeat-offender jail: an IP banned 5+ times in a day gets a 1-week ban
# instead of the standard 1h — closes the "just wait an hour and retry"
# gap that a flat SSH-jail bantime alone leaves open.
configure_recidive_jail() {
  local jail_local="${1:-}"
  local firewall="${2:-}"

  # Same issue as the sshd jail above: jail.conf's stock [recidive]
  # section only has logpath/banaction/bantime/findtime explicitly —
  # `enabled` isn't one of them, inherited (as false) from [DEFAULT] — so
  # this needs _f2b_set_options too, not a substitution that silently does
  # nothing when there's no existing line to match.
  _f2b_set_options "$jail_local" recidive \
    "enabled=true" "bantime=1w" "findtime=1d" "maxretry=5"

  if [ "$firewall" = "firewalld" ]; then
    _f2b_set_options "$jail_local" recidive \
      "action=firewallcmd-rich-rules[actiontype=<multiport>]" "blocktype=drop"
  elif [ "$firewall" = "ufw" ]; then
    _f2b_set_options "$jail_local" recidive "action=ufw"
  fi

  log_success "fail2ban recidive jail configured (repeat offenders: 1w ban)"
}

# Enable and start fail2ban service
enable_and_start_fail2ban() {
  ui_info "Enabling and starting fail2ban service..."

  # Reload systemd in case fail2ban was just installed
  sudo -n systemctl daemon-reload >/dev/null 2>&1

  if sudo -n systemctl enable --now fail2ban >>"$INSTALL_LOG" 2>&1; then
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
  if ! sudo -n systemctl is-active --quiet fail2ban 2>/dev/null; then
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
    jails=$(sudo -n fail2ban-client status 2>/dev/null | grep "Jail list" | sed 's/.*://;s/,/ /g; s/^[[:space:]]*//')
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
