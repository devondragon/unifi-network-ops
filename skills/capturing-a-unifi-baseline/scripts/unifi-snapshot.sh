#!/usr/bin/env bash
# unifi-snapshot.sh — capture a restorable, read-only baseline of a UniFi site.
#
# READ-ONLY. Issues only GETs, plus one POST to cmd/backup which asks the controller to
# generate a native .unf backup file. It never modifies configuration.
#
# Usage:
#   ./unifi-snapshot.sh [outdir]            # default: ./unifi-baseline-YYYY-MM-DD
#   ./unifi-snapshot.sh --help
#
# Env:
#   UNIFI_GW        gateway/console host or IP   (default 192.168.1.1)
#   UNIFI_SITE      internal site name           (default: auto-detected, falls back to "default")
#   UNIFI_KEY       API key, inline
#   UNIFI_KEY_KEYCHAIN         macOS Keychain service name — opt-in; unset = feature off
#   UNIFI_KEY_KEYCHAIN_ACCOUNT Keychain account for the above  (default $USER)
#   UNIFI_KEY_FILE  file containing the API key  (default ~/.config/unifi/key)
#   SKIP_BACKUP=1   skip the native .unf backup (faster; loses full-restore capability)
#
# The API key comes from: UniFi UI -> Settings -> Control Plane -> Integrations.
#
# ⚠️  OUTPUT CONTAINS CLEARTEXT SECRETS: WPA passphrases (wlanconf), the device SSH
#     password and IPS utm_token (setting), per-device x_authkey (stat_device), and the
#     entire config (.unf). Gitignore the output directory BEFORE your first run.

set -uo pipefail

case "${1:-}" in
  -h|--help)
    sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

GW="${UNIFI_GW:-192.168.1.1}"
OUT="${1:-./unifi-baseline-$(date +%F)}"
KEYFILE="${UNIFI_KEY_FILE:-$HOME/.config/unifi/key}"

# ---- credential ------------------------------------------------------------------
if [ -n "${UNIFI_KEY:-}" ]; then
  KEY="$UNIFI_KEY"
elif [ -n "${UNIFI_KEY_KEYCHAIN:-}" ] && command -v security >/dev/null; then
  # macOS only, opt-in. Fails loudly rather than falling through to $KEYFILE: if you asked
  # for the Keychain and it has no answer, a stale file key is the wrong thing to succeed with.
  KCACCT="${UNIFI_KEY_KEYCHAIN_ACCOUNT:-${USER:-$(id -un)}}"
  KEY=$(security find-generic-password -a "$KCACCT" -s "$UNIFI_KEY_KEYCHAIN" -w 2>/dev/null); KCRC=$?
  if [ -z "$KEY" ]; then
    # rc 44 is genuinely "no such item". rc 0 with no value means the item exists but was
    # stored empty — easy to do, since security's -w prompt asks twice and a mismatch on
    # the retype silently leaves you entering an empty password. Any other rc (locked
    # keychain, denied or cancelled auth prompt) means the item may well exist and be fine,
    # so do not suggest -U there: that would overwrite a working credential to fix a lock.
    if [ "$KCRC" -eq 44 ]; then
      echo "FATAL: no Keychain item for service '$UNIFI_KEY_KEYCHAIN', account '$KCACCT'." >&2
      echo "       Store one: security add-generic-password -a \"\$USER\" -s $UNIFI_KEY_KEYCHAIN -U -w" >&2
    elif [ "$KCRC" -eq 0 ]; then
      echo "FATAL: the Keychain item for service '$UNIFI_KEY_KEYCHAIN', account '$KCACCT' is empty." >&2
      echo "       Re-store it: security add-generic-password -a \"\$USER\" -s $UNIFI_KEY_KEYCHAIN -U -w" >&2
    else
      echo "FATAL: could not read the Keychain item for service '$UNIFI_KEY_KEYCHAIN', account '$KCACCT'" >&2
      echo "       (security exited $KCRC — the keychain is locked, or access was denied)." >&2
    fi
    exit 1
  fi
