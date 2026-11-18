#!/bin/bash
# Auto-update Hermes via system cron (outside the gateway process tree).
# Outside the tree the updater drains + restarts the gateway itself via systemd,
# so no STALE race: the script can wait for the fleet to be current and verify.
# Notify on Telegram only for real outcomes (update installed / failure).
#
# v5.15 (2026-11-18): issue #1 — stable-channel --check verdicts and daily-schedule alerting.
#   C1 `hermes update --check` on the stable channel prints none of the two phrases v5.14
#      knew ("Update available" / "Already up to date" are only printed by the branch-compare
#      path), so EVERY successful stable check fell into "unrecognized" — including
#      "→ Selected release available", i.e. stable hosts never installed anything. The check
#      is now classified by line-anchored verdict patterns taken from upstream
#      hermes_cli/update_cmd_check.py (v0.23.1): available / none / hold / ahead / unrecognized.
#      "→ This checkout is newer than the selected release" is NEVER installed (hermes update
#      would move the checkout BACK to that release); it reminds a human at a low rate.
#      "→ Holding at this build" is logged only. An exit-0 body carrying a "✗" line, no
#      verdict, or contradictory verdicts stays "unrecognized" (alerts) — never success.
#   C2 re-alerts are throttled by TIME, not by tick count: `N == 3 || N % 24 == 0` meant
#      day 3 then day 24 under the recommended daily schedule. Check failures alert once the
#      streak reaches 3, then every AU_REALERT_SECS (default 259200 = 3 days); real update
#      failures alert at once, then every AU_REALERT_SECS; the dead-channel re-alert likewise.
#      Stamps live in the state dir and are read through read_epoch() (garbage / overflow /
#      FUTURE stamp -> "never alerted", so a bad stamp can only make an alert come sooner).
#   C3 check-failure alerts carry the real error line (first "✗" line, else an error/timeout
#      line — not line 1, which is usually "→ Update channel: stable"), the streak length and
#      the last successful install time (new state file last_install_ok).
#   C4 the installed version is taken from the "Update complete" line's LAST vX.Y.Z, so the
#      current "(v0.23.0 → v0.23.1) [detached @ …]" form no longer notifies "updated to unknown".
#   C5 `hermes update --yes` that found nothing to do ("✓ Already up to date!", "✓ Up to date
#      with your fork", "✓ Holding at this build until a newer …") is not announced as an
#      install even when its receipt is fresh; marker handling on that path is unchanged.
# v5.13 (2026-09-17): external-review round — two defects that no existing check could see.
#   D1 read_counter clamped by LENGTH *after* the arithmetic. A 20-digit all-digit counter file
#      does not abort bash (no "value too great for base" escape): $((10#...)) wraps SILENTLY
#      to 3, or to a NEGATIVE value, so the counter was written as 4 / -4 and every `-eq 3`
#      and `% 24` alert trigger stopped matching — a negative counter delays the alert forever.
#      Order swapped (clamp then arithmetic). counter_sanity.sh grew the length-overflow case,
#      and the release gate now feeds its neuter to that probe (teeth verified both ways).
#   D2 install.sh's recommended cron line did not DELIVER the env file: `. env; AU_APPLY=1
#      script` leaves every value in the scheduler shell (the script never sources the file —
#      verified by grep), so AU_REPO_DIR / AU_GATEWAY_STATE / AU_HERMES_BIN silently never
#      arrived. TG_PROXY survived only via the script's own default — the very hardcoded
#      endpoint the 5.12 entry above calls a landmine. Now `set -a; [ -f env ] && . env;
#      set +a; AU_APPLY=1 script`, the `[ -f ]` guard so a missing env file cannot abort the
#      tick before the flag is delivered. New probe scripts/schedule_delivery.sh runs the
#      shapes under bash/dash/sh (env present AND absent) and reports what the child inherited.
# v5.14 (2026-10-05): corrected the v5.12 fix's documented delivery path. The empty-TG_PROXY
#   override was written into ~/.hermes/.env (and the v5.12/v5.13 notes said to put it there),
#   but this script NEVER sources that file: TG_ENV is read only for the bot token and chat id,
#   so a TG_PROXY= line there reaches nothing. The value silently fell back to the hardcoded
#   default below — i.e. the exact foreign-endpoint landmine v5.12 was fixing stayed armed,
#   hidden by the working fallback (observable only as a "notify via proxy failed" line on
#   every delivered alert). Correct channel: $HOME/.hermes/scripts/auto_update.env, the file the
#   scheduler sources (set -a). ~/.hermes/.env is credentials-only for this script.
#   To audit: `grep -c 'notify via proxy failed' ~/.hermes/logs/auto_update.log` must stay at the
#   pre-fix count, i.e. a healthy direct host logs no new ones.
# v5.12 (2026-09-17): notify proxy→direct fallback (to6429 incident). The updater kept
#   "succeeding" for 14 ticks while its ONLY alert channel was dead: hardcoded default
#   TG_PROXY=127.0.0.1:18089 was a Kimi-sandbox leftover; that host isn't walled, xray
#   doesn't exist there, curl exit 7 every tick. Primary fix = `TG_PROXY=` (empty = direct,
#   per the v5.7 ${VAR-default} contract) in auto_update.env — NOT ~/.hermes/.env, see v5.14.
#   Belt-and-suspenders fix = notify()
#   falls back to ONE direct attempt when the proxy attempt fails and TG_PROXY is
#   non-empty (direct mode has no fallback — nothing to fall back to). Lesson: hardcoded
#   endpoints from a migrated host are silent landmines; all safety nets worked (dead
#   letter, counter, exit semantics) but none could self-heal a dead endpoint.
# v3 (2026-09-11): fresh-gate + stall guard
# v5.1 (2026-09-11): drain_pending is set BEFORE the catch-up poll, so an interruption
#   during the poll cannot lose the flag (03-drain-marker-before-poll.patch).
# v5.3 (2026-09-11): review round 4 — C1 health-check paths env-sealed (AU_REPO_DIR /
#   AU_GATEWAY_STATE / AU_GATEWAY_UNIT; hermetic S10/S11 at last); C2 receipt=success
#   keeps+consumes the marker in-line (receipt=success = restart ISSUED, not gateway
#   verified — hot streaks had starved no-update ticks); C3 counter reads numeric-guarded
#   (corrupt state file self-heals instead of aborting pre-alert); C5 poll reads gated
#   fresh; C6 dead-channel sentinel files (notify_dead_letter.log / notify_dead); C8
#   rollback alert lists actual backup refs; C9 .env tolerates export-prefixed lines.
# v5.11 (2026-09-12): review round 10 — the AU_APPLY gate (v5.9) broke the two support probes:
#   they drove ticks that then never installed, so the sweep reported "marker erased" and
#   counter_sanity "not sanitized" — false alarms that read as "the updater is broken".
#   Both now set AU_APPLY=1 themselves; the sweep distinguishes "never set" from "erased".
#   scripts/release_gate.sh added so the pre-publish recipe RUNS instead of being described
#   (the recipe that documented these probes had never been executed — this is the fix for
#   the class, not just the instance). Recipe's pointer check no longer false-positives on
#   example paths or root files named from prose.
# v5.10 (2026-09-12): review round 9 — every external call inside the lock is now BOUNDED.
#   D5: `hermes update --yes` had no timeout. Upstream can legitimately block 30 min
#   (restart_after_turn_timeout=1800), but with no cap a WEDGED updater holds the flock
#   forever: every later tick logs "previous update still running" and exits 0, and the
#   stall guard only counts check-phase failures — so nothing ever alerts. Now wrapped in
#   `timeout -k` (AU_UPDATE_TIMEOUT default 3600 = 2x upstream ceiling; AU_UPDATE_KILL
#   default 60); 124/137 = wedged -> alert + keep the drain marker + exit 1. S25.
#   D6: `hermes update --check` was likewise unbounded while already holding the lock.
#   Now bounded (AU_CHECK_TIMEOUT default 300); a timeout lands in the existing transient
#   check-failure path (counter, alert at 3). S26.
#   D7: a backtick inside the harness's UNQUOTED heredoc was executed at setup time
#   (`timeout -k` ran during stub_setup). Escaped; whole toolchain swept for the class.
# v5.9 (2026-09-12): destructive install is now OPT-IN. Without AU_APPLY=1 the script
#   only reports ("update available, not applied") and exits 0 — so running it (a smoke
#   test, an installer, an exploratory shell) can no longer mutate the host. The scheduled
#   invocation must pass AU_APPLY=1 (crontab updated). Prompted by a real accident: an
#   installer's "dry run" invoked the updater and installed a new version mid-session.
# v5.8 (2026-09-12): review round 8 — D1 the catch-up poll confirmed the gateway from a
#   fresh success receipt alone, short-circuiting the is-active check written below it
#   (re-admitted the C2 false positive into the poll path). Gateway health now has ONE
#   implementation, gateway_confirmed(), used by poll and recheck alike. D2 notify now
#   requires "ok":true in the response body (HTTP 200 + ok:false = blocked bot). D3 the
#   healthy no-update tick resets consec_real_fails so a later unrelated failure is not
#   deduped by a stale count. Matrix +S20/S21/S22, all three teeth-verified.
# v5.7 (2026-09-12): cross-host deployment (WSL laptop + pc20) —
#   TG_PROXY now uses ${VAR-default} so an EMPTY value = direct connection (${VAR:-def}
#   swallowed empty and silently forced this host's xray proxy onto machines without one).
#   Preflight block logs loud warnings when cron's unit or the gateway unit is inactive:
#   a non-resident WSL distro never fires cron, and that silence looks like "all fine".
# v5.6 (2026-09-11): review round 7 — the R1 SHA discriminator shipped WITHOUT a test
#   (neutering it changed nothing: the stub never wrote pre/post SHAs). Harness now has
#   race_sha/race_same modes + S18/S19 with verified teeth (force the branch 0 -> S18 fails;
#   force it 1 -> S19 fails).
# v5.5 (2026-09-11): review round 6 — race-branch false failure on reworded output (R1):
#   primary evidence is now the receipt's pre/post_update SHAs (post != pre proves the
#   install landed); "Update complete" text is a fallback only. AU_SETTLE_SECONDS knob
#   documented + used by the matrix (R2); matrix asserts marker consumption on healthy
#   success (R3).
# v5.4.1 (2026-09-11): success notifications now carry BOTH versions explicitly —
#   "hermes agent updated to <hermes-version> (updater v<UPDATER_VERSION>)" — ending the
#   v0.21.1-vs-v5.x confusion (zip name = updater version; notify = installed Hermes version).
# v5.4 (2026-09-11): review round 5 — the C1 fix itself was incomplete: the catch-up
#   poll's inline health check still carried hardcoded /root + /usr/local/lib paths
#   (fixed C1 in recheck_drain_marker only). All health-check sites now use the sealed
#   REPO/GATEWAY_STATE/GATEWAY_UNIT vars; TG_PROXY parameterized; AU_HERMES_BIN as an
#   extra binary candidate (kept LAST so the harness's first-candidate sed still wins).
# v5.2 (2026-09-11): the exit≠0 race branch cleared drain_pending without the gateway
#   being verified — erasing the re-verify hook (Defect-2 class in an unpatched branch).
#   It now refreshes the marker; next tick re-verifies via recheck_drain_marker.
# v5 (2026-09-11): Nova's review — stall-guard counter reset moved to conclusive
#   branches (was dead code: reset ran before the unrecognized branch, counter stuck
#   at 1); drain_pending marker + recheck_drain_marker() so "next tick re-verifies"
#   is code, not a comment; poll knobs AU_POLL_EVERY/AU_POLL_TRIES; lock moved out of
#   /tmp; log rotation at 5MB; notify(msg) single-arg API
# v4 (2026-09-11): real-failure dedup (3/12h cadence), credential-loss alerting,
#   drain-timeout neutral verdict (no more false failure on long drains),
#   is-active health check in gateway confirmation, dead-code cleanup —
#   #1 exit=1 with "Update complete!" = install succeeded, fleet restart raced
#      (receipt outcome=partial / fleet STALE). Re-classify via receipt + gateway
#      state instead of trusting the exit code alone.
#   #2 failure notifications get a consec-failure counter + curl --retry,
#      so a proxy blip can't silently swallow the one alert that matters.
#   #3 success/failure judged from update_receipts/latest.json (machine-written
#      contract), not by grepping human-readable text like "Update complete!".

