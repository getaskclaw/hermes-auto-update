# verify/ — hermetic stub harness

Runs the updater against **stub** `hermes`, `curl` and `systemctl` in a throwaway workspace:
no real hermes binary, no real gateway restart, no Telegram message. The stub is inserted as
the **first** absolute-path candidate, which is the only way to win the candidate race —
otherwise a "test" run can fire a real update.

```bash
bash stub_setup.sh /path/to/auto_update.sh    # build the harness (HARNESS_ROOT, default ${TMPDIR:-/tmp}/au-harness)
bash stub_matrix.sh                           # run every scenario, print PASS/FAIL + its own tally
```

`stub_setup.sh` refuses to continue if it cannot prove the stub is first in the candidate
list. `mode` files drive the stub — check phase: `uptodate | weird | checkfail |
checkwedge`; install phase: `ok | partial0 | race | race_sha | race_same | noop |
weirdyes | fail | wedged`. `gw_down` makes the stub `systemctl is-active` return `inactive`;
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
| S16 | exit0 + stale receipt + unrecognized output, HEAD unchanged | UNPROVEN no-op (PATCH5) → exit 1 + 1 ⚠ reminder, not a real failure, never marked installed |
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

## Issue #1 acceptance points → the test that carries each

The stable-channel / alerting behaviour of issue #1 is asserted in
`scripts/check_compat_sanity.py` (a fake clock, per-scenario fake HOME, the same stub-first rule
as this harness), not in `stub_matrix.sh`. `scripts/release_gate.sh` runs both (step 2 = matrix,
step 3b = compat probe, step 3c = upstream print corpus over every official release) and neuters
each guard in step 4.