elif [ -r "$KEYFILE" ]; then
  KEY=$(tr -d '\r\n' < "$KEYFILE")
else
  echo "FATAL: no API key. Set UNIFI_KEY or UNIFI_KEY_KEYCHAIN, or write one to $KEYFILE (chmod 600)." >&2
  echo "       Create a key at: UniFi UI -> Settings -> Control Plane -> Integrations" >&2
  exit 1
fi

for tool in curl jq; do
  command -v "$tool" >/dev/null || { echo "FATAL: $tool is required." >&2; exit 1; }
done

req() { curl -sk -m 30 -H "X-API-KEY: $KEY" "$@"; }

# ---- reachability and auth, as two distinct failures ------------------------------
if ! curl -sk -m 10 -o /dev/null "https://${GW}" 2>/dev/null; then
  echo "FATAL: cannot reach https://${GW} — wrong host, or this machine is not on the LAN." >&2
  exit 1
fi

probe=$(req -o /dev/null -w '%{http_code}' "https://${GW}/proxy/network/integration/v1/sites")
case "$probe" in
  200) ;;
  401|403) echo "FATAL: API key rejected (HTTP $probe). Key revoked, rotated, or mistyped." >&2; exit 1 ;;
  *)   echo "FATAL: unexpected HTTP $probe from the Integration API. Is this a UniFi OS console?" >&2; exit 1 ;;
esac

# ---- site resolution --------------------------------------------------------------
# THE TWO SURFACES USE DIFFERENT SITE IDENTIFIERS. This is the single most common cause
# of a 400/404 that looks like an auth problem:
#   legacy + v2      -> internalReference, e.g. "default"
#   integration v1   -> id, a UUID, e.g. "aaaaaaaa-bbbb-...."
# The display name ("Default") is never a valid URL component.
sites_json=$(req "https://${GW}/proxy/network/integration/v1/sites")
if [ -n "${UNIFI_SITE:-}" ]; then
  SITE="$UNIFI_SITE"
else
  SITE=$(echo "$sites_json" | jq -r '.data[0].internalReference // "default"' 2>/dev/null)
  [ -z "$SITE" ] || [ "$SITE" = "null" ] && SITE="default"
fi
SITE_UUID=$(echo "$sites_json" | jq -r --arg s "$SITE" \
  '.data[] | select(.internalReference==$s) | .id' 2>/dev/null)
[ "$SITE_UUID" = "null" ] && SITE_UUID=""

A="https://${GW}/proxy/network/api/s/${SITE}"        # legacy — the useful one
V2="https://${GW}/proxy/network/v2/api/site/${SITE}" # zone firewall
I1="https://${GW}/proxy/network/integration/v1"      # clean but sparse

if ! req -o /dev/null -w '%{http_code}' "$A/stat/device" | grep -q 200; then
  echo "FATAL: legacy API rejected site '${SITE}'. Set UNIFI_SITE to the internal name." >&2
  echo "       List sites: curl -sk -H \"X-API-KEY: \$KEY\" $I1/sites | jq" >&2
  exit 1
fi

mkdir -p "$OUT/raw" || exit 1
chmod 700 "$OUT" 2>/dev/null

echo "UniFi snapshot"
echo "  gateway : $GW"
echo "  site    : $SITE  (legacy/v2)"
echo "  site id : ${SITE_UUID:-<unresolved>}  (integration v1)"
echo "  output  : $OUT"
echo