set -u
HOME="${HOME:-$(getent passwd "$(id -u)" | cut -d: -f6)}"
# systemctl --user needs XDG_RUNTIME_DIR; system cron provides neither DBUS session vars
# nor XDG_RUNTIME_DIR, and without it the updater's gateway-restart path silently no-ops
# (is-active returns empty → early return → gateway never restarted after the code swap).
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
LOG="$HOME/.hermes/logs/auto_update.log"
LOCK="$HOME/.hermes/state/auto_update/auto_update.lock"   # /tmp is world-writable + predictable
STATE_DIR="$HOME/.hermes/state/auto_update"
RECEIPT="$HOME/.hermes/logs/update_receipts/latest.json"
mkdir -p "$(dirname "$LOG")" "$STATE_DIR"

# keep the log bounded: it only ever grows otherwise (every update appends tail -40)
if [ -f "$LOG" ] && [ "$(stat -c %s "$LOG" 2>/dev/null || echo 0)" -gt 5242880 ]; then
    mv -f "$LOG" "$LOG.1" 2>/dev/null || true
fi

log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

# Read a consec-counter defensively (C3): a corrupted/non-numeric state file under set -u
# makes $((m+1)) abort the whole script BEFORE any alert can fire. Treat garbage as 0
# (start the count over) and overwrite the bad file — the counter self-heals.
read_counter() {  # $1 = counter file name; echoes a sanitized integer
    local v
    v=$(cat "$STATE_DIR/$1" 2>/dev/null | tr -cd '0-9')
    case "$v" in '') v=0 ;; esac
    # Clamp by LENGTH *before* the arithmetic, never after. A long all-digit string does NOT
    # abort bash: `$((10#9999999999999999999))` overflows SILENTLY (rc=0) to a small — even
    # NEGATIVE — value, and a post-arithmetic `> 6` guard never sees a negative. The counter
    # then goes negative, every `-eq 3` / `% 24` alert trigger stops matching, and the alert
    # is delayed forever. Measured on the arithmetic-first order: 18446744073709551619 -> 4,
    # 18446744073709551611 -> -4 (correct answer in both cases: 1).
    if [ "${#v}" -gt 6 ]; then v=0; fi
    v=$((10#$v))
    echo "$v"
}

# Epoch-stamp reader, same covenant as read_counter: a bad state file must never abort the
# script under `set -u`, and must never SUPPRESS an alert. Empty / non-numeric / overlong
# (overflow) -> 0 ("never"). A FUTURE stamp (clock jump, hand edit) -> 0 too: `now - last`
# would stay negative and silence the re-alert until the clock caught up.
read_epoch() {  # $1 = state file name; echoes a sanitized epoch (0 = none)
    local v now
    v=$(cat "$STATE_DIR/$1" 2>/dev/null | tr -d '[:space:]')
    case "$v" in ''|*[!0-9]*) v=0 ;; esac
    if [ "${#v}" -gt 11 ]; then v=0; fi
    v=$((10#$v))
    now=$(date +%s)
    if [ "$v" -gt $((now + 300)) ]; then v=0; fi
    echo "$v"
}

# Numeric env knob: garbage, negative or empty -> the default (never an arithmetic abort).
knob_secs() {  # $1 = raw value  $2 = default
    local v="$1"
    case "$v" in ''|*[!0-9]*) v="$2" ;; esac
    if [ "${#v}" -gt 9 ]; then v="$2"; fi
    echo $((10#$v))
}

# Re-alert cadence is WALL-CLOCK, not tick count (issue #1): a tick-counted "every 24th"
# meant 24 days under the recommended daily schedule. 3 days default: a stalled updater is
# re-announced twice a week, a one-off blip is not. AU_REALERT_SECS=0 = every tick.
AU_REALERT_SECS=$(knob_secs "${AU_REALERT_SECS-}" 259200)
# "Checkout newer than the selected release" needs a human decision, not an emergency page.
AU_AHEAD_REMIND_SECS=$(knob_secs "${AU_AHEAD_REMIND_SECS-}" 604800)
# Scheduler jitter: a daily cron starts a few seconds earlier or later each day, so an exact
# `>= 3 days` comparison could slip a whole tick. 1h of slack absorbs it at any cadence.
REALERT_SLACK=3600
realert_due() {  # $1 = stamp file  $2 = interval secs; true when an alert may go out now
    local last now
    last=$(read_epoch "$1")
    [ "$last" -eq 0 ] && return 0
    now=$(date +%s)
    [ $((now - last + REALERT_SLACK)) -ge "$2" ]
}
mark_alerted() { date +%s > "$STATE_DIR/$1"; }

# Conclusive outcomes reset their streak AND its re-alert stamp, so the next new streak
# pages on its own schedule instead of inheriting the old one's silence.
reset_check_fails() {
    echo 0 > "$STATE_DIR/consec_check_fails"
    rm -f "$STATE_DIR/check_last_alert"
}
reset_real_fails() {
    echo 0 > "$STATE_DIR/consec_real_fails"
    rm -f "$STATE_DIR/real_last_alert"
}
record_install_ok() { date +%s > "$STATE_DIR/last_install_ok"; }
last_install_text() {
    local t
    t=$(read_epoch last_install_ok)
    if [ "$t" -eq 0 ]; then
        echo "none recorded (tracked since updater v5.15)"
    else
        date -d "@$t" '+%F %T %Z' 2>/dev/null || echo "epoch $t"
    fi
}

# Truncate to N characters without splitting a UTF-8 sequence (Telegram rejects invalid
# UTF-8, which would lose the very alert this text belongs to). Bytes fallback if no python.
trunc_chars() {  # $1 = max chars, text on stdin
    local s
    s=$(cat)
    printf '%s' "$s" | python3 -c 'import sys; s=sys.stdin.buffer.read().decode("utf-8","replace"); sys.stdout.write(s[:int(sys.argv[1])])' "$1" 2>/dev/null \
        || printf '%s' "${s:0:$1}"
}

# One diagnostic line from a multi-line check output. Line 1 is usually "→ Update channel: X",
# which says nothing about the failure (issue #1): prefer the first "✗" line, then a line
# naming an error/timeout, then the first line that is not the channel banner.
check_error_summary() {  # $1 = output; echoes one line
    local line
    line=$(printf '%s\n' "$1" | grep -m1 -E '^[[:space:]]*✗')
    [ -n "$line" ] || line=$(printf '%s\n' "$1" | grep -m1 -iE 'error|timed out|timeout|fatal|failed|traceback')
    [ -n "$line" ] || line=$(printf '%s\n' "$1" | grep -m1 -vE '^[[:space:]]*(→ Update channel:.*)?$')
    [ -n "$line" ] || line=$(printf '%s\n' "$1" | head -1)
    [ -n "$line" ] || line="(no output)"
    printf '%s' "$line" | sed 's/^[[:space:]]*//' | tr -d '\r' | trunc_chars 400
}

# --- `hermes update --check` verdicts ------------------------------------------------
# Source of truth: hermes_cli/update_cmd_check.py at Hermes v0.23.1 (3b42157858).
#   channel_compare_branch()  (release-pinned channels, e.g. stable):
#     L110 "✓ No newer release: <label>."                       -> none
#     L112 "✓ Up to date with the latest release (<label>)."    -> none
#     L115 "→ Holding at this build: <label> predates …"        -> hold
#     L119 "→ This checkout is newer than the selected release: <label>." -> ahead
#     L123 "→ Selected release available: <label>"              -> available
#     L97 "→ Update channel: X" and L108 "→ X retired; source destination: Y" are context only.
#   report_shallow_verdict() / report_rev_list_verdict()  (branch compare, e.g. main):
#     L200/L208/L222 "✓ Already up to date."                    -> none
#     L212/L214/L225 "⚕ Update available: N commits behind R." / "⚕ Update available (behind R)."
#   Errors: "✗ …" then sys.exit(1) (L103, update_cmd.py L639/L669); admission refusal exits 2.
# Upstream has NO machine-readable form (no --json on `update --check`; every verdict exits
# 0), so the text is the contract. Every pattern is anchored to the START of a line with its
# phrase, so an error line that merely contains the words ("✗ … could not determine if up to
# date") can never read as a verdict. The legacy glyphs (⚕/✓) are optional for the two
# branch-compare phrases only, which older Hermes builds printed without them.
P_CHECK_ERR='^[[:space:]]*✗'
P_AVAILABLE='^[[:space:]]*((⚕[[:space:]]+)?Update available([:. (]|$)|→ Selected release available: )'
P_NONE='^[[:space:]]*((✓[[:space:]]+)?Already up to date([.!]|$)|✓ No newer release: |✓ Up to date with the latest release \()'
P_HOLD='^[[:space:]]*→ Holding at this build: '
P_AHEAD='^[[:space:]]*→ This checkout is newer than the selected release: '
check_pattern() {
    case "$1" in
        available) echo "$P_AVAILABLE" ;; none) echo "$P_NONE" ;;
        hold) echo "$P_HOLD" ;; ahead) echo "$P_AHEAD" ;;
    esac
}
# Echoes available | none | hold | ahead | unrecognized. Exactly ONE verdict class must be
# present; none at all, two contradictory ones, or any "✗" line in an exit-0 body is
# unrecognized — an output we do not understand is never treated as "nothing to do".
classify_check() {  # $1 = output of an exit-0 check
    local found="" c
    if printf '%s\n' "$1" | grep -qE "$P_CHECK_ERR"; then echo unrecognized; return; fi
    for c in available none hold ahead; do
        printf '%s\n' "$1" | grep -qE "$(check_pattern "$c")" && found="$found $c"
    done
    case "$found" in
        " available"|" none"|" hold"|" ahead") echo "${found# }" ;;
        *) echo unrecognized ;;
    esac
}
verdict_line() {  # $1 = output  $2 = class; the matching line, trimmed
    printf '%s\n' "$1" | grep -m1 -E "$(check_pattern "$2")" | sed 's/^[[:space:]]*//' | tr -d '\r' | trunc_chars 300
}

