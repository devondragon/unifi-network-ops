#!/usr/bin/env bash
# unifi-sample-rf.sh — sample UniFi RF metrics repeatedly and report min/median/max.
#
# READ-ONLY. Only issues GETs.
#
# WHY THIS EXISTS: channel utilization (cu_total) and tx_retries_pct on this platform are
# instantaneous and swing hard — one radio was observed at 69% and 90% hours apart with no
# config change. A single before/after pair will confirm whatever you already believe.
# This takes N samples and reports the spread so you can compare medians honestly.
#
# Usage:
#   ./unifi-sample-rf.sh [--samples N] [--interval SEC] [--label TEXT] [outfile]
#
#   --samples   number of samples        (default 6)
#   --interval  seconds between samples  (default 420 = 7 min; 6x420 covers ~42 min)
#   --label     free text recorded in the header (e.g. "pre-change", "24h settled")
#
# Env: UNIFI_GW, UNIFI_SITE, UNIFI_KEY / UNIFI_KEY_FILE  (see unifi-snapshot.sh)
#
# COMPARE LIKE WITH LIKE: run the "after" pass at the same time of day as the "before".
# Household RF load has a strong daily cycle. Also note that AP reboots reset these
# counters, so a run started minutes after a reprovision is not comparable to anything.

set -uo pipefail

SAMPLES=6; INTERVAL=420; LABEL=""; OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --samples)  SAMPLES="$2"; shift 2;;
    --interval) INTERVAL="$2"; shift 2;;
    --label)    LABEL="$2"; shift 2;;
    -h|--help)  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *)          OUT="$1"; shift;;
  esac
done

GW="${UNIFI_GW:-192.168.1.1}"
SITE="${UNIFI_SITE:-default}"
OUT="${OUT:-./unifi-rf-samples-$(date +%Y%m%d-%H%M).txt}"
KEYFILE="${UNIFI_KEY_FILE:-$HOME/.config/unifi/key}"

if [ -n "${UNIFI_KEY:-}" ]; then KEY="$UNIFI_KEY"
elif [ -r "$KEYFILE" ]; then KEY=$(tr -d '\r\n' < "$KEYFILE")
else echo "FATAL: no API key (UNIFI_KEY or $KEYFILE)." >&2; exit 1; fi

command -v jq >/dev/null || { echo "FATAL: jq is required." >&2; exit 1; }

A="https://${GW}/proxy/network/api/s/${SITE}"

mkdir -p "$(dirname "$OUT")" 2>/dev/null
exec > >(tee -a "$OUT") 2>&1

echo "=============================================================="
echo "UniFi RF sample run — $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "gateway=$GW site=$SITE samples=$SAMPLES interval=${INTERVAL}s"
[ -n "$LABEL" ] && echo "label: $LABEL"
echo "=============================================================="

code=$(curl -sk -m 15 -o /dev/null -w '%{http_code}' -H "X-API-KEY: $KEY" "$A/stat/device")
case "$code" in
  200) ;;
  000) echo "FATAL: cannot reach $GW — is this machine on the LAN?"; exit 1;;
  401|403) echo "FATAL: API key rejected (HTTP $code) — rotated or revoked?"; exit 1;;
  *)   echo "FATAL: HTTP $code from $A/stat/device — check UNIFI_SITE."; exit 1;;
esac

# The controller refreshes radio counters on its own cycle (minutes, not seconds).
# Sampling faster than that returns byte-identical readings that LOOK like independent
# samples and will make a noisy radio look perfectly stable.
if [ "$INTERVAL" -lt 120 ] && [ "$SAMPLES" -gt 1 ]; then
  echo
  echo "WARNING: interval ${INTERVAL}s is shorter than the controller's stats refresh."
  echo "         Samples will likely be duplicates. Use --interval 300 or more for a"
  echo "         real spread. Continuing anyway (useful only as a smoke test)."
fi

RAW=$(mktemp -d); trap 'rm -rf "$RAW"' EXIT

