# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Continuous verification.** `tests/run.sh` runs `bash -n`, shellcheck, and two
  behavioural test files — credential precedence and every Keychain failure cause, plus a
  check that no header line has fallen out of any script's `--help`. The macOS Keychain
  and `curl` are stubbed, so the suite needs no network, controller, or credentials and
  covers the macOS-only code paths on Linux too. GitHub Actions runs it on Linux and macOS
  for every push and pull request.

## [1.1.0] - 2026-07-27

### Added

- **macOS Keychain as a credential source.** All three scripts can read the API key from
  the login Keychain instead of a file on disk. Opt in by setting `UNIFI_KEY_KEYCHAIN` to
  the Keychain service name; `UNIFI_KEY_KEYCHAIN_ACCOUNT` overrides the account, which
  defaults to `$USER`. Resolution order is `UNIFI_KEY`, then `UNIFI_KEY_KEYCHAIN`, then
  `UNIFI_KEY_FILE`. Leaving `UNIFI_KEY_KEYCHAIN` unset changes nothing, and every new code
  path is behind a `command -v security` guard, so Linux and Docker users are unaffected.
  A Keychain lookup that returns nothing is a fatal error naming the service and account
  rather than a silent fall-through to the file, so a revoked or renamed item cannot be
  masked by a stale key on disk.

### Changed

- The README now stores the key with `security add-generic-password ... -U -w`, which
  prompts for the value instead of taking it as an argument, keeping it out of shell
  history and the process list — the same reason a key file is preferred over inline
  `UNIFI_KEY`.
- The quick start's "confirm it works" step no longer assumes the key file, so it works
  for readers who chose the Keychain.
- `capturing-a-unifi-baseline/SKILL.md` documents the full credential precedence. It only
  described the key file, so the Keychain option was invisible to the skill itself.

### Fixed

- A failed Keychain lookup now reports what actually went wrong. It previously said the
  item was missing whatever the cause, and suggested `-U`, which updates in place — so a
  merely locked keychain led you to overwrite a working credential. Missing (`rc 44`),
  present but empty (`rc 0`), and locked or denied are now distinct messages, and only the
  first two suggest storing a key.
- The no-API-key error names `UNIFI_KEY_KEYCHAIN`, so mistyping the variable no longer
  produces a message implying the option does not exist.

## [1.0.0] - 2026-07-26

Initial release. Four Claude Code skills and three scripts for auditing, tuning, and
safely changing UniFi networks through the controller API, distilled from a real
performance and security engagement on a live 5-AP, 90-client UDM Pro site.

### Added

#### Skills

- **`capturing-a-unifi-baseline`**. The three API surfaces and which one answers what,
  API key authentication and its limits, site identifier resolution, capturing a
  restorable snapshot, and which captured files contain cleartext credentials.
- **`tuning-unifi-wifi-rf`**. Reading RF metrics correctly, 2.4 GHz and 5 GHz channel
  planning, DFS and the US TDWR exclusion, transmit power, sticky clients, min-RSSI
  versus per-client AP pinning, minimum data rate, and RF AI.
- **`applying-unifi-changes`**. The write path. PUT merge semantics, settings gated by
  other settings, verifying runtime state rather than stored config, provisioning and DFS
  outage windows, change sequencing, referential integrity on deletes, and the shell
  traps that have silently corrupted payloads.
- **`reviewing-unifi-security`**. Zone-based firewall policies and the ALLOW/BLOCK
  reading trap, segmentation invariants, IDS/IPS modes and constraints, and triaging
  findings against the owner's actual threat model.

#### Scripts

Bash, requiring only `curl` and `jq`. Credentials are read from `UNIFI_KEY` or
`UNIFI_KEY_FILE` and never hardcoded.

- **`unifi-snapshot.sh`**. Read-only. Captures every config and state endpoint plus a
  native `.unf` controller backup. Resolves both site identifier forms, records
  non-200 responses without failing the run, and verifies captured files parse as JSON.
- **`unifi-sample-rf.sh`**. Read-only. Takes N RF samples at a set interval and reports
  min, median, and max per radio. Warns when the interval is shorter than the
  controller's stats refresh, which would otherwise yield duplicate readings that look
  like independent samples.
- **`unifi-revert.sh`**. Writes. Restores a single object from a snapshot. Dry-run by
  default and requires `--apply`. Shows a live-versus-snapshot diff, refuses ambiguous
  matches, strips server-managed fields, reports blast radius by object type, and reads
  back after writing.

#### Packaging and documentation

- Claude Code plugin manifest (`.claude-plugin/plugin.json`) and marketplace manifest
  (`.claude-plugin/marketplace.json`), enabling a two-line install.
- README with a quick start covering API key creation, safe key storage, a connectivity
  probe, and the six-step engagement order with explicit skill invocations.
- Apache License 2.0.

### Notes on verification

Every endpoint path, `jq` snippet, and `curl` command in these skills was executed
against a live UniFi Network 10.4.57 controller on a UDM Pro while writing them. That
process corrected four errors before release:

- v2 firewall policies are at `firewall-policies`, not `firewall/policy`.
- The Integration API keys on a site UUID while the legacy and v2 surfaces key on
  `internalReference`; passing the wrong one returns 400, not 404.
- The firewall policy schema carries `zone_id` only, so zone names require a join against
  the zones collection. The first documented query returned `null -> null`.
- `list/alarm` and `rest/ipsalert` do answer an API-key credential. Only `stat/event`
  returns 404.

### Known limits

- Verified against UniFi Network 10.4 only. Endpoint paths shift between major versions.
  The skills describe how to probe rather than assume.
- Channel and DFS guidance assumes country code 840 (US). The reasoning transfers, the
  specific channels do not.
- `unifi-revert.sh --apply` has been exercised end to end, but only as a no-op restore
  against a client database record. Its behaviour on device or WLAN objects is reasoned,
  not observed.
- The skills have not been validated by adversarial testing. An attempt was made and
  discarded as methodologically void.
- UniFi Protect, Access, and Talk are different APIs and are out of scope.

[Unreleased]: https://github.com/devondragon/unifi-network-ops/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/devondragon/unifi-network-ops/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/devondragon/unifi-network-ops/releases/tag/v1.0.0
