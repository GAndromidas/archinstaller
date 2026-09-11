#!/usr/bin/env bash
# Unit tests for pure bootloader cmdline helpers.
# These functions are copied in minimal form from
# scripts/modules/bootloader_config.sh (which executes its main dispatch on
# source, so it cannot be sourced directly here). Keep in sync — if the
# real file changes, update these mirrors and vice versa.
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0

MANAGED_PARAM_KEYS="quiet loglevel nowatchdog splash vt.global_cursor_default nvidia_drm.modeset nvidia_drm.fbdev NVreg_DynamicPowerManagement NVreg_PreserveVideoMemoryAllocations NVreg_TemporaryFilePath radeon.si_support amdgpu.si_support radeon.cik_support amdgpu.cik_support amd_pstate i915.enable_guc rootflags video"

_merge_param_key() {
  local tok="$1"
  if [[ "$tok" == *=* ]]; then echo "${tok%%=*}"; else echo "$tok"; fi
}

merge_kernel_params() {
  local existing="$1" managed="$2"
  local out=()
  local tok key seen m
  # shellcheck disable=SC2086
  for tok in $existing; do
    [[ -z "$tok" ]] && continue
    key=$(_merge_param_key "$tok")
    # shellcheck disable=SC2076
    if [[ " $MANAGED_PARAM_KEYS " =~ " $key " ]]; then continue; fi
    seen=false
    for m in ${out[@]+"${out[@]}"}; do [[ "$m" == "$tok" ]] && seen=true && break; done
    [[ "$seen" == false ]] && out+=("$tok")
  done
  # shellcheck disable=SC2086
  for tok in $managed; do [[ -z "$tok" ]] && continue; out+=("$tok"); done
  echo "${out[*]}"
}

ensure_root_rw() {
  local merged="$1"
  if ! echo " $merged " | grep -qE ' root=[^ ]+ '; then
    # In unit tests there is no live root UUID — callers must supply root=.
    return 1
  fi
  if ! echo " $merged " | grep -qE '(^| )rw( |$)'; then merged="$merged rw"; fi
  echo "$merged"
}

assert_eq() {
  local name="$1" got="$2" want="$3"
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

# 4. ensure_root_rw adds rw when missing
got=$(ensure_root_rw "root=UUID=abc quiet")
assert_eq "ensure-rw" "$got" "root=UUID=abc quiet rw"

# 5. ensure_root_rw refuses rootless
if ensure_root_rw "quiet splash" >/dev/null 2>&1; then
  FAIL=$((FAIL+1)); echo "FAIL: rootless-refused — should have failed"
else
  PASS=$((PASS+1)); echo "PASS: rootless-refused"
fi

# 6. Live consistency: MANAGED keys in test mirror match the real file
real_keys=$(grep -E '^MANAGED_PARAM_KEYS=' "$ROOT_DIR/scripts/modules/bootloader_config.sh" | cut -d'"' -f2)
assert_eq "managed-keys-in-sync" "$MANAGED_PARAM_KEYS" "$real_keys"

echo "unit: $PASS passed, $FAIL failed"
exit "$([ "$FAIL" -eq 0 ] && echo 0 || echo 1)"