# `hermes update --yes` lines meaning "nothing was installed" (update_cmd.py L1726/L1727 and
# L1911, the completion message of _finish_already_up_to_date()). The no-op path still runs
# the completion and may write a FRESH receipt, so the receipt alone cannot tell it apart.
P_YES_NOOP='^[[:space:]]*✓ (Already up to date|Up to date with your fork|Holding at this build until a newer )'

# Installed version from the completion line (update_cmd_maint.py L371/L373):
# "✓ Update complete! (v0.23.0 → v0.23.1) [detached @ …]" -> v0.23.1 (the LAST version);
# "✓ Update complete! (v0.21.4)" -> v0.21.4. A local suffix (+529.g6660547) is kept.
extract_version() {  # $1 = update output
    local v
    v=$(printf '%s\n' "$1" | grep -E 'Update complete' | grep -oE 'v[0-9]+(\.[0-9]+)+(\+[0-9A-Za-z.]+)?' | tail -1)
    [ -n "$v" ] || v=$(printf '%s\n' "$1" | grep -oE '\(v[0-9.]+\)' | head -1 | tr -d '()')
    printf '%s' "$v"
}

# Telegram notify via the local xray proxy (direct api.telegram.org is blocked here).
# Must be defined BEFORE any call site (bash resolves functions at call time).
TG_ENV="$HOME/.hermes/.env"
# Machine-specific Telegram proxy, env-overridable for tests/other machines
# NOTE: `-` not `:-` — an EMPTY value is a legitimate setting meaning "no proxy, direct
# connection" (machines that reach api.telegram.org directly). `${VAR:-def}` would treat
# empty as unset and silently force this machine's xray address onto other hosts.
TG_PROXY="${TG_PROXY-http://127.0.0.1:18089}"
notify() {
    local tok cid msg="$1"
    # C9: tolerate `export VAR=` forms and surrounding quotes in .env
    tok=$(grep -oP '^(?:export )?TELEGRAM_BOT_TOKEN=\K.*' "$TG_ENV" 2>/dev/null | tr -d '"' | tail -1)
    cid=$(grep -oP '^(?:export )?TELEGRAM_ALLOWED_USERS=\K.*' "$TG_ENV" 2>/dev/null | tr -d '"' | awk '{print $1}' | tail -1)
    # Missing credentials = the ONLY alert channel is dead: never silently swallow it.
    if [ -z "$tok" ] || [ -z "$cid" ]; then
        local m
        m=$(read_counter consec_notify_fails)
        m=$((m + 1))
        echo "$m" > "$STATE_DIR/consec_notify_fails"
        log "⚠ notify skipped: TELEGRAM_BOT_TOKEN/TELEGRAM_ALLOWED_USERS missing or empty in $TG_ENV ($m consecutive) — unsent: $msg"
        printf '%s\n' "[$(date '+%F %T')] notify skipped (no credentials, $m consecutive) — last unsent: $msg" >> "$STATE_DIR/notify_dead"
        return 1
    fi
    # D2: curl's exit code is NOT delivery. Telegram answers HTTP 200 with
    # {"ok":false} for a blocked bot or a bad chat, which curl reports as success.
    # Require an explicit "ok":true in the body before counting this as delivered.
    local resp
    resp=$(curl -s -m 20 --retry 2 --retry-delay 2 -x "$TG_PROXY" \
        "https://api.telegram.org/bot${tok}/sendMessage" \
        --data-urlencode "chat_id=${cid}" \
        --data-urlencode "text=$msg" 2>/dev/null)
    # Proxy fallback (to6429 2026-09-17): a proxy that listens-but-fails or is gone
    # must not silently kill the only alert channel. curl exit≠0 or empty/no-ok body
    # with a NON-empty TG_PROXY → one direct retry. Only when a proxy was actually
    # configured (direct mode has nothing to fall back to).
    if ! printf '%s' "$resp" | grep -q '"ok":true'; then
        if [ -n "$TG_PROXY" ]; then
            log "notify via proxy failed — falling back to direct connection"
            resp=$(curl -s -m 20 --retry 1 --retry-delay 2 \
                "https://api.telegram.org/bot${tok}/sendMessage" \
                --data-urlencode "chat_id=${cid}" \
                --data-urlencode "text=$msg" 2>/dev/null)
        fi
    fi
    if printf '%s' "$resp" | grep -q '"ok":true'; then
        echo 0 > "$STATE_DIR/consec_notify_fails"
        rm -f "$STATE_DIR/notify_last_alert"
        return 0
    fi
    [ -n "$resp" ] && log "notify rejected by API: $(printf '%s' "$resp" | head -c 200)"
    # Delivery failed: count it; re-alert from the 3rd consecutive failure on, then at most
    # every AU_REALERT_SECS (wall clock — a tick-counted "every 24th" was 24 days on a daily
    # schedule). Stamped whether or not this attempt lands: the channel is known-bad, and the
    # dead-letter file below is the local trace that does not depend on it.
    local n
    n=$(read_counter consec_notify_fails)
    n=$((n + 1))
    echo "$n" > "$STATE_DIR/consec_notify_fails"
    log "notify delivery failed ($n consecutive)"
    if [ "$n" -ge 3 ] && realert_due notify_last_alert "$AU_REALERT_SECS"; then
        mark_alerted notify_last_alert
        # C6: this re-alert travels the SAME possibly-dead channel — a proxy that stays
        # down would make every warning vanish. Leave a local sentinel + log fingerprint
        # so a dead notification channel is discoverable without Telegram.
        printf '%s\n' "[$(date '+%F %T')] $n consecutive delivery failures — last unsent: $msg" >> "$STATE_DIR/notify_dead_letter.log"
        curl -s -m 20 -x "$TG_PROXY" \
            "https://api.telegram.org/bot${tok}/sendMessage" \
            --data-urlencode "chat_id=${cid}" \
            --data-urlencode "text=⚠ hermes auto-update: notifications failing ($n consecutive) — last unsent: $msg" >/dev/null 2>&1 || true
    fi
    return 1
}

