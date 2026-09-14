#!/usr/bin/env bash
# Integration test harness for archinstaller.
#
# Phase 1 (default, safe everywhere): static checks — syntax smoke test,
# cmdline-merge unit tests, and shellcheck gated on errors only (warnings
# are pre-existing tech debt, tracked but not gating).
#
# Phase 2 (--run-vm, needs a KVM host): boots the official Arch ISO in
# QEMU with this project shared into the guest, so a real archinstall +
# archinstaller cycle can be exercised. Semi-automated by design: the
# in-guest archinstall run itself is interactive and version-sensitive,
# so the harness prepares everything, prints the exact in-guest commands,
# and waits — it never pretends an unattended full install happened.
#
# Phase 2 never runs unless explicitly requested, and skips (exit 0) with
# a clear reason when prerequisites are missing, so CI stays green.
#
# Usage:
#   bash tests/integration.sh            # phase 1 only
#   bash tests/integration.sh --run-vm   # phase 1 + VM boot (needs ARCH_ISO)
#
# Env for phase 2:
#   ARCH_ISO     path to an official Arch Linux ISO (required)
#   ITEST_MEM    guest RAM in MB (default 4096)
#   ITEST_DISK   guest disk size in GB (default 20)

set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_VM=false
[[ "${1:-}" == "--run-vm" ]] && RUN_VM=true

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
skip() { echo "SKIP: $1"; }

phase() { echo ""; echo "=== $1 ==="; }

# ---------- Phase 1: static checks ----------
phase "Phase 1 — static checks"

if bash "$ROOT_DIR/tests/syntax.sh"; then
  pass "syntax smoke test"
else
  fail "syntax smoke test"
fi

if bash "$ROOT_DIR/tests/unit.sh"; then
  pass "bootloader cmdline unit tests"
else
  fail "bootloader cmdline unit tests"
fi

if command -v shellcheck &>/dev/null; then
  # Error severity only: warning-level findings predate this harness.
  if shellcheck --severity=error -x "$ROOT_DIR/install.sh" "$ROOT_DIR"/scripts/common.sh \
    "$ROOT_DIR"/scripts/verify.sh "$ROOT_DIR"/scripts/lib/*.sh \
    "$ROOT_DIR"/scripts/modules/*.sh "$ROOT_DIR"/tests/*.sh; then
    pass "shellcheck (error severity)"
  else
    fail "shellcheck (error severity)"
  fi
else
  skip "shellcheck not installed — error-severity gate not run"
fi

# ---------- Phase 2: VM boot (opt-in only) ----------
if [[ "$RUN_VM" != true ]]; then
  skip "phase 2 VM boot (pass --run-vm on a KVM host with ARCH_ISO set)"
  echo ""
  echo "integration: $PASS passed, $FAIL failed"
  exit "$([ "$FAIL" -eq 0 ] && echo 0 || echo 1)"
fi

phase "Phase 2 — VM boot"

need() {
  if ! command -v "$1" &>/dev/null; then
    skip "phase 2: missing prerequisite '$1'"
    return 1
  fi
  return 0
}

need qemu-system-x86_64 || { echo "integration: $PASS passed, $FAIL failed"; exit 0; }
need qemu-img || { echo "integration: $PASS passed, $FAIL failed"; exit 0; }
[[ -n "${ARCH_ISO:-}" && -f "${ARCH_ISO:-}" ]] || {
  skip "phase 2: set ARCH_ISO to an official Arch Linux ISO path"
  echo "integration: $PASS passed, $FAIL failed"
  exit 0
}

MEM="${ITEST_MEM:-4096}"
DISKGB="${ITEST_DISK:-20}"
WORKDIR="/tmp/archinstaller-itest"
mkdir -p "$WORKDIR" || { fail "phase 2: cannot create $WORKDIR"; echo "integration: $PASS passed, $FAIL failed"; exit 1; }

DISK="$WORKDIR/disk.qcow2"
if [[ ! -f "$DISK" ]]; then
  if qemu-img create -f qcow2 "$DISK" "${DISKGB}G"; then
    pass "phase 2: created ${DISKGB}G test disk"
  else
    fail "phase 2: disk creation failed"
    echo "integration: $PASS passed, $FAIL failed"
    exit 1
  fi
else
  echo "Reusing existing test disk: $DISK (delete it for a from-scratch run)"
fi

# OVMF firmware varies by distro — try common locations, fall back to BIOS.
OVMF_CODE=""
for candidate in /usr/share/edk2-ovmf/x64/OVMF_CODE.fd \
  /usr/share/edk2/ovmf/OVMF_CODE.fd \
  /usr/share/OVMF/OVMF_CODE.fd; do
  [[ -f "$candidate" ]] && OVMF_CODE="$candidate" && break
done

QEMU_FW_ARGS=()
if [[ -n "$OVMF_CODE" ]]; then
  cp -f "$OVMF_CODE" "$WORKDIR/OVMF_CODE.fd" 2>/dev/null || true
  QEMU_FW_ARGS=(-drive "if=pflash,format=raw,readonly=on,file=$WORKDIR/OVMF_CODE.fd")
  echo "UEFI boot via $OVMF_CODE"
else
  skip "phase 2: no OVMF found — falling back to BIOS boot"
fi

KVM_ARGS=()
[[ -c /dev/kvm ]] && KVM_ARGS=(-enable-kvm) || echo "No /dev/kvm — emulation will be slow (TCG)"

cat <<EOF

Starting VM: ${MEM}MB RAM, ${DISKGB}G disk, ISO: ${ARCH_ISO}
This project is shared into the guest at /mnt/archinstaller (9p, read-only).

In-guest steps:
  1. Boot the ISO, run 'archinstall' (or reuse a saved config) and install.
  2. Reboot into the new system (send Ctrl-Alt-Del, or 'system_powerdown').
  3. Mount the shared folder and run the installer:
       mount -t 9p -o version=9p2000.L,ro hostshare /mnt/archinstaller
       cd /mnt/archinstaller && ./install.sh --dry-run   # preview first
       cd /mnt/archinstaller && ./install.sh             # for real
  4. After reboot:  bash scripts/verify.sh   (or ./install.sh --check)

Press Ctrl+A then X to quit QEMU when done. The harness waits here —
close QEMU to finish phase 2.
EOF

if qemu-system-x86_64 "${KVM_ARGS[@]}" -m "$MEM" -smp 2 \
  "${QEMU_FW_ARGS[@]}" \
  -drive "file=$DISK,format=qcow2,if=virtio" \
  -cdrom "$ARCH_ISO" -boot order=d \
  -nic "user,hostfwd=tcp::2222-:22" \
  -fsdev "local,path=$ROOT_DIR,mount_tag=hostshare,security_model=none,readonly=on,id=hostshare" \
  -device virtio-9p-pci,fsdev=hostshare,mount_tag=hostshare \
  -nographic; then
  pass "phase 2: VM session completed (review in-guest results above)"
else
  fail "phase 2: QEMU exited abnormally"
fi

echo ""
echo "integration: $PASS passed, $FAIL failed"
exit "$([ "$FAIL" -eq 0 ] && echo 0 || echo 1)"
