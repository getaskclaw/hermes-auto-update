# verify/ — hermetic stub harness

Runs the updater against **stub** `hermes`, `curl` and `systemctl` in a throwaway workspace:
no real hermes binary, no real gateway restart, no Telegram message. The stub is inserted as
the **first** absolute-path candidate, which is the only way to win the candidate race —
otherwise a "test" run can fire a real update.

```bash
bash stub_setup.sh /path/to/auto_update.sh    # build the harness (HARNESS_ROOT, default /tmp/au-harness)
bash stub_matrix.sh                           # run every scenario, print PASS/FAIL + its own tally
```

`stub_setup.sh` refuses to continue if it cannot prove the stub is first in the candidate
list. `mode` files drive the stub — check phase: `uptodate | weird | checkfail |
checkwedge`; install phase: `ok | partial0 | race | race_sha | race_same | noop |
weirdyes | fail | wedged`. Stable-channel check modes (verbatim shapes of upstream
`hermes_cli/update_cmd_check.py` L97-L124): `stable_none | stable_uptodate | stable_avail |
stable_retired_avail | stable_hold | stable_ahead | stable_avail_hold` (the last checks
"available" and then has `--yes` hold with a fresh receipt), `checkfail_multi` (exit 1, banner on
line 1, `✗ … timed out` on line 2), and adversarial exit-0 bodies `trap_err_words |
trap_mid_words | contradictory`. Every `update --yes` call is appended to `yes.calls`, so a
scenario can assert that NO install was attempted. `gw_down` makes the stub `systemctl is-active` return `inactive`;
`gw_flip_after=N` returns `inactive` for the first N calls then `active` (a gateway that
comes back mid-poll); `curl_fail` makes the stub curl fail; `tg_reject` makes it answer
HTTP 200 with `{"ok":false}`; every notify is appended to `notify.calls` instead of sent.

The matrix prints its own tally — never restate that number in prose (it drifts the moment a
scenario is added). What each scenario must hold:

