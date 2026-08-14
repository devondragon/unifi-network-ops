---
name: reviewing-unifi-security
description: Use when auditing the security posture of a UniFi network - zone-based firewall policies, VLAN segmentation, guest isolation, IDS/IPS configuration, port forwards, management exposure, or WPA/SSID settings. Also use when deciding which security findings are worth recommending to a specific owner.
---

# Reviewing UniFi Security

## Overview

A UniFi security review is mostly reading the zone firewall correctly and then being
honest about which findings actually matter for *this* network.

**Core principle: a finding is only worth raising if it is real under the owner's threat
model.** A generic hardening checklist applied to a specific site produces confident
recommendations that the owner will correctly reject — and every rejected recommendation
costs you credibility on the ones that matter.

## When to Use

- Auditing a UniFi site's firewall, segmentation, or exposure
- Reviewing IDS/IPS configuration or deciding between detection and prevention
- Writing up security findings for a network owner
- Verifying segmentation still holds after a change

**REQUIRED FIRST:** `capturing-a-unifi-baseline`.

---

## Part 1 — Read the zone firewall correctly

UniFi 10.x uses **zone-based** policies. On a zone-based site the legacy
`rest/firewallrule` collection is typically **empty** — reading it and reporting "no
firewall rules" is wrong. Use:

```
/proxy/network/v2/api/site/<site>/firewall/zone         # zones
/proxy/network/v2/api/site/<site>/firewall-policies     # policies (note: hyphen)
```

### ⚠️ An ALLOW between two zones usually is not an opening

Zone pairs commonly carry both an ALLOW and a BLOCK. A naive "does an ALLOW exist between
these zones" check — or a `sort -u` over the matrix — makes fully-protected zones look
wide open. Two things make an ALLOW harmless:

- **`connection_states: ["RELATED","ESTABLISHED"]`** — it is the *return path* for traffic
  that some other policy legitimately opened, not a way in.
- **`index` ordering** — policies are first-match-wins. A specific ALLOW sits at a low
  index and the catch-all BLOCK sits at `2147483647` (INT_MAX).

Note that **`connection_states: []` means ALL, not none.** On one real site: 71 policies
with `[]`, 14 with `RELATED,ESTABLISHED`, 12 with `INVALID`.

The policy schema does **not** carry zone names — only `source.zone_id` and
`destination.zone_id`. You have to join against the zones collection:

```bash
jq -r --slurpfile z raw/firewall_zones.json '
  ($z[0] | map({key:._id, value:.name}) | from_entries) as $zn
  | .[] | select(.enabled)
  | "\($zn[.source.zone_id] // "?") -> \($zn[.destination.zone_id] // "?")  \(.action)  " +
    "[\(.connection_states | if length==0 then "ALL" else join(",") end)]  idx=\(.index)  \(.name)"
' raw/firewall_policies.json | sort
```

**Worked example — IoT → Internal on a correctly segmented site:**

```
idx=30000       ALLOW  [RELATED,ESTABLISHED]  Allow Main Control to IOT (Return)
idx=2147483647  BLOCK  [ALL]                  Block All Traffic
```

An ALLOW *does* exist from IoT to Internal, and the zone is nonetheless fully protected:
the ALLOW only carries return traffic for connections Internal initiated, and everything
else hits the catch-all BLOCK. Reporting this as "IoT can reach Internal" is wrong.

### Segmentation invariants worth verifying explicitly

Check each direction rather than eyeballing a matrix:

| Invariant | Why |
|---|---|
| IoT → Internal BLOCK | The main point of an IoT VLAN |
| IoT → IoT BLOCK | Intra-zone isolation; without it one compromised device reaches every other |
| Guest → Internal BLOCK | |
| Guest → IoT BLOCK | Frequently missed |
| External → everything BLOCK | |
| Port forwards | `rest/portforward` — count should usually be 0 |

**Re-verify all of them after any firewall or network change**, especially after deleting
a zone or network, since deletes cascade policies.

---

## Part 2 — IDS/IPS

### Valid modes

```jsonc
{"ips_mode": "disabled"}   // off
{"ips_mode": "ids"}        // detection only — logs, does not drop
{"ips_mode": "ips"}        // prevention — drops
```

`"detection"` and `"prevention"` are **not valid** and return `api.err.InvalidPayload`.

### The constraint is RAM, not throughput

Gateways are rated far above most WAN speeds for IDS/IPS (e.g. 3.5 Gbps against a 713
Mbps line), and CPU typically sits low. **Memory is what actually limits it.** Enabling
the ruleset moved one gateway from 66% → 72% RAM.

Recommended path: enable `ids` first, run a week, and promote to `ips` only if memory
stays comfortably under ~85%. `memory_optimized: true` is worth confirming.

### Know what IPS does *not* see

