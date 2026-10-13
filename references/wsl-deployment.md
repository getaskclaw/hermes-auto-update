# WSL2 deployment (laptop / pc20)

Two Windows machines run Hermes inside WSL2. The updater works there, but WSL changes two
assumptions the Linux-server design made.

## What their machines reported

| check | laptop | pc20 | meaning |
|---|---|---|---|
| `/etc/wsl.conf` `[boot] systemd=true` | ✅ | ✅ | user systemd works; the gateway unit is manageable |
| `systemctl is-active cron` | **inactive** | **inactive** | cron is not running — pick a scheduler below |
| `systemctl --user status hermes-gateway` | loaded, enabled | loaded, enabled | gateway exists as a user unit |
| `curl https://api.telegram.org` | 302 | 302 | direct access — **no proxy needed** |

## Choosing a scheduler — what each option actually costs

The goal is "stay current while the machine is in use", not "run every tick". Missed ticks
are fine; they are not a backlog. That makes in-distro cron a perfectly good choice — the
only thing to know is WHEN it is alive:

| situation | WSL state | in-distro cron | effect |
|---|---|---|---|
| laptop open, a terminal running | resident | running | ✅ updates hourly |
| all terminals closed | terminates after ~8 s idle | stops | ⏸ pauses |
| terminal reopened | boots again | **restarts automatically** | ✅ resumes |
| shut down overnight / for days | not running | stops | ⏸ paused for that whole period |

**`enable` is persistent** — `systemctl enable --now cron` writes a symlink on disk
(`/etc/systemd/system/multi-user.target.wants/cron.service`), so cron comes back by itself
every time the distro boots. You do not re-enable it after each restart.

**Missed ticks are not replayed** (cron has no catch-up). With the goal above that is a
feature, not a gap: the next tick installs everything that accumulated meanwhile.

### Option A — in-distro cron (simplest; good if the machine is on most of the day)

```bash
sudo systemctl enable --now cron      # persistent + start now
systemctl is-active cron              # expect: active
(crontab -l; echo '23 * * * * AU_APPLY=1 ~/.hermes/scripts/auto_update.sh >/dev/null 2>&1') | crontab -
```
`AU_APPLY=1` is required — without it the tick only reports that an update is available and
installs nothing.

If the defaults do not fit this host, source the env file and keep the flag on the SCRIPT:

```
23 * * * * . ~/.hermes/scripts/auto_update.env; AU_APPLY=1 ~/.hermes/scripts/auto_update.sh >/dev/null 2>&1
```

Note the order: `AU_APPLY=1` prefixes the script, not the `.` that sources the env file. An
assignment prefixed to `.` binds to the source builtin and is never exported to the child, so
`AU_APPLY=1 . env; script` contains the flag but delivers nothing — the tick would report an
available update forever and never install (verified under both bash and dash).

### Option B — Windows Task Scheduler (if the machine is often off)

Windows is always running, so the schedule is driven from outside WSL:

```powershell
schtasks /create /tn "hermes-update" /sc hourly /mo 1 /st 00:23 /rl highest ^
  /tr "wsl.exe -d <distro> -u <user> -e bash -lc 'AU_APPLY=1 AU_CRON_UNIT= ~/.hermes/scripts/auto_update.sh'"
```
`AU_APPLY=1` performs the install (without it the run only reports); `AU_CRON_UNIT=` (empty)
tells the script that no in-distro cron is expected, so the preflight warning is suppressed.
Task Scheduler wakes the distro, one tick runs, it idles out.

### Option C — once at login

If hourly is heavier than you want on a laptop, run one tick when you log in. Updates arrive
when you sit down, which is when a laptop needs them.

## No proxy on these machines

Both hosts reach `api.telegram.org` directly (302). The script defaults `TG_PROXY` to the
server's xray address, which does not exist there. Set it **empty** to mean "direct"
(v5.7+; older versions silently fell back to the proxy and lost every notification):

```bash
TG_PROXY=""     # put it in ~/.hermes/scripts/auto_update.env (the file the scheduler sources) —
                # NOT in ~/.hermes/.env, which the script reads only for the bot token and chat id
```

## Values to set per host

Defaults are written for the server. Set what differs on each machine:

| variable | why |
|---|---|
| `AU_REPO_DIR` | the git checkout (not `/usr/local/lib/hermes-agent` there) |
| `AU_HERMES_BIN` | absolute hermes binary (`which hermes`) |
| `TG_PROXY=""` | direct Telegram (confirmed 302) |
| `AU_CRON_UNIT=""` | only for Options B/C (host OS schedules) |
| `AU_APPLY=1` | **required in the scheduler command** — absent means report-only, no install |
| `AU_GATEWAY_STATE`, `AU_GATEWAY_UNIT` | usually already correct |
| `AU_UPDATE_TIMEOUT` / `AU_CHECK_TIMEOUT` / `AU_UPDATE_KILL` | caps on the bounded updater/check calls (defaults 3600 / 300 / 60s); only lower them for testing |

## Checklist (run on each host)

```bash
systemctl --user is-active hermes-gateway    # active
systemctl is-active cron                     # active (Option A), or AU_CRON_UNIT="" for B/C
file ~/.hermes/scripts/auto_update.sh | grep -q CRLF && echo "FIX: dos2unix" || echo "LF ok"
curl -s -m 5 -o /dev/null -w '%{http_code}\n' https://api.telegram.org   # 302 -> TG_PROXY=""
AU_REPO_DIR=<repo> AU_HERMES_BIN=<bin> TG_PROXY="" bash ~/.hermes/scripts/auto_update.sh
#   ^ no AU_APPLY here on purpose: this is a safe report-only run. Add AU_APPLY=1 only when
you intend to install right now.
grep preflight ~/.hermes/logs/auto_update.log   # should be empty when configured right
```

A Windows copy must be LF-only: a CRLF `auto_update.sh` fails as `bad interpreter`. Keep the
checkout on the Linux filesystem — `/mnt/c/...` (DrvFs) has different permissions and git
behaviour.

## Per-host state is not shared evidence

Receipts (`~/.hermes/logs/update_receipts/`) and state (`~/.hermes/state/auto_update/`) belong
to the machine that wrote them. Never ship one host's receipt as another's.
