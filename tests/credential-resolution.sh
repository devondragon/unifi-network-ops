#!/usr/bin/env bash
# Black-box tests for the credential block shared by all three scripts.
#
# HOW THIS OBSERVES THE CHOSEN KEY: a stub curl on PATH records whatever it was handed as
# X-API-KEY and returns nothing, so the script fails fast at its own HTTP-code check
# instead of running a whole snapshot. Asserting on the recorded value tests the real
# script end to end rather than a copy of its credential block, which would drift.
#
# The macOS Keychain branch is exercised everywhere via a stub `security`, so Linux CI
# covers code that only ever runs on macOS. The one case that needs a genuinely absent
# `security` is skipped on macOS, where /usr/bin/security always exists.
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/bin"
mkdir -p "$BIN" "$WORK/home/.config/unifi"

cat > "$BIN/curl" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in "X-API-KEY: "*) printf '%s' "${a#X-API-KEY: }" > "$CAPTURE" ;; esac
done
exit 0
STUB

# The scripts require jq to exist, but nothing reaches real jq parsing before they give up
# on the stub curl's empty response.
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/jq"

cat > "$BIN/security" <<'STUB'
#!/usr/bin/env bash
[ -n "${STUB_SECURITY_OUT:-}" ] && printf '%s\n' "$STUB_SECURITY_OUT"
exit "${STUB_SECURITY_RC:-0}"
STUB

chmod +x "$BIN/curl" "$BIN/jq" "$BIN/security"

# 192.0.2.0/24 is TEST-NET-1: if a stub is ever missed, the request goes nowhere real.
run() { # env assignments are the caller's; prints combined output
  rm -f "$WORK/capture"
  env PATH="$BIN:$PATH" HOME="$WORK/home" CAPTURE="$WORK/capture" UNIFI_GW=192.0.2.1 \
      "$@" 2>&1
}
captured() { cat "$WORK/capture" 2>/dev/null; }
write_keyfile() { printf 'file-key\n' > "$WORK/home/.config/unifi/key"; }
no_keyfile() { rm -f "$WORK/home/.config/unifi/key"; }

echo "credential resolution"

# ---- precedence ---------------------------------------------------------------------
write_keyfile
run env UNIFI_KEY=inline-key UNIFI_KEY_KEYCHAIN=svc STUB_SECURITY_OUT=keychain-key \
    "$SNAPSHOT" >/dev/null
assert_eq "$(captured)" "inline-key" "UNIFI_KEY wins over Keychain and key file"

run env UNIFI_KEY_KEYCHAIN=svc STUB_SECURITY_OUT=keychain-key "$SNAPSHOT" >/dev/null
assert_eq "$(captured)" "keychain-key" "Keychain wins over key file"

run "$SNAPSHOT" >/dev/null
assert_eq "$(captured)" "file-key" "key file used when nothing else is set"

# ---- Keychain failures are distinct, and only safe ones suggest storing a key --------
out=$(run env UNIFI_KEY_KEYCHAIN=svc STUB_SECURITY_RC=44 "$SNAPSHOT")
assert_contains "$out" "no Keychain item for service 'svc'" "rc 44 reports a missing item"
assert_contains "$out" "-U -w" "rc 44 suggests storing one"
assert_eq "$(captured)" "" "rc 44 does not fall through to the key file"

out=$(run env UNIFI_KEY_KEYCHAIN=svc STUB_SECURITY_RC=0 "$SNAPSHOT")
assert_contains "$out" "is empty" "rc 0 with no value reports an empty item"
assert_eq "$(captured)" "" "empty item does not fall through to the key file"

out=$(run env UNIFI_KEY_KEYCHAIN=svc STUB_SECURITY_RC=128 "$SNAPSHOT")
assert_contains "$out" "locked, or access was denied" "rc 128 reports locked/denied"
case "$out" in
  *"-U -w"*) bad "rc 128 must not suggest -U (it overwrites a working item)" ;;
  *)         ok  "rc 128 does not suggest -U" ;;
esac

# ---- the terse scripts report the same causes ---------------------------------------
out=$(run env UNIFI_KEY_KEYCHAIN=svc STUB_SECURITY_RC=44 "$SAMPLE_RF")
assert_contains "$out" "rc=44" "unifi-sample-rf.sh reports the security exit code"
out=$(run env UNIFI_KEY_KEYCHAIN=svc STUB_SECURITY_RC=44 "$REVERT" --snapshot "$WORK/none" --type wlanconf)
assert_contains "$out" "rc=44" "unifi-revert.sh reports the security exit code"

# ---- no credential at all names every source ----------------------------------------
no_keyfile
for s in "$SNAPSHOT" "$SAMPLE_RF"; do
  out=$(run "$s")
  assert_contains "$out" "UNIFI_KEY_KEYCHAIN" "$(basename "$s"): no-key error names UNIFI_KEY_KEYCHAIN"
done

# ---- off macOS the feature is inert -------------------------------------------------
if [ "$(uname -s)" = "Darwin" ]; then
  echo "  skip  fall-through when security is absent (macOS always has /usr/bin/security)"
else
  write_keyfile
  rm -f "$BIN/security"
  run env UNIFI_KEY_KEYCHAIN=svc "$SNAPSHOT" >/dev/null
  assert_eq "$(captured)" "file-key" "UNIFI_KEY_KEYCHAIN is ignored where security is absent"
fi

summary "credential resolution"
