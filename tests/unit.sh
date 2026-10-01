#!/usr/bin/env bash
# Unit tests for pure bootloader cmdline helpers.
# Sources the real single source (scripts/lib/boot/kernel_params.sh) —
# no mirrors, nothing to keep in sync. Only hermetic pure-function asserts
# here; live-system probes (detect_root_uuid) are intentionally untested.
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib/boot/kernel_params.sh"
PASS=0; FAIL=0

assert_eq() {
  local name="${1:-}" got="${2:-}" want="${3:-}"
  if [[ "$got" == "$want" ]]; then PASS=$((PASS+1)); echo "PASS: $name";
  else FAIL=$((FAIL+1)); echo "FAIL: $name — got '$got', want '$want'"; fi
}

# 1. Managed keys replaced, unmanaged preserved
got=$(merge_kernel_params "root=UUID=abc rw cryptdevice=UUID=x:y quiet loglevel=7" "quiet loglevel=3")
assert_eq "managed-replace-preserve-unmanaged" "$got" "root=UUID=abc rw cryptdevice=UUID=x:y quiet loglevel=3"

# 2. Stale video= stripped (cleanup-only key, no longer generated)
got=$(merge_kernel_params "root=UUID=abc video=1920x1080" "quiet")
assert_eq "stale-video-stripped" "$got" "root=UUID=abc quiet"

# 3. Exact duplicates deduped
got=$(merge_kernel_params "root=UUID=abc root=UUID=abc rw" "quiet")
assert_eq "dedupe" "$got" "root=UUID=abc rw quiet"

# 4. ensure_root_rw adds rw when root= present
got=$(ensure_root_rw "root=UUID=abc quiet")
assert_eq "ensure-rw" "$got" "root=UUID=abc quiet rw"

# 5. ensure_root_rw keeps existing rw, no duplication
got=$(ensure_root_rw "root=UUID=abc rw quiet")
assert_eq "keep-rw" "$got" "root=UUID=abc rw quiet"

# 6. strip_managed_dupes drops managed keys present in reference, keeps the rest
got=$(strip_managed_dupes "quiet splash cryptdevice=UUID=x:y" "quiet loglevel=3")
assert_eq "strip-managed" "$got" "splash cryptdevice=UUID=x:y"

# 7. strip_managed_dupes keeps unmanaged duplicates of reference keys
got=$(strip_managed_dupes "cryptdevice=UUID=x:y resume=UUID=z" "cryptdevice=UUID=w")
assert_eq "strip-keeps-unmanaged" "$got" "cryptdevice=UUID=x:y resume=UUID=z"

# 8. _merge_param_key splits key=value, passes bare tokens through
got=$(_merge_param_key "nvidia_drm.modeset=1")
assert_eq "key-of-kv" "$got" "nvidia_drm.modeset"
got=$(_merge_param_key "rw")
assert_eq "key-of-bare" "$got" "rw"

# 9. Single source: module must not define its own copy anymore
if grep -qE '^MANAGED_PARAM_KEYS=' "$ROOT_DIR/scripts/modules/bootloader_config.sh"; then
  FAIL=$((FAIL+1)); echo "FAIL: single-source — module still defines MANAGED_PARAM_KEYS"
else
  PASS=$((PASS+1)); echo "PASS: single-source"
fi

# 10. Wiring: module sources the lib
if grep -q 'lib/boot/kernel_params.sh' "$ROOT_DIR/scripts/modules/bootloader_config.sh" \
   && grep -q 'lib/boot/kernel_params.sh' "$ROOT_DIR/install.sh"; then
  PASS=$((PASS+1)); echo "PASS: wiring"
else
  FAIL=$((FAIL+1)); echo "FAIL: wiring — lib not sourced by module/install.sh"
fi

echo "unit: $PASS passed, $FAIL failed"
exit "$([ "$FAIL" -eq 0 ] && echo 0 || echo 1)"
