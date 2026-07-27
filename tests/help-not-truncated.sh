#!/usr/bin/env bash
# Each script builds --help by sed-ing a fixed line range out of its own header comment.
# Add a line to the header and forget to bump the range and the tail of the header silently
# vanishes from --help — for unifi-snapshot.sh that tail is the CLEARTEXT SECRETS warning,
# which is the single most important thing in the file.
#
# So: assert every header comment line still reaches --help. Extra trailing lines are
# tolerated; missing ones are not.
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

# The header is the run of #-comments starting at line 2. The sub() mirrors the scripts'
# own `sed 's/^# \{0,1\}//'` so the two can be compared line for line.
header_lines() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$1"
}

echo "help output"

for script in "$SNAPSHOT" "$REVERT" "$SAMPLE_RF"; do
  name=$(basename "$script")
  help=$("$script" --help 2>&1)
  rc=$?
  assert_eq "$rc" "0" "$name: --help exits 0"

  missing=0
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    printf '%s\n' "$help" | grep -Fxq "$line" || { missing=$((missing + 1)); printf '        missing: %s\n' "$line"; }
  done < <(header_lines "$script")
  assert_eq "$missing" "0" "$name: every header line reaches --help"
done

summary "help output"