# Receipt outcome reader (machine-written, machine-read — never grep the text).
receipt_outcome() {
    python3 - "$RECEIPT" <<'PYEOF' 2>/dev/null || echo "unreadable"
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get("outcome", "missing"))
except Exception:
    print("unreadable")
PYEOF
}

# Freshness-gated reader: outcome is only meaningful if the receipt was FINISHED after
# $1 (epoch). A stale receipt (older run) returns "stale" — callers must not treat it
# as evidence about THIS run. Parses ISO finished_at incl. the +00:00 tz suffix.
receipt_outcome_fresh() {
    python3 - "$RECEIPT" "$1" <<'PYEOF' 2>/dev/null || echo "unreadable"
import json, sys
from datetime import datetime
try:
    d = json.load(open(sys.argv[1]))
    fin = datetime.fromisoformat(d["finished_at"])
    started = float(sys.argv[2])
    if fin.timestamp() >= started - 5:  # 5s clock skew tolerance
        print(d.get("outcome", "missing"))
    else:
        print("stale")
except Exception:
    print("unreadable")
PYEOF
}

# A timed-out drain leaves drain_pending behind. Nothing else ever re-verifies the
# gateway: the no-update tick exits long before --yes would re-run its fleet check.
# Without this, "next tick re-verifies" is a comment that lies, and a gateway that never
# came back goes silent forever after a single warning.
clear_drain_marker() {
    rm -f "$STATE_DIR/drain_pending"
    echo 0 > "$STATE_DIR/consec_drain_pending"
}

