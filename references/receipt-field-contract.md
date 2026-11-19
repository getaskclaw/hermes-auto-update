# Receipt Field Contract (`update_receipts/latest.json`)

Machine-written by the updater at finalize time. This is the classification source of truth — never grep human-readable updater output when a field exists here.

## Fields that matter for classification

- `outcome` — `success` | `partial` | `failed` | `refused` | `running` | `missing` (no file). The script classifies ONLY from its own private, immutable post-run snapshot of this file. The snapshot is copied once after `--yes` exits, and the live file is never re-read for the verdict. Mapping: proven success → ✓; proven partial → wait for gateway catch-up then ✓ (or a neutral "still draining" verdict on timeout — a timeout is NOT failure, drain can legitimately take 30 min); failed/refused/running/unknown value → ✗ with dedup (alert on attempt 1, then every `AU_REALERT_SECS` of wall clock; any success path or legitimate no-op resets the counter). Gateway health can NEVER upgrade failed/refused/running/unknown to success. Missing (no file) → never an install; a benign no-op drain recheck applies only on exit 0 when the output matches `RE_NOOP` AND nothing in the same output vetoes it (a ✗ line, an error / failed / timed out line, an available or checkout-newer verdict line — vetoed = REAL FAILURE). Unknown output is an inconclusive warning (exit 1), and a non-zero exit with a missing receipt is a real failure (see the decision table).
  - Freshness rule: `finished_at` (ISO, carries tz offset — `datetime.fromisoformat(...).timestamp()`) must be ≥ the epoch captured BEFORE launching `--yes` (±5s skew) or the receipt predates this run and says nothing about it (`stale` → rejected). The 5s is a clock-skew TOLERANCE, not identity: a receipt inside the window is merely not-stale, and that alone does not make it this run's receipt.
  - Identity rules (applied to the post-run snapshot before any outcome is trusted):
    1. The digest of `latest.json` captured BEFORE launch must differ from the snapshot's digest. An equal digest means the updater did not finalize this run (`unchanged` → rejected).
    2. When the receipt carries a correlation id, it must equal the id this invocation passed. The implementation classifies a mismatch as `stale` (rejected). `foreign` is reserved for a receipt of a non-install kind (e.g. `kind=plugin-check`).
    3. A legacy receipt with no correlation id is owned by this run ONLY as follows. On exit 0, either of two proofs suffices. The first is that this run's own output contains the anchored completion line, matched at LINE START with an exact phrase boundary rather than as a substring; a trailing suffix such as a version is allowed. The second is that the checkout was observed to move along the receipt's SHA pair: HEAD captured before launch matches `pre_update.short_sha` and HEAD after exit matches `post_update.short_sha`, with the two differing. Each match is a valid-prefix match, not string equality. On a non-zero exit, the anchored completion line is REQUIRED, and observed checkout movement alone is insufficient.
    4. A snapshot that cannot be parsed is `unreadable` (rejected).
    5. A same or missing SHA pair does not by itself reject an install when an affirmative anchored completion line is present. Actual no-op output, with no completion line and no movement, is never an install. Pull-stage failures (merge conflict, syntax-guard rollback, SIGKILL) exit without finalizing, leaving the previous run's receipt on disk; a pre-pull admission refusal finalizes `refused` (best-effort, via `record_refusal_receipt`).
