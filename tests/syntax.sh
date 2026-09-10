#!/usr/bin/env bash
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
status=0
while IFS= read -r -d '' file; do
  if ! bash -n "$file"; then
    echo "FAIL: $file" >&2
    status=1
  fi
done < <(find "$ROOT_DIR" -type f -name "*.sh" -not -path "*/.git/*" -print0)
if (( status == 0 )); then
  echo "PASS: all Bash scripts pass bash -n"
fi
exit "$status"
