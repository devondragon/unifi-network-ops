---
name: applying-unifi-changes
description: Use before writing any configuration to a UniFi controller - PUT/POST/DELETE against wlanconf, networkconf, rest/device, radio settings, firewall, or IPS. Covers merge-not-replace PUT semantics, verifying runtime state rather than stored config, provisioning and DFS outage windows, referential integrity on deletes, and the shell traps that have silently corrupted payloads.
---

# Applying UniFi Changes

## Overview

Reading a UniFi controller is safe. Writing to one is not. A single config PUT
reprovisions devices, bounces radios, and drops every wireless client on the affected APs.

**Core principle: `rc: ok` means the controller accepted your payload. It does not mean
the device applied it, and it does not mean you changed what you think you changed.**

Every incident described in this skill happened on a real network with a competent
operator. None were exotic.

## When to Use

Before **any** of: `PUT /rest/wlanconf`, `PUT /rest/device`, `PUT /rest/networkconf`,
`PUT /rest/setting/*`, `DELETE /rest/*`, `POST /cmd/*`.

**REQUIRED FIRST:** `capturing-a-unifi-baseline`. If you do not have a snapshot and a
native `.unf` backup, you are not ready to write.

---

## The gate — before the first write

1. **Snapshot captured and verified** (`capturing-a-unifi-baseline`)
2. **Native `.unf` backup downloaded** — the only full-restore path
3. **Per-change revert payload saved** for each object you will touch
4. **Owner has approved this specific change and its timing.** Not "approved the project"
   — this change, this window. A radio change drops clients; someone may be on a call.
5. **You can state the blast radius in one sentence**: which devices reprovision, how many
   clients drop, for how long.

Outage budget:

| Change | Downtime |
|---|---|
| Non-DFS channel or power change | ~30 s on that radio |
| **DFS channel change** | **~100 s** (~77 s of it Channel Availability Check, radio silent) |
| WLAN (`wlanconf`) change | Site-wide reprovision — every AP |
| Network/VLAN delete | Reprovisions switches with affected ports |

---

## PUT merges, it does not replace

`PUT /rest/<collection>/<id>` **merges** your payload into the stored object.

**Consequences:**
- Omitting a field leaves the stored value intact. You **cannot clear a field by leaving
  it out** of the payload.
- You do not need to send the whole object — send only what you're changing. This is
  safer, not lazier.
- Some fields cannot be cleared at all: `x_passphrase: ""` is rejected by validation even
  on an `open` network, and `virtual_network_override_id: null` returns `InvalidPayload`.
  To "remove" such a reference you must **repoint it at another valid object**, not null it.

---

## ⚠️ Never build a payload in a temp file inside a loop

This is the single most destructive trap in this skill. It caused a total 2.4 GHz outage.

```bash
# ☠️  BROKEN — do not do this
for ssid in a b c d; do
  jq ... > /tmp/payload.json          # zsh `noclobber` makes `>` FAIL on an existing file
  curl -X PUT ... -d @/tmp/payload.json
done
```

Under zsh with `noclobber` set, `>` **fails** on an existing file. Only the first
iteration writes a payload. Every later iteration silently re-sends the **first** one.
The result: four different SSIDs were overwritten with a copy of the first, all four
briefly became the same network on the same band, and every 2.4 GHz-only device in the
building had no SSID to join.

```bash
# ✅ CORRECT — pipe jq straight into curl, nothing touches disk
for id in "${ids[@]}"; do
  jq -nc --arg id "$id" '{minrate_ng_data_rate_kbps:6000, minrate_setting_preference:"manual"}' \
  | curl -sk -X PUT -H "X-API-KEY: $KEY" -H 'Content-Type: application/json' \
         -d @- "$API/rest/wlanconf/$id"
  # then RE-READ this object before moving to the next one
done
```

**Re-read and verify each object after each write.** Not at the end of the loop — after
each write. The outage above ran for minutes because verification was batched to the end.

### Related shell traps

- **`GID` is a reserved integer variable in zsh.** Assigning a hex string throws "bad math
  expression". Same class as `UID`, `EUID`, `PPID`. Never name a loop variable `GID`.
- **`du` is commonly aliased** (e.g. to `dust`) in modern shells; use `command du` in scripts.

---

## Verify runtime state, not stored config

A device can accept a config change and silently continue running the old value.

Observed: a long-range AP accepted a channel change with `rc: ok`, the config read back
correct, and `radio_table_stats` showed it **still on the old channel**. Transmit power
from the same PUT applied fine — so a partial application looks like a full one.

```bash
# After ANY radio change, check the runtime, not the config you just wrote:
curl -sk -H "X-API-KEY: $KEY" "$API/stat/device" \
| jq -r --arg m "$MAC" '.data[]|select(.mac==$m)|.radio_table_stats[]
   | "\(.radio) ch=\(.channel) state=\(.state)"'
# Want: state == "RUN" on the channel you asked for.
# DFS_WAIT is normal and transient (~77s). INIT for minutes is not.
```

If the runtime disagrees with the config:

```bash
curl -sk -X POST -H "X-API-KEY: $KEY" -H 'Content-Type: application/json' \
  -d "{\"cmd\":\"force-provision\",\"mac\":\"$MAC\"}" "$API/cmd/devmgr"
```

---

## Silent no-ops: settings gated by other settings

Some values are ignored unless a companion field is also set. The PUT returns `rc: ok`
and nothing changes.

| You set | Also required | Otherwise |
|---|---|---|
| `minrate_ng_data_rate_kbps` | `minrate_setting_preference: "manual"` | Silently ignored while `"auto"` |
| `tx_power: <n>` | `tx_power_mode: "custom"` | Named modes ignore the value |

**Always diff the object after the write.** `rc: ok` proves nothing about a gated field.