- `pre_update.short_sha` vs `post_update.short_sha` (v5.16, B1300: per side the full `sha` when present, else `short_sha` ≥ 7 hex; both full → full compare, otherwise the common prefix; a length change of the same commit, or a `short_sha` that contradicts its own side's `sha`, is NOT an advance) — a SHA advance is evidence of code movement, distinguishing a real install from a false success. Both `success` and `partial` additionally require an affirmative completion OR a SHA advance before they count as an install. For a legacy (no-correlation) receipt, the SHA pair counts only on exit 0 and only when it matches the checkout movement this run observed. On a non-zero exit, a legacy receipt requires the anchored completion line. A correlation-matched receipt may use the machine SHA proof even on a non-zero exit.
  - Last successful installation (reported in check-failure alerts): recorded ONLY from a proven install, meaning a ✓ or race-✓ row in the decision table. That requires a fresh, changed-digest, immutable snapshot owned by THIS run, with outcome `success`/`partial` AND an affirmative completion or code movement. Ownership means a matching correlation id. For legacy receipts, it means the anchored completion line, or observed checkout movement on exit 0 only. For an accepted `partial`, the last installation is recorded BEFORE the health poll, and the record stands whether the poll ends healthy or on drain timeout. None of these ever proves an install: a stale receipt (predates `RUN_STARTED`, or carries a correlation id mismatch); a foreign receipt (another operation, e.g. `kind=plugin-check`); an unchanged receipt; an unreadable receipt; a no-op SHA pair without an affirmative completion; an unproven receipt; a missing receipt. Until the first proven install, the value reads `unknown`.
- `fleet[].state` — `current` | `stale`. Frozen at finalize time; a drain finishing AFTER finalize leaves `stale` rows even though the gateway is now current (see SKILL.md pitfall). Cross-check live state via `gateway_state.json` (`code_sha` == git HEAD) AND `systemctl --user is-active hermes-gateway` = active before treating a gateway as confirmed — a SHA match against a stale state file alone can hide a crashed gateway.
- `gateway_restart.incomplete` — `true` means the updater could not prove the restart landed; the updater exits 1 on this path (source: `_restart.incomplete → sys.exit(1)` in the updater's fleet module).

## Frozen-receipt reconciliation

A lingering `~/.hermes/fleet_restart_pending` marker + "⚠ A previous update pulled new code" warning means an OLD receipt's fleet rows are stale relative to the live gateway. Discharge it with a real `hermes update --yes` (even when up to date — the catch-up path runs on the "Already up to date" branch too). Do not hand-delete the marker: the updater reconciles against identity-matched gateways, and deleting it out from under a genuine obligation can strand the fleet on pre-update code.

## Classification decision table

All rows read the private post-run snapshot. "Proven" means the identity rules pass (changed digest, not stale, correlation id matches or legacy ownership proof) AND an affirmative completion or SHA advance. "Health recheck" means gateway_state `code_sha` == git HEAD AND systemd is-active.

| exit | post-run snapshot | ownership / install proof | verdict |
|---|---|---|---|
| 0 | `success` | proven, correlation-matched or legacy-proven | ✓ notify, record last install, THEN run the health recheck; clear `drain_pending` only on a positive recheck |
| 0 | `partial` | proven | record last install BEFORE the poll (stands whether the poll ends healthy or on drain timeout); set `drain_pending` BEFORE the poll; poll the CURRENT gateway 6×30s for catch-up (health recheck) → ✓; on timeout → neutral "still draining", exit 0, marker makes the next no-update tick re-verify (S12: a script killed MID-poll must still leave the marker — write it before the wait, not only on timeout) |
| ≠0 | `success`/`partial` | proven (correlation-matched: SHA advance or anchored completion; legacy: anchored completion line REQUIRED, checkout movement alone insufficient) | ✓ notify with race note; record last install; do NOT clear `drain_pending` — the gateway is exactly the unverified thing; refresh the marker so the next no-update tick re-verifies (a marker may be cleared ONLY after positive verification: sha match + is-active, never merely because the verdict "isn't a failure") |
| any | `failed` / `refused` / `running` / unknown value | fresh, changed digest, correlation not mismatched | ✗ REAL FAILURE notify (dedup: attempt 1, then every `AU_REALERT_SECS`); gateway health NEVER upgrades this to success; no install mark |
| any | `partial`, owned or legacy | `post_update.short_sha` == `pre_update.short_sha` and no affirmative completion | ✗ REAL FAILURE — the code did not land; do not report a race success |
| any (missing: exit 0 only) | missing / foreign (non-install kind, e.g. `kind=plugin-check`) / stale (incl. correlation mismatch) / unchanged (digest == pre-run) / unreadable; OR owned `success` with a no-op pair and no affirmative completion; OR legacy `success` with neither the anchored completion line nor matching observed movement | no completion line in output, AND output matches `RE_NOOP` (e.g. Already up to date / hold / no newer release), AND no veto (no ✗ line, no error / failed / timed out line, no available or checkout-newer verdict line) | no-op: drain recheck (health recheck), then reset `consec_real_fails`; exit 0 if healthy, 1 otherwise; no install mark; last install untouched; marker cleared only on a positive recheck. A vetoed no-op is a ✗ REAL FAILURE (counted, alerted, exit 1) |
| any (missing: exit 0 only) | same as the row above | no completion line, and output does NOT match `RE_NOOP` (unknown) | ⚠ inconclusive warning, exit 1; retain the marker; no install mark; last install untouched |
| ≠0 | missing | no completion line | ✗ REAL FAILURE notify (dedup: attempt 1, then every `AU_REALERT_SECS`); no install mark; last install untouched |
| any | missing / foreign / stale / unchanged / unreadable | completion line present, but ownership NOT proven | ⚠ unproven, exit 1; retain the marker; no install mark; last install untouched |

Freshness rule: the receipt can be evidence about THIS run only when `finished_at >= RUN_STARTED - 5s`, with `RUN_STARTED=$(date +%s)` captured BEFORE launching `--yes` — capturing it after the update makes a fresh receipt misread as stale (clock-order bug). The 5s window is skew tolerance, not identity: freshness is necessary but never sufficient. Ownership comes from the pre-run digest check, the correlation id, and (legacy only) the anchored completion line or, on exit 0 only, observed checkout movement. A fresh, non-foreign `refused` receipt (admission refusal, exit 2) classifies as failure, and gateway health never upgrades it.

The race branch's discriminator is the SHA PAIR, not the banner: on a correlation-matched receipt, `post_update.short_sha != pre_update.short_sha` proves the install landed even when the output was reworded and even when the exit code is non-zero. On a legacy (no-correlation) receipt, the pair proves it only on exit 0, and only when it matches the checkout movement this run observed (HEAD before launch matches `pre_update`, HEAD after exit matches `post_update`, each by valid prefix). On a non-zero exit, a legacy receipt needs the anchored completion line. Text is a fallback only, and only as the anchored completion line in this run's own output. Completion text next to an un-owned receipt (missing/foreign/stale/unchanged/unreadable) yields ⚠ unproven (exit 1, marker retained), never ✓. A proven non-zero ✓ still leaves the `drain_pending` marker in place and carries the race note. Do NOT simplify this to "fresh partial → success": `partial` is also produced by a failed dependency install after a successful pull, and that case must stay a failure (dropping the discriminator trades a false failure for a false success — the worse error). Both directions need a scenario: owned/observed SHA-advanced + no text → ✓ (S18); SHA-unchanged `partial` + no text → ✗ (S19).

`--check` has no machine-readable form upstream (bare store_true, `hermes_cli/subcommands/update.py:18-20`; `print()` verdicts with exit 0, `hermes_cli/update_cmd_check.py:97-125` and `:191-228`). Verdicts are matched as WHOLE upstream lines (stable `:110/:112/:115/:119/:123`; main `:200/:208/:222`, `:212/:214/:225`, plus the older `☤` glyph); known context and `  (…)` cleanup lines carry no verdict; any ✗, any error / failed / timed out word, any other non-empty line, or two different verdicts → unknown:

| `--check` outcome | action |
|---|---|
| up to date | silent |
| `hold` | benign: no install, not a check failure |
| update available | only reaches the `AU_APPLY` gate; target version is extracted from the update completion line (new `old→new` form or legacy single version), not the check line |
| checkout newer than the selected release ("rollback") | manual action required; NEVER an automatic `--yes`; reminder every `AU_ROLLBACK_REMIND_SECS` (stamp `rollback_remind_ts`, written on delivery) |
| unknown / failed | still blocked: no install, check-failure counter, never a silent tick |

Check-failure alert cadence:
- First alert at the 3rd consecutive failure.
- After that, time-based re-alerts every `AU_CHECK_ALERT_INTERVAL` seconds (default 82800 = 1 day − 1h; the margin absorbs start jitter and DST).
- Interval values must be positive integer seconds; an invalid, empty, or zero value falls back to the default.

## Receipt claims vs what the updater actually verifies

- receipt=success carries a sha-verified fleet snapshot: the updater's post-restart fleet matrix compares every live gateway's stamped `code_sha` against the fresh checkout (update_cmd_fleet.py explicitly does NOT assume the restart phase worked). So receipt=success is NOT "no verification at all" — but the residuals are real: a crash in the window AFTER the fleet matrix runs (narrow), and no is-active check (a running-but-sick gateway still shows a current sha). Keep drain_pending through the receipt and clear only after the script's own recheck (sha match + is-active).
- When an external reviewer grades a defect "critical" on the basis of what a receipt value means, read the upstream source for that value's full contract before accepting the grade — a claim that receipt=success "lacks any sha check" was verifiably wrong, and accepting it would have mis-graded the fix.

## Alert dedup covenants

Every alert path needs a consec-counter or persistent failures spam one notification per cron tick. Three counters coexist, each reset by its own success:

- `consec_check_fails` — check/fetch failures and unknown/failed `--check` outcomes.
  - Alert at 3, then on a time basis every `AU_CHECK_ALERT_INTERVAL` seconds (default 82800; invalid/zero → 82800).
  - The last-alert timestamp is written ONLY after the notification is delivered, so an undelivered alert retries next tick.
  - Migration: a count N>3 with no timestamp alerts on the next tick.
  - The alert carries the consecutive count, the last successful installation, and the real error (multiline, bounded).
- `consec_notify_fails` — curl delivery failures AND missing/empty credentials (the dead channel can't page, but it must count + log); dead letter + meta-alert at 3, then every `AU_REALERT_SECS` of wall clock (`notify_alert_last_ts`, written with the dead-letter entry).
- `consec_real_fails` — real update failures (incl. a vetoed `--yes` no-op); alert on attempt 1 (a NEW failure pages immediately), then every `AU_REALERT_SECS` of wall clock (`real_alert_last_ts`, written only on delivery); reset by every success-path exit AND every legitimate no-op exit (check-time up-to-date / held / checkout-newer, and the `--yes` no-op that passed the veto AND is proven by this run's receipt — PATCH5 `PROVEN_NOOP`: `outcome=success`, `correlation_id` == the `HERMES_UPDATE_CORRELATION_ID` passed, no `followups` / `user_action`, pre/post `short_sha` equal and a prefix of the observed HEAD), after the drain recheck. An unproven `--yes` no-op never resets it (⚠ reminder instead, from the first one).
- Every timestamp is the tick-start epoch and is read through `read_ts`: empty / garbage / over-long / more than 300s in the future = no stamp → alert now, overwrite on delivery.

When adding a fourth alert path, give it its own counter — do not reuse another path's counter (different reset conditions).

## Counter sanitizer contract

The numeric guard on a counter read has THREE jobs, and only the first aborts loudly:

1. Non-digit garbage → `$((10#v))` raises `value too great for base` (rc≠0 expression error). Strip with `tr -cd '0-9'` and treat empty as 0.
2. Overlong all-digit strings → bash overflows SILENTLY to a negative value (rc=0, e.g. 26 nines → `-2537764290115403777`). A single-sided `> max` guard cannot catch a negative, so the bad value passes and the alert is delayed one tick. Clamp by length BEFORE the arithmetic: `if [ "${#v}" -gt 6 ]; then v=0; fi`.
3. Negative / out-of-range survivors → the existing `> max` check re-zeros them.

Test the sanitizer through a path that READS the counter, and assert on stderr (no `value too great for base` may escape) — an end-value assertion cannot see the difference: a failed arithmetic expression is replaced by `1`, which is numeric. The read_counter teeth live in gate step 4/4 (neuter `tr -cd '0-9'` → `cat`; the probe must FAIL on that build).

## Owed actions after a proven install (v5.16)

- `user_action` (`{"step", "reason"}`, upstream `record_user_action`; makes the run `partial`, exit 1) and `followups` (`[{"step", "reason", "at"}]`, upstream `record_followup`; the run stays `success`) are read from the SAME receipt snapshot on every path that reaches `mark_installed`.
- Any truthy value → one ⚠ reminder after the ✓ notice (step + reason verbatim, sanitized, bounded). Empty values (`null`, `""`, `[]`, `{}`, `false`, `0`) → nothing owed.
- The reminder never changes the install verdict, the counters or the exit code.
- No local queue (fix round 3): at every tick start and after the ✓ the receipt directory (`latest.json` + upstream's `update_*_<update_id>.json` archive, read only) is scanned; a receipt is reminded about when its `correlation_id` is this version's `au-r1-<epoch>-…` with `kind` absent / `update` and `outcome` `success` / `partial` — no SHA required (fix round 4, r11A B2100: `get_code_identity` may write `sha=None` or `{}` for a real install) — or its key is in `state/auto_update/owed_action_claims` (written before `mark_installed`; required only for legacy receipts without `correlation_id`), it is within 30 days / the newest 50 files, and its key is not in the dedupe ledger `state/auto_update/owed_action_notified` (key = `id-<update_id>`, else `sha-<receipt sha256>`; written only after `ok:true`, read back). Receipts launched by older updater versions (old `au-<ns>-…` ids) count as handled.
- On no-op paths these fields keep their PATCH5 meaning: a receipt owing either one never proves a clean no-op.