for i in $(seq 1 "$SAMPLES"); do
  ts=$(date '+%H:%M:%S')
  curl -sk -m 25 -H "X-API-KEY: $KEY" "$A/stat/device" -o "$RAW/dev.$i.json" || true
  if ! jq -e . "$RAW/dev.$i.json" >/dev/null 2>&1; then
    echo "[$ts] sample $i/$SAMPLES: FETCH FAILED, skipping"
    [ "$i" -lt "$SAMPLES" ] && sleep "$INTERVAL"
    continue
  fi
  echo
  echo "--- sample $i/$SAMPLES at $ts ---"
  jq -r '.data[]|select(.type=="uap")|.name as $n|(.radio_table_stats[]?|
    [$n,.radio,(.channel|tostring),((.num_sta//0)|tostring),
     ((.cu_total//0)|tostring),((.tx_retries_pct//0)|tostring),
     ((.satisfaction//-1)|tostring),(.state//"?")]|@tsv)' "$RAW/dev.$i.json" \
  | awk -F'\t' 'BEGIN{printf "  %-20s %-5s %-6s %-8s %-7s %-9s %-6s %s\n","AP","BAND","CH","CLIENTS","UTIL","RETRIES","SAT","STATE"}
    {printf "  %-20s %-5s %-6s %-8s %-7s %-9s %-6s %s\n",$1,$2,$3,$4,$5"%",$6"%",$7,$8}'
  jq -r '.data[]|select(.type=="udm" or .type=="ugw")|"  gateway cpu=\(.["system-stats"].cpu)% mem=\(.["system-stats"].mem)%"' "$RAW/dev.$i.json" 2>/dev/null
  [ "$i" -lt "$SAMPLES" ] && sleep "$INTERVAL"
done

got=$(ls "$RAW"/dev.*.json 2>/dev/null | wc -l | tr -d ' ')
echo
echo "=============================================================="
echo "AGGREGATE across $got successful samples"
echo "=============================================================="
for f in "$RAW"/dev.*.json; do jq -e . "$f" >/dev/null 2>&1 && cat "$f"; done \
| jq -s -r '
  def med: sort | if length==0 then 0 elif length%2==1 then .[length/2|floor]
                  else ((.[length/2-1]+.[length/2])/2) end;
  # Averaging two floats reintroduces binary-float noise (9.600000000000001).
  def r1: (. * 10 | round) / 10;
  [ .[] | .data[] | select(.type=="uap") | .name as $n
    | (.radio_table_stats[]? | {k:"\($n)|\(.radio)|ch\(.channel)",
        u:(.cu_total//0), r:(.tx_retries_pct//0), s:(.satisfaction//-1), c:(.num_sta//0)}) ]
  | group_by(.k) | .[]
  | ( .[0].k | split("|") ) as $p
  | [ $p[0], $p[1], $p[2], (length|tostring),
      ([.[].u]|min|r1|tostring), ([.[].u]|med|r1|tostring), ([.[].u]|max|r1|tostring),
      ([.[].r]|med|r1|tostring), ([.[].s]|med|r1|tostring), ([.[].c]|med|r1|tostring) ] | @tsv' \
| sort \
| awk -F'\t' 'BEGIN{printf "  %-20s %-5s %-7s %-3s %-8s %-9s %-8s %-10s %-6s %s\n","AP","BAND","CH","n","UTIL_lo","UTIL_med","UTIL_hi","RETRY_med","SAT","CLIENTS"}
  {printf "  %-20s %-5s %-7s %-3s %-8s %-9s %-8s %-10s %-6s %s\n",$1,$2,$3,$4,$5"%",$6"%",$7"%",$8"%",$9,$10}'

cat <<'EOF'

INTERPRETING THIS
  UTIL_lo/med/hi is the spread across samples. A wide spread means a single reading of
  this radio proves nothing — quote the median and the range, never one number.

  2.4 GHz airtime: <10% quiet | 10-20% normal | 20-30% investigate | >30% sustained is real.

  RETRY_med rising after a fix is NOT automatically bad. Retry % is a ratio and a
  successful fix collapses its denominator. Multiply UTIL_med x RETRY_med before and
  after: that product is the airtime actually lost to retransmission, and it is the
  number that should go down.

  SAT of -1 means no clients associated, not "bad". Ignore it.
EOF
echo
echo "Run complete $(date '+%Y-%m-%d %H:%M:%S %Z'). Output: $OUT"
