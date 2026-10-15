#!/usr/bin/env bash
# Unit tests for performance helpers: common.sh network/RAM/wait helpers and
# the fail2ban single-pass section setter. All hermetic (stubs, fixtures,
# temp files — no network, no hardware, no sudo).
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/common.sh"
PASS=0; FAIL=0

assert_eq() {
  local name="${1:-}" got="${2:-}" want="${3:-}"
  if [[ "$got" == "$want" ]]; then PASS=$((PASS+1)); echo "PASS: $name";
  else FAIL=$((FAIL+1)); echo "FAIL: $name — got '$got', want '$want'"; fi
}
assert_rc() {
  local name="${1:-}" want="${2:-}"; shift 2
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" == "$want" ]]; then PASS=$((PASS+1)); echo "PASS: $name";
  else FAIL=$((FAIL+1)); echo "FAIL: $name — rc $rc, want $want"; fi
}

# --- flatpak_parallel_ok honors real RAM ---------------------------------
mem_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
if [[ "$mem_kb" =~ ^[0-9]+$ ]] && (( mem_kb >= 4194304 )); then want_ram=0; else want_ram=1; fi
assert_rc "flatpak-parallel-matches-ram" "$want_ram" flatpak_parallel_ok

# --- wait_with_timeout ----------------------------------------------------
( exit 3 ) & _wjob=$!
assert_rc "wait-fast-job-finishes" 0 wait_with_timeout "$_wjob" 10
( sleep 60 ) & _wjob=$!
assert_rc "wait-timeout-returns-124" 124 wait_with_timeout "$_wjob" 0
kill "$_wjob" 2>/dev/null || true; wait "$_wjob" 2>/dev/null || true
assert_rc "wait-no-pid-fails" 1 wait_with_timeout "" 10
( exit 0 ) & _wjob=$!
assert_rc "wait-bad-timeout-falls-back-to-default" 0 wait_with_timeout "$_wjob" bogus

# --- check_internet with stubbed signals ----------------------------------
# Real ping/getent are shadowed in this shell only.
ping() {
  case "$*" in
    *8.8.8.8*) return "${PING_IP_RC:-1}" ;;
    *archlinux.org*) return "${PING_DNS_RC:-1}" ;;
    *) return 1 ;;
  esac
}
getent() { return "${GETENT_RC:-1}"; }

PING_IP_RC=0 PING_DNS_RC=1 GETENT_RC=1
assert_rc "internet-ip-only" 0 check_internet
PING_IP_RC=1 PING_DNS_RC=0 GETENT_RC=1
assert_rc "internet-dns-only" 0 check_internet
PING_IP_RC=1 PING_DNS_RC=1 GETENT_RC=0
assert_rc "internet-resolver-only" 0 check_internet
PING_IP_RC=1 PING_DNS_RC=1 GETENT_RC=1
assert_rc "internet-offline" 1 check_internet

# Parallelism proof: stubbed pings each take 3s; sequential would take 6s+.
ping() { sleep 3; return 1; }
getent() { return 1; }
SECONDS=0
check_internet >/dev/null 2>&1 || true
if (( SECONDS < 5 )); then PASS=$((PASS+1)); echo "PASS: internet-checks-parallel";
else FAIL=$((FAIL+1)); echo "FAIL: internet-checks-parallel — took ${SECONDS}s (want <5s)"; fi
unset -f ping getent

# --- _f2b_set_options against a realistic jail.conf fixture ---------------
# Extracted (not sourced): fail2ban.sh executes main() on source.
F2B_FUNCS=$(mktemp /tmp/f2b_funcs.XXXXXX) || exit 1
trap 'rm -f "$F2B_FUNCS"' EXIT
sed -n '/^_f2b_set_options() {/,/^}$/p' "$ROOT_DIR/scripts/modules/fail2ban.sh" > "$F2B_FUNCS"
[[ -s "$F2B_FUNCS" ]] || { echo "FAIL: f2b-extract"; FAIL=$((FAIL+1)); }
# shellcheck disable=SC1090
source "$F2B_FUNCS"
sudo() { if [[ "${1:-}" == "-n" ]]; then shift; fi; "$@"; }

F2B_FIXTURE=$(mktemp /tmp/f2b_jail.XXXXXX) || exit 1
trap 'rm -f "$F2B_FUNCS" "$F2B_FIXTURE"' EXIT
cat > "$F2B_FIXTURE" <<'EOF'
[DEFAULT]
bantime  = 10m
findtime  = 10m
maxretry = 5
backend = auto

[sshd]

port    = ssh
logpath = %(sshd_log)s
backend = %(sshd_backend)s

[sshd-ddos]
port = ssh
enabled = false

