# hermes-auto-update bundle (updater v5.14)

Hands-off Hermes updates via system cron, outside the gateway process tree. Notifies Telegram only for real outcomes.

**Support boundary / disclaimer:** hard-resets a git checkout and restarts a gateway as root, unattended. Linux + systemd + git installs only. Best-effort support.

## Install

```bash
bash install.sh          # preconditions check ONLY — never runs the updater
```

The recommended schedule (install.sh prints it; crontab.txt carries it):

```cron
23 3 * * * set -a; [ -f $HOME/.hermes/scripts/auto_update.env ] && . $HOME/.hermes/scripts/auto_update.env; set +a; AU_APPLY=1 $HOME/.hermes/scripts/auto_update.sh >> $HOME/.hermes/logs/auto_update_cron.log 2>&1
```

`set -a` is not decoration: without it the env file delivers NOTHING to the script (a bare
`. file` sets variables in the scheduler shell, which exits immediately, and the updater never
sources the file itself). The `[ -f ]` guard keeps a not-yet-created env file from aborting the
line before `AU_APPLY=1` is delivered. `scripts/schedule_delivery.sh` runs this shape under
bash/dash/sh with the env file present and absent, and reports what the child inherited.

## Per-host values

| variable | why |
|---|---|
| `AU_APPLY=1` | REQUIRED in the scheduler command — absent = report-only, never installs |
| `TG_PROXY=""` (or `TG_PROXY=` unset value) | direct Telegram (302). **Must live in `~/.hermes/scripts/auto_update.env`** — the file the scheduler sources. A copy in `~/.hermes/.env` never arrives (the script reads that file only for bot token + chat id). Empty value is meaningful, never delete the var. |
| `AU_REPO_DIR` / `AU_HERMES_BIN` | non-default checkout / binary paths |
| `AU_GATEWAY_STATE` / `AU_GATEWAY_UNIT` / `AU_CRON_UNIT` | systemd specifics |

See SKILL.md + references/wsl-deployment.md for the full checklist.

## Files

- `auto_update.sh` — the updater (UPDATER_VERSION 5.14)
- `LICENSE` — MIT
- `scripts/release_gate.sh` — run BEFORE shipping: doc pointers + matrix + probes + teeth
- `scripts/schedule_delivery.sh` — does the recommended cron shape deliver env + flag?
- `scripts/marker_lifecycle_sweep.sh`, `scripts/counter_sanity.sh` — companion probes
- `verify/` — hermetic harness (stub hermes/curl/systemctl); matrix = executable contract
- `references/` — receipt contract, WSL deployment, bundle recipe, health fixture

sha256 (auto_update.sh): a6aff05b0e48e29e2c6e765f768f056c007be40c6afc56037e02042455f3f58d
_evidence captured 2026-10-06; regenerate with `sha256sum auto_update.sh` before re-packing._
