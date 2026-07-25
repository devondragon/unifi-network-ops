---
name: tuning-unifi-wifi-rf
description: Use when diagnosing or fixing UniFi WiFi performance - slow wireless, high channel utilization or airtime, co-channel interference, sticky clients stuck on a distant AP at poor dBm, DFS/radar channel questions, transmit power and min-RSSI decisions, or 2.4GHz minimum data rate. Also use before claiming a UniFi RF metric shows a problem.
---

# Tuning UniFi WiFi RF

## Overview

Most UniFi RF problems are self-inflicted: overlapping channels, mismatched transmit
power, and settings that fight each other. The fix is usually a deliberate manual plan,
not more automation.

**Core principle: measure before and after with multiple samples, because every headline
RF metric on this platform is instantaneous and swings hard.** A single before/after pair
will tell you whatever you want to hear.

## When to Use

- "WiFi is slow" / high airtime / high retries on a UniFi site
- A client is attached to a distant AP at −85 dBm and won't move
- Planning channels or transmit power across multiple APs
- Deciding on min-RSSI, minimum data rate, or whether to run RF AI
- **Before writing any RF finding into a report** — the traps below have produced
  confidently-wrong conclusions more than once

**REQUIRED FIRST:** `capturing-a-unifi-baseline` (you need `stat/device` and `stat/sta`).
**REQUIRED BEFORE WRITING:** `applying-unifi-changes`.

---

## Part 1 — Read the metrics correctly (do this first)

Four traps, each of which has produced a confident, wrong, publicly-retracted claim.

### `stat/rogueap` is rolling history, not a live scan

It accumulates every BSSID ever heard. Raw counts are meaningless — most entries are at
the noise floor and months stale. Reading it raw produced a "73 competing BSSIDs on
channel 6, your neighborhood is congested" claim on a site whose true live picture was
**five** signals above −70 dBm, all of them one device.

**Always filter on both recency and signal:**

```bash
jq --argjson cutoff "$(( $(date +%s) - 3600 ))" '
  [.data[] | select(.last_seen > $cutoff and .signal > -70)]
  | group_by(.channel)[] | {channel: .[0].channel, count: length}' raw/stat_rogueap.json
```

Run against a live site while writing this skill: **136 BSSIDs** in the rolling table,
**4** actually present above −70 dBm in the last hour. Quoting the raw count would have
overstated the interference by 34×.

### `cu_total` (channel utilization / airtime) is instantaneous

Observed swinging 69% → 90% on the *same radio* hours apart with no config change, and
82% → 43% → 18% → 23% across one evening. **Never judge a change on one before/after
pair.** Use `scripts/unifi-sample-rf.sh` to take 6+ samples and compare medians at the
same time of day.

### Retry percentage is a ratio — check the denominator

After a successful fix, retry *percentage* often **rises** while the network gets
dramatically better. Retry % is retries ÷ total transmissions, and a fix collapses the
denominator. Worse, relieving congestion makes rate adaptation ambitious: clients that
crawled at reliable 1–2 Mbps now attempt 72 Mbps+ and occasionally miss.

**Weight it by utilization before concluding anything:**

| Radio | Before (util × retry) | Lost | After | Lost | Verdict |
|---|---|---|---|---|---|
| AP-1 2.4 | 90% × 5.4% | 4.86 | 21% × 14.1% | 2.96 | better |
| AP-2 2.4 | 82% × 10.0% | 8.20 | 19% × 15.2% | 2.89 | better |

Retry % nearly tripled on AP-2 while its actual airtime lost to retransmission fell by
two-thirds. Rough 2.4 GHz thresholds: <10% quiet · 10–20% normal · 20–30% investigate ·
>30% sustained is real.

### `tx_rate` is the last frame's rate, not the client's capability

A device showing `tx_rate: 1000` is usually **not** a legacy 802.11b device — it is very
often a modern client whose last transmission was a low-rate management frame. Check
`radio_proto` (`ng`/`na`/`ac`/`ax`) and `rx_rate` before calling anything legacy.

On one site this trap nearly triggered an unnecessary migration of a dozen "legacy"
devices. The actual protocol audit found **zero** 802.11b/g-only clients.

### Client names are not stable identifiers

Device display names come from DHCP/mDNS and can differ between polls on the same MAC.
A claim built on names ("an iMac is parked on 2.4 GHz") did not survive re-verification.
**Identify clients by MAC** before acting.

---

## Part 2 — Channel planning

### 2.4 GHz: only 1, 6, 11, and put reuse on the diagonals

Only three non-overlapping channels exist. With four corner APs, the two APs that share
a channel must be the two that are physically **farthest apart**:

```
   NW ─────────── NE          NW and SE share ch1
  ch1             ch11        NE and SW share ch11
        center                center takes ch6
  ch11            ch1
   SW ─────────── SE
```

Co-channel with another *WiFi* transmitter degrades gracefully — 1/6/11 don't partially
overlap, so they share airtime through CSMA/CA. **Adjacent-channel overlap (e.g. 3 vs 6)
is strictly worse** because the frames corrupt rather than defer. Never "split the
difference" onto channel 3 or 9.

### 5 GHz: think in 80 MHz blocks, not channels

At 80 MHz width, a channel number implies a whole block. Two APs on "different channels"
149 and 153 occupy the **identical** 149–161 block — a full collision that reads as two
distinct channels in the UI.

**US (country code 840) usable 80 MHz blocks — exactly five:**

| Block | Channels | DFS | Notes |
|---|---|---|---|
| 36–48 | 36/40/44/48 | no | give to a busy radio |
| 52–64 | 52/56/60/64 | yes | verified usable |
| 100–112 | 100/104/108/112 | yes | |
| 132–144 | 132/136/140/144 | yes | |
| 149–161 | 149/153/157/161 | no | give to a busy radio |

**⚠️ The 116–128 block is NOT usable in the US.** It spans 5570–5650 MHz, overlapping the
TDWR weather radar band (5600–5650 MHz). UniFi generally does not offer 120/124/128 under
country 840. Assigning it is a common and confident mistake.

Five blocks for five APs means **zero slack**. A sixth AP has to share, at 40 MHz or with
an accepted co-channel hit.

### The API does not expose an allowed-channel list

`radio_table` gives `has_dfs` and `has_fccdfs` but never enumerates permitted channels.
**Verify a new channel empirically:** set it, then read back
`radio_table_stats[].channel` and confirm `state == "RUN"` rather than a silent fallback
to the previous channel.

### DFS costs ~60–100 s of downtime per radio

Moving to a DFS channel triggers a Channel Availability Check. Measured: **~100 s** from
PUT to `state=RUN`, about 77 s of it CAC. The radio does not transmit at all during CAC —
its clients are offline for the whole duration, not the ~30 s a non-DFS change costs.

Non-DFS radio change: ~30 s. DFS: ~100 s. Budget accordingly and tell the owner.

---

## Part 3 — Transmit power

### Setting a specific dBm requires custom mode

```json
{"radio_table": [{"radio": "na", "tx_power_mode": "custom", "tx_power": 23}]}
```

The named modes (`low` / `medium` / `high` / `auto`) **ignore any `tx_power` value you
send alongside them.** Setting `"tx_power_mode": "high", "tx_power": 23` silently gives
you "high", not 23 dBm.

A radio with `tx_power_mode` unset/null typically runs at hardware maximum.

### Check the per-radio regulatory cap first

`min_txpower` / `max_txpower` in `radio_table` are per-radio and differ by model. Typical:
2.4 GHz caps at 22 dBm on mid-tier APs and 26 on long-range models; 5 GHz at 26–27. Floor
is usually 6 dBm. A value outside the range is rejected or silently clamped.

### Symmetry matters more than absolute power

Mismatched power is what *creates* sticky clients. One site had a 2.4 GHz radio pinned at
6 dBm (4 mW) while neighbors ran 26 dBm — a 100× deficit. It held one client because
nothing could hear it, yet showed 45% utilization because it could hear everyone else
without being able to compete.

### ⚠️ Do not cut power on a long-range AP that covers outbuildings

The instinct to reduce a "too loud" AP is often wrong. Cutting a long-range AP's 2.4 GHz
power 26 → 17 dBm to fix a sticky client measurably broke the thing that AP existed for:
an outdoor camera went −72 → −82 dBm, exactly tracking the 9 dB cut. It had to be reverted.

**A long-range AP holds distant clients through high-gain receive sensitivity, not
transmit reach.** Cutting TX power does not stop it attracting distant clients; it just
degrades the ones that legitimately depend on it. Ask what the AP covers before touching it.

---

## Part 4 — Sticky clients

### min-RSSI evicts; it does **not** steer

This is the single most misunderstood control on the platform. min-RSSI kicks a client
below the threshold. The client then rescans and is **free to pick the same AP again**.

A client sitting just under the threshold enters a loop: evicted → rescans → re-picks the
same bad AP → evicted. Observed exactly this at −81 dBm against a −80 threshold.

Set min-RSSI to remove genuinely broken associations, and **only on radios where a better
AP actually exists**. Around −80 on 5 GHz is a reasonable start.

**Do not set min-RSSI on a radio serving devices that have nowhere else to go** —
outdoor cameras, remote sensors, hard-to-re-pair IoT. Evicting a device with no
alternative is self-inflicted damage.

### Per-client AP pinning is the tool that actually relocates a client

```jsonc
// PUT /api/s/<site>/rest/user/<user_id>
{
  "fixed_ap_enabled": true,
  "fixed_ap_mac": "aa:bb:cc:dd:ee:ff"   // the AP you want it on
}
```

**Field names matter and are easy to get wrong.** `fixed_ap_enabled` + `fixed_ap_mac` are
correct. `ap_mac_fixed` is **not a real field** — it appears in plenty of forum posts and
is absent from every real record. Read an already-pinned client on the site and copy its
field names rather than guessing.

Follow the write with `POST cmd/stamgr {"cmd":"kick-sta","mac":"<client>"}` to force
reassociation.

**Result on a real device:** −91 dBm on an AP ~80 ft away → **−38 dBm** on the AP 6 ft
away, ~11× throughput. min-RSSI alone had failed to fix it twice, and a power cycle fixed
it only until the next night.

**Tradeoff to state explicitly to the owner:** a pinned client will not fail over if its
AP goes down.

### `kick-sta` is the surgical tool for redistributing clients

After an outage or a reprovision, 2.4 GHz IoT devices latch onto whichever AP answered
first and roam poorly afterward. Compare each client's current AP and signal to baseline
**by MAC**, then kick only the ones that are demonstrably worse off.

Note: **a `tx_power` change alone does not drop clients**, so it is not a usable way to
bounce a radio.

---

## Part 5 — Rates and automation

### 2.4 GHz minimum data rate is gated by a second setting

```jsonc
// PUT /api/s/<site>/rest/wlanconf/<id>
{
  "minrate_ng_data_rate_kbps": 6000,
  "minrate_setting_preference": "manual"   // REQUIRED — without it the rate is ignored
}
```

While `minrate_setting_preference` is `"auto"`, UniFi manages the rate and **silently
ignores** `minrate_ng_data_rate_kbps`. The PUT returns `rc: ok` and nothing changes.

**Choose 6 Mbps, not 12.** 6 Mbps preserves every OFDM rate and full range for distant
802.11n clients. A frame at 1 Mbps consumes ~50× the airtime of the same frame at 54 Mbps,
so 1 → 6 is where nearly all the benefit is.

Before raising it, audit `radio_proto` across clients for genuine 802.11b/g-only devices.
Do not use `tx_rate` for this (see Part 1).

### Turn RF AI off if you pin channels manually

RF AI optimizes per-radio with no floor-plan awareness. On a site with mostly-pinned
channels it has nothing to work with, and where it *is* free it can pick a channel that
collides with a manually pinned neighbor — one observed case had auto pick 149 directly
into a manually pinned 153.

**Commit to one or the other.** Half-auto/half-manual is the worst configuration.

---

## Quick Reference

| Symptom | Likely cause | Check |
|---|---|---|
| High airtime, few clients | Co-channel with a neighbor AP | `radio_table_stats[].channel` across all APs |
| Two APs "on different channels" still colliding | Same 80 MHz block | Map channel → block |
| Client at −90 dBm on a distant AP | Sticky client + power asymmetry | `stat/sta` signal vs AP `tx_power` |
| min-RSSI set, client keeps coming back | Client sits just under threshold | Pin it instead |
| Min-rate PUT returns ok, nothing changes | `minrate_setting_preference: auto` | `has("minrate_setting_preference")` |
| Channel set, AP still on the old one | Silent fallback or wedged provisioning | `radio_table_stats[].state == "RUN"` |
| Retries up after a fix | Denominator collapsed | Weight by utilization |

## Measuring a change

```bash
./scripts/unifi-sample-rf.sh --samples 6 --interval 420 before.txt   # pre-change
# ... apply changes ...
./scripts/unifi-sample-rf.sh --samples 6 --interval 420 after.txt    # SAME time of day
```

AP reboots reset counters, so a sample taken minutes after a reprovision is not comparable
to one taken before it. Wait for the network to settle — several hours is not excessive.

**Don't sample faster than the controller updates.** Radio counters refresh on the
controller's own cycle (minutes, not seconds). Two pulls seconds apart return
byte-identical numbers that look like two independent samples and will make a volatile
radio appear perfectly stable. Use an interval of 300 s or more; the script warns below 120 s.

## Common Mistakes

| Mistake | Reality |
|---|---|
| Judging a change on one before/after sample | Airtime swings 4× on its own. Take 6. |
| Reading `stat/rogueap` counts raw | Rolling history. Filter `last_seen` + `signal`. |
| "Retries went up, the change failed" | Weight by utilization first. |
| Assigning 116–128 in the US | TDWR radar band. Not available. |
| Cutting power on a long-range AP to fix stickiness | Breaks its actual coverage job. Pin the client. |
| Expecting min-RSSI to steer | It evicts. Only pinning relocates. |
| Trusting the config read-back | Verify `radio_table_stats`, not stored config. |
| Calling a device legacy from `tx_rate` | Check `radio_proto` and `rx_rate`. |

## Real-World Impact

Five-AP site, before → after a manual channel/power plan built on these rules:
total 2.4 GHz airtime **265% → 98%**, worst radio **90% → 30%**, mean 2.4 GHz client
rate **52 → 79 Mbps**, clients stuck at ≤2 Mbps **8 → 0**, clients below 80 satisfaction
**7 → 1**. No devices lost. Absolute airtime spent on retransmission fell ~51%.
