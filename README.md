# unifi-network-ops

Claude Code skills for auditing, tuning, and safely changing **UniFi** networks
(UDM / UDM Pro / UDM SE / Cloud Key) through the controller API.

These are distilled from a real performance-and-security engagement on a live 5-AP,
90-client site, including the parts that went wrong. Several sections exist specifically
because a confident, plausible conclusion turned out to be false and had to be retracted.

## Install

In Claude Code, run:

```
/plugin marketplace add devondragon/unifi-network-ops
/plugin install unifi-network-ops@unifi-network-ops
```

That is the whole install. All four skills become available immediately and Claude loads
whichever one matches the task you are working on.

<details>
<summary>Alternative: manual symlink (if you would rather not use the plugin system)</summary>

```bash
git clone https://github.com/devondragon/unifi-network-ops ~/git/unifi-network-ops
for s in ~/git/unifi-network-ops/skills/*/; do
  ln -s "$s" ~/.claude/skills/$(basename "$s")
done
```

</details>

## Quick start

### 1. Create an API key

In the UniFi UI (verified on Network **10.4**):

**Settings → Control Plane → Integrations → Create API Key**

Give it a name, create it, and **copy the key immediately**. It is shown once and cannot
be retrieved later. Keys are 32 characters.

One thing the UI does not tell you: although the key is presented as being for the
Integration API, it also works against the legacy `/api/s/<site>/` and v2
`/v2/api/site/<site>/` surfaces, which is where nearly all the useful data lives.
A few endpoints still refuse it (`stat/event` returns 404), and those need a local admin
login instead.

### 2. Store the key

Put it in a file that only you can read. Never paste it into a script, a prompt, or a
commit.

```bash
mkdir -p ~/.config/unifi
printf '%s' 'PASTE_KEY_HERE' > ~/.config/unifi/key
chmod 600 ~/.config/unifi/key
```

Then point the tooling at it, and set your gateway address:

```bash
export UNIFI_GW=192.168.1.1
export UNIFI_KEY_FILE=~/.config/unifi/key
```

`UNIFI_KEY` works too if you would rather pass the value directly, but a file keeps the
key out of your shell history and process list. Add both to your shell profile if you
will be doing this more than once.

<details>
<summary>Alternative: macOS Keychain (macOS only, opt-in)</summary>

If you are on macOS and would rather not keep the key on disk in cleartext, store it in
the login Keychain instead:

```bash
security add-generic-password -a "$USER" -s unifi-api-key -U -w
export UNIFI_KEY_KEYCHAIN=unifi-api-key
```

With `-w` last and no value after it, `security` prompts for the key instead of taking it
as an argument — so it stays out of your shell history and the process list, the same
reason the file above is preferred over inline `UNIFI_KEY`.

`UNIFI_KEY_KEYCHAIN` is the Keychain **service** name. The account defaults to `$USER`;
override it with `UNIFI_KEY_KEYCHAIN_ACCOUNT` if you stored it under a different one.

This is entirely opt-in. Leaving `UNIFI_KEY_KEYCHAIN` unset changes nothing, and the file
above stays the portable default — it is the only option that works on Linux and in
Docker. If `UNIFI_KEY_KEYCHAIN` is set but the lookup finds nothing, the scripts stop with
an error rather than quietly falling back to the file, so a revoked or renamed Keychain
item cannot be masked by a stale key on disk.

</details>

### 3. Confirm it works before anything else

```bash
KEY=$(cat ~/.config/unifi/key)
# Keychain instead? KEY=$(security find-generic-password -a "$USER" -s unifi-api-key -w)

curl -sk -o /dev/null -w '%{http_code}\n' \
  -H "X-API-KEY: $KEY" \
  "https://$UNIFI_GW/proxy/network/integration/v1/sites"
```

`200` means you are good. `401` or `403` means the key is wrong or revoked. `000` means
you cannot reach the gateway at all, which is a different problem: check you are on the
same LAN.

### 4. Work through the skills in order

Invoke each skill explicitly with a slash command, then add your own prompt after it.
Claude can also load these automatically when your request matches, but invoking them by
name is worth doing here: you get a deterministic result and you can see that the right
skill loaded, which matters most at step 5 where the wrong answer reprovisions your APs.

The skill name depends on how you installed:

| Install method | Invoke as |
|---|---|
| Plugin (recommended) | `/unifi-network-ops:capturing-a-unifi-baseline` |
| Manual symlink | `/capturing-a-unifi-baseline` |

Examples below use the plugin form. Type `/` and start typing `unifi` to autocomplete.

**Steps 1 through 4 are entirely read-only.** You can run all of them against a production
network in the middle of the day without disturbing anything. Only step 5 writes.

```
1.  /unifi-network-ops:capturing-a-unifi-baseline
    capture a full baseline of my site before we change anything

2.  /unifi-network-ops:tuning-unifi-wifi-rf
    take a before reading of RF performance across all my APs

3.  /unifi-network-ops:tuning-unifi-wifi-rf
    audit my WiFi performance and propose a channel and power plan.
    my APs are in the four corners of the main floor, one in the basement

4.  /unifi-network-ops:reviewing-unifi-security
    review my network's security posture. I care most about keeping IoT
    devices away from my main LAN

5.  /unifi-network-ops:applying-unifi-changes          <-- WRITES TO THE NETWORK
    apply change 1 from the plan

6.  /unifi-network-ops:tuning-unifi-wifi-rf
    take an after reading and compare it to the before run
```