| # | scenario | must hold |
|---|---|---|
| S1 | up-to-date | exit 0, **0 notifications** (silent) |
| S2 | exit0 + fresh `success` receipt | exit 0, 1 `✓` |
| S3 | exit1 + fresh `partial` + "Update complete" | exit 0, 1 `✓` (restart race, not failure) |
| S4 | pull-stage failure over a **stale** success receipt ×3 | counter 3, alerts ≤ 2 (not one per tick) |
| S5 | **unrecognized `--check` output ×4** | counter **4**, alert on the 3rd |
| S6 | `--check` exiting 1 ×3 | counter 3, alert on the 3rd |
| S7 | bare env (`env -i`) | still runs, exit 0 |
| S8 | Telegram creds removed | `consec_notify_fails` increments (never silent) |
| S9 | code landed, gateway never healthy | exit 0 **+ `drain_pending` marker** (neutral, not a failure) |
| S10 | the following no-update ticks, gateway still down | `consec_drain_pending` climbs, alerts deduped |
| S11 | gateway recovers | marker cleared, exit 0, 0 notifications |
| S12 | **script killed while inside the catch-up poll** | `drain_pending` must already exist (a marker written only on timeout is invisible here) |
| S13 | **exit≠0 restart-race branch** (gateway unconfirmed) then a no-update tick | marker must be **PRESENT** after the race, and the next tick must re-verify — clearing it there erases the re-verify hook |
| S14 | gateway comes back **during** the catch-up poll | exit 0, success alert, marker **cleared** |
| S15 | hermes binary missing from every candidate path | exit 1 + 1 alert (install broken) |
| S16 | exit0 + stale receipt + unrecognized output | inconclusive → exit 1 + 1 alert |
| S17 | notify delivery fails (curl/proxy down) | counter increments + the failure is logged (not swallowed) |
| S18 | SHA discriminator positive: `pre != post`, no text marker | exit 0, `✓` (the install landed) |
| S19 | SHA discriminator negative: `pre == post`, no text marker | real failure, `✗` |
| S20 | fresh `success` receipt while the gateway is **down** | must NOT confirm the gateway: no `✓`, marker still set |
| S21 | Telegram answers HTTP 200 + `{"ok":false}` | not delivery: counter increments, rejection logged |
| S22 | healthy no-update tick | resets `consec_real_fails` (a later unrelated failure still alerts) |
| S23 | run **without** `AU_APPLY=1` | must NOT install (no receipt written) — report-only, exit 0 |
| S24 | `install.sh` / `crontab.txt` / `README.md` | each must require `AU_APPLY=1` in any schedule it prints |
| S24b | the recommended schedule, run under **bash and dash** | must DELIVER `AU_APPLY` to the script (`AU_APPLY=1 . env; script` binds it to the source builtin and delivers nothing) |
| S25 | install-phase call **wedged** (ignores TERM) | bounded: exit 1 promptly, logged + alerted, `drain_pending` left set |
| S26 | check-phase call **wedged** | bounded: a transient check failure (counter path), no install attempted |
| S27 | stable `✓ No newer release: …` (issue #1 verbatim) | up-to-date: silent, streak + stamp reset, no install |
| S28 | stable `✓ Up to date with the latest release (…)` | up-to-date: silent, no install |
| S29 | stable `→ Selected release available: …` | **installs**; notify names `v0.23.1` from `(v0.23.0 → v0.23.1) [detached @ …]`; `last_install_ok` written |
| S30 | `→ X retired; source destination: Y` + Selected release available | installs (retired line is context only) |
| S31 / S31b | stable `→ Holding at this build: …` | no install, no alert, not a failure; still re-verifies a pending drain marker |
| S32 | stable `→ This checkout is newer than the selected release: …` | **never installs**; not a failure; one reminder, the next only after 7 days |
| S33 | main `✓ Already up to date.` / `⚕ Update available: …` | up-to-date / installs; old `(v9.9.9)` completion → `v9.9.9` |
| S34 | `✗ … up to date` line, verdict words mid-line, two contradictory verdicts (all exit 0) | unrecognized: counted, no install |
| S35 | exit 1, banner on line 1, `✗ … timed out` on line 2, streak 33 → 34 | alert carries the `✗` line, `(34 consecutive, exit 1)`, last successful install time |
| S36 | daily ticks, persistent check failure, 10 simulated days | alerts on days **3 6 9** (wall clock, 3-day default) |
| S37 | same with `AU_REALERT_SECS=86400` | alerts on days 3 4 5 |
| S38 | the day-3 alert is not delivered | no stamp; the day-4 tick re-sends it |
| S39 | persistent real install failure, 7 simulated days | alerts on days **1 4 7** |
| S40 | dead notification channel, 7 simulated days | dead-letter re-alert on days 3 6 |
| S41 | check "available", `--yes` holds (`✓ Holding at this build until a newer …`) with a FRESH success receipt | no `✓ updated` claim, no `last_install_ok`; marker consumed by the in-line recheck as on success |

Simulated days age every `*_last_alert` stamp by 86400 s between ticks (`age_stamps`), so the
wall-clock cadence is tested without a clock hook in the script. `scripts/counter_sanity.sh`
covers corrupt / empty / overflowing / FUTURE stamps and garbage `AU_REALERT_SECS` /
`AU_AHEAD_REMIND_SECS`, each through the branch that reads it.

## Teeth

Every fix carries a destructive check: neuter the branch it guards, re-run the matrix, and
confirm the matching scenario fails. A fix whose scenario still passes when the code is
removed is not covered. Two habits this repo learned the hard way:

- **Re-run `stub_setup.sh` after neutering.** The matrix runs `$HARNESS_ROOT/au.sh`, a copy
  made at setup time; neutering the source without re-seeding tests the *old* code and
  reports a false "no teeth".
- **Test delivery, not presence.** A schedule can contain the text `AU_APPLY=1` and still
  never deliver it; S24b runs the real shape under two shells to catch exactly that (S24's
  grep alone passed the broken line).

Time-based behaviour is env-tunable (`AU_POLL_EVERY`, `AU_POLL_TRIES`, `AU_SETTLE_SECONDS`,
`AU_UPDATE_TIMEOUT`, `AU_CHECK_TIMEOUT`, `AU_UPDATE_KILL`, `AU_REALERT_SECS`,
`AU_AHEAD_REMIND_SECS`) so the drain-timeout and wedged
branches run in seconds instead of minutes; if you add a poll or wait anywhere, add the same
knob and set it in the matrix's `run()` or nobody will ever exercise that path.