# Health-check targets are env-overridable so the hermetic harness can seal them:
# real-machine defaults, but AU_REPO_DIR / AU_GATEWAY_STATE let stub tests point at
# throwaway fixtures instead of this machine's live state (C1: hardcoded paths made
# S10/S11 pass by borrowing the real machine's health).
UPDATER_VERSION="5.15"   # this script's own version (changelog in header) — distinct from the Hermes version it installs
REPO_DIR="${AU_REPO_DIR:-/usr/local/lib/hermes-agent}"
REPO="${AU_REPO_DIR:-$REPO_DIR}"   # harness compatibility: stub_setup rewrites REPO=
GATEWAY_STATE="${AU_GATEWAY_STATE:-$HOME/.hermes/gateway_state.json}"
GATEWAY_UNIT="${AU_GATEWAY_UNIT:-hermes-gateway}"

# Single source of truth for "the gateway is healthy on the new code":
# live state SHA == checkout HEAD AND systemd reports the unit active.
# Every caller (poll, recheck) must use THIS — divergence between callers is how the
# C2 false positive escaped into the poll branch (D1).
gateway_confirmed() {
    local h act
    h=$(git -C "$REPO" rev-parse HEAD 2>/dev/null)
    act=$(systemctl --user is-active "$GATEWAY_UNIT" 2>/dev/null)
    [ -n "$h" ] && [ "$act" = "active" ] || return 1
    python3 - "$h" "$GATEWAY_STATE" <<'PYEOF' 2>/dev/null
import json, sys
s = json.load(open(sys.argv[2]))
raise SystemExit(0 if s.get("code_sha") == sys.argv[1] else 1)
PYEOF
}

