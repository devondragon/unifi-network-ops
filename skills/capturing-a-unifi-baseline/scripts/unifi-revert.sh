#!/usr/bin/env bash
# unifi-revert.sh — restore a single UniFi object from a snapshot taken by unifi-snapshot.sh.
#
# ⚠️  THIS WRITES TO A LIVE NETWORK. A restore reprovisions devices and bounces radios
#     exactly like the change you are undoing did. Budget the same outage window.
#     DEFAULTS TO DRY-RUN. Nothing is written until you pass --apply.
#
# Usage:
#   ./unifi-revert.sh --snapshot DIR --type TYPE [--id ID | --name NAME] [--apply]
#   ./unifi-revert.sh --snapshot DIR --list
#
#   TYPE is a rest/ collection: wlanconf | networkconf | portconf | setting | user
#        or the pseudo-type 'device' for AP/switch radio+port config (stat_device).
#
# Examples:
#   ./unifi-revert.sh --snapshot ./baseline/2026-07-24 --type wlanconf --list
#   ./unifi-revert.sh --snapshot ./baseline/2026-07-24 --type wlanconf --name MySSID
#   ./unifi-revert.sh --snapshot ./baseline/2026-07-24 --type wlanconf --name MySSID --apply
#
# Env: UNIFI_GW, UNIFI_SITE, UNIFI_KEY / UNIFI_KEY_KEYCHAIN / UNIFI_KEY_FILE  (see unifi-snapshot.sh)
#
# WHY ONE OBJECT AT A TIME: a bulk revert re-applies every field of every object,
# including ones you never touched and ones that legitimately changed since. Revert the
# specific thing you broke.

set -uo pipefail

SNAP=""; TYPE=""; ID=""; NAME=""; APPLY=0; LIST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --snapshot) SNAP="$2"; shift 2;;
    --type)     TYPE="$2"; shift 2;;
    --id)       ID="$2";   shift 2;;
    --name)     NAME="$2"; shift 2;;
    --apply)    APPLY=1;   shift;;
    --list)     LIST=1;    shift;;
    -h|--help)  sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done

[ -n "$SNAP" ] && [ -n "$TYPE" ] || { echo "FATAL: --snapshot and --type are required. See --help." >&2; exit 1; }

GW="${UNIFI_GW:-192.168.1.1}"
SITE="${UNIFI_SITE:-default}"
KEYFILE="${UNIFI_KEY_FILE:-$HOME/.config/unifi/key}"
if [ -n "${UNIFI_KEY:-}" ]; then KEY="$UNIFI_KEY"
elif [ -n "${UNIFI_KEY_KEYCHAIN:-}" ] && command -v security >/dev/null; then   # macOS only, opt-in
  KCACCT="${UNIFI_KEY_KEYCHAIN_ACCOUNT:-${USER:-$(id -un)}}"
  KEY=$(security find-generic-password -a "$KCACCT" -s "$UNIFI_KEY_KEYCHAIN" -w 2>/dev/null); KCRC=$?
  [ -n "$KEY" ] || { echo "FATAL: Keychain lookup failed for service '$UNIFI_KEY_KEYCHAIN', account '$KCACCT' (security rc=$KCRC; 44 = no such item, anything else = locked or denied)." >&2; exit 1; }
elif [ -r "$KEYFILE" ]; then KEY=$(tr -d '\r\n' < "$KEYFILE")
else echo "FATAL: no API key (UNIFI_KEY, UNIFI_KEY_KEYCHAIN, or $KEYFILE)." >&2; exit 1; fi

A="https://${GW}/proxy/network/api/s/${SITE}"

case "$TYPE" in
  device) SRC="$SNAP/raw/stat_device.json"; KEYFIELD="name" ;;
  *)      SRC="$SNAP/raw/${TYPE}.json";     KEYFIELD="name" ;;
esac
[ -r "$SRC" ] || { echo "FATAL: no $SRC in snapshot. Was this type captured?" >&2; exit 1; }

if [ "$LIST" = 1 ]; then
  echo "Objects of type '$TYPE' in $SNAP:"
  jq -r --arg k "$KEYFIELD" '.data[] | "  \(._id)  \(.[$k] // .mac // "<unnamed>")"' "$SRC"
  exit 0
fi

# ---- select exactly one object ------------------------------------------------------
if [ -n "$ID" ]; then
  SEL=$(jq -c --arg i "$ID" '[.data[] | select(._id==$i)]' "$SRC")
elif [ -n "$NAME" ]; then
  SEL=$(jq -c --arg n "$NAME" --arg k "$KEYFIELD" '[.data[] | select(.[$k]==$n)]' "$SRC")
else
  echo "FATAL: pass --id or --name (or --list to see what is available)." >&2; exit 1
fi

