# Hermes Auto-Update

[简体中文](README.md) · English

Hands-off [Hermes Agent](https://github.com/NousResearch/hermes-agent) updates via a system-cron job outside the gateway process tree; notifies Telegram only for real outcomes.

Current version: **updater v5.16** (this is the updater's own version — distinct from the Hermes version it installs; see "v5.16 release notes" and "v5.15 release notes" below).

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
| `AU_CHECK_ALERT_INTERVAL` | check-failure re-alert interval in seconds (default `82800` = 1 day − 1h). Must be a positive integer; an invalid, empty, or `0` value falls back to the default |
| `AU_REALERT_SECS` | re-alert interval for real install failures and notify-delivery failures, seconds (default `255600` = 3 days − 1h). Same rules |
| `AU_ROLLBACK_REMIND_SECS` | reminder interval for "checkout newer than the selected release", seconds (default `601200` = 7 days − 1h). Same rules |

See SKILL.md + references/wsl-deployment.md for the full checklist.

## Notification design

Silence when up to date. `✓` on install (headline the Hermes version, name the updater version), `✗` on failure. When an install's receipt still owes a `user_action` / `followups`, one `⚠` owed-action reminder follows the `✓` (v5.16, once per `update_id`, see "v5.16 release notes").

### How `update --check` is classified

Upstream `hermes update --check` has **no machine-readable output**: `--check` is a bare boolean flag (`hermes_cli/subcommands/update.py:18-20`) and every verdict is one `print()` followed by exit 0 (`hermes_cli/update_cmd_check.py:97-125`, `:191-228`; the file is byte-identical in v0.23.1 / v0.23.2 / upstream main 67e4d22). So the text is the contract, matched **whole line** against the upstream sentences (surrounding whitespace and one trailing CR trimmed):

| verdict | upstream sentence (`update_cmd_check.py`) | action |
|---|---|---|
| up to date | `:110` `✓ No newer release: {ahead label}.`, `:112` `✓ Up to date with the latest release ({label}).`, `:200/:208/:222` `✓ Already up to date.` | silent, no install, not a check failure |
| held | `:115` `→ Holding at this build: {label} predates the gateway runtime your sessions use.` | same, one log line |
| checkout newer than the selected release | `:119` `→ This checkout is newer than the selected release: {label}.` | NEVER an automatic `--yes` (it would downgrade); not a check failure; low-frequency reminder (`AU_ROLLBACK_REMIND_SECS`) for a human decision |
| update available | `:123` `→ Selected release available: {label}`, `:212/:225` `⚕ Update available: N commit(s) behind <ref>.`, `:214` `⚕ Update available (behind <ref>).` | reaches the `AU_APPLY` gate only; the version comes from the completion line (new `old → new` form: the destination; legacy single version), never from the check line |
| unknown | anything else | no install, counted as a check failure, alert on the 3rd in a row |

- `{label}` looks like `stable v0.23.2 (ae2a81ccc00e)` (`source_releases.py:61-65`). `No newer release` is printed only when `target.ahead` (`update_cmd_check.py:109-110`), and then the label is always the long "checkout is newer and waits for the next release" form (`source_releases.py:62-64`), so that sentence accepts **only** the long form; a short label after it never ships and is unknown.
- Older main-channel builds printed the same two sentences with the `☤` glyph (v2026.9.24), earlier with `⚕`; no release ever printed a glyph-less `--check` verdict, so a glyph-less line is not accepted.
- Known context lines carry no verdict and are accepted: `:97` channel banner, `:108` retired line, `:116-117/:120-121/:124/:215/:228` hints, `:143/:164` `→ Fetching from …...`, and the `  (…)` cleanup lines `:49/:52/:62/:65/:180/:183`.
- **Veto**: any line with `✗`, any line containing `error` / `failed` / `timed out` (any case), any other unrecognized non-empty line, or two different verdicts → the whole output is unknown. Alert rather than "no update" — and never install.

### `--yes` "nothing to do" (PATCH4: observable state; PATCH5: silence needs positive evidence)

When `--yes` exits 0 without an **install** receipt of its own for this run, **the conclusion sentence is not read** (earlier rounds judged sentence shapes and kept misjudging normal output in both directions, three rounds in a row; that direction does not converge). Text is used only to find errors (it can only add alerts); whether the run may stay silent is decided by this run's receipt alone. In order:

1. A completion line (`✓ Update complete…`) → "install unproven" alert, `drain_pending` set, exit 1 (unchanged since v5.15).
2. **Error veto**: after removing SGR colour codes, turning in-line CRs into spaces and trimming surrounding whitespace, a line that holds a `✗` **anywhere** (PATCH5, B1201: `ok\r✗ …` is a terminal overwrite), or that contains an error word (any case, **whole word** — the characters on both sides are not letters, digits or `_`; any run of spaces inside the multi-word forms): `error`, `failed`, `failure`, `timed out`, `could not`, `couldn't` (also `’`), `cannot`, `unable to`, `traceback` → real failure (counted, the alert carries that line, exit 1, no reset). Whole word means `0 failed` hits while `errors` / `unfailed` do not. A receipt of this run does not lift the veto.
3. HEAD is read before and after `--yes` with a read-only `git rev-parse --verify HEAD` (`PRE_HEAD` / `POST_HEAD`). Either one unreadable (not 40/64 hex) → inconclusive: alert, exit 1.
4. HEAD moved → code moved without a receipt of this run: "install unproven" alert, `drain_pending` set, exit 1.
5. HEAD unchanged → nothing to do; never marked installed (`mark_installed` is not called); drain recheck first. Then two branches (PATCH5, option D):
   - **5a proven (`PROVEN_NOOP=1`)**: this run's receipt has `outcome=success`; `correlation_id` equal to the `HERMES_UPDATE_CORRELATION_ID` the script passed to `--yes`; no `followups` and no `user_action`; `pre_update.short_sha == post_update.short_sha`, and the observed HEAD starts with it. → `consec_real_fails` reset, counted by the stuck guard, **silent exit 0**.
   - **5b unproven (everything else: no receipt; a stale / foreign / unchanged / id-less receipt; or one that still owes followups)** → a ⚠ reminder "the check says an update is available, but it was not installed and the updater left no receipt of this run — please take a look", with the last 6 lines of the `--yes` output, from the **first** such tick on; throttled by wall clock every `AU_CHECK_ALERT_INTERVAL` (shares `available_noop_alert_last_ts` with the stuck guard, written only on delivery); **not** a real failure (not counted, no ✗), **no** streak reset; **exit 1** (the scheduler log shows a tick that needs a look; the counters stay as they were).

Why `followups` must be empty: upstream runs the same completion tail (dependency sync etc.) on its "already up to date" path; when a step fails the receipt **stays `success`** and only lists the owed step in `followups`, and the printed line (`⚠ Update follow-up '<step>' did not finish: …`) need not carry an error word (measured receipt: `verify/fixtures/receipt_noop_deps_owed_v0.23.2.json`). So "success" alone is no evidence of a clean no-op.

### Upstream receipt generations (measured in PATCH5)

`--check` has no machine-readable output (previous section); `--yes` **has a receipt from the third generation on**. Per official tag, `hermes_cli/update_receipt.py` read-only (`verify/receipt_probe/receipt_generations.sh`, output `verify/receipt_probe/receipt_generations.txt`):

| Gen | Versions | Tags | Receipt module | `correlation_id` | This script's no-op |
|---|---|---|---|---|---|
| 1 | v2026.3.12 … v2026.8.18 | 28 | no | no | always 5b reminder |
| 2 | v2026.8.19 … v2026.9.24 | 8 | yes | no | always 5b reminder (the receipt carries no id of this run, so it cannot prove it is this run's) |
| 3 | v0.21.6 … v0.23.2 | 13 | yes | yes: `update_receipt.py:135-141` reads `HERMES_UPDATE_CORRELATION_ID`, `:159` stores it as `correlation_id`; command-boundary safety net `finalize_pending_update_receipt` (v0.23.2 `:869-892`) | silent when the receipt satisfies 5a, else 5b |

The third generation really writes that receipt on its "already up to date" path: `update_cmd.py` opens it **before** the `commit_count == 0` decision (v0.23.2 `:1813` → `:1520-1526`, decision at `:1923`; v0.21.6 `:1809` → `:1547-1553`, decision at `:1942`); the no-op goes `_finish_already_up_to_date` → `_complete_source_update` → the completion child `update_completion._finish`, which closes it as `success`. PATCH5 exported these **real functions** of every one of the 13 third-generation tags and ran them isolated, one tag at a time (git / pip / gateway / network stubbed, `HERMES_HOME` in a scratch dir, 0 curl calls): all 13 wrote `outcome=success`, `correlation_id` = the id passed in, identical pre/post SHAs, no `followups` (probe `verify/receipt_probe/receipt_noop_probe.py`; needs the upstream repo, not part of the release gate). The test fixtures `verify/fixtures/receipt_noop_v0.23.2.json` and `verify/fixtures/receipt_noop_v0.21.6.json` are those receipts verbatim.

### Out of scope (by design, not defects)

1. **This tool is an updater, not a host health monitor**: it does not check whether the venv / dependencies, data such as `state.db`, or runtimes other than the gateway are healthy. With the checkout already current, `--check` says "up to date" and `--yes` never runs, so a broken venv is never seen. For a run with this run's receipt, `success` and no `followups`, the script trusts the receipt and does not interpret ⚠ lines in the text.
2. **On builds without a receipt of this run (generations 1 and 2), every "the check says available but nothing was installed" tick reminds** (at most once per `AU_CHECK_ALERT_INTERVAL`), including a perfectly normal race no-op. That is the price of "silence needs positive evidence", by design.
3. **pip / PyPI installs are out of scope** (`--check`'s `⚕ Update available on PyPI.` classifies unknown and never installs; `check_registered` in `verify/upstream_error_review.json`).
4. **Owed-action reminders go by the upstream receipts** (v5.16 fix round 3, see the invariant in "v5.16 release notes"): as long as the receipt is there and inside the look-back bound, the reminder is derived and sent again every tick until it is delivered and recorded — a state dir that is briefly unwritable as a whole (disk full, read-only mount) only delays it. The resulting boundaries: (a) a reminder still undelivered when its receipt has been pruned by upstream (it keeps the last 20 archives), was launched more than 30 days ago, or is not among the newest 50 receipt files is no longer sent (one still in the directory is logged every tick); (b) while the dedupe ledger cannot be written, the same reminder is sent again every tick until it can be recorded (more alerts); a deleted / unreadable ledger may re-send reminders delivered within the bound; (c) a receipt without this tool's new-format `correlation_id` (older Hermes, which does not pass the id back) is recognized only through the claim written at install time — if that claim could not be written either, it is sent on the install tick only; a receipt carrying this tool's id but lacking SHAs is no longer in this case (fix round 4, r11A B2100); (d) a receipt this tool launched with `outcome` `success` / `partial` is reminded about once even if that run was not judged an install (e.g. killed by the timeout, judged stale by clock skew, a no-op owing something) — worded as an install when its SHAs advanced, otherwise saying the receipt alone does not show an install.

The error-word rule was checked against the upstream `print()` templates of every official release (`scripts/upstream_print_corpus.py`, snapshot `verify/upstream_corpus.json`, see "Upstream wording corpus" below): every line it hits is listed in `verify/upstream_error_review.json` as either "reports a failure" or "normal sentence". There are exactly 4 normal sentences, exempted as **whole upstream sentences** (`V_YES_EXEMPT` in `auto_update.sh`, each with its source): a systemd job that timed out but finished (state active / inactive only; `(failed)` stays an error), `ℹ Got updates from upstream but couldn't push to fork (no write access?)`, and two Windows hand-off progress lines.

### Stuck guard (`consec_available_noop`)

Without sentence judging, "the check says an update is available, but `--yes` has nothing to do (and its receipt proves it), every time" would stay silent forever. So: `--yes` runs only after `--check` said "available", and each no-op (5a and 5b alike) counts one `consec_available_noop`; 5b reminds from the first one (above); for 5a the 3rd in a row alerts "the check says an update is available but the installer had nothing to do — suspected stuck", with the check line and the last 6 lines of the latest `--yes` output; after that it re-alerts by wall clock every `AU_CHECK_ALERT_INTERVAL` (default 82800s), the stamp `available_noop_alert_last_ts` written only on delivery. **Cleared** by every proven install (`mark_installed`) and by a `--check` verdict of up to date / held / checkout newer than the selected release. A failed check or a failed install in between **neither counts nor clears** (nothing was installed; an intermittent failure must not hide a stuck installer).

This is also the new verdict on the two B500 rows without an error word (`✓ Already up to date. (cached result from yesterday)`, `→ Holding at this build? Channel status unavailable.`): HEAD unchanged = nothing installed; without a receipt of this run it reminds on the first tick; with a receipt that proves it, silent, and repeated, the stuck guard alerts on the 3rd.

### Alert cadence (all wall clock)

| alert | first | then | knob (seconds) | default and why |
|---|---|---|---|---|
| check failing / unknown (`⚠`) | 3rd in a row | every `AU_CHECK_ALERT_INTERVAL` | `AU_CHECK_ALERT_INTERVAL` | `82800` (1 day − 1h): a stalled pipeline gets a daily reminder. The stamp is the **tick start** time, so the check's own duration (1s vs 300s) cannot shift the cadence. Daily ticks are still not exactly 86400s apart: stamps are whole seconds, so a tick that started 1s late followed by an on-time one is 86399s, and a local-time cron across a DST change is off by 1h. A zero-margin 86400 would slip the reminder a day in those cases, hence the 1h margin |
| real install failure (`✗`) | 1st, at once | every `AU_REALERT_SECS` | `AU_REALERT_SECS` | `255600` (3 days − 1h): the same broken install retried daily is one incident; every third daily tick keeps it visible without a daily page. The 1h margin absorbs scheduler jitter so it cannot slip to the 4th day |
| notify delivery failing (dead letter + meta-alert) | 3rd in a row | every `AU_REALERT_SECS` | same | the local `notify_dead_letter.log` entry IS the delivered artefact, so the stamp is written with it |
| checkout newer than the selected release (`→`) | on entering the state | every `AU_ROLLBACK_REMIND_SECS` | `AU_ROLLBACK_REMIND_SECS` | `604800 − 3600` (7 days − 1h): a human decision, not an emergency — a weekly nudge |
| available but nothing to do, again and again, proven by the receipt (stuck guard, `⚠`) | 3rd in a row | every `AU_CHECK_ALERT_INTERVAL` | same as check alerts | `82800`: the same "pipeline stalled" kind as the check alert, the same daily reminder |
| available but not installed, and no receipt of this run (5b, `⚠`) | 1st | every `AU_CHECK_ALERT_INTERVAL` | same as check alerts | `82800`: no evidence, no silence; not a failure, so the check-alert cadence rather than the real-failure one |
| installed, but the receipt owes a `user_action` / `followups` (v5.16, `⚠`) | that install, after the `✓` | never re-sent once delivered and recorded; otherwise derived from the receipt again and re-sent at the start of every tick until delivered and recorded (look-back bound 30 days / 50 receipts) | none | once per `update_id` (done only when `owed_action_notified` reads it back after delivery): a thing a human must do is said once, and not given up on before it arrives |

- Every stamp (`check_alert_last_ts`, `real_alert_last_ts`, `notify_alert_last_ts`, `rollback_remind_ts`, `available_noop_alert_last_ts`) goes through one reader: empty, garbage, over-long, signed, or more than 300s in the future → "no stamp": alert now and overwrite on delivery (self-heal). Never a `set -u` crash, never silent forever.
- Stamps are written **only after delivery** (dead letter excepted, see above). A failed delivery is retried on the next tick.
- An invalid, empty, `0`, or longer-than-9-digit knob falls back to its default; `00060` reads as 60.
- Migration: a pre-existing counter above its threshold with no stamp alerts once on the next run; the old one-shot `rollback_notified` marker no longer silences the reminder forever.

### Alert content

Check-failure alerts carry the consecutive count, the last successful installation (`unknown` until the first proven install), and the real error: lines with `✗` / error / failed / timed out come first (each with the next line as context), the remaining budget is filled with the other lines in order, and only then is the summary bounded (6 lines, 200 bytes per line, 1000 bytes total). An error after a screen of cleanup chatter is not cut off.

An install is proven only by installation proof bound to the current invocation: a fresh, immutable receipt for THIS run plus an affirmative completion or code movement. Stale, missing, or unrelated (another operation, e.g. `kind=plugin-check`) or unchanged receipts never prove an install.

## v5.16 release notes

- **Relay what upstream says is still owed after an install** (2026-11-18 incident: the v0.23.1→v0.23.2 install was judged correctly, but the receipt's `user_action` — `local_changes`: a local modification stashed and NOT restored, with the stash ref and the re-apply command — reached nobody). After every path that reaches `mark_installed` (correlated success, partial + SHA advance with exit 0, the non-zero-exit race branch, a legacy receipt accepted on this run's own evidence), if the receipt's `user_action` or `followups` is non-empty, **one** ⚠ reminder follows the ✓ notice with `user_action.step` / `reason` verbatim and each follow-up's `step` / `reason` (escape sequences and control characters removed, whitespace collapsed to one line; each reason at most 600 characters — upstream itself caps it at 500, so the stash ref and the re-apply command arrive whole; follow-ups are added up to 3300 bytes and the rest counted; the whole message ≤ 3500 bytes).
  - **The install verdict does not change**: still `mark_installed`, counters still reset, every path exits exactly as in v5.15 (success 0, both partial exit-0 branches 0, race branch 0), whether or not the reminder is delivered.
  - **The invariant** (PR #4 fix round 3, review r10A B1900, r9B B1800 / B1801; in code: the `THE INVARIANT` comment block in `auto_update.sh`, `owed_scan` / `owed_deliver`): **what is owed is decided by the upstream receipts; a reminder is done only when it was delivered (an explicit Telegram `ok:true`) AND its key was written into the ledger and read back.** No copy of a reminder is kept locally any more — the queue dir `owed_action_pending/`, the fallback files `owed_action_fallback.*`, the `.owed_sent.*` markers, the `.owed_q.*` temps and the `gen-` stand-ins of the first two rounds are all gone. Those rounds kept hardening our own copy, and each review found one more way it could not be written, while the source of truth (the receipt) was still there.
  - **Derivation**: at **the start of every tick** (and after the ✓ of an install) the upstream receipt directory `~/.hermes/logs/update_receipts/` is scanned READ ONLY (`latest.json` plus upstream's per-run archive `update_*_<update_id>.json`; nothing in it is ever written, moved or deleted), and every receipt that meets all of the following gets one reminder, its text computed from the receipt each time:
    - **launched by this tool** (fix round 4, review r11A B2100): its `correlation_id` has this version's format `au-r1-<launch epoch>-…` (`AU_CORR_ID`), `kind` is absent or `update`, `outcome` is `success` / `partial` — all read from the receipt, no local state involved. **No pre/post SHA is required**: upstream v0.23.2's `version_info.get_code_identity` legitimately returns `sha=None` when git times out, and `_code_identity` returns `{}` on an error, so the receipt of a real install can lack one or both SHAs. Why: this id is generated by this tool and handed only to the `--yes` this tool launches, so it proves by itself "this is our run"; whether the run installed is the install verdict's job, not the reminder derivation's (the install verdict, the `mark_installed` paths and the B1300 SHA rule are unchanged). The `kind` / `outcome` conditions stay because every path to `mark_installed` needs them, so they filter out no real install. **Or** its key is in `state/auto_update/owed_action_claims`, the claim written **before** `mark_installed` — now needed only for a **legacy receipt without `correlation_id`** (nothing else can tell it is ours); for receipts carrying this tool's id, correctness does not depend on the claim.
    - **Wording**: an install proven by this tick, by a claim, or by the receipt's own SHA advance (B1300) is reminded as "Hermes was updated …"; anything else (e.g. the pre-update identity read timed out and the claim could not be written) as "an update run launched by this updater finished … The receipt alone does not show that new code was installed" — it never claims an install it cannot show.
    - **More alerts (allowed)**: a `success` / `partial` receipt this tool launched that was not judged an install (a no-op owing `followups`, a partial without evidence) and owes something is reminded about once at a later tick, with the second wording. A receipt with `outcome` `failed` etc. never reaches `mark_installed` and is still not reminded.
    - `user_action` / `followups` is non-empty, and its key (`id-<update_id>`, else `sha-<sha256 of the receipt bytes>`) is not in the dedupe ledger `state/auto_update/owed_action_notified`.
    - **Look-back bound**: launched within the last 30 days **and** among the newest 50 receipt files (whichever is smaller). Why: upstream itself keeps only the last 20 archives (`update_receipt._RECEIPT_KEEP = 20`), about 20 days on the daily schedule, so 50 is only a cap (manual runs, many profile mirrors never make the scan unbounded); 30 days: a reminder that could not be delivered for a month has long since triggered the dead letter and the meta-alert, and deriving it further would only dump old news on the day the channel comes back. An owed receipt beyond the bound is logged every tick ("no longer reminded"), never sent. At most 10 reminders per tick, the rest on the following ticks.
  - **First enable does not flood the history**: the choice is "cut off at install time", with the cut-off carried by the receipts themselves — from v5.16 on, the `HERMES_UPDATE_CORRELATION_ID` this tool hands upstream has the new format `au-r1-…`; every receipt from before this version was installed has the old `au-<nanoseconds>-…` format (or no `correlation_id`) and no claim, so it counts as handled. Why: nothing has to be written on the first run for this to hold (the alternative, "record every historic update_id in the ledger on the first run", has to choose between flooding and holding everything back when that first write fails, and a timestamp file has the same problem when it breaks later), and losing the ledger or any marker file can never dig the history up again.
  - **So**: if the install tick could not deliver, could not write anything, or was killed after `mark_installed` (B1800), the next tick's start derives the same reminder from the receipt and sends it; the same holds when the whole state dir was briefly unwritable or only the reminder's temp files were refused (the two r10A scenarios): after recovery it arrives exactly once.
  - **The ledger**: after a delivery it is rewritten whole (its valid key lines plus this key, at most 500 lines) through a temp file + `mv` and read back. A ledger that is a directory / symlink is moved aside (`.owed_bad.*`, never deleted) and rebuilt; garbage lines are dropped, valid keys kept; an unreadable one is read as empty (logged). **If the ledger cannot be written** (delivered, but not recorded): logged, and the reminder is sent again at the next tick, until it can be recorded (more alerts, never fewer — accepted).
  - **Broken receipts** (B1801): a receipt that is not valid JSON is logged and parsed again at the next tick, and reminds as usual once it parses; one whose text cannot be formatted still gets a reminder naming the receipt, deduped the same way; an unreadable receipt directory is logged, and the reminder goes out once it can be read.
  - Malformed fields (string, list, number, bool, null, over-long, non-dict items, empty dicts) never crash and never go silent: any truthy `user_action` / `followups` reminds; empty values (`null`, `""`, `[]`, `{}`, `false`, `0`) = nothing owed, output identical to v5.15, and no state is written.
  - No-op / failure verdicts are unchanged: a no-op receipt owing something never proved the no-op (5b reminder), a failure is still a failure, neither is `mark_installed`. From fix round 4 on, such a receipt launched by this tool with `outcome` `success` / `partial` is reminded about once at a later tick, worded "the receipt alone does not show that new code was installed" (see "More alerts" above); one with any other outcome is not.
- **B1300 hardening** (`receipt_sha_advanced`): a `short_sha` string difference alone no longer proves the code moved. Per side the identity is the full `sha` (40/64 hex) when present, else `short_sha` (≥ 7 hex), case-insensitive; a `short_sha` that is not a prefix of its own side's full `sha` = self-contradicting receipt = no advance. Both sides full → compare the full SHAs; otherwise compare the common prefix (the shorter length): different lengths where one is a prefix of the other (the r7A forged receipt: same `sha`, `short_sha` 7 vs 8 chars) = the same commit = **not advanced**.
- Regressions: `OwedActionNotice` in `scripts/check_compat_sanity.py` (fixture `verify/fixtures/receipt_partial_user_action_v0.23.2.json` = the real 11-18 receipt, field structure kept, host paths / profile names / launcher id replaced) and `ShaAdvanceB1300`. Fix round 3 replaces the queue-specific `OwedActionPersistence` / `OwedActionInvariant` of the first two rounds with the entry-level `OwedActionDerived`: the two r10A recovery scenarios, the six r9A and the three r8A scenarios, each now asserting **exactly one delivery in the end, after recovery**; plus a SIGKILL right after `mark_installed` (three install paths), first enable not flooding historic receipts, the 30-day and 50-receipt bounds (10 per tick), an unreadable receipt directory, a receipt that is not JSON, 6 kinds of broken ledger, re-sending until the ledger can be written, a legacy install recovered through its claim, and a recovery matrix (4 failure modes at install × 4 kinds of leftovers from older versions × 4 ledger states, 16 runs as a Latin square). Fix round 4 (r11A B2100) adds the entry tests `test_r11a_pre_identity_timeout_claim_refused_dead_channel_recovers` (fixture `verify/fixtures/receipt_success_followups_pre_identity_timeout_v0.23.2.json`: the receipt the real v0.23.2 identity / receipt functions write when the pre-update identity read times out; `*owed*` temps refused, channel dead → exactly one after recovery) and `test_r11a_missing_sha_shapes_recover` (pre SHA missing, post SHA missing, both missing, the whole identity `{}` — fixture `receipt_success_followups_no_identity_v0.23.2.json` — plus a control with the claim written). Every no-update tick asserts that the receipt directory's content, mtimes and modes are unchanged. Release-gate mutations: reminder removed, ledger check removed, recorded although undelivered, **tick-start derivation removed**, **first-enable cut-off removed**, 30-day bound removed, 50-receipt bound removed, "records an install" no longer required (now only the wording), **eligibility requiring SHAs again (`owedeligsha`)**, claim never written, ledger appended blindly, the old `receipt_sha_advanced` restored — each must turn red.

## v5.15 release notes

- `--check` verdicts are matched whole line against the upstream sentences, with the veto above; unknown output always alerts and never installs.
- A `--yes` run without a receipt is judged on observable state (PATCH4, see above): an error line → real failure; HEAD unreadable → inconclusive alert; HEAD moved → install unproven; HEAD unchanged → no-op. The conclusion sentence is no longer read; the conclusion-keyword, step-sentence and code-movement tables are gone. New stuck guard (the check says available and `--yes` has nothing to do for the 3rd time in a row → alert).
- **Silence needs positive evidence** (PATCH5, option D, see above): only a no-op proven by this run's receipt (`success`, `correlation_id` of this run, no `followups` / `user_action`, pre/post SHA = the observed HEAD) is silent and resets the real-failure counter; every other no-op reminds (⚠) from the first one, is not a failure, resets nothing, exits 1. Generations 1 and 2 of Hermes (v2026.3.12 – v2026.9.24) write no receipt with our id, so on them every "available but not installed" tick reminds. The error veto now catches a `✗` anywhere in a line (B1201). The corpus tool fails on a parse error, a tag with 0 `print()`, or an empty (a)/(b) corpus (B1102).
- New `scripts/upstream_print_corpus.py`: scans the update code's `print()` templates of every official release, checks the `--check` classification and the `--yes` error-word rule against them, snapshot in `verify/upstream_corpus.json`, run by the release gate.
- The check-failure re-alert defaults to `82800`s (1 day − 1h), a margin for start jitter and DST; `--check`'s `No newer release` accepts only the ahead label.
- Real failures, notify-delivery failures, and the checkout-newer reminder now follow a wall-clock cadence (new knobs `AU_REALERT_SECS`, `AU_ROLLBACK_REMIND_SECS`) instead of tick counts ("every 12th" was every 12 days on the daily schedule).
- The check-failure alert summary puts error lines first.
- **Behaviour change**: `--yes` exiting 0 without a fresh receipt of its own for this run is **no longer a success** — with a completion line → "install unproven" alert, `drain_pending` set, exit 1; everything else by the observable state above (since PATCH4: unrecognized output with no error line and HEAD unchanged → legitimate no-op, no alert; HEAD moved → install unproven). Hermes builds that write no update receipt therefore alert on every install; make sure the target Hermes writes `~/.hermes/logs/update_receipts/latest.json`.

## Upstream wording corpus

`--check` has no machine-readable output, and `--yes` receipts carry this run's id only from the third generation on (see "Upstream receipt generations"), so the two text rules (the `--check` verdict classification and the `--yes` error words) must hold for **every** official release, not just the newest. `scripts/upstream_print_corpus.py` (read-only: `git tag` / `git ls-tree` / `git show <tag>:<path>`, no fetch, no checkout, one tag at a time):

- lists every official release tag (`vX.Y.Z` and `vYYYY.M.D[.N]`; rc / canary / abandoned / `+` build metadata / any other name excluded and counted);
- per tag reads `hermes_cli/update_cmd*.py`, `update_handoff.py`, `update_pause_record.py`, `source_releases.py` whole, and from older builds' `hermes_cli/main.py` the functions reachable from `cmd_update` / `_cmd_update_impl` / `_cmd_update_check`; extracts every `print(...)` template with `ast` (variable parts of f-strings etc. kept as `<<expr>>` placeholders);
- (a) the templates reachable from `_cmd_update_check` are instantiated with the real label shapes and fed to the REAL `classify_line` of `auto_update.sh`: a conclusion line judged `unknown` fails (registered findings excepted, `check_registered` in `verify/upstream_error_review.json`);
- (b) every template line is fed to the REAL `yes_error_line` (exemption table off): every hit must be listed as `error` or `exempt` in `verify/upstream_error_review.json`; then with the table on, every exempt sample must pass and every `error` line must still be vetoed.

The deduplicated snapshot is `verify/upstream_corpus.json` (at most 512KB); the release gate runs `--gate` on it (no upstream checkout needed on the recipient's side). The scan must have content to count (PATCH5, B1102): any source that fails to parse, any tag with no `print()` found, or an (a) / (b) pass that checked nothing makes both the scan mode and `--gate` exit non-zero; `CorpusToolFailsClosed` in `scripts/check_compat_sanity.py` is the broken-source regression. After an upstream release: `python3 -I scripts/upstream_print_corpus.py --write-snapshot`; new hits fail the gate as "unreviewed" until each is listed. Limits: only `print()` is seen; output via `logger`, `sys.stdout.write`, subprocesses (pip, git, npm, systemctl) and strings built elsewhere and passed to `print` are invisible or reduced to a placeholder; `print(end="")` joins are not reconstructed. The runtime content of placeholders (profile names, branch names, exception text) is outside the proof.

## Files

- `auto_update.sh` — the updater (UPDATER_VERSION 5.16)
- `LICENSE` — MIT
- `scripts/release_gate.sh` — run BEFORE shipping: doc pointers + matrix + probes + teeth
- `scripts/schedule_delivery.sh` — does the recommended cron shape deliver env + flag?
- `scripts/marker_lifecycle_sweep.sh`, `scripts/counter_sanity.sh` — companion probes
- `scripts/check_compat_sanity.py` — `--check` outcome compatibility check, run as `python3 scripts/check_compat_sanity.py auto_update.sh`; part of the release gate
- `scripts/upstream_print_corpus.py` — upstream wording scan over every official release (see "Upstream wording corpus"); `verify/upstream_corpus.json` the corpus snapshot, `verify/upstream_error_review.json` every error-word hit with its verdict
- `verify/` — hermetic harness (stub hermes/curl/systemctl); matrix = executable contract
- `verify/fixtures/` — third-generation no-op receipts written by the real upstream functions (verbatim), and the real 11-18 install receipt (partial + `user_action`, desensitized), used as test fixtures
- `verify/receipt_probe/` — the isolated probe that produced them and the receipt-generation scan (need the upstream repo; read-only, never runs `hermes update`)
- `references/` — receipt contract, WSL deployment, bundle recipe, health fixture

## Verify

From the extracted copy run:

```bash
bash scripts/release_gate.sh
```

Require PASS. The gate includes `python3 scripts/check_compat_sanity.py auto_update.sh`. The matrix and the compat probe are the executable contract of the script's behavior (they print their own tallies; counts are not restated here). Which test carries which acceptance point: `verify/README.md`.

sha256 (auto_update.sh, updater v5.16): `089733c707cc5df02c71d27479ff9c616ccd8705c7c5605286782a0234a803cb`
_Regenerate with `sha256sum auto_update.sh` before re-packing._