recheck_drain_marker() {
    [ -f "$STATE_DIR/drain_pending" ] || return 0
    local h n
    h=$(git -C "$REPO" rev-parse HEAD 2>/dev/null)
    act=$(systemctl --user is-active "$GATEWAY_UNIT" 2>/dev/null)
    if gateway_confirmed
    then
        clear_drain_marker
        log "drain marker cleared: gateway healthy on ${h:0:10}"
        return 0
    fi
    n=$(read_counter consec_drain_pending)
    n=$((n + 1))
    echo "$n" > "$STATE_DIR/consec_drain_pending"
    log "drain marker STILL pending (#$n): gateway not healthy on ${h:0:10} (is-active=$act)"
    if [ "$n" -eq 1 ] || [ $((n % 3)) -eq 0 ]; then
        REFS=$(git -C "$REPO_DIR" for-each-ref --format='%(refname:short)' refs/hermes-update-backups/ 2>/dev/null | tail -3 | tr '\n' ' ')
        notify "⚠ hermes auto-update: code is installed but the gateway never came back on ${h:0:10} (#$n) — rollback candidates: ${REFS:-none listed} (git -C $REPO_DIR reset --hard <ref>)"
    fi
    return 1
}

# Resolve hermes by absolute path — cron PATH is minimal.
HERMES_BIN=""
for cand in "$HOME/.hermes/venvs/hermes-dev/bin/hermes" /usr/local/lib/hermes-agent/venv/bin/hermes ${AU_HERMES_BIN:+"$AU_HERMES_BIN"}; do
    if [ -x "$cand" ]; then
        HERMES_BIN="$cand"
        break
    fi
done
HERMES_BIN="${HERMES_BIN:-$(command -v hermes || true)}"
if [ -z "$HERMES_BIN" ]; then
    log "✗ CRITICAL: hermes binary not found"
    notify "✗ hermes auto-update: hermes binary not found — install broken"
    exit 1
fi

# --- Preflight (fail loud, never silently degrade) ---------------------------------
# A host can have systemd enabled but NO cron daemon running (typical on WSL, where the
# distro is not resident). The updater would then simply never fire, and nothing would
# say so. Warn once per run into the log; the check is cheap and read-only.
if ! command -v systemctl >/dev/null 2>&1; then
    log "⚠ preflight: systemctl not found — gateway restart/verification will not work here"
fi
if command -v systemctl >/dev/null 2>&1; then
    # `-` not `:-`: AU_CRON_UNIT="" means "no in-distro scheduler by design" (the host OS
    # drives the tick, e.g. Windows Task Scheduler on WSL) and skips the check entirely.
    CRON_UNIT="${AU_CRON_UNIT-cron}"
    if [ -n "$CRON_UNIT" ] && ! systemctl is-active --quiet "$CRON_UNIT" 2>/dev/null; then
        log "⚠ preflight: no active '$CRON_UNIT' unit — in-distro cron will never fire this script. Set AU_CRON_UNIT= (empty) if the host OS schedules it instead."
    fi
    if ! systemctl --user is-active --quiet "$GATEWAY_UNIT" 2>/dev/null; then
        log "⚠ preflight: user unit '$GATEWAY_UNIT' is not active — gateway restart/verification will not work here."
    fi
fi

exec 9>"$LOCK"
if ! flock -n 9; then
    log "previous update still running, skipped"
    exit 0
fi

# Bounded check: it fetches from origin while already holding the lock. A hung fetch would
# hold the flock forever and every later tick would skip with no alert.
AU_CHECK_TIMEOUT="${AU_CHECK_TIMEOUT:-300}"
CHECK_OUT=$(timeout -k "${AU_UPDATE_KILL:-60}" "$AU_CHECK_TIMEOUT" "$HERMES_BIN" update --check 2>&1)
CHECK_STATUS=$?

# Stall-guard alert for the check phase (exit≠0 AND unrecognized output share one streak):
# first page when the streak reaches 3, then at most every AU_REALERT_SECS of wall clock.
# The stamp is written only when the alert was DELIVERED, so a lost alert is retried on the
# next tick instead of going quiet for the whole interval (notify() counts the dead channel).
check_alert() {  # $1 = streak length  $2 = what is wrong (one line)
    if [ "$1" -lt 3 ]; then return 0; fi
    if ! realert_due check_last_alert "$AU_REALERT_SECS"; then
        log "check alert suppressed (#$1): last alert < ${AU_REALERT_SECS}s ago"
        return 0
    fi
    if notify "⚠ hermes auto-update: $2 | last successful install: $(last_install_text) | nothing is installed until a check succeeds (updater v${UPDATER_VERSION})"; then
        mark_alerted check_last_alert
    fi
}

if [ $CHECK_STATUS -ne 0 ]; then
    # Fetch failures (429/5xx/network/git timeouts) exit 1 with "✗" — never install on them.
    CHECK_ERR=$(check_error_summary "$CHECK_OUT")
    log "check failed (exit $CHECK_STATUS): $(echo "$CHECK_OUT" | head -2 | tr '\n' ' ')| error: $CHECK_ERR"
    N=$(read_counter consec_check_fails)
    N=$((N + 1))
    echo "$N" > "$STATE_DIR/consec_check_fails"
    check_alert "$N" "update check failing ($N consecutive, exit $CHECK_STATUS) — $CHECK_ERR"
    exit 0
fi

VERDICT=$(classify_check "$CHECK_OUT")
case "$VERDICT" in
    none)
        # Conclusive: nothing to update.
        reset_check_fails
        rm -f "$STATE_DIR/ahead_last_alert"
        # D3: a healthy no-update tick is a SUCCESSFUL updater run. Without this reset a
        # real failure followed by healthy no-op ticks keeps its counter climbing, so the
        # next unrelated failure is suppressed by the stale count (deduped as if ongoing).
        reset_real_fails
        log "up-to-date: $(verdict_line "$CHECK_OUT" none)"
        recheck_drain_marker || exit 1
        exit 0
        ;;
    hold)
        # Conclusive, not an update and not a failure: upstream keeps this build because the
        # release predates the gateway runtime in use; the next release installs normally.
        reset_check_fails
        rm -f "$STATE_DIR/ahead_last_alert"
        reset_real_fails
        log "holding (no update to install yet, not a failure): $(verdict_line "$CHECK_OUT" hold)"
        recheck_drain_marker || exit 1
        exit 0
        ;;
    ahead)
        # NEVER install: `hermes update` would move this checkout BACK to the older release
        # (a downgrade). The check itself succeeded, so this is not a failure either — but
        # someone has to decide (follow main, or wait for the next release): remind rarely.
        reset_check_fails
        reset_real_fails
        AHEAD_LINE=$(verdict_line "$CHECK_OUT" ahead)
        log "checkout NEWER than the selected release — not installing (would be a downgrade): $AHEAD_LINE"
        if realert_due ahead_last_alert "$AU_AHEAD_REMIND_SECS"; then
            if notify "⚠ hermes auto-update: not installing — $AHEAD_LINE An update would move this checkout BACK to that release. Decide: \`hermes update --set-channel main\` to follow every commit, or wait for the next release. (reminder at most every $((AU_AHEAD_REMIND_SECS / 3600))h; updater v${UPDATER_VERSION})"; then
                mark_alerted ahead_last_alert
            fi
        fi
        recheck_drain_marker || exit 1
        exit 0
        ;;
    available)
        ;;
    *)
        # No verdict, contradictory verdicts, or an error line in an exit-0 body: INCONCLUSIVE.
        # Alert, never silently stall — a missed wording change would otherwise stop updating
        # forever with zero noise (and it did: issue #1, every stable check for weeks).
        log "⚠ unrecognized --check output (wording changed upstream?): $(echo "$CHECK_OUT" | head -3 | tr '\n' ' ')"
        N=$(read_counter consec_check_fails)
        N=$((N + 1))
        echo "$N" > "$STATE_DIR/consec_check_fails"
        check_alert "$N" "--check output unrecognized ($N consecutive) — update pipeline may be stalled: $(check_error_summary "$CHECK_OUT")"
        exit 0
        ;;