n=$(echo "$SEL" | jq 'length')
if [ "$n" = 0 ]; then echo "FATAL: no matching object in the snapshot." >&2; exit 1; fi
if [ "$n" != 1 ]; then
  echo "FATAL: $n objects matched — refusing to guess. Use --id." >&2
  echo "$SEL" | jq -r '.[] | "  \(._id)  \(.name // .mac)"' >&2
  exit 1
fi

OBJ=$(echo "$SEL" | jq -c '.[0]')
OID=$(echo "$OBJ" | jq -r '._id')

# Strip server-managed fields. Sending these back can be rejected or can clobber state
# that legitimately moved on since the snapshot.
STRIP='del(.site_id, .last_seen, .uptime, .state, .num_sta, .satisfaction, .x_authkey,
           .known_cfgversion, .cfgversion, .upgradable, .provisioned_at, .connected_at)'

case "$TYPE" in
  device)
    MAC=$(echo "$OBJ" | jq -r '.mac')
    DEVID=$(echo "$OBJ" | jq -r '._id')
    PAYLOAD=$(echo "$OBJ" | jq -c '{radio_table, port_overrides} | with_entries(select(.value != null))')
    URL="$A/rest/device/$DEVID"
    LABEL="device $(echo "$OBJ" | jq -r '.name // .mac') ($MAC)"
    ;;
  *)
    PAYLOAD=$(echo "$OBJ" | jq -c "$STRIP")
    URL="$A/rest/$TYPE/$OID"
    LABEL="$TYPE $(echo "$OBJ" | jq -r '.name // ._id')"
    ;;
esac

# ---- show the diff against live -----------------------------------------------------
echo "Target : $LABEL"
echo "URL    : PUT $URL"
echo
LIVE=$(curl -sk -m 20 -H "X-API-KEY: $KEY" "$A/rest/${TYPE/device/device}" \
       | jq -c --arg i "$OID" '.data[] | select(._id==$i)' 2>/dev/null)
if [ -n "$LIVE" ]; then
  echo "Fields that would change (live -> snapshot):"
  diff <(echo "$LIVE" | jq -S 'to_entries|map("\(.key)=\(.value)")|.[]' -r 2>/dev/null | sort) \
       <(echo "$PAYLOAD" | jq -S 'to_entries|map("\(.key)=\(.value)")|.[]' -r 2>/dev/null | sort) \
    | grep -E '^[<>]' | sed 's/^</  live    /; s/^>/  restore /' | head -40
  echo
fi

# Blast radius depends entirely on the object type. Saying "radios will bounce" for a
# client-database write trains people to ignore the warning.
case "$TYPE" in
  device)     IMPACT="Reprovisions this device. Radios bounce; its clients drop ~30s (~100s if the target is a DFS channel).";;
  wlanconf)   IMPACT="SITE-WIDE reprovision. Every AP re-applies WLANs; expect all wireless clients to drop briefly.";;
  networkconf|portconf)
              IMPACT="Reprovisions switches/gateway carrying affected ports. Wired ports on this network may bounce.";;
  user)       IMPACT="Client DB record only. No device is reprovisioned and no radio bounces. Takes effect on the client's next association.";;
  setting)    IMPACT="Varies by setting key. Security/IPS settings usually do not bounce radios; wireless settings can.";;
  *)          IMPACT="Unknown blast radius for type '$TYPE'. Assume a reprovision until you have checked.";;
esac

if [ "$APPLY" != 1 ]; then
  cat <<EOF
DRY RUN — nothing was written.

Blast radius: $IMPACT

Re-run with --apply to restore. Before you do:
  - confirm the window with whoever depends on this network, if the impact above is non-trivial
  - re-read the object after the write and verify the RUNTIME state, not just the config
EOF
  exit 0
fi
echo "Blast radius: $IMPACT"

echo "APPLYING..."
RESP=$(curl -sk -m 30 -X PUT -H "X-API-KEY: $KEY" -H 'Content-Type: application/json' \
        -d @- "$URL" <<<"$PAYLOAD")
RC=$(echo "$RESP" | jq -r '.meta.rc // "?"')
echo "  rc=$RC"
if [ "$RC" != "ok" ]; then
  echo "  FAILED: $(echo "$RESP" | jq -r '.meta.msg // .' )" >&2
  exit 1
fi

# ---- verify by reading back ---------------------------------------------------------
# A PUT returning rc:ok does NOT mean the device applied it. Always read back.
sleep 3
echo
echo "Read-back verification:"
curl -sk -m 20 -H "X-API-KEY: $KEY" "$A/rest/$TYPE" \
  | jq --arg i "$OID" '.data[] | select(._id==$i) | del(.x_authkey, .x_passphrase, .x_ssh_password)' 2>/dev/null \
  | head -40
cat <<EOF

⚠️  Config read-back is not proof of runtime state. For radios, confirm the AP actually
    moved: stat/device -> radio_table_stats[].channel and .state == "RUN".
    A device can accept a channel change and silently keep running on the old one.
EOF