IPS inspects **routed** traffic. Same-VLAN LAN transfers never touch it — a NAS pulling
at 2.5/10 Gbps from a client on the same VLAN is invisible to it. Do not size or justify
IPS on total LAN throughput.

### Zero alerts is not automatically proof of anything

`rest/ipsalert` returning 200 with 0 items is plausible for a site with no inbound
exposure. But some alert endpoints refuse an API-key credential outright, so you may be
unable to distinguish "nothing happened" from "this credential cannot read alerts."
**State which of the two you actually verified**, and name the endpoint that gave you the
200 — "zero alerts" backed by one working endpoint is a narrower claim than it sounds.

Which endpoints answer a key **changes across controller versions**: `list/alarm` answered
200 on Network 10.4.57 and returns `400 api.err.InvalidObject` on 10.5.67. So a report that
was honest when written can quietly decay into an overclaim. Re-probe before repeating a
zero-alert finding from a previous session — see `capturing-a-unifi-baseline`.

---

## Part 3 — Triage findings against the owner's threat model

This is the part that separates a useful review from a checklist dump.

Ask, before recommending anything: **what is this network's actual exposure, and what
does the fix cost?**

A worked example — a remote residential site where the nearest neighbor is far outside
WiFi range. Under that threat model, an attacker within RF range is already physically on
the property, which changes the calculus completely:

| Generic finding | Verdict on this site | Reasoning |
|---|---|---|
| Weak WPA PSK (8–9 chars) | **Declined** | Dozens of IoT devices, many extremely hard to re-pair. RF range implies physical presence. |
| Open guest SSID | **Declined** | Same reasoning. Guest is walled off from Internal and IoT at the firewall. |
| No WPA3 / PMF | **Dropped** | PMF's value is blocking forced-deauth → handshake capture. If physical proximity is already assumed, that attack is not the binding constraint. |
| Merge SSIDs for band steering | **Dropped** | Would force re-pairing the same hard-to-pair IoT. |
| IPS disabled | **Accepted** | Real, cheap, reversible. Enabled in detection mode. |
| Segmentation | **Already correct** | Say so plainly. |

Note the pattern: the declined items all cost significant re-pairing work to mitigate a
risk the site's physical isolation already handles. The accepted item was cheap and
reversible.

**Rules that follow from this:**

1. **Say plainly what is already right.** Correct segmentation is the hard part; leading
   with it establishes that you actually read the config.
2. **Record declined items and why — then do not re-raise them.** A decision log is part
   of the deliverable. Re-proposing a considered rejection reads as not having listened.
3. **Separate "is a real risk here" from "is a deviation from best practice."** Both are
   worth listing; only the first is worth pushing.
4. **Price every recommendation.** "Rotate the PSK" is one sentence to write and a weekend
   of re-pairing thermostats to execute.

---

## Part 4 — Handle the captured data as the secret it is

An audit produces files containing live credentials. See `capturing-a-unifi-baseline` for
the full list; the short version:

| File | Contains |
|---|---|
| `rest/wlanconf` | WPA passphrases, cleartext |
| `rest/setting` | Device SSH password, IPS `utm_token` |
| `stat/device` | Per-device `x_authkey` |
| `*.unf` | Everything above |

Gitignore before the first capture. **Also treat the audit transcript as sensitive** — it
contains full topology and every client MAC even when the API key itself is redacted.

**If an API key was ever pasted into a chat, a ticket, or a transcript, recommend
rotating it** (UniFi UI → Settings → Control Plane → Integrations). Write your tooling to
read the key from a file or environment variable so rotation breaks nothing.

---

## Also worth checking (usually low priority)

| Setting | Where | Note |
|---|---|---|
| UPnP / NAT-PMP | `rest/setting` `usg` | Secure mode on is the meaningful part |
| Device SSH | `rest/setting` `mgmt` | Often password auth with 0 keys |
| Teleport / remote access | `rest/setting` | |
| DNS | `rest/networkconf` | A single internal resolver with no secondary is an availability risk, not a security one — label it correctly |
| DNS filtering | `rest/setting` `dns_filtering` | Frequently enabled globally but set to `none` per network, which does nothing |

## Common Mistakes

| Mistake | Reality |
|---|---|
| Reading `rest/firewallrule` on a 10.x site | Empty. Zone policies live at the v2 endpoint. |
| "An ALLOW exists between these zones, so it's open" | Check `connection_states`; it is probably the ESTABLISHED return path. |
| `ips_mode: "detection"` | Invalid. It is `ids`. |
| Sizing IPS against LAN throughput | It only inspects routed traffic. RAM is the constraint. |
| "Zero alerts, so it's working" | Confirm the endpoint answers your credential at all. |
| Generic hardening checklist | Findings the owner will reject, costing credibility on real ones. |
| Re-raising a declined item | Keep a decision log and honor it. |
| Reporting "no firewall rules configured" | You read the wrong collection. |