Step 3 is worth giving real detail to. The channel plan depends on where your APs
physically are, and the skill cannot infer that. Tell it your layout, which rooms matter,
and anything that must not break, such as an outdoor camera or a device that is painful
to re-pair.

**Step 1** also runs the snapshot script, which is what makes everything after it
reversible:

```bash
./unifi-snapshot.sh ./baseline/$(date +%F)
```

**Step 2** takes the before reading. Airtime on this platform swings hard enough that one
sample proves nothing, so take at least six:

```bash
./unifi-sample-rf.sh --samples 6 --interval 420 --label pre-change before.txt
```

**Step 5 is the one that matters.** It reprovisions devices and drops wireless clients.
Do not start it until you have a snapshot from step 1, a native `.unf` backup, and
agreement from whoever depends on the network about when it happens. Apply one class of
change at a time (radios, then WLANs, then networks, then security) and confirm every AP
is back to `RUN` before starting the next class.

**Step 6** must run at roughly the same time of day as step 2, or you are comparing a
weekday evening to a Sunday morning:

```bash
./unifi-sample-rf.sh --samples 6 --interval 420 --label post-change after.txt
```

If something goes wrong, revert one object rather than restoring everything:

```bash
./unifi-revert.sh --snapshot ./baseline/2026-07-26 --type wlanconf --list
./unifi-revert.sh --snapshot ./baseline/2026-07-26 --type wlanconf --name MySSID
./unifi-revert.sh --snapshot ./baseline/2026-07-26 --type wlanconf --name MySSID --apply
```

The first `--apply`-less run is a dry run that shows you exactly what would change.

### If you only have ten minutes

Do steps 1 through 4 and stop. A snapshot plus a read-only audit costs you nothing, tells
you what is actually wrong, and leaves you with a rollback point for whenever you do have
a maintenance window.

## The four skills

| Skill | Use it when |
|---|---|
| **capturing-a-unifi-baseline** | First contact with a controller, or before any change. Which API surface answers what, what an API key cannot read, capturing a restorable snapshot, and which captured files hold cleartext credentials. |
| **tuning-unifi-wifi-rf** | Slow WiFi, high airtime, co-channel interference, sticky clients, channel/power planning, DFS, min-RSSI, minimum data rate. |
| **applying-unifi-changes** | Before any PUT/POST/DELETE. Merge semantics, silent no-ops, runtime-vs-config verification, provisioning outage windows, referential integrity, shell traps. |
| **reviewing-unifi-security** | Zone firewall, segmentation, IDS/IPS, exposure, and triaging findings against the owner's actual threat model. |

Read them in that order for a full engagement. `applying-unifi-changes` is the gate:
nothing writes to a live network without it.

## Scripts

All are POSIX-ish bash, need only `curl` and `jq`, and take credentials from
`UNIFI_KEY`, `UNIFI_KEY_KEYCHAIN` (macOS only, opt-in), or `UNIFI_KEY_FILE`, in that
order of precedence. Nothing is ever hardcoded.

| Script | Safety |
|---|---|
| `capturing-a-unifi-baseline/scripts/unifi-snapshot.sh` | **Read-only.** Full site snapshot plus native `.unf` backup. |
| `capturing-a-unifi-baseline/scripts/unifi-revert.sh` | **Writes.** Restores one object from a snapshot. Defaults to dry-run; needs `--apply`. |
| `tuning-unifi-wifi-rf/scripts/unifi-sample-rf.sh` | **Read-only.** Multi-sample RF metrics with min/median/max. |

```bash
export UNIFI_GW=192.168.1.1
export UNIFI_KEY_FILE=~/.config/unifi/key      # chmod 600

./unifi-snapshot.sh ./baseline/$(date +%F)
./unifi-sample-rf.sh --samples 6 --interval 420 --label pre-change before.txt
./unifi-revert.sh --snapshot ./baseline/2026-07-24 --type wlanconf --list
```

Installed via the plugin system, the scripts live under
`~/.claude/plugins/cache/`. Run `/plugin` to find the exact path, or clone the repo
separately if you would rather invoke them from somewhere you control.

## Scope and caveats

- Verified against **UniFi Network 10.4** on a UDM Pro. Endpoint paths shift between major
  versions, so the skills tell you how to probe rather than assume.
- Channel and DFS guidance assumes **country code 840 (US)**. The usable 80 MHz blocks and
  the TDWR exclusion differ elsewhere; the reasoning transfers, the specific channels do not.
- UniFi Protect / Access / Talk are different APIs and are out of scope.
- Site-specific tuning values are deliberately absent. The skills teach the method and the
  traps; your channel plan depends on your floor plan.

## The short version, if you read nothing else

1. Capture a restorable baseline before you write anything.
2. `rc: ok` does not mean it applied. Read back the **runtime** state.
3. Never judge an RF change on a single before/after sample.
4. min-RSSI evicts clients; it does not steer them.
5. A security finding is only worth raising if it is real under this owner's threat model.

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

## License

[Apache License 2.0](LICENSE), Copyright 2026 Devon Hillard.

Note that the scripts write to live network hardware. The license's "AS IS" warranty
disclaimer (section 7) and limitation of liability (section 8) apply in full: verify
against your own controller before trusting anything here on a network you care about.
