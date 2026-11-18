# Hermes Auto-Update

[简体中文](README.md) · English

Hands-off [Hermes Agent](https://github.com/NousResearch/hermes-agent) updates via a system-cron job outside the gateway process tree; notifies Telegram only for real outcomes.

Current version: **updater v5.14** (this is the updater's own version — distinct from the Hermes version it installs).

## Support boundary / disclaimer

Hard-resets a git checkout and restarts a gateway as root, unattended. Linux + systemd + git installs only. Best-effort support.

## Why system cron, not hermes cron

<p align="center"><img src="assets/in-tree-deadlock.en.png" width="720" alt="Why it deadlocks: a hermes-cron job launches the updater inside the gateway process tree; the updater waits for the gateway restart, but the gateway is its parent and can't restart until the updater exits"></p>

A hermes-cron job lives inside the gateway process tree — the root of every update race: the updater can only signal a restart after it exits, waiting inside the script deadlocks, and the fleet check reports STALE. Out of the tree the updater drains the gateway, restarts it via systemd, and verifies the fleet itself before exiting, so the script can verify synchronously.

<p align="center"><img src="assets/out-of-tree-flow.en.png" width="520" alt="The fixed flow: system cron fires → flock → check → AU_APPLY gate → update → drain → systemd restart → self-verify → three notification branches"></p>

(Diagram sources: `assets/src/in-tree-deadlock.en.puml`, `assets/src/out-of-tree-flow.en.puml` — regenerate with `plantuml -tpng`.)

## Install

```bash
bash install.sh          # preconditions check ONLY — never runs the updater
```

The recommended schedule (install.sh prints it; crontab.txt carries it):

```cron
23 3 * * * set -a; [ -f $HOME/.hermes/scripts/auto_update.env ] && . $HOME/.hermes/scripts/auto_update.env; set +a; AU_APPLY=1 $HOME/.hermes/scripts/auto_update.sh >> $HOME/.hermes/logs/auto_update_cron.log 2>&1
```

`set -a` is not decoration: without it the env file delivers NOTHING to the script (a bare `. file` sets variables in the scheduler shell, which exits immediately, and the updater never sources the file itself). The `[ -f ]` guard keeps a not-yet-created env file from aborting the line before `AU_APPLY=1` is delivered. `scripts/schedule_delivery.sh` runs this shape under bash/dash/sh with the env file present and absent, and reports what the child inherited.

## Per-host values

| variable | why |
|---|---|
| `AU_APPLY=1` | REQUIRED in the scheduler command — absent = report-only, never installs |
| `TG_PROXY=""` (or empty value) | direct Telegram. **Must live in `~/.hermes/scripts/auto_update.env`** — the file the scheduler sources. A copy in `~/.hermes/.env` never arrives (the script reads that file only for bot token + chat id). Empty value is meaningful, never delete the var. |
| `AU_REPO_DIR` / `AU_HERMES_BIN` | non-default checkout / binary paths |
| `AU_GATEWAY_STATE` / `AU_GATEWAY_UNIT` / `AU_CRON_UNIT` | systemd specifics |
| `AU_CHECK_ALERT_INTERVAL` | check-failure re-alert interval in seconds (default `86400`). Must be a positive integer; an invalid, empty, or `0` value falls back to `86400` |

See SKILL.md + references/wsl-deployment.md for the full checklist.

## Notification design

Silence when up to date. `✓` on install (headline the Hermes version, name the updater version), `✗` on failure.

`update --check` outcomes are recognized in both the stable form and the legacy form:
- up to date / `hold` → benign: no install, and not counted as a check failure;
- update available → only reaches the `AU_APPLY` gate; the target version is extracted from the update completion line (new `old→new` form, or legacy single version), NOT from the check line;
- rollback → notify and require manual action; it NEVER triggers an automatic `--yes`;
- unknown / failed → still blocked: no install, counted as a check failure.

Check-failure alerts (`⚠`):
- The first alert fires on the 3rd consecutive failure. After that, alerts repeat on a time basis, every `AU_CHECK_ALERT_INTERVAL` seconds (default 86400).
- The alert timestamp is written ONLY when the notification is actually delivered. A failed delivery is retried on the next tick.
- Migration: a pre-existing count N>3 with no timestamp alerts once on the next tick.
- The alert carries the consecutive count, the last successful installation, and the real error output (multiline, length-bounded).
- The last successful installation reads `unknown` until the first proven install.

An install is proven only by installation proof bound to the current invocation: a fresh, immutable receipt for THIS run plus an affirmative completion or code movement. Stale, missing, or unrelated (another operation, e.g. `kind=plugin-check`) or unchanged receipts never prove an install.

The real-failure cadence (alert on the 1st, then every 12th) and the notify-failure cadence (3, then every 24th) are unchanged.

## Files

- `auto_update.sh` — the updater (UPDATER_VERSION 5.14)
- `LICENSE` — MIT
- `scripts/release_gate.sh` — run BEFORE shipping: doc pointers + matrix + probes + teeth
- `scripts/schedule_delivery.sh` — does the recommended cron shape deliver env + flag?
- `scripts/marker_lifecycle_sweep.sh`, `scripts/counter_sanity.sh` — companion probes
- `scripts/check_compat_sanity.py` — `--check` outcome compatibility check, run as `python3 scripts/check_compat_sanity.py auto_update.sh`; part of the release gate
- `verify/` — hermetic harness (stub hermes/curl/systemctl); matrix = executable contract
- `references/` — receipt contract, WSL deployment, bundle recipe, health fixture

## Verify

From the extracted copy run:

```bash
bash scripts/release_gate.sh
```

Require PASS. The gate includes `python3 scripts/check_compat_sanity.py auto_update.sh`. The 62-scenario matrix is the executable contract of the script's behavior.

sha256 (auto_update.sh, v5.14 release baseline — unreleased candidate changes do not match this hash): `a6aff05b0e48e29e2c6e765f768f056c007be40c6afc56037e02042455f3f58d`
_Regenerate with `sha256sum auto_update.sh` before re-packing._
