# shellcheck shell=bash
# Shared helpers. Sourced by the test scripts; not executable on its own.
#
# The script paths below are consumed by the files that source this one, which shellcheck
# cannot see from here — hence the file-wide SC2034 exemption.
# shellcheck disable=SC2034

REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
SNAPSHOT="$REPO_ROOT/skills/capturing-a-unifi-baseline/scripts/unifi-snapshot.sh"
REVERT="$REPO_ROOT/skills/capturing-a-unifi-baseline/scripts/unifi-revert.sh"
SAMPLE_RF="$REPO_ROOT/skills/tuning-unifi-wifi-rf/scripts/unifi-sample-rf.sh"

PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; return 0; }

assert_contains() { # haystack needle label
  case "$1" in
    *"$2"*) ok "$3" ;;
    *)      bad "$3" "expected to find: $2" ;;
  esac
}

assert_eq() { # actual expected label
  if [ "$1" = "$2" ]; then ok "$3"; else bad "$3" "expected [$2], got [$1]"; fi
}

summary() { # label
  printf '%s: %d passed, %d failed\n' "$1" "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ]
}