esac

reset_check_fails   # conclusive: an update really is available
rm -f "$STATE_DIR/ahead_last_alert"
log "update available: $(verdict_line "$CHECK_OUT" available)"

# --- apply gate -------------------------------------------------------------------
# Installing is destructive (hard-resets the checkout, reinstalls deps, restarts the
# gateway). It must be OPT-IN, so that "run the script" and "mutate the host" are not the
# same action: a smoke test, an installer, or an exploratory run must be harmless.
# The cron/Task-Scheduler invocation passes AU_APPLY=1.
if [ "${AU_APPLY:-0}" != "1" ]; then
    log "update available but NOT applied (AU_APPLY != 1) — report-only run"
    echo "Update available; not applied (set AU_APPLY=1 to install)."
    echo "$CHECK_OUT" | tail -3
    exit 0
fi

# Real-failure alert: a NEW failure pages at once (no stamp = due), a persisting one again
# every AU_REALERT_SECS of wall clock (was: attempt 1, then every 12th attempt — 12 days on
# the daily schedule). Stamped only on delivery, so a lost alert is retried next tick.
real_fail_alert() {  # $1 = attempt number  $2 = message
    if realert_due real_last_alert "$AU_REALERT_SECS"; then
        if notify "$2"; then mark_alerted real_last_alert; fi
    else
        log "failure #$1 - notify suppressed (last alert < ${AU_REALERT_SECS}s ago)"
    fi
}

RUN_STARTED=$(date +%s)
# Bounded install: upstream can legitimately block for restart_after_turn_timeout (1800s
# default) while draining, so the cap is 2x that. Without a cap a wedged updater holds the
# flock forever and every later tick skips silently — the stall guard below only counts
# check-phase failures, so nothing would ever alert.
AU_UPDATE_TIMEOUT="${AU_UPDATE_TIMEOUT:-3600}"
UPDATE_OUT=$(timeout -k "${AU_UPDATE_KILL:-60}" "$AU_UPDATE_TIMEOUT" "$HERMES_BIN" update --yes 2>&1)
STATUS=$?

log "update exit=$STATUS (cap ${AU_UPDATE_TIMEOUT}s)"
echo "$UPDATE_OUT" | tail -40 >> "$LOG"

# 124 = timeout expired, 137 = the -k SIGKILL fallback fired: the updater is WEDGED, not
# merely slow. Leave the drain marker set (so the next tick still re-verifies the gateway),
# alert at once, and exit non-zero. Deduped like other persistent failures.
if [ "$STATUS" = "124" ] || [ "$STATUS" = "137" ]; then
    log "REAL FAILURE: updater exceeded ${AU_UPDATE_TIMEOUT}s (exit=$STATUS) — wedged, not slow"
    touch "$STATE_DIR/drain_pending"
    n=$(read_counter consec_real_fails); n=$((n + 1)); echo "$n" > "$STATE_DIR/consec_real_fails"
    real_fail_alert "$n" "✗ hermes auto-update: updater WEDGED (no completion within ${AU_UPDATE_TIMEOUT}s, exit=$STATUS, attempt $n) — install state unknown, check the host (updater v${UPDATER_VERSION})"
    exit 1
fi

# Receipt written by THIS run's updater (or the previous one if the marker raced).
# Classification order: receipt outcome first, exit code second — BUT only a receipt
# FINISHED after RUN_STARTED (captured before --yes) is trustworthy: a pull-stage
# failure (merge conflict, syntax guard, SIGKILL) exits before finalize, leaving the
# PREVIOUS run's success receipt on disk. Reading that stale 'success' would fake a
# success notify. Freshness-gate it.
OUTCOME=$(receipt_outcome_fresh "$RUN_STARTED")
VERSION=$(extract_version "$UPDATE_OUT")

