# unifi-network-ops

Claude Code skills for auditing, tuning, and safely changing **UniFi** networks
(UDM / UDM Pro / UDM SE / Cloud Key) through the controller API.

These are distilled from a real performance-and-security engagement on a live 5-AP,
90-client site — including the parts that went wrong. Several sections exist specifically
because a confident, plausible conclusion turned out to be false and had to be retracted.

## The four skills

| Skill | Use it when |
|---|---|
| **capturing-a-unifi-baseline** | First contact with a controller, or before any change. Which API surface answers what, what an API key can't read, capturing a restorable snapshot, and which captured files hold cleartext credentials. |
| **tuning-unifi-wifi-rf** | Slow WiFi, high airtime, co-channel interference, sticky clients, channel/power planning, DFS, min-RSSI, minimum data rate. |
| **applying-unifi-changes** | Before any PUT/POST/DELETE. Merge semantics, silent no-ops, runtime-vs-config verification, provisioning outage windows, referential integrity, shell traps. |
| **reviewing-unifi-security** | Zone firewall, segmentation, IDS/IPS, exposure — and triaging findings against the owner's actual threat model. |

Read them in that order for a full engagement. `applying-unifi-changes` is the gate:
nothing writes to a live network without it.

## Scripts

All are POSIX-ish bash, need only `curl` and `jq`, and take credentials from
`UNIFI_KEY` or `UNIFI_KEY_FILE` — never hardcoded.

| Script | Safety |
|---|---|
| `capturing-a-unifi-baseline/scripts/unifi-snapshot.sh` | **Read-only.** Full site snapshot + native `.unf` backup. |
| `capturing-a-unifi-baseline/scripts/unifi-revert.sh` | **Writes.** Restores one object from a snapshot. Defaults to dry-run; needs `--apply`. |
| `tuning-unifi-wifi-rf/scripts/unifi-sample-rf.sh` | **Read-only.** Multi-sample RF metrics with min/median/max. |

```bash
export UNIFI_GW=192.168.1.1
export UNIFI_KEY_FILE=~/.config/unifi/key      # chmod 600

./unifi-snapshot.sh ./baseline/$(date +%F)
./unifi-sample-rf.sh --samples 6 --interval 420 --label pre-change before.txt
./unifi-revert.sh --snapshot ./baseline/2026-07-24 --type wlanconf --list
```

## Install

As a plugin (this repo is a valid Claude Code plugin), or by copying/symlinking the
skills into your skills directory:

```bash
git clone <this-repo> ~/git/unifi-network-ops
for s in ~/git/unifi-network-ops/skills/*/; do
  ln -s "$s" ~/.claude/skills/$(basename "$s")
done
```

## Scope and caveats

- Verified against **UniFi Network 10.4** on a UDM Pro. Endpoint paths shift between major
  versions — the skills tell you how to probe rather than assume.
- Channel/DFS guidance assumes **country code 840 (US)**. The usable 80 MHz blocks and the
  TDWR exclusion differ elsewhere; the reasoning transfers, the specific channels do not.
- UniFi Protect / Access / Talk are different APIs and are out of scope.
- Site-specific tuning values are deliberately absent. The skills teach the method and the
  traps; your channel plan depends on your floor plan.

## The short version, if you read nothing else

1. Capture a restorable baseline before you write anything.
2. `rc: ok` does not mean it applied. Read back the **runtime** state.
3. Never judge an RF change on a single before/after sample.
4. min-RSSI evicts clients; it does not steer them.
5. A security finding is only worth raising if it is real under this owner's threat model.

## License

MIT