| acceptance point | test (`scripts/check_compat_sanity.py` unless noted) | gate teeth (step 4) |
|---|---|---|
| 6 stable shapes + main shapes classified right (incl. retired line, cleanup lines, CRLF, older ☤, a real `--check` capture); `No newer release` only with the ahead label | `StrictVerdicts.test_upstream_shapes_classify`, `Verdicts.*` | `anchor`, `unknownline`, `noneweraheadonly` |
| error / near-miss / mixed / unknown-line / prefixed-available output never "no update", never install | `StrictVerdicts.test_error_and_unknown_shapes_fail_closed`, `StrictVerdicts.test_unknown_three_times_alerts_with_offending_line`, `Banners.*`, `Hardening.*` | `anchor`, `unknownline`, `errorword`, `availanchor` |
| `--yes` without a receipt: a line with a ✗ anywhere or a whole-word error word → real failure with the line in the alert (B500 rows 1/3, SGR, CRLF, `ok\r✗` overwrite, typographic apostrophe, hyphen boundary, `0 failed`), also with a proven receipt; `errors` / `unfailed` are not errors; the 4 exempt upstream sentences pass only whole | `YesErrorVeto.*` | `yeserror`, `exemptwhole`, `midlinex` |
| `--yes` without a receipt and no error line: HEAD unchanged → legitimate no-op whatever the sentences say (r5A default / named profile `: up to date`, dashboard action id, legacy `⚕` banner runs, stable / held / stable-ahead / fork / full tail / CRLF, stale or foreign receipt; B500 rows 2/4) — PATCH5: silent + reset only with THIS run's proven receipt, otherwise one ⚠ reminder, no reset (each row is run both ways) — healthy marker cleared / unhealthy kept; HEAD moved → install unproven + marker; HEAD unreadable before / after / both → inconclusive; completion line → unproven; real install runs still install | `YesHeadState.*`; matrix S16/S16b/S16c | `headcompare`, `headunknown` |
| stuck guard: available + nothing to do, 3rd in a row → alert with the `--yes` tail, then every `AU_CHECK_ALERT_INTERVAL`; undelivered retries; cleared by a proven install and by up-to-date / held / rollback; failures in between neither count nor clear | `StuckGuard.*` | `stuckguard`, `stuckclear` |
| every official upstream release: `--check` conclusion templates classify (registered findings listed), every `--yes` error-word hit reviewed, exempt samples pass, error lines still vetoed | `scripts/upstream_print_corpus.py --gate` (gate step 3c) | `exemptwhole` |
| every legitimate no-op resets `consec_real_fails` (old failure → no-op → new failure alerts at once); for `--yes` only a PROVEN no-op (PATCH5) | `NoopResetsRealFails.test_yes_noop_proven_receipt`, `.test_check_time_uptodate_held_rollback`; matrix S22 | `noopreset` |
| PATCH5 silence needs positive evidence: a `--yes` no-op without a receipt of this run reminds (⚠) from the first tick, keeps `consec_real_fails`, never `mark_installed`; the real gen-3 receipt (`verify/fixtures/`) is silent | `OptionD.*`, `NoopResetsRealFails.test_yes_noop_*_keeps_streak`, `StuckGuard.test_unproven_*`, `YesHeadState.*` (proven / unproven); matrix S16 | `corrmatch`, `unprovenremind`, `unprovenreset`, `followups` |
| PATCH5 B1201: a ✗ anywhere in a `--yes` line (after SGR / CR removal) is an error | `YesErrorVeto.test_error_line_is_a_real_failure` (`b1201-*` rows) | `midlinex` |
| PATCH5 B1102: the corpus tool fails on a parse error / a 0-print tag / an empty corpus | `CorpusToolFailsClosed.*` | `parseerror`, `zeroprints`, `emptya` (tool neuters) |
| v5.16: every path reaching `mark_installed` relays the receipt's `user_action` / `followups` as ONE ⚠ reminder per `update_id` (after the ✓; install verdict, counters and exit code unchanged; queued before delivery, retried every tick until delivered; malformed fields never crash, never silent; nothing owed = exactly v5.15) | `OwedActionNotice.*` (fixture `verify/fixtures/receipt_partial_user_action_v0.23.2.json`, the real 11-18 receipt) | `owednotice`, `owededupe`, `owedstamp`, `owedretry` |
| v5.16 B1300: a short_sha length change (7 vs 8) of the same commit, or a short_sha contradicting its own side's full sha, is not a SHA advance | `ShaAdvanceB1300.*` | `shaadvance` |
| exit≠0 multi-line output: the alert carries the real ✗ / error line, even after line 9 | `AlertSummary.*`, `Summary.*` | `summarypriority` |
| check alerts by wall clock (first at 3rd, daily cadence with a 1h margin: start jitter and DST do not slip a day, undelivered retries) | `Cadence.*` (incl. `Cadence.test_daily_ticks_with_start_jitter_alert_every_day`, `Cadence.test_dst_short_day_still_alerts`) | `alertstamp`, `checkinterval` |
| real-failure re-alert by wall clock (daily schedule: re-alert after 3–4 days) | `RealFailureCadence.*`; matrix S4/S25 (dedup) | `realclock` |
| notify-failure dead letter by wall clock | `NotifyFailureCadence.*`; matrix S8/S17/S21 | — |
| checkout-newer reminder: low frequency, never installs, never a check failure | `RollbackReminder.*`, `Verdicts.test_rollback_never_installs_and_notifies_once` | `remindclock` |
| corrupted / empty / future timestamps and garbage knobs: no crash, no permanent silence | `Cadence.test_garbage_overflow_future_timestamps_alert_and_self_heal`, `RealFailureCadence.test_corrupt_or_future_stamp_alerts_and_self_heals`, `RealFailureCadence.test_knob_override_and_garbage`, `RollbackReminder.test_undelivered_reminder_retries_and_corrupt_stamp_self_heals`; counters: `scripts/counter_sanity.sh` | `sanitizer`, `clamporder` (counters) |
| version from both completion-line formats | `Verdicts.test_stable_available_installs_to_arrow_destination`, `Verdicts.test_legacy_available_installs_with_legacy_completion` | — |
| receipt binding: production `pre_update`/`post_update` schema, legacy checkout proof both ways, foreign correlation id, uncorrelated exit/drain | `ReceiptBinding.*`, `RealMovement.*`, `Receipts.*`, `Hardening.test_legacy_fresh_success_without_completion_or_movement_not_marked` | `checkoutproof` |
| no install without `AU_APPLY=1` | `Banners.test_noisy_available_is_report_only_without_apply`; matrix S23/S24/S24b | `applygate` |
| existing behaviour (drain marker, kill mid-poll, wedges, bare env) | matrix S1–S26; `scripts/marker_lifecycle_sweep.sh` | — |

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
`AU_UPDATE_TIMEOUT`, `AU_CHECK_TIMEOUT`, `AU_UPDATE_KILL`) so the drain-timeout and wedged
branches run in seconds instead of minutes; if you add a poll or wait anywhere, add the same
knob and set it in the matrix's `run()` or nobody will ever exercise that path.