if [ "$STATUS" -eq 0 ]; then
    if [ "$OUTCOME" = "stale" ]; then
        # exit 0 but no receipt was finalized during this run: the updater most likely
        # found "Already up to date" (beaten by another updater between check and
        # install) and exited without writing. Never claim success on stale data.
        if echo "$UPDATE_OUT" | grep -q "Already up to date" || printf '%s\n' "$UPDATE_OUT" | grep -qE "$P_YES_NOOP"; then
            log "no-op: beaten by another updater between check and install (exit=0, stale receipt)"
            exit 0
        fi
        log "⚠ exit=0, stale receipt, output unrecognized — treating as inconclusive"
        notify "⚠ hermes auto-update: exit=0 but no fresh receipt (raced?) — verify fleet manually"
        exit 1
    fi
    if [ "$OUTCOME" = "success" ] && printf '%s\n' "$UPDATE_OUT" | grep -qE "$P_YES_NOOP" \
       && ! printf '%s\n' "$UPDATE_OUT" | grep -q "Update complete"; then
        # The updater found nothing to install (raced by another updater, or it held at this
        # build) but still ran its completion, so the receipt is fresh. Not an install: no
        # "✓ updated" message and no last_install_ok. Marker handling is IDENTICAL to the
        # success branch below — the completion may have restarted the fleet too.
        log "no-op: receipt success but nothing installed — $(printf '%s\n' "$UPDATE_OUT" | grep -m1 -E "$P_YES_NOOP" | sed 's/^[[:space:]]*//')"
        reset_real_fails
        touch "$STATE_DIR/drain_pending"
        sleep "${AU_SETTLE_SECONDS:-45}"
        recheck_drain_marker >/dev/null 2>&1 || true
        exit 0
    fi
    if [ "$OUTCOME" = "success" ]; then
        log "success $VERSION (receipt: success)"
        reset_real_fails
        record_install_ok
        # receipt=success means the restart was ISSUED (upstream: restart.incomplete only
        # covers a failed signal) — NOT that the new gateway process actually came up on
        # the new code. Clearing the marker here (C2) erased the re-verify hook precisely
        # during upstream hot streaks, when no-update ticks are scarce. Set/keep the
        # marker; the in-line recheck below (and any later tick) verifies and clears it.
        touch "$STATE_DIR/drain_pending"
        notify "✓ hermes agent updated to ${VERSION:-unknown} — gateway restarting (updater v${UPDATER_VERSION})"
        # Consume the marker now when possible (C7: hot streaks starve no-update ticks):
        # after a short settle wait, verify and clear on health.
        sleep "${AU_SETTLE_SECONDS:-45}"   # env knob: matrix sets 0 to keep runs fast
        recheck_drain_marker >/dev/null 2>&1 || true
        exit 0
    fi
    # exit 0 but receipt says partial/missing: install landed, restart may race.
    # Wait for the gateway to catch up before declaring anything.
    log "exit=0 but receipt outcome=$OUTCOME — waiting for gateway to restart"
    # Set the marker BEFORE waiting, not only after the wait times out: if this script is
    # killed mid-poll (a terminal timeout, the very restart it just triggered, a reboot)
    # the install stays flagged and the next no-update tick consumes it. Marker-on-timeout
    # only is invisible to precisely the interruption it exists to survive.
    touch "$STATE_DIR/drain_pending"
    GW_OK=0
    # Env knobs so the drain-timeout branch is testable in seconds, not minutes
    # (AU_POLL_EVERY seconds x AU_POLL_TRIES tries; defaults keep the 6x30s behavior).
    AU_POLL_EVERY="${AU_POLL_EVERY:-30}"
    AU_POLL_TRIES="${AU_POLL_TRIES:-6}"
    for _ in $(seq 1 "$AU_POLL_TRIES"); do
        sleep "$AU_POLL_EVERY"
        # Gateway confirmation requires the SAME evidence everywhere: state SHA == HEAD
        # AND systemd says active. A fresh success receipt is NOT sufficient — it only
        # means some updater finished, not that this gateway is healthy on the new code
        # (D1: the old `[ "$LATEST" = success ] && break` short-circuited exactly the
        # is-active check written two lines below it, re-admitting the C2 false positive).
        if gateway_confirmed; then GW_OK=1; break; fi
    done
    if [ "$GW_OK" -eq 1 ]; then
        log "success $VERSION (receipt: $OUTCOME → gateway confirmed current)"
        reset_real_fails
        record_install_ok
        clear_drain_marker
        notify "✓ hermes agent updated to ${VERSION:-unknown} — gateway restarted (updater v${UPDATER_VERSION})"
        exit 0
    fi
    # Drain can legitimately take up to 30 min (restart_after_turn_timeout) — our 3 min
    # window is only a fast-path confirmation. Timing out is NOT evidence of failure.
    # The next tick only re-verifies because recheck_drain_marker() runs on the no-update
    # path; a dead gateway keeps the marker and re-alerts on the 1st/3rd/6th tick.
    touch "$STATE_DIR/drain_pending"
    record_install_ok   # the code landed (exit 0); only the gateway restart is unconfirmed
    log "⚠ install ok, gateway not confirmed within 3 min (still draining?) — drain_pending set, next tick re-verifies"
    notify "⚠ hermes auto-update: installed $VERSION, gateway restart still draining (no failure) — re-check next tick"
    exit 0
fi

# Nonzero exit: could be a real failure OR the STALE race (update complete, restart
# still draining when the fleet check ran — exit 1, receipt outcome=partial/pending).
# Only a FRESH receipt is evidence about this run ("stale" = pre-run data, ignore it).
if [ "$OUTCOME" = "success" ] || [ "$OUTCOME" = "partial" ]; then
    # Install demonstrably landed. Primary evidence = the receipt's MACHINE fields:
    # post_update.short_sha advanced past pre_update.short_sha proves code landed.
    # Text ("Update complete") is only a fallback when the SHAs are unavailable —
    # never the primary signal (upstream rewords banners; machine fields don't drift).
    SHA_ADVANCED=0
    if [ -f "$RECEIPT" ]; then
        SHA_ADVANCED=$(python3 - "$RECEIPT" <<'PYEOF' 2>/dev/null || echo 0
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    pre = ((d.get("pre_update") or {}).get("short_sha") or "").strip()
    post = ((d.get("post_update") or {}).get("short_sha") or "").strip()
    print(1 if (pre and post and pre != post) else 0)
except Exception:
    print(0)
PYEOF
)
    fi
    if [ "$SHA_ADVANCED" = "1" ] || echo "$UPDATE_OUT" | grep -q "Update complete"; then
        log "success $VERSION (exit=$STATUS but receipt=$OUTCOME, code landed per SHA advance/text — restart race, not failure)"
        reset_real_fails
        record_install_ok
        # DO NOT clear the drain marker here: the race means the gateway was NOT
        # confirmed current — the receipt froze stale. Keep/refresh the marker so the
        # next no-update tick re-verifies (recheck_drain_marker); erasing it here
        # reproduced Nova's Defect-2 class in this branch (gateway dies → silence).
        touch "$STATE_DIR/drain_pending"
        notify "✓ hermes agent updated to ${VERSION:-unknown} (exit=$STATUS race; fleet catches up on next restart) (updater v${UPDATER_VERSION})"
        exit 0
    fi
fi

# Real failure. Dedup (a persistent failure like a merge conflict must not page every
# tick): alert on the first attempt, then at most every AU_REALERT_SECS (real_fail_alert).
log "REAL FAILURE (exit=$STATUS, receipt=$OUTCOME)"
F=$(read_counter consec_real_fails)
F=$((F + 1))
echo "$F" > "$STATE_DIR/consec_real_fails"
real_fail_alert "$F" "✗ hermes auto-update failed (attempt $F, exit $STATUS): $(echo "$UPDATE_OUT" | grep -E "✗|⚠" | head -2 | tr '\n' ' ')| last successful install: $(last_install_text) (updater v${UPDATER_VERSION})"
exit 1