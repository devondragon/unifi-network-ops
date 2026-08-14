---
name: capturing-a-unifi-baseline
description: Use when connecting to a UniFi controller (UDM/UDM Pro/UDM SE/Cloud Key) for the first time, auditing a UniFi site, or before making any UniFi configuration change - covers which API surface to use, what an API key can and cannot read, capturing a restorable snapshot, and which captured files contain cleartext credentials.
---

# Capturing a UniFi Baseline

## Overview

Before you read anything useful off a UniFi controller you have to pick the right API
surface, and before you change anything you need a snapshot you can restore from.

**Core principle: no write without a restorable baseline.** A UniFi config change
reprovisions devices and bounces radios. On a site with 60 wireless clients that is a real
outage. The snapshot is what turns "we broke it" into "we reverted it."

## When to Use

- First contact with any UniFi controller — you need to know which endpoints answer
- Auditing a site's config, RF, clients, firewall, or security posture
- **Before any change batch** — this is the required first step
- You got a 404 from a UniFi endpoint and don't know if it's the wrong path or the wrong credential

Not for: switch/AP CLI work over SSH, UniFi Protect/Access/Talk (different APIs).

## The three API surfaces

A UniFi OS console proxies several generations of API at once. They are not
interchangeable and the modern one is the *least* useful for auditing.

| Surface | Path prefix | Use it for |
|---|---|---|
| **Integration** (v1) | `/proxy/network/integration/v1/...` | Clean, documented, stable. Site list, device inventory. **Client records lack RSSI, TX/RX rates, and SSID** — nearly useless for RF work. |
| **Legacy** | `/proxy/network/api/s/<site>/...` | Everything actually useful: `stat/sta`, `stat/device`, `rest/wlanconf`, `rest/setting`, `rest/networkconf`, `stat/rogueap`. This is where you will live. |
| **v2** | `/proxy/network/v2/api/site/<site>/...` | Zone-based firewall (UniFi 10.x+). The old `rest/firewallrule` is empty on zone-based sites. |

All requests need `-k` (the console serves a self-signed cert).

### ⚠️ The two surfaces use different site identifiers

This is the most common cause of a 400/404 that looks like an auth failure. One site has
**two** identifiers and they are not interchangeable:

```bash
curl -sk -H "X-API-KEY: $KEY" "https://$GW/proxy/network/integration/v1/sites" | jq -c '.data[0]'
# {"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","internalReference":"default","name":"Default"}
```

| Surface | Wants | Example |
|---|---|---|
| legacy `/api/s/<x>/` | `internalReference` | `/api/s/default/stat/device` |
| v2 `/v2/api/site/<x>/` | `internalReference` | `/v2/api/site/default/firewall/zone` |
| integration `/v1/sites/<x>/` | **`id` (UUID)** | `/v1/sites/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/devices` |

`name` (the display name, "Default") is **never** a valid URL component. Passing
`default` to the Integration API returns **400**, not 404 — easy to misread as a malformed
request rather than a wrong identifier.

### Endpoint paths that don't follow the pattern

The v2 firewall endpoints are not consistently named. Verified on Network 10.4:

| Want | Path | Not |
|---|---|---|
| Zones | `/v2/api/site/<site>/firewall/zone` | — |
| Policies | `/v2/api/site/<site>/**firewall-policies**` | `firewall/policy` → 404 |

Singular-vs-plural and slash-vs-hyphen both vary. Probe with `-o /dev/null -w '%{http_code}'`
before assuming an endpoint doesn't exist.

## Authentication

**API key (preferred).** UniFi UI → Settings → Control Plane → Integrations → Create API
Key. Send as an `X-API-KEY` header. It works against **all three surfaces** above, which
is not obvious — the key is advertised for the Integration API only.

```bash
KEY=$(cat ~/.config/unifi/key)     # never hardcode, never echo
curl -sk -H "X-API-KEY: $KEY" "https://$GW/proxy/network/api/s/default/stat/device"
```

The scripts here resolve the key from `UNIFI_KEY`, then `UNIFI_KEY_KEYCHAIN` (macOS
Keychain **service** name, opt-in; account defaults to `$USER`, override with
`UNIFI_KEY_KEYCHAIN_ACCOUNT`), then `UNIFI_KEY_FILE` (default `~/.config/unifi/key`), in
that order. On macOS the Keychain equivalent of the above is:

```bash
KEY=$(security find-generic-password -a "$USER" -s unifi-api-key -w)
```

**What an API key cannot do.** Some endpoints return 404 to a key credential that a
browser session reads fine. Confirmed 404 with a key: `stat/event` (historical event log).
Do **not** conclude the feature is off or the path is wrong — test the same path with a
local-admin session before drawing any conclusion.

