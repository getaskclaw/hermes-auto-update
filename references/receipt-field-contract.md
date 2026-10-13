# Receipt Field Contract (`update_receipts/latest.json`)

Machine-written by the updater at finalize time. This is the classification source of truth — never grep human-readable updater output when a field exists here.

## Fields that matter for classification

- `outcome` — `success` | `partial` | `failed` | `refused` | `running` | `missing` (no file). The script maps: success → ✓; partial → wait for gateway catch-up then ✓ (or a neutral "still draining" verdict on timeout — a timeout is NOT failure, drain can legitimately take 30 min); failed/missing → ✗ with dedup (alert on attempt 1, re-alert every 12th attempt; any success path resets the counter).
  - Freshness rule: `finished_at` (ISO, carries tz offset — `datetime.fromisoformat(...).timestamp()`) must be ≥ the epoch captured BEFORE launching `--yes` (±5s skew) or the receipt predates this run and says nothing about it. Pull-stage failures (merge conflict, syntax-guard rollback, SIGKILL) exit without finalizing, leaving the previous run's receipt on disk; a pre-pull admission refusal finalizes `refused` (best-effort, via `record_refusal_receipt`).
- `pre_update.short_sha` vs `post_update.short_sha` — the SHA advancing proves the install was real, not a false success.
- `fleet[].state` — `current` | `stale`. Frozen at finalize time; a drain finishing AFTER finalize leaves `stale` rows even though the gateway is now current (see SKILL.md pitfall). Cross-check live state via `gateway_state.json` (`code_sha` == git HEAD) AND `systemctl --user is-active hermes-gateway` = active before treating a gateway as confirmed — a SHA match against a stale state file alone can hide a crashed gateway.
- `gateway_restart.incomplete` — `true` means the updater could not prove the restart landed; the updater exits 1 on this path (source: `_restart.incomplete → sys.exit(1)` in the updater's fleet module).

## Frozen-receipt reconciliation

A lingering `~/.hermes/fleet_restart_pending` marker + "⚠ A previous update pulled new code" warning means an OLD receipt's fleet rows are stale relative to the live gateway. Discharge it with a real `hermes update --yes` (even when up to date — the catch-up path runs on the "Already up to date" branch too). Do not hand-delete the marker: the updater reconciles against identity-matched gateways, and deleting it out from under a genuine obligation can strand the fleet on pre-update code.

## Classification decision table

| exit | fresh receipt says | output contains | verdict |
|---|---|---|---|
| 0 | success | — | ✓ notify |
| 0 | partial/missing | — | set `drain_pending` BEFORE the poll; poll 6×30s for gateway catch-up (gateway_state `code_sha` == git HEAD AND systemd is-active) → ✓; on timeout → neutral "still draining", exit 0, marker makes the next no-update tick re-verify (S12: a script killed MID-poll must still leave the marker — write it before the wait, not only on timeout) |
| 0 | stale | `Already up to date` | silent no-op (beaten by another updater) |
| 0 | stale | other | ⚠ inconclusive, exit 1 |
| ≠0 | success/partial | `post_update.short_sha` != `pre_update.short_sha` (SHA advanced), OR `Update complete` as fallback | ✓ notify with race note; do NOT clear `drain_pending` — the gateway is exactly the unverified thing; refresh the marker so the next no-update tick re-verifies (a marker may be cleared ONLY after positive verification: sha match + is-active, never merely because the verdict "isn't a failure") |
| ≠0 | partial with `post_update.short_sha` == `pre_update.short_sha` and no text marker | — | ✗ REAL FAILURE — the code did not land; do not report a race success |
| ≠0 | anything else | — | ✗ REAL FAILURE notify (dedup: attempt 1, then every 12th) |

Freshness rule: the receipt is evidence about THIS run only when `finished_at >= RUN_STARTED - 5s`, with `RUN_STARTED=$(date +%s)` captured BEFORE launching `--yes` — capturing it after the update makes a fresh receipt misread as stale (clock-order bug). A fresh `refused` receipt (admission refusal, exit 2) classifies as failure.

The race branch's discriminator is the SHA PAIR, not the banner: `post_update.short_sha != pre_update.short_sha` proves the install landed even when the output was reworded and even when the exit code is non-zero. Text is a fallback only. Do NOT simplify this to "fresh partial → success": `partial` is also produced by a failed dependency install after a successful pull, and that case must stay a failure (dropping the discriminator trades a false failure for a false success — the worse error). Both directions need a scenario: SHA-advanced + no text → ✓ (S18), SHA-unchanged + no text → ✗ (S19).

Only "Already up to date" is a legitimate no-update wording for `--check`; any other no-update-looking body is inconclusive → check-failure counter (3/24 alert cadence), never a silent tick.

## Receipt claims vs what the updater actually verifies

- receipt=success carries a sha-verified fleet snapshot: the updater's post-restart fleet matrix compares every live gateway's stamped `code_sha` against the fresh checkout (update_cmd_fleet.py explicitly does NOT assume the restart phase worked). So receipt=success is NOT "no verification at all" — but the residuals are real: a crash in the window AFTER the fleet matrix runs (narrow), and no is-active check (a running-but-sick gateway still shows a current sha). Keep drain_pending through the receipt and clear only after the script's own recheck (sha match + is-active).
- When an external reviewer grades a defect "critical" on the basis of what a receipt value means, read the upstream source for that value's full contract before accepting the grade — a claim that receipt=success "lacks any sha check" was verifiably wrong, and accepting it would have mis-graded the fix.

## Alert dedup covenants

Every alert path needs a consec-counter or persistent failures spam one notification per cron tick. Three counters coexist, each reset by its own success:

- `consec_check_fails` — check/fetch failures and unrecognized `--check` output; alert at 3, then every 24th.
- `consec_notify_fails` — curl delivery failures AND missing/empty credentials (the dead channel can't page, but it must count + log); alert at 3, then every 24th.
- `consec_real_fails` — real update failures; alert on attempt 1 (a NEW failure pages immediately), re-alert every 12th; reset by every success-path exit.

When adding a fourth alert path, give it its own counter — do not reuse another path's counter (different reset conditions).

## Counter sanitizer contract

The numeric guard on a counter read has THREE jobs, and only the first aborts loudly:

1. Non-digit garbage → `$((10#v))` raises `value too great for base` (rc≠0 expression error). Strip with `tr -cd '0-9'` and treat empty as 0.
2. Overlong all-digit strings → bash overflows SILENTLY to a negative value (rc=0, e.g. 26 nines → `-2537764290115403777`). A single-sided `> max` guard cannot catch a negative, so the bad value passes and the alert is delayed one tick. Clamp by length BEFORE the arithmetic: `if [ "${#v}" -gt 6 ]; then v=0; fi`.
3. Negative / out-of-range survivors → the existing `> max` check re-zeros them.

Test the sanitizer through a path that READS the counter, and assert on stderr (no `value too great for base` may escape) — an end-value assertion cannot see the difference: a failed arithmetic expression is replaced by `1`, which is numeric. The read_counter teeth live in gate step 4/4 (neuter `tr -cd '0-9'` → `cat`; the probe must FAIL on that build).