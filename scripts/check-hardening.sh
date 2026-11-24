#!/bin/bash
# Refuses a build another program could inject code into (D-263). Full Disk Access is granted to
# this app's signature, so everything in the bundle has to keep the hardened runtime and none of
# the entitlements that switch its protections off.
set -euo pipefail
APP="${1:?usage: check-hardening.sh Mactivity.app}"
FORBIDDEN='get-task-allow|cs\.disable-library-validation|cs\.allow-dyld-environment-variables|cs\.allow-unsigned-executable-memory|cs\.disable-executable-page-protection|cs\.debugger'
failed=0
checked=0
while IFS= read -r -d '' file; do
  file -b "$file" | grep -q 'Mach-O' || continue
  checked=$((checked + 1))
  details="$(codesign -dv "$file" 2>&1 || true)"
  if ! grep -q 'flags=.*runtime' <<<"$details"; then
    echo "✗ No hardened runtime: ${file#"$APP"/}"
    failed=1
  fi
  if codesign -d --entitlements - --xml "$file" 2>/dev/null | grep -aEq "$FORBIDDEN"; then
    echo "✗ Forbidden entitlement: ${file#"$APP"/}"
    failed=1
  fi
done < <(find "$APP/Contents" -type f -perm -111 -print0)
[ "$checked" -gt 0 ] || { echo "✗ Found nothing to check in $APP"; exit 1; }
[ "$failed" -eq 0 ] || exit 1
echo "✓ Hardened: $checked executables, no entitlement that lets code in"