Endpoints that *do* answer a key despite looking like they belong in the same family:
`rest/ipsalert`. Verify per-endpoint rather than assuming a category.

**And re-verify after a controller upgrade — this is per-version, not just per-endpoint.**
`list/alarm` answered a key credential with 200 on Network **10.4.57** and returns
**`400 api.err.InvalidObject`** on **10.5.67** against the same key and the same site. A
note from a previous session is evidence about the version it was written on, nothing more.
Re-probe the endpoints you depend on after an upgrade:

```bash
for ep in list/alarm rest/ipsalert stat/event; do
  printf '%-16s %s\n' "$ep" \
    "$(curl -sk -o /dev/null -w '%{http_code}' -H "X-API-KEY: $KEY" "$API/$ep")"
done
```

Note a 400 here is not the same failure as the 400 you get from passing a site's display
name to the Integration API. Both are "malformed request" in the abstract; this one means
the endpoint no longer accepts the credential class, not that you built the URL wrong.

**Local admin login** (when you need event history):

```bash
curl -sk -c /tmp/uc.jar -H 'Content-Type: application/json' \
  -d '{"username":"<local-admin>","password":"<pw>"}' "https://$GW/api/auth/login"
curl -sk -b /tmp/uc.jar "https://$GW/proxy/network/api/s/default/stat/event?_limit=200"
```

This requires a **local** account, not a Ubiquiti SSO account with MFA.

## Capturing the snapshot

Use `scripts/unifi-snapshot.sh` (read-only, safe to run any time):

```bash
UNIFI_GW=192.168.1.1 UNIFI_KEY_FILE=~/.config/unifi/key \
  ./scripts/unifi-snapshot.sh ./baseline/$(date +%F)
```

It captures every config and state endpoint, plus a **native `.unf` controller backup**,
which is the only true full-restore path. Run `--help` for options.

The `.unf` backup is your nuclear rollback (UI → Settings → System → Backups → Restore).
The per-endpoint JSON is your *surgical* rollback — you can PUT a single object back
without reverting everything else.

### Verify the snapshot before trusting it

An empty or truncated capture is worse than none, because you'll believe you're covered.

```bash
for f in baseline/*/raw/*.json; do
  jq -e '.data|length' "$f" >/dev/null 2>&1 || echo "SUSPECT: $f"
done
```

## ⚠️ Captured files contain cleartext credentials

Verified across UniFi Network 9.x–10.x. Every one of these is a secret-bearing file:

| File | Contains |
|---|---|
| `rest/wlanconf` | **WPA passphrases in cleartext** (`x_passphrase`) |
| `rest/setting` | Device SSH password (`x_ssh_password`), IPS subscription `utm_token` |
| `stat/device` | Per-device `x_authkey`, and `x_ssh_password` on some models |
| `*.unf` | Full config including all of the above |

**Add these to `.gitignore` before the first capture, not after.** Git history is
forever; a passphrase committed once is a passphrase to rotate.

```gitignore
baseline/*/raw/
*.unf
*.key
.unifi_key
```

If you must track a captured file, scrub it first — do not simply un-ignore it.

Note also that any transcript of your audit session contains full topology and every
client MAC even if the API key itself is redacted.

## Building a surgical rollback

For each object you intend to change, save its pre-change state as a ready-to-PUT payload:

```bash
# Save the exact current state of one radio config
curl -sk -H "X-API-KEY: $KEY" "$API/stat/device" \
  | jq --arg mac "$MAC" '.data[] | select(.mac==$mac) | {radio_table}' \
  > revert/radio_${NAME}.json
```

Then `scripts/unifi-revert.sh` PUTs any saved payload back. **It defaults to dry-run** —
pass `--apply` to actually write.

Reverting is itself a change: it reprovisions and bounces radios exactly like the original
did. Budget the same outage window.

## Common Mistakes

| Mistake | Consequence |
|---|---|
| Auditing from the Integration API's client records | No RSSI, no rates, no SSID. You will miss every sticky-client and RF problem. |
| Treating a 404 as "feature disabled" | `stat/event` 404s on a key credential but works in a browser. You'll report a gap that isn't one. |
| Using the display site name in the URL | `/api/s/Default/` 404s; the internal name is `default`. |
| Capturing after the first change | The baseline now includes your change. You cannot get back. |
| `.gitignore` written after the first commit | Passphrases are in history. Rotate them. |
| Trusting a snapshot you didn't verify | Empty `data` arrays look like valid JSON. |

## Real-World Impact

On a 10-device / 90-client site, the full snapshot takes about 40 seconds and produced
the artifact that made three separate incidents recoverable — including one where four
WLANs were overwritten with a copy of a fourth and had to be restored field-for-field
from `raw/wlanconf.json`.

**REQUIRED NEXT:** before writing anything, read `applying-unifi-changes`.