### jq's `//` operator lies about `false`

```bash
jq '.min_rssi_enabled // "ABSENT"'   # returns "ABSENT" for a legitimate `false`
jq 'has("min_rssi_enabled")'         # ✅ correct presence test
```

`//` treats `false` and `null` identically. Auditing boolean settings with `//` will
report disabled features as missing ones.

Measured on a live 5-AP site: across 10 radios, `//` reported **5 as "ABSENT"** while
`has()` returned **true for all 10**. Those 5 were not missing the field — they had
`min_rssi_enabled: false`. An audit built on `//` would have concluded the setting was
unavailable on half the radios.

---

## Sequencing: don't batch change classes

Batching a radio change and a WLAN change close together triggers **overlapping
reprovisions**. On one site this left three APs of the same model and firmware wedged in
`state=INIT` with `channel=null` and zero VAPs up, for more than six minutes.

Diagnostics at the time: `dev_state=1` and 113–162 day uptimes, so they had not crashed —
the radios simply never came back up. A field-level diff against baseline showed no
config corruption. One of the wedged APs had a channel that **never changed**. Reverting
the config did not recover them, and `force-provision` did not either.

**Recovery:** `POST /cmd/devmgr {"cmd":"restart","mac":"<mac>"}`.

**Prevention:** apply one change class at a time and confirm every AP reaches `RUN`
before starting the next class. Order that works well:

1. Radio channel/power (per AP, verify `RUN` after each)
2. Wait for full settle
3. WLAN / `wlanconf` changes (site-wide reprovision)
4. Wait for full settle
5. Network/VLAN structural changes
6. Security settings (IPS, firewall) — usually no radio impact

---

## Deleting a network needs a real reference audit

UniFi enforces referential integrity and will reject the delete. Checking shared port
profiles, SSID bindings, and current clients is **not sufficient** — two reference types
are easy to miss:

| Error | Hidden reference | Where |
|---|---|---|
| `NETWORK_IS_USED_BY_PORT_NATIVE_NETWORK` | Per-port native VLAN override | `stat/device` → `port_overrides[].native_networkconf_id` |
| `NETWORK_IS_USED_BY_CLIENT_AS_VIRTUAL_NETWORK` | Per-client VLAN override | `rest/user` → `virtual_network_override_id` |

Both survive long after the device is gone — one was last seen five months earlier, the
other eight. **Treat UniFi's rejection as correct and go find the reference.**

```bash
# Find every reference to a network id before attempting a delete
NID=<network_id>
curl -sk -H "X-API-KEY: $KEY" "$API/stat/device" \
  | jq --arg n "$NID" '.data[]|select(.port_overrides[]?.native_networkconf_id==$n)|{name,mac}'
curl -sk -H "X-API-KEY: $KEY" "$API/rest/user" \
  | jq --arg n "$NID" '.data[]|select(.virtual_network_override_id==$n)|{name,mac,_id}'
```

Clear each binding by **repointing it at another network** (null is rejected), then delete.

### Deleting a firewall zone cascades

Removing a zone deletes every policy referencing it. Before deleting, confirm none of
those policies are user-defined — check for a `predefined`/`rule_index` marker and count
them. One cleanup cascaded 18 policies, all boilerplate, losing nothing; that was verified
*first*, not assumed.

---

## Moving clients without a full bounce

- **A `tx_power` change alone does not drop clients**, so it is not a usable way to force
  reassociation.
- To move specific clients surgically:
  `POST /cmd/stamgr {"cmd":"kick-sta","mac":"<client_mac>"}`
- Compare each client to baseline **by MAC** and kick only the ones measurably worse off.
  After an outage, IoT devices latch onto whichever AP answered first and roam poorly
  afterward; a blanket kick just re-randomizes them.

---

## Quick Reference

| Command | Purpose |
|---|---|
| `POST /cmd/devmgr {"cmd":"force-provision","mac":M}` | Push config to a device that ignored it |
| `POST /cmd/devmgr {"cmd":"restart","mac":M}` | Recover a device wedged in `INIT` |
| `POST /cmd/stamgr {"cmd":"kick-sta","mac":M}` | Force one client to reassociate |
| `POST /cmd/backup {"cmd":"backup","days":"0"}` | Generate a native `.unf` backup |
| `stat/device → radio_table_stats[].state` | The only trustworthy radio status |

Valid enum values that are easy to guess wrong:

| Field | Valid | Rejected |
|---|---|---|
| `ips_mode` | `disabled` / `ids` / `ips` | `detection`, `prevention` → `api.err.InvalidPayload` |
| `tx_power_mode` | `auto` / `low` / `medium` / `high` / `custom` | anything else |
| `minrate_setting_preference` | `auto` / `manual` | — |

## Red Flags — stop before writing

- You have no `.unf` backup
- You have not saved a revert payload for this specific object
- You are looping over objects building payloads in a file
- You are about to change a radio *and* a WLAN in the same batch
- You verified with "the PUT returned ok"
- You are about to delete a network you "confirmed is unreferenced" by checking only port profiles
- Nobody has agreed to an outage window

## Common Mistakes

| Mistake | Reality |
|---|---|
| "`rc: ok` means it worked" | Gated fields silently no-op. Read back and diff. |
| "Config reads back right, so it applied" | Runtime can differ. Check `radio_table_stats`. |
| Omitting a field to clear it | PUT merges. The old value survives. |
| Building payloads in a temp file in a loop | `noclobber` re-sends the first payload to every object. |
| Batching radio + WLAN changes | Overlapping reprovisions wedge APs in `INIT`. |
| Trusting your own "unreferenced" pre-flight | Check `port_overrides` and `virtual_network_override_id`. |
| Reverting to recover a wedged AP | Reverting did not help. `restart` did. |