[recidive]
logpath  = /var/log/fail2ban.log
banaction = %(banaction_allports)s
bantime  = 1 week
findtime = 1 day
maxretry = 5
EOF
cp "$F2B_FIXTURE" "$F2B_FIXTURE.orig"

# section extractor for assertions
section_of() { awk -v s="$2" '
  /^\[.*\]/ { h=$0; sub(/^\[/,"",h); sub(/\].*$/,"",h); cur=(h==s) }
  cur { print }
' "$1"; }

_f2b_set_options "$F2B_FIXTURE" sshd \
  "enabled=true" "port=ssh" "filter=sshd" \
  "maxretry=3" "bantime=1h" "findtime=10m" || { echo "FAIL: f2b-sshd rc"; FAIL=$((FAIL+1)); }

sshd_sec=$(section_of "$F2B_FIXTURE" sshd)
for kv in "enabled = true" "port = ssh" "filter = sshd" "maxretry = 3" "bantime = 1h" "findtime = 10m"; do
  n=$(printf '%s\n' "$sshd_sec" | grep -cFx "$kv" || true)
  assert_eq "f2b-sshd-$kv-once" "$n" "1"
done
# stale aligned port line must be gone (no duplicate keys)
n=$(printf '%s\n' "$sshd_sec" | grep -cE '^[[:space:]]*port[[:space:]]*=' || true)
assert_eq "f2b-sshd-no-dup-port" "$n" "1"
# untouched sections
assert_eq "f2b-sshd-ddos-untouched" "$(section_of "$F2B_FIXTURE" sshd-ddos | grep -c 'enabled = true' || true)" "0"
assert_eq "f2b-default-untouched" "$(section_of "$F2B_FIXTURE" DEFAULT | grep -c 'backend = auto' || true)" "1"
assert_eq "f2b-recidive-untouched" "$(section_of "$F2B_FIXTURE" recidive | grep -c 'enabled = true' || true)" "0"

# idempotent: second run is byte-identical
cp "$F2B_FIXTURE" "$F2B_FIXTURE.once"
_f2b_set_options "$F2B_FIXTURE" sshd \
  "enabled=true" "port=ssh" "filter=sshd" \
  "maxretry=3" "bantime=1h" "findtime=10m" >/dev/null 2>&1
if cmp -s "$F2B_FIXTURE" "$F2B_FIXTURE.once"; then PASS=$((PASS+1)); echo "PASS: f2b-idempotent";
else FAIL=$((FAIL+1)); echo "FAIL: f2b-idempotent"; fi
rm -f "$F2B_FIXTURE.once"

# firewalld action, then recidive stack
_f2b_set_options "$F2B_FIXTURE" sshd \
  "action=firewallcmd-rich-rules[actiontype=<multiport>]" "blocktype=drop" >/dev/null 2>&1
sshd_sec=$(section_of "$F2B_FIXTURE" sshd)
assert_eq "f2b-action-once" "$(printf '%s\n' "$sshd_sec" | grep -cF 'action = firewallcmd-rich-rules[actiontype=<multiport>]' || true)" "1"
assert_eq "f2b-blocktype-once" "$(printf '%s\n' "$sshd_sec" | grep -cF 'blocktype = drop' || true)" "1"
_f2b_set_options "$F2B_FIXTURE" recidive \
  "enabled=true" "bantime=1w" "findtime=1d" "maxretry=5" >/dev/null 2>&1
rec_sec=$(section_of "$F2B_FIXTURE" recidive)
assert_eq "f2b-recidive-enabled" "$(printf '%s\n' "$rec_sec" | grep -cFx 'enabled = true' || true)" "1"
assert_eq "f2b-recidive-bantime" "$(printf '%s\n' "$rec_sec" | grep -cFx 'bantime = 1w' || true)" "1"

# unknown section leaves the file byte-identical
cp "$F2B_FIXTURE" "$F2B_FIXTURE.once"
_f2b_set_options "$F2B_FIXTURE" nosuchjail "enabled=true" >/dev/null 2>&1
if cmp -s "$F2B_FIXTURE" "$F2B_FIXTURE.once"; then PASS=$((PASS+1)); echo "PASS: f2b-unknown-section-noop";
else FAIL=$((FAIL+1)); echo "FAIL: f2b-unknown-section-noop"; fi
rm -f "$F2B_FIXTURE.once"

# guards
assert_rc "f2b-no-args" 1 _f2b_set_options
assert_rc "f2b-bad-pair" 1 _f2b_set_options "$F2B_FIXTURE" sshd "notakeyvalue"

rm -f "$F2B_FIXTURE" "$F2B_FIXTURE.orig"
trap - EXIT
rm -f "$F2B_FUNCS"

echo "unit-perf: $PASS passed, $FAIL failed"
exit "$([ "$FAIL" -eq 0 ] && echo 0 || echo 1)"