# ---- capture ----------------------------------------------------------------------
# name:url pairs. Config endpoints first (what you restore), then state (what you compare).
grab() {
  local name="$1" url="$2" f="$OUT/raw/${1}.json"
  local code
  code=$(req -o "$f" -w '%{http_code}' "$url")
  if [ "$code" != "200" ]; then
    printf '  %-22s HTTP %s\n' "$name" "$code"
    # 404 on an API key is expected for some endpoints; record it, don't fail the run.
    mv "$f" "$f.http${code}" 2>/dev/null
    return
  fi
  local n
  n=$(jq -r 'if type=="array" then length elif .data then (.data|length) else 1 end' "$f" 2>/dev/null || echo "?")
  printf '  %-22s ok (%s records)\n' "$name" "$n"
}

echo "config:"
grab networkconf      "$A/rest/networkconf"
grab wlanconf         "$A/rest/wlanconf"
grab setting          "$A/rest/setting"
grab portconf         "$A/rest/portconf"
grab portforward      "$A/rest/portforward"
grab firewallrule     "$A/rest/firewallrule"
grab firewallgroup    "$A/rest/firewallgroup"
grab routing          "$A/rest/routing"
grab user             "$A/rest/user"
grab dynamicdns       "$A/rest/dynamicdns"
grab firewall_zones   "$V2/firewall/zone"
grab firewall_policies "$V2/firewall-policies"   # NOTE: hyphen, not firewall/policy
grab trafficroutes    "$V2/trafficroutes"

echo "state:"
grab stat_device      "$A/stat/device"
grab stat_sta         "$A/stat/sta"
grab stat_health      "$A/stat/health"
grab stat_rogueap     "$A/stat/rogueap"
grab sysinfo          "$A/stat/sysinfo"
grab list_alarm       "$A/list/alarm"
grab stat_event       "$A/stat/event?_limit=500"   # commonly 404s on an API-key credential
if [ -n "$SITE_UUID" ]; then
  grab integration_devices "$I1/sites/${SITE_UUID}/devices"
  grab integration_clients "$I1/sites/${SITE_UUID}/clients"
else
  echo "  integration_*          skipped (no site UUID resolved)"
fi

date -u '+%Y-%m-%dT%H:%M:%SZ' > "$OUT/raw/_timestamp.txt"
echo "$GW $SITE" > "$OUT/raw/_target.txt"

# ---- native controller backup ------------------------------------------------------
if [ "${SKIP_BACKUP:-0}" != "1" ]; then
  echo "native backup:"
  ver=$(jq -r '.data[0].version // empty' "$OUT/raw/sysinfo.json" 2>/dev/null)
  bk=$(req -H 'Content-Type: application/json' -d '{"cmd":"backup","days":"0"}' "$A/cmd/backup")
  path=$(echo "$bk" | jq -r '.data[0].url // empty' 2>/dev/null)
  if [ -n "$path" ]; then
    # The returned path is relative to /proxy/network
    if req -o "$OUT/controller-backup-$(date +%Y%m%d).unf" "https://${GW}/proxy/network${path}"; then
      sz=$(command du -h "$OUT/controller-backup-$(date +%Y%m%d).unf" 2>/dev/null | awk '{print $1}')
      echo "  saved controller-backup-$(date +%Y%m%d).unf ($sz, controller ${ver:-unknown})"
    fi
  else
    echo "  FAILED to trigger backup — use the UI instead:"
    echo "  Settings -> System -> Backups -> Download. Do NOT change anything without one."
  fi
fi

# ---- verify -------------------------------------------------------------------------
echo
echo "verification:"
bad=0
for f in "$OUT"/raw/*.json; do
  [ -e "$f" ] || continue
  if ! jq -e . "$f" >/dev/null 2>&1; then
    echo "  SUSPECT (not valid JSON): $(basename "$f")"; bad=1
  fi
done
[ "$bad" = 0 ] && echo "  all captured files parse as JSON"

cat <<EOF

⚠️  SECRETS IN THIS DIRECTORY — gitignore it now if you have not already:
      raw/wlanconf.json   WPA passphrases in cleartext
      raw/setting.json    device SSH password, IPS utm_token
      raw/stat_device.json per-device x_authkey
      *.unf               full config including all of the above

Snapshot complete: $OUT
EOF
