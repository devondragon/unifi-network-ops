#!/usr/bin/env bash
# Runs every check CI runs. No network, no controller, no credentials required.
#
#   ./tests/run.sh
set -uo pipefail
cd "$(dirname "$0")/.."

status=0

echo "== syntax =="
while IFS= read -r f; do
  if bash -n "$f"; then printf '  ok    %s\n' "$f"; else status=1; fi
done < <(git ls-files '*.sh')

if command -v shellcheck >/dev/null; then
  echo
  echo "== shellcheck =="
  # SC2012 (ls instead of find) is long-standing and deliberate here, and is info-level.
  if git ls-files '*.sh' | xargs shellcheck --severity=warning; then
    echo "  ok    no warnings"
  else
    status=1
  fi
else
  echo
  echo "== shellcheck == (not installed, skipped)"
fi

for t in tests/help-not-truncated.sh tests/credential-resolution.sh; do
  echo
  echo "== $t =="
  "./$t" || status=1
done

echo
[ "$status" -eq 0 ] && echo "ALL CHECKS PASSED" || echo "CHECKS FAILED"
exit "$status"
