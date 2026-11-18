#!/bin/bash
# Auto-update Hermes via system cron (outside the gateway process tree).
# Outside the tree the updater drains + restarts the gateway itself via systemd,
# so no STALE race: the script can wait for the fleet to be current and verify.
# Notify on Telegram only for real outcomes (update installed / failure).
#
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
# v5.15 (2026-11-18): issue #1 — stable-channel verdicts + wall-clock alerting (7d2f640 + follow-up).
#   Upstream `hermes update --check` has NO machine-readable output (argparse --check is a bare
#   store_true, hermes_cli/subcommands/update.py:18-20; every verdict exits 0 as plain print()s,
#   hermes_cli/update_cmd_check.py:97-125 and :191-228). So the text IS the contract:
#   - classify_verdicts accepts only the exact upstream sentences, whole line (stable :110 :112
#     :115 :119 :123; main :200/:208/:222 and :212/:214/:225, plus the ☤ glyph older builds used),
#     the known context lines (:97 banner, :108 retired, :116-117/:120-121/:124/:215/:228 hints,
#     :143/:164 fetching) and the known `  (…)` cleanup lines (:49 :52 :62 :65 :180 :183). ANY
#     other non-empty line, any ✗, any line containing error/failed/timed out (any case), or two
#     different verdicts = unknown (counted, alerted at 3) — never "no update", never install.
#   - --yes no-op with no receipt for this run is accepted only on an exact upstream --yes no-op
#     sentence (update_cmd.py:1730/:1731/:1915, optional " [<branch> @ <sha>]" suffix) and only
#     after the veto, which judges only the lines that CLAIM a conclusion (they contain a
#     conclusion keyword: up to date, holding at this build, no newer release, release / update
#     available, newer than the, nothing to update, …). Each such line must be a whole upstream
#     sentence, else vetoed. Banners and progress lines carry no keyword and pass as neutral (no
#     line whitelist). Also vetoed: ✗ / error words, an available-or-rollback verdict, a line
#     announcing code movement (Post-swap hand-off, Pulling updates, Code updated!, …). A vetoed
#     no-op is a REAL FAILURE (counted, alerted, exit 1, no reset).
#   - every legitimate no-op exit (check-time and --yes) resets consec_real_fails after the drain
#     recheck, so an old streak cannot swallow the next unrelated failure's first alert.
#   - check alerts: first at the 3rd consecutive problem, then every AU_CHECK_ALERT_INTERVAL s
#     (default 82800 = 1 day - 1h of scheduling margin);
#     real failures: first at once, then every AU_REALERT_SECS s; notify-failure dead letter +
#     meta-alert: at the 3rd, then every AU_REALERT_SECS s; "checkout newer than the selected
#     release": reminder every AU_ROLLBACK_REMIND_SECS s (never installs). All stamps are the
#     TICK START epoch, read through read_ts (garbage/empty/huge/future = due, then self-heal).
#   - check alert summary picks ✗ / error / failed / timed out lines (+1 line of context) first,
#     then fills with the remaining lines, then bounds the size.
#   - behaviour change: exit 0 with no receipt for THIS run is no longer a success (completion
#     text -> "install unproven", exit 1; unrecognized -> exit 1). Hermes builds that write no
#     update receipt therefore alert on every install.
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
# Tick start (epoch). Every alert/reminder timestamp is THIS value and every interval is measured
# from it, so the length of the check itself (1s vs a 300s timeout) cannot shift the cadence.
# Start jitter remains (a tick that starts 1s late, then one on time, are 86399s apart; a local-time
# cron across a DST change is 82800s or 90000s apart), so the daily defaults keep a 1h margin.
TICK_TS=$(date +%s)
case "$TICK_TS" in ''|*[!0-9]*) TICK_TS=0 ;; esac
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

# Epoch reader. This is NOT read_counter, whose 6-digit clamp would zero every real epoch.
# Garbage, empty, or more than 12 digits echoes nothing, and the caller treats that as
# "no timestamp": it alerts, and on delivery the file is overwritten (self-heal).
read_ts() {
    local v
    v=$(head -c 64 "$STATE_DIR/$1" 2>/dev/null | tr -d '[:space:]')
    case "$v" in ''|*[!0-9]*) return 0 ;; esac
    [ "${#v}" -le 12 ] || return 0
    printf '%s' "$((10#$v))"
}
fmt_ts() { date -d "@$1" '+%F %T %Z' 2>/dev/null || printf '%s' "$1"; }

# Interval knob in seconds. $1 = raw value, $2 = default. Empty, non-numeric (incl. a sign),
# zero, or more than 9 digits falls back to the default; leading zeros are decimal ("00060" = 60).
knob_secs() {
    local v="$1"
    case "$v" in ''|*[!0-9]*) printf '%s' "$2"; return 0 ;; esac
    [ "${#v}" -le 9 ] || { printf '%s' "$2"; return 0; }
    v=$((10#$v))
    [ "$v" -gt 0 ] || v="$2"
    printf '%s' "$v"
}

# Wall-clock throttle. True (0) when an alert/reminder guarded by stamp file $1 may go out now:
# no usable stamp (missing, empty, garbage, over-long: never "silent forever"), a stamp more than
# 300s in the future (clock moved back / corrupted: would otherwise suppress forever), or at least
# $2 seconds since the stamp. Callers write the stamp ($TICK_TS) only after delivery.
interval_due() {
    local last
    last=$(read_ts "$1")
    [ -n "$last" ] || return 0
    [ "$last" -gt $((TICK_TS + 300)) ] && return 0
    [ $((TICK_TS - last)) -ge "$2" ]
}

# Alert cadences (wall clock, seconds; see README "Alert cadence" for the reasoning):
#  - AU_CHECK_ALERT_INTERVAL (default 82800 = 1 day - 1h): re-alert while --check keeps failing /
#    unknown, after the first alert on the 3rd consecutive problem. Stamps are tick-start epochs,
#    so the check's own duration cannot shift the cadence; the 1h margin absorbs start jitter
#    (whole-second epochs: 86399s between a late and an on-time tick) and a local-time cron
#    crossing a DST change (82800s), either of which would otherwise slip the reminder a day.
#  - AU_REALERT_SECS (default 255600 = 3 days - 1h): re-alert for a persisting REAL install failure
#    (the first failure always alerts at once) and for the notify-failure dead letter + meta-alert
#    (first at the 3rd consecutive delivery failure). The same broken install retried daily is one
#    incident: a reminder every third daily tick keeps it visible without a daily page; the 1h
#    margin keeps a late-starting tick from slipping the reminder to the 4th day.
#  - AU_ROLLBACK_REMIND_SECS (default 601200 = 7 days - 1h): "this checkout is newer than the
#    selected release" needs a human decision, not an emergency page — a weekly nudge, same margin.
AU_CHECK_ALERT_INTERVAL=$(knob_secs "${AU_CHECK_ALERT_INTERVAL-}" 82800)
AU_REALERT_SECS=$(knob_secs "${AU_REALERT_SECS-}" 255600)
AU_ROLLBACK_REMIND_SECS=$(knob_secs "${AU_ROLLBACK_REMIND_SECS-}" 601200)

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
        rm -f "$STATE_DIR/notify_alert_last_ts"
        return 0
    fi
    [ -n "$resp" ] && log "notify rejected by API: $(printf '%s' "$resp" | head -c 200)"
    # Delivery failed: count it. Dead letter + meta-alert on the 3rd consecutive failure, then
    # by WALL CLOCK every AU_REALERT_SECS (a tick count re-alerted only every 24 ticks = 24 days
    # on the daily schedule).
    local n
    n=$(read_counter consec_notify_fails)
    n=$((n + 1))
    echo "$n" > "$STATE_DIR/consec_notify_fails"
    log "notify delivery failed ($n consecutive)"
    if [ "$n" -ge 3 ] && { [ "$n" -eq 3 ] || interval_due notify_alert_last_ts "$AU_REALERT_SECS"; }; then
        # C6: this re-alert travels the SAME possibly-dead channel — a proxy that stays
        # down would make every warning vanish. Leave a local sentinel + log fingerprint
        # so a dead notification channel is discoverable without Telegram. The local dead
        # letter IS the delivered artefact here, so the throttle stamp is written with it.
        printf '%s\n' "[$(date '+%F %T')] $n consecutive delivery failures — last unsent: $msg" >> "$STATE_DIR/notify_dead_letter.log"
        echo "$TICK_TS" > "$STATE_DIR/notify_alert_last_ts"
        curl -s -m 20 -x "$TG_PROXY" \
            "https://api.telegram.org/bot${tok}/sendMessage" \
            --data-urlencode "chat_id=${cid}" \
            --data-urlencode "text=⚠ hermes auto-update: notifications failing ($n consecutive) — last unsent: $msg" >/dev/null 2>&1 || true
    fi
    return 1
}

# Freshness-gated reader over a receipt FILE. $1 = path to the immutable post-command
# snapshot (never the shared latest.json), $2 = run start epoch, $3 = correlation id.
# Outcome is only meaningful if the receipt was FINISHED after $2. A stale receipt (older
# run) returns "stale" — callers must not treat it as evidence about THIS run. Parses ISO
# finished_at incl. the +00:00 tz suffix.
receipt_outcome_fresh() {
    python3 - "$1" "$2" "${3:-}" <<'PYEOF' 2>/dev/null || echo "unreadable"
import json, sys
from datetime import datetime
try:
    d = json.load(open(sys.argv[1]))
    # Upstream UpdateReceipt (schema 1) writes NO "kind" field. Its keys are schema/started_at/
    # finished_at/argv/pid/outcome/pre_update/post_update/steps/skips/gateway_restart/fleet/
    # update_id/correlation_id/action_id. So an absent kind is the real upstream shape. An
    # explicit kind is accepted only when it is "update". Any other kind (plugin-check etc.
    # sharing latest.json) is NOT install evidence.
    kind = d.get("kind")
    if kind is not None and str(kind).strip().lower() != "update":
        print("foreign"); raise SystemExit(0)
    # Upstream copies the launcher's HERMES_UPDATE_CORRELATION_ID into correlation_id.
    # A non-null id that is not ours belongs to another invocation.
    want = sys.argv[3] if len(sys.argv) > 3 else ""
    got = d.get("correlation_id")
    if want and got not in (None, "") and str(got) != want:
        print("stale"); raise SystemExit(0)
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

# --- issue #1: check verdicts, time-based check alerts, install proof -------------------
# Repeat check alerts are TIME-based, not tick-count based. The first alert fires on the 3rd
# consecutive failed-or-unknown check. After that, at most one alert per
# AU_CHECK_ALERT_INTERVAL seconds (default 82800, parsed with the other knobs above). The
# delivery timestamp is written ONLY when notify() succeeds, so a dead channel retries on the
# next tick.
# Line-anchored --yes patterns. Quoted diagnostic text in the middle of a line never matches.
# RE_NOOP is deliberately BROAD: it finds every line SHAPED like a no-op claim (any indentation,
# any tail). It routes the run into the no-op branch and makes the legacy-receipt rules stricter,
# but it never accepts a no-op on its own: yes_noop_veto() accepts only V_YES_NOOP (below), and
# vetoes every other no-op-shaped line as a real failure.
RE_COMPLETE='^[[:space:]]*(✓[[:space:]]*)?Update complete([^[:alnum:]_]|$)'
RE_NOOP='^[[:space:]]*((✓|→)[[:space:]]*)?(Already up to date|Up to date|Holding at this build|No newer release)([^[:alnum:]_]|$)'

mark_installed() { date +%s > "$STATE_DIR/last_install_ts"; }   # call ONLY on proven installs
check_ok() { echo 0 > "$STATE_DIR/consec_check_fails"; rm -f "$STATE_DIR/check_alert_last_ts"; }
# A conclusive updater run (proven install, or a legitimate no-op after the veto and the drain
# recheck) ends the real-failure streak: the next unrelated failure must alert at once.
reset_real_fails() { echo 0 > "$STATE_DIR/consec_real_fails"; rm -f "$STATE_DIR/real_alert_last_ts"; }
# Leaving the "checkout newer than the selected release" state ends its reminder cycle.
# rollback_notified is the pre-5.15 one-shot marker; removed wherever the stamp is.
clear_rollback_remind() { rm -f "$STATE_DIR/rollback_remind_ts" "$STATE_DIR/rollback_notified"; }

# Real (install-phase) failures. The first failure of a streak alerts at once; while the streak
# persists, re-alert by WALL CLOCK every AU_REALERT_SECS (a count of every 12th tick meant every
# 12 days on the daily schedule). The stamp is written only when the alert is delivered, so an
# undelivered first alert is retried on the next failure. Sets REAL_F (the streak length).
real_fail_count() {
    REAL_F=$(read_counter consec_real_fails); REAL_F=$((REAL_F + 1))
    echo "$REAL_F" > "$STATE_DIR/consec_real_fails"
}
real_fail_alert() {  # $1 = alert text (call real_fail_count first)
    if [ "$REAL_F" -eq 1 ] || interval_due real_alert_last_ts "$AU_REALERT_SECS"; then
        if notify "$1"; then
            echo "$TICK_TS" > "$STATE_DIR/real_alert_last_ts"
        else
            log "real-failure alert #$REAL_F not delivered — retrying on the next failure"
        fi
    else
        log "failure #$REAL_F - notify suppressed (last alert $(fmt_ts "$(read_ts real_alert_last_ts)"), re-alert interval ${AU_REALERT_SECS}s)"
    fi
}
# The generic install-phase REAL FAILURE exit (reads STATUS / OUTCOME / UPDATE_OUT). $1 = extra
# reason for the alert (optional).
real_failure_exit() {
    log "REAL FAILURE (exit=$STATUS, receipt=$OUTCOME)${1:+ — $1}"
    real_fail_count
    real_fail_alert "✗ hermes auto-update failed (attempt $REAL_F, exit $STATUS, receipt $OUTCOME)${1:+ — $1}: $(echo "$UPDATE_OUT" | grep -E "✗|⚠" | head -2 | tr '\n' ' ')"
    exit 1
}

# Bounded multiline error summary. Channel banner lines and blank lines are dropped. Lines with
# a ✗ or naming error / failed / timed out (any case) come FIRST, each with the one line after it
# as context; the remaining budget is filled with the other lines in order; only then is the
# result bounded (6 lines, 200 bytes per line, 1000 bytes total). So a real error after a screen
# of cleanup chatter (update_cmd_check.py:49/:52/:62 print before the verdict) is never cut off.
check_summary() {
    local s
    s=$(printf '%s\n' "$1" | tr -d '\r' | awk '
        /^[[:space:]]*$/ { next }
        /^[[:space:]]*→[[:space:]]*Update channel:/ { next }
        { n++; line[n] = $0; low = tolower($0)
          if (index($0, "✗") || low ~ /error|failed|timed out/) pri[n] = 1 }
        END {
          max = 6; out = 0
          for (i = 1; i <= n && out < max; i++) {
            if (!pri[i]) continue
            if (!seen[i]) { seen[i] = 1; print line[i]; out++ }
            if (i + 1 <= n && !seen[i + 1] && out < max) { seen[i + 1] = 1; print line[i + 1]; out++ }
          }
          for (i = 1; i <= n && out < max; i++)
            if (!seen[i]) { seen[i] = 1; print line[i]; out++ }
        }' | cut -c1-200 | head -c 1000)
    printf '%s' "${s:-(no output)}"
}

# Failed (nonzero) and unknown checks share ONE counter and ONE cadence.
check_problem() {  # $1 = label
    local n li msg
    n=$(read_counter consec_check_fails); n=$((n + 1))
    echo "$n" > "$STATE_DIR/consec_check_fails"
    [ "$n" -ge 3 ] || return 0
    # Alert when this is the 3rd problem, or when interval_due says so: no usable timestamp
    # (migration from the old counter at N>3, malformed/huge), a timestamp more than 300s in the
    # future (would otherwise suppress forever), or the interval has elapsed.
    if [ "$n" -ne 3 ] && ! interval_due check_alert_last_ts "$AU_CHECK_ALERT_INTERVAL"; then
        log "check problem #$n — alert suppressed (last alert $(fmt_ts "$(read_ts check_alert_last_ts)"), interval ${AU_CHECK_ALERT_INTERVAL}s)"
        return 0
    fi
    li=$(read_ts last_install_ts)
    msg="⚠ hermes auto-update: update check $1 ($n consecutive)
last successful install: $(if [ -n "$li" ]; then fmt_ts "$li"; else echo unknown; fi)
$(check_summary "$CHECK_OUT")"
    if notify "$msg"; then
        echo "$TICK_TS" > "$STATE_DIR/check_alert_last_ts"
    else
        log "check alert #$n not delivered — retrying next tick"
    fi
}

# --- `hermes update --check` output contract (upstream has NO machine-readable form) ---------
# `--check` is a bare store_true flag (hermes_cli/subcommands/update.py:18-20); every verdict is
# a print() followed by exit 0 (hermes_cli/update_cmd_check.py, byte-identical in v0.23.1,
# v0.23.2 and upstream main 67e4d22). The text is therefore the contract, matched WHOLE LINE
# after trimming surrounding whitespace and one trailing CR:
#   stable  :110 "✓ No newer release: {label}."     (printed only under target.ahead (:109), so
#                                                    the label is always the "ahead" form below)
#           :112 "✓ Up to date with the latest release ({label})."
#           :115 "→ Holding at this build: {label} predates the gateway runtime your sessions use."
#           :119 "→ This checkout is newer than the selected release: {label}."
#           :123 "→ Selected release available: {label}"
#   main    :200/:208/:222 "✓ Already up to date."
#           :212/:225 "⚕ Update available: {N} commit(s) behind {ref}."  :214 "⚕ Update available (behind {ref})."
#           Older builds printed the same two sentences with ☤ (v2026.9.24 update_cmd.py:623/:625)
#           and ⚕ before that (v2026.6.19/v2026.7.20 main.py); no release printed a glyph-less
#           --check verdict, so a glyph-less line is NOT accepted.
#   label   hermes_cli/source_releases.py:61-65: "{channel} v{version} ({commit[:12]})", or when
#           target.ahead the form "{channel} v{version}; this checkout is newer and waits for the
#           next release (`hermes update --set-channel main` follows every commit)" (:62-64). Since
#           :110 runs only when ahead, "No newer release" accepts ONLY the ahead label.
#   context :97 banner, :108 retired line, :116-117 / :120-121 / :124 / :215 / :228 hints,
#           :143 / :164 "→ Fetching from {remote}...", and the `  (…)` cleanup lines :49 :52 :62
#           :65 :180 :183 — accepted, carry no verdict.
# A line with ✗, a line containing error / failed / timed out (any case), and ANY other non-empty
# line make the whole output unknown. Errors exit 1 upstream (:103-104, update_cmd.py:639/:669).
_V_LBL='[^[:space:]]+ v[^[:space:]]+( \([0-9a-f]{7,40}\))?'
_V_LBL_AHEAD='[^[:space:]]+ v[^[:space:]]+; this checkout is newer and waits for the next release \(`hermes update --set-channel main` follows every commit\)'
_V_REF='[^[:space:]]+'
V_UPTODATE="^(✓ No newer release: $_V_LBL_AHEAD\.|✓ Up to date with the latest release \($_V_LBL\)\.|✓ Already up to date\.)\$"
V_HELD="^→ Holding at this build: $_V_LBL predates the gateway runtime your sessions use\.\$"
V_ROLLBACK="^→ This checkout is newer than the selected release: $_V_LBL\.\$"
V_AVAILABLE="^(→ Selected release available: $_V_LBL|(⚕|☤) Update available(: [0-9]+ commits? behind $_V_REF\.| \(behind $_V_REF\)\.))\$"
V_CONTEXT="^(→ Update channel: $_V_REF|→ $_V_REF retired; source destination: $_V_REF|→ Fetching from $_V_REF\.\.\.|Run '[^']+' to install\.|\((removed stale git lock: .+|removed [0-9]+ aborted-fetch pack temp file\(s\)|git cleanup: .+|git cleanup stopped at its [0-9]+s limit; the next update continues it|restored [0-9]+ broken shallow boundary\(ies\)|pruned [0-9]+ stale shallow graft\(s\) left by past depth-1 checks)\))\$"

# Classify ONE output line into CL: blank | error | uptodate | held | rollback | available |
# context | unknown. Sets a global (no subshell) so loops stay cheap.
classify_line() {
    local l="${1%$'\r'}"
    l="${l#"${l%%[![:space:]]*}"}"
    l="${l%"${l##*[![:space:]]}"}"
    CL=blank
    [ -n "$l" ] || return 0
    CL=error
    case "$l" in *"✗"*) return 0 ;; esac
    case "${l,,}" in *error*|*failed*|*"timed out"*) return 0 ;; esac
    if [[ $l =~ $V_UPTODATE ]]; then CL=uptodate
    elif [[ $l =~ $V_HELD ]]; then CL=held
    elif [[ $l =~ $V_ROLLBACK ]]; then CL=rollback
    elif [[ $l =~ $V_AVAILABLE ]]; then CL=available
    elif [[ $l =~ $V_CONTEXT ]]; then CL=context
    else
        case "$l" in
            '`hermes update` stays on this build; the next release that includes the runtime installs normally (`hermes update --set-channel main` follows every commit).' \
            | '`hermes update` moves it back to that release (`hermes update --set-channel main` follows every commit).' \
            | 'Run `hermes update` to install it.') CL=context ;;
            *) CL=unknown ;;
        esac
    fi
}

# Classify --check output. Echoes available | uptodate | held | rollback | unknown.
# unknown (fail closed) = any error line, any unrecognized non-empty line, no verdict, or two
# different verdicts.
classify_verdicts() {
    local line found="" bad=0
    while IFS= read -r line; do
        classify_line "$line"
        case "$CL" in
            blank|context) ;;
            error|unknown) bad=1 ;;
            *) case " $found " in *" $CL "*) ;; *) found="${found:+$found }$CL" ;; esac ;;
        esac
    done <<< "$1"
    if [ "$bad" -ne 0 ]; then echo unknown; return 0; fi
    case "$found" in available|uptodate|held|rollback) echo "$found" ;; *) echo unknown ;; esac
}

# Why --check output is unknown, for the log: the first error / unrecognized line, else
# "no verdict" or the conflicting verdict set.
verdict_detail() {
    local line found=""
    while IFS= read -r line; do
        classify_line "$line"
        case "$CL" in
            error|unknown) printf '%s line: %s' "$CL" "$(printf '%s' "$line" | tr -d '\r' | head -c 200)"; return 0 ;;
            uptodate|held|rollback|available) found="${found:+$found }$CL" ;;
        esac
    done <<< "$1"
    printf '%s' "${found:+conflicting verdicts: $found}"
    [ -n "$found" ] || printf 'no verdict line'
}

# --- `hermes update --yes` no-op contract -----------------------------------------------------
# On a no-op run upstream prints the whole maintenance tail and then ONE conclusion line,
# _print_update_completion (update_cmd_maint.py:304-311) = "{message}{_branch_head_suffix()}",
# suffix " [<branch|detached> @ <git rev-parse --short HEAD>]" or "" (update_cmd_git.py:160-175).
# The message on the no-op path (_finish_already_up_to_date) is exactly one of:
#   "✓ Already up to date!"                                    update_cmd.py:1730 (v0.23.1 :1726;
#        v2026.9.24 update_cmd.py:764; bare print in v2026.3.12 main.py:1667, v2026.6.19
#        main.py:8798, v2026.7.20 main.py:10256)
#   "✓ Up to date with your fork (official repo not checked)."  update_cmd.py:1731 (v0.23.1 :1727;
#        v2026.9.24 update_cmd.py:765)
#   "✓ Holding at this build until a newer {channel} release ships."  update_cmd.py:1915
#        (v0.23.1 :1911)
# Nothing else is a --yes no-op. "✓ Already up to date." (period) is ONLY the --check sentence
# (update_cmd_check.py:200/:208/:222; v2026.6.19 main.py:7913/:8004 and v2026.7.20 main.py:8876/
# :8985/:9003, all inside _cmd_update_check); no --yes path ever printed it.
V_YES_NOOP='^(✓ Already up to date!|✓ Up to date with your fork \(official repo not checked\)\.|✓ Holding at this build until a newer [^[:space:]]+ release ships\.)( \[[^][]+ @ [0-9a-f]{4,40}\])?$'
# --- which --yes lines are judged (PATCH3, B700/B801/B802) ----------------------------------
# Only a line that CLAIMS a conclusion is judged. A line claims one when, after removing SGR
# colour codes, a trailing CR and surrounding whitespace, it contains a conclusion keyword (any
# case, "up to date" also hyphenated). Keywords and where upstream prints them (origin/main
# 67e4d22 unless noted):
#   up to date            update_cmd.py:1730/:1731; update_cmd_check.py:112/:200/:208/:222;
#                         step reports update_cmd_maint.py:516, update_cmd_config.py:259,
#                         update_cmd_git.py:421, source_build.py:276/:282/:348/:350,
#                         update_receipt.py:1244
#   holding at this build update_cmd.py:1915; update_cmd_check.py:115
#   no newer release      update_cmd_check.py:110
#   nothing to update     update_cmd_check.py:323-324
#   newer than the        update_cmd_check.py:119 (rollback verdict), :323
#   release available     update_cmd_check.py:123
#   update(s) available   update_cmd_check.py:212/:214/:225; update_cmd.py:1938;
#                         update_cmd_maint.py:185
#   release status, release check, channel status: never printed by any upstream --yes path; a
#                         line about the release / channel status is a claim about the outcome
#                         (the r3/r4 "→ Release status could not be verified" vetoes stay).
# A judged line passes only if it is a WHOLE upstream sentence from one of the three tables
# below and holds no extra keyword (so a free slot cannot smuggle a second claim):
#   V_YES_NOOP       the no-op conclusions (the only lines that make the run a no-op)
#   V_YES_HELD_WHY   the held explanation that precedes the held conclusion
#   V_YES_STEP       upstream step reports that name their own subject ("Skills are up to date")
# Anything else that claims a conclusion is vetoed. Lines WITHOUT a keyword (banners such as
# "☤/⚕ Updating Hermes Agent...", "→ Fetching updates...", "→ Fleet: …", maintenance logs) are
# neutral: there is deliberately no whitelist for them.
RE_YES_CONCL='(up[ -]?to[ -]?date|holding at this build|no newer release|nothing (new )?to update|newer than the|release available|updates? available|release status|release check|channel status)'
# The available / rollback class, for the veto reason only: such a line beside a no-op conflicts.
RE_YES_CONFLICT='(newer than the|release available|updates? available)'
# Lines that announce that code moved or is being swapped. Beside a no-op they contradict it
# (movement + nothing to do), so the run is vetoed. Where upstream prints them (origin/main):
#   post-swap hand-off              update_handoff.py:143
#   switching to source commit      update_cmd.py:1931
#   found N new commit(s)           update_cmd.py:1933
#   switched the running checkout   update_cmd.py:1935
#   pulling updates                 update_cmd.py:1940
#   resetting to match remote       update_cmd.py:877
#   rolling back to                 update_cmd.py:915
#   falling back to zip download    update_cmd.py:1667
#   pulling from upstream, commit(s) behind upstream   update_cmd_git.py:423
#   syncing fork                    update_cmd_git.py:487
#   code updated                    update_completion.py:427
#   downloading latest version, items from zip   update_cmd_zip.py:576/:597
#   update complete                 update_cmd_maint.py:356 (completion line)
RE_YES_MOVE='(post-swap hand-off|switching to source commit|new commit|switched the running checkout|pulling (updates|from upstream)|resetting to match remote|rolling back to|falling back to zip|syncing fork|behind upstream|code updated|downloading latest version|items from zip|update complete)'
# The held explanation, update_cmd_check.py:323-324 (hold_channel_release_behind_runtime). It is
# printed on the --yes held path just before the held conclusion; it carries two keywords.
V_YES_HELD_WHY='^→ This build is newer than the [A-Za-z0-9_.-]+ release [0-9a-f]{7,40}: that release predates the gateway runtime your sessions use, so there is nothing to update to yet\.$'
# Upstream step reports that contain a keyword about their OWN subject, whole sentence each:
#   ✓ Skills are up to date             update_cmd_maint.py:516 (v2026.3.12 main.py:1595/:1715,
#                                       v2026.7.20 main.py:10550)
#   ✓ Configuration is up to date       update_cmd_config.py:259 (v2026.3.12 main.py:1755,
#                                       v2026.7.20 main.py:10739)
#   ✓ Fork is up to date with upstream  update_cmd_git.py:421 (v2026.7.20 main.py:7126)
#   ✓ TUI is up to date / ✓ Web UI is up to date   source_build.py:276/:282
#   ✓ Desktop app is up to date[: no desktop build input changed since <sha12>]  source_build.py:348/:350
#   ✓ Desktop app up to date            v2026.7.20 main.py:10495
#   ✓ <profile> (pid <pid>) @ <sha> — up to date   update_receipt.py:1244 (fleet row)
#   ◆ Search index update available     update_cmd_maint.py:185 (post-update notice, printed on
#                                       the no-op tail too: update_cmd_maint.py:1072)
V_YES_STEP='^(✓ Skills are up to date|✓ Configuration is up to date|✓ Fork is up to date with upstream|✓ TUI is up to date|✓ Web UI is up to date|✓ Desktop app is up to date(: no desktop build input changed since [0-9a-f]{7,40})?|✓ Desktop app up to date|✓ [^[:space:]]+ \(pid [0-9]+\) @ [0-9a-f]{4,40} — up to date|◆ Search index update available)$'

# Strip SGR / other CSI escapes, one trailing CR and surrounding whitespace into YT.
yes_trim() {
    local t="${1%$'\r'}" esc=$'\e'
    while [[ $t =~ ${esc}\[[0-9\;?]*[A-Za-z] ]]; do t="${t/"${BASH_REMATCH[0]}"/}"; done
    t="${t#"${t%%[![:space:]]*}"}"
    YT="${t%"${t##*[![:space:]]}"}"
}
# Number of conclusion keywords in $1 (lower-case text) into KWN.
yes_kw_count() {
    local s="$1"
    KWN=0
    while [[ $s =~ $RE_YES_CONCL ]]; do KWN=$((KWN + 1)); s="${s/"${BASH_REMATCH[0]}"/ }"; done
}

# --yes no-op veto. The no-op stands ("nothing installed, nothing wrong") only if
#   - at least one line is an exact upstream no-op sentence (V_YES_NOOP), and
#   - no line is ✗ / names error, failed or timed out (any case) / is an available or rollback
#     verdict, and
#   - no line announces code movement (RE_YES_MOVE), and
#   - every line that claims a conclusion (RE_YES_CONCL) is a whole upstream sentence from
#     V_YES_NOOP / V_YES_HELD_WHY / V_YES_STEP with no extra keyword ("✓ Already up to date? …",
#     "✓ Already up to date. (cached …)", the --check sentences, "→ Fleet: … Already up to date"
#     are all vetoed), and
#   - the held explanation appears only together with the held conclusion.
# Every other line is neutral. Echoes the reason and returns 0 when vetoed; returns 1 (no output)
# when the no-op may stand.
yes_noop_veto() {
    local raw t lc seen=0 held=0 why=0
    while IFS= read -r raw; do
        yes_trim "$raw"; t=$YT
        [ -n "$t" ] || continue
        classify_line "$t"
        case "$CL" in
            error)
                printf 'error line: %s' "$(printf '%s' "$t" | head -c 200)"; return 0 ;;
            available|rollback)
                printf 'conflicting %s verdict: %s' "$CL" "$(printf '%s' "$t" | head -c 200)"; return 0 ;;
        esac
        lc="${t,,}"
        if [[ $lc =~ $RE_YES_MOVE ]]; then
            printf 'code movement beside a no-op: %s' "$(printf '%s' "$t" | head -c 200)"; return 0
        fi
        [[ $lc =~ $RE_YES_CONCL ]] || continue          # no conclusion claimed: neutral
        yes_kw_count "$lc"
        if [ "$KWN" -eq 1 ] && [[ $t =~ $V_YES_NOOP ]]; then
            seen=1
            case "$t" in "✓ Holding at this build until "*) held=1 ;; esac
            continue
        fi
        if [ "$KWN" -eq 2 ] && [[ $t =~ $V_YES_HELD_WHY ]]; then why=1; continue; fi
        if [ "$KWN" -eq 1 ] && [[ $t =~ $V_YES_STEP ]]; then continue; fi
        if [[ $lc =~ $RE_YES_CONFLICT ]]; then
            printf 'conflicting conclusion line, not an upstream --yes sentence: %s' "$(printf '%s' "$t" | head -c 200)"; return 0
        fi
        printf 'no-op line is not an upstream --yes sentence: %s' "$(printf '%s' "$t" | head -c 200)"; return 0
    done <<< "$1"
    if [ "$seen" -ne 1 ]; then printf 'no upstream --yes no-op sentence'; return 0; fi
    if [ "$why" -eq 1 ] && [ "$held" -ne 1 ]; then
        printf 'held explanation without the held conclusion'; return 0
    fi
    return 1
}
# The accepted no-op sentence, for the log (call only after the veto passed).
yes_noop_line() {
    local raw t
    while IFS= read -r raw; do
        yes_trim "$raw"; t=$YT
        if [[ $t =~ $V_YES_NOOP ]]; then printf '%s' "$t" | head -c 200; return 0; fi
    done <<< "$1"
}

# Version from the completion line.
# New format: "(vA → vB) [detached @ sha]" yields the destination vB.
# Legacy format: "(vX)" ON THE COMPLETION LINE is kept verbatim. There is no fallback to an
# arbitrary (vX) elsewhere in the output, because that could name an unrelated version.
parse_version() {
    local line v
    line=$(printf '%s\n' "$1" | grep -E "$RE_COMPLETE" | tail -1)
    v=$(printf '%s' "$line" | grep -oE '→ ?v[0-9][0-9A-Za-z.+-]*' | tail -1 | grep -oE 'v[0-9][0-9A-Za-z.+-]*')
    [ -n "$v" ] || v=$(printf '%s' "$line" | grep -oE '\(v[0-9.]+\)' | head -1)
    printf '%s' "$v"
}

# 1 only when the receipt is a Hermes install receipt (kind absent = upstream shape, or kind "update")
# AND post_update.short_sha differs from pre_update.short_sha. $1 = receipt snapshot path.
receipt_sha_advanced() {
    [ -n "${1:-}" ] && [ -f "$1" ] || { echo 0; return 0; }
    python3 - "$1" <<'PYEOF' 2>/dev/null || echo 0
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    kind = d.get("kind")
    if kind is not None and str(kind).strip().lower() != "update":
        print(0); raise SystemExit(0)
    pre = ((d.get("pre_update") or {}).get("short_sha") or "").strip()
    post = ((d.get("post_update") or {}).get("short_sha") or "").strip()
    print(1 if (pre and post and pre != post) else 0)
except Exception:
    print(0)
PYEOF
}

# Correlation state of a receipt snapshot vs this invocation's id. $1 = snapshot, $2 = our id.
#   match    — correlation_id equals ours: this invocation's receipt
#   legacy   — no correlation_id (old Hermes / fixtures): ownership UNPROVEN
#   mismatch — another invocation's id (receipt_outcome_fresh already reports it as stale)
receipt_corr_state() {
    python3 - "$1" "${2:-}" <<'PYEOF' 2>/dev/null || echo "unreadable"
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    want = sys.argv[2]
    got = d.get("correlation_id")
    if got is None or got == "":
        print("legacy")
    elif want and str(got) == want:
        print("match")
    else:
        print("mismatch")
except Exception:
    print("unreadable")
PYEOF
}

# 1 only when the ACTUAL checkout moved during this command and the receipt's SHAs describe
# that exact move: the observed before/after HEADs (full hex from read-only rev-parse) differ,
# and pre_update.short_sha / post_update.short_sha (>= 7 hex chars, distinct) prefix-match them.
# $1 = receipt snapshot, $2 = HEAD before --yes, $3 = HEAD after --yes.
receipt_checkout_agrees() {
    [ -n "${1:-}" ] && [ -f "$1" ] || { echo 0; return 0; }
    python3 - "$1" "${2:-}" "${3:-}" <<'PYEOF' 2>/dev/null || echo 0
import json, re, sys
HEX = re.compile(r"[0-9a-f]+")
def full(s):
    s = s.strip().lower()
    return s if len(s) in (40, 64) and HEX.fullmatch(s) else ""
def short(side):
    s = str((side or {}).get("short_sha") or "").strip().lower()
    return s if len(s) >= 7 and HEX.fullmatch(s) else ""
try:
    d = json.load(open(sys.argv[1]))
    kind = d.get("kind")
    if kind is not None and str(kind).strip().lower() != "update":
        print(0); raise SystemExit(0)
    before, after = full(sys.argv[2]), full(sys.argv[3])
    pre, post = short(d.get("pre_update")), short(d.get("post_update"))
    ok = bool(before and after and before != after and pre and post and pre != post
              and before.startswith(pre) and after.startswith(post))
    print(1 if ok else 0)
except Exception:
    print(0)
PYEOF
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
# Orphaned receipt snapshots (SIGKILL skips the EXIT trap). Safe here: only the lock holder
# ever creates them, and we now hold the lock.
find "$STATE_DIR" -maxdepth 1 -type f -name 'receipt_snap.*' -delete 2>/dev/null || true

# Bounded check: it fetches from origin while already holding the lock. A hung fetch would
# hold the flock forever and every later tick would skip with no alert.
AU_CHECK_TIMEOUT="${AU_CHECK_TIMEOUT:-300}"
CHECK_OUT=$(timeout -k "${AU_UPDATE_KILL:-60}" "$AU_CHECK_TIMEOUT" "$HERMES_BIN" update --check 2>&1)
CHECK_STATUS=$?

if [ $CHECK_STATUS -ne 0 ]; then
    # Fetch failures (429/5xx/network) exit 1 with "✗". They are transient: never install on them.
    log "check failed (exit $CHECK_STATUS): $(echo "$CHECK_OUT" | head -2 | tr '\n' ' ')"
    check_problem "failing (exit $CHECK_STATUS)"
    exit 0
fi
# Exit 0 is not enough on its own. Only a single, unambiguous line-start verdict counts.
# Stable verdicts and legacy main verdicts are both recognized. Anything else is
# INCONCLUSIVE: it alerts, and never silently stalls.
VERDICT=$(classify_verdicts "$CHECK_OUT")
case "$VERDICT" in
    uptodate|held)
        check_ok   # conclusive: nothing to install
        clear_rollback_remind
        if [ "$VERDICT" = held ]; then
            log "held (benign, no install): $(printf '%s\n' "$CHECK_OUT" | grep -m1 'Holding at this build' | head -c 300)"
        else
            log "up-to-date: $(echo "$CHECK_OUT" | tail -1)"
        fi
        recheck_drain_marker; DRAIN_RC=$?
        # D3: a healthy no-update tick is a SUCCESSFUL updater run. Reset the real-failure count
        # (after the drain recheck) so the next unrelated failure is not deduped by a stale count.
        reset_real_fails
        [ "$DRAIN_RC" -eq 0 ] || exit 1
        exit 0 ;;
    rollback)
        # The checkout is newer than the selected release. Moving it back is a manual decision:
        # never run --yes for this verdict, regardless of AU_APPLY. Not a check failure either.
        # Remind at a low frequency (AU_ROLLBACK_REMIND_SECS) for as long as the state holds; the
        # stamp is written only after delivery, so a dead channel retries on the next tick.
        check_ok
        log "⚠ checkout newer than selected release — rollback is manual, NOT applied: $(printf '%s\n' "$CHECK_OUT" | grep -m1 'newer than the selected release' | head -c 300)"
        if interval_due rollback_remind_ts "$AU_ROLLBACK_REMIND_SECS"; then
            if notify "→ hermes auto-update: this checkout is newer than the selected release — NOT moved back automatically (manual: run hermes update by hand, or hermes update --set-channel main). Reminder repeats every $((AU_ROLLBACK_REMIND_SECS / 3600))h while this holds."; then
                echo "$TICK_TS" > "$STATE_DIR/rollback_remind_ts"
                rm -f "$STATE_DIR/rollback_notified"
            else
                log "rollback reminder not delivered — retrying next tick"
            fi
        else
            log "rollback reminder suppressed (last $(fmt_ts "$(read_ts rollback_remind_ts)"), interval ${AU_ROLLBACK_REMIND_SECS}s)"
        fi
        recheck_drain_marker; DRAIN_RC=$?
        reset_real_fails
        [ "$DRAIN_RC" -eq 0 ] || exit 1
        exit 0 ;;
    available) ;;
    *)
        log "⚠ unrecognized --check output (wording changed upstream?): $(verdict_detail "$CHECK_OUT")"
        check_problem "output unrecognized/conflicting — update pipeline may be stalled"
        exit 0 ;;
esac

check_ok   # conclusive: an update really is available
clear_rollback_remind

log "update available: $(printf '%s\n' "$CHECK_OUT" | grep -m1 -E 'available' | head -c 300)"

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

# Bind the receipt to THIS invocation. A receipt that is byte-identical to the one on disk
# before --yes was not written by this run, whatever its finished_at says. Without this check,
# the 5s skew window admits a previous run's receipt.
receipt_digest() {  # $1 = file path; empty output = read error (callers fail closed)
    if [ -e "$1" ]; then sha256sum 2>/dev/null < "$1" | cut -d' ' -f1; else echo absent; fi
}
PRE_RECEIPT_DIGEST=$(receipt_digest "$RECEIPT")
# Upstream records HERMES_UPDATE_CORRELATION_ID as the receipt's correlation_id. When a
# receipt carries one, it must be ours.
AU_CORR_ID="au-$(date +%s%N)-$$-$RANDOM"
RUN_STARTED=$(date +%s)
# Observed checkout identity BEFORE this command (read-only). Paired with POST_HEAD after
# --yes, it is this run's own install evidence for receipts that carry no correlation_id.
PRE_HEAD=$(git -C "$REPO" rev-parse HEAD 2>/dev/null)
# Bounded install: upstream can legitimately block for restart_after_turn_timeout (1800s
# default) while draining, so the cap is 2x that. Without a cap a wedged updater holds the
# flock forever and every later tick skips silently — the stall guard below only counts
# check-phase failures, so nothing would ever alert.
AU_UPDATE_TIMEOUT="${AU_UPDATE_TIMEOUT:-3600}"
UPDATE_OUT=$(HERMES_UPDATE_CORRELATION_ID="$AU_CORR_ID" timeout -k "${AU_UPDATE_KILL:-60}" "$AU_UPDATE_TIMEOUT" "$HERMES_BIN" update --yes 2>&1)
STATUS=$?

# Immutable post-command receipt snapshot, taken FIRST. Every receipt-derived verdict below
# (outcome, kind, freshness, correlation, digest, SHA advance) reads THIS private copy only,
# never the shared latest.json again: a concurrent updater replacing latest.json after this
# point cannot swap the evidence out from under the binding checks. Private mktemp under
# STATE_DIR (mode 0600, unpredictable name), removed on exit. Any snapshot failure is fail
# closed: the receipt is treated as unreadable, i.e. no install evidence.
SNAP=""
SNAP_STATE=error
_au_snap_cleanup() { if [ -n "$SNAP" ]; then rm -f -- "$SNAP"; fi; }
trap '_au_snap_cleanup' EXIT
trap '_au_snap_cleanup; exit 129' HUP
trap '_au_snap_cleanup; exit 130' INT
trap '_au_snap_cleanup; exit 143' TERM
SNAP=$(mktemp "$STATE_DIR/receipt_snap.XXXXXX" 2>/dev/null) || SNAP=""
if [ -n "$SNAP" ] && [ -f "$SNAP" ] && [ ! -L "$SNAP" ]; then
    if [ ! -e "$RECEIPT" ] && [ ! -L "$RECEIPT" ]; then
        SNAP_STATE=absent
    elif cp -- "$RECEIPT" "$SNAP" 2>/dev/null; then
        SNAP_STATE=ok
    fi
fi
# Observed checkout identity AFTER this command (read-only), read right after the snapshot.
# If something moves HEAD after this point, the receipt's post SHA cannot match: fail closed.
POST_HEAD=$(git -C "$REPO" rev-parse HEAD 2>/dev/null)

log "update exit=$STATUS (cap ${AU_UPDATE_TIMEOUT}s)"
echo "$UPDATE_OUT" | tail -40 >> "$LOG"

# 124 = timeout expired, 137 = the -k SIGKILL fallback fired: the updater is WEDGED, not
# merely slow. Leave the drain marker set (so the next tick still re-verifies the gateway),
# alert at once, and exit non-zero. Deduped like other persistent failures.
if [ "$STATUS" = "124" ] || [ "$STATUS" = "137" ]; then
    log "REAL FAILURE: updater exceeded ${AU_UPDATE_TIMEOUT}s (exit=$STATUS) — wedged, not slow"
    touch "$STATE_DIR/drain_pending"
    real_fail_count
    real_fail_alert "✗ hermes auto-update: updater WEDGED (no completion within ${AU_UPDATE_TIMEOUT}s, exit=$STATUS) — install state unknown, check the host (updater v${UPDATER_VERSION})"
    exit 1
fi

# Receipt written by THIS run's updater (or the previous one if the marker raced).
# Classification order: receipt outcome first, exit code second — BUT only a receipt
# FINISHED after RUN_STARTED (captured before --yes) is trustworthy: a pull-stage
# failure (merge conflict, syntax guard, SIGKILL) exits before finalize, leaving the
# PREVIOUS run's success receipt on disk. Reading that stale 'success' would fake a
# success notify. Freshness-gate it.
case "$SNAP_STATE" in
    ok)
        OUTCOME=$(receipt_outcome_fresh "$SNAP" "$RUN_STARTED" "$AU_CORR_ID")
        SNAP_DIGEST=$(receipt_digest "$SNAP") ;;
    absent)
        OUTCOME=unreadable; SNAP_DIGEST=absent ;;
    *)
        log "⚠ receipt snapshot failed (mktemp/copy under $STATE_DIR) — receipt treated as unreadable, no install evidence (fail closed)"
        OUTCOME=unreadable; SNAP_DIGEST="" ;;
esac
# Unchanged bytes = not written by this invocation, even inside the 5s skew window.
# The SNAPSHOT's digest is compared with the original pre-run receipt bytes. An empty digest
# on either side (read error) cannot prove a new receipt, so it counts as unchanged.
if [ -z "$SNAP_DIGEST" ] || [ -z "$PRE_RECEIPT_DIGEST" ] || [ "$SNAP_DIGEST" = "$PRE_RECEIPT_DIGEST" ]; then
    case "$OUTCOME" in foreign|unreadable) ;; *) OUTCOME=unchanged ;; esac
fi
VERSION=$(parse_version "$UPDATE_OUT")
# Evidence is computed once, from THIS run's output and the SAME receipt snapshot only.
SHA_ADVANCED=0
case "$OUTCOME" in success|partial) SHA_ADVANCED=$(receipt_sha_advanced "$SNAP") ;; esac
HAS_COMPLETE=0
printf '%s\n' "$UPDATE_OUT" | grep -qE "$RE_COMPLETE" && HAS_COMPLETE=1
HAS_NOOP=0
printf '%s\n' "$UPDATE_OUT" | grep -qE "$RE_NOOP" && HAS_NOOP=1
# Receipt ownership. correlation_id == ours means this invocation's receipt (a foreign id was
# already "stale"). No correlation_id means legacy: freshness + changed bytes do NOT prove
# ownership (a concurrent updater can write such a receipt). It is install evidence only with
# independent affirmative evidence from THIS command: the anchored completion line, or the
# real checkout moving during the command with the receipt's pre/post SHAs agreeing with it.
# A no-op line never yields an install from a legacy receipt, whatever the receipt claims.
CORR_STATE=n/a
CHECKOUT_PROOF=0
case "$OUTCOME" in
    success|partial)
        CORR_STATE=$(receipt_corr_state "$SNAP" "$AU_CORR_ID")
        CHECKOUT_PROOF=$(receipt_checkout_agrees "$SNAP" "$PRE_HEAD" "$POST_HEAD")
        if [ "$CORR_STATE" = "match" ]; then
            :
        elif [ "$CORR_STATE" = "legacy" ] && [ "$HAS_NOOP" != 1 ] \
            && { [ "$HAS_COMPLETE" = 1 ] || { [ "$STATUS" = 0 ] && [ "$CHECKOUT_PROOF" = 1 ]; }; }; then
            # The receipt's own SHA claim counts only when the observed checkout agrees with it.
            SHA_ADVANCED=$CHECKOUT_PROOF
            log "legacy receipt (no correlation_id) accepted on this run's evidence: completion_line=$HAS_COMPLETE checkout ${PRE_HEAD:0:10}->${POST_HEAD:0:10} agrees=$CHECKOUT_PROOF"
        else
            log "⚠ receipt=$OUTCOME not owned by this run (correlation=$CORR_STATE, completion_line=$HAS_COMPLETE, noop_line=$HAS_NOOP, checkout_proof=$CHECKOUT_PROOF) — not install evidence"
            OUTCOME=uncorrelated
            SHA_ADVANCED=0
        fi ;;
esac

if [ "$STATUS" -eq 0 ]; then
    case "$OUTCOME" in stale|unchanged|foreign|unreadable|missing|uncorrelated) NO_RECEIPT=1 ;; *) NO_RECEIPT=0 ;; esac
    # A no-op verdict stays a no-op even if a bound success receipt exists, provided there is
    # no completion line and no SHA advance. Nothing was installed, so it must never reach
    # mark_installed.
    if [ "$OUTCOME" = "success" ] && [ "$HAS_NOOP" = 1 ] && [ "$HAS_COMPLETE" = 0 ] && [ "$SHA_ADVANCED" != 1 ]; then
        NO_RECEIPT=1
    fi
    if [ "$NO_RECEIPT" = "1" ]; then
        # exit 0, but this run finalized no Hermes install receipt. The receipt is one of:
        #   stale      — from an older run
        #   foreign    — written by plugin-check or similar
        #   unreadable — none on disk
        #   unchanged  — byte-identical to the receipt present before --yes
        #   uncorrelated — no correlation_id and no evidence from this command that it installed
        # Never reuse it as success. gateway_confirmed() is no proof either: HEAD equals the
        # running SHA even when nothing was installed.
        if printf '%s\n' "$UPDATE_OUT" | grep -qE "$RE_COMPLETE"; then
            # A real completion line with no receipt: possibly installed, but UNPROVEN.
            log "⚠ exit=0, update reported complete ${VERSION} but receipt=$OUTCOME — install UNPROVEN, drain_pending set"
            touch "$STATE_DIR/drain_pending"
            notify "⚠ hermes auto-update: updater reported completion${VERSION:+ to $VERSION} but wrote no fresh install receipt (receipt=$OUTCOME) — install unproven, verify the host (updater v${UPDATER_VERSION})"
            exit 1
        fi
        if printf '%s\n' "$UPDATE_OUT" | grep -qE "$RE_NOOP"; then
            # A no-op-shaped line alone never decides: the conclusion must be upstream's exact
            # --yes no-op sentence, and a ✗ line, an error / failed / timed out line, an
            # available / rollback verdict, a code-movement line, or any line claiming a
            # conclusion that is not a whole upstream sentence means the run is NOT a harmless
            # no-op. That is a REAL FAILURE (counted, alerted, exit 1, the streak is NOT reset).
            if VETO=$(yes_noop_veto "$UPDATE_OUT"); then
                real_failure_exit "no-op line vetoed ($VETO)"
            fi
            log "no-op: beaten by another updater between check and install / held / no newer release (exit=0, receipt=$OUTCOME): $(yes_noop_line "$UPDATE_OUT")"
            # No install happened, so never mark_installed here. A pending drain marker must
            # still be re-verified, exactly as on the check-time no-update path; then this
            # legitimate no-op ends any real-failure streak (same as the check-time no-op).
            recheck_drain_marker; DRAIN_RC=$?
            reset_real_fails
            [ "$DRAIN_RC" -eq 0 ] || exit 1
            exit 0
        fi
        log "⚠ exit=0, stale receipt, output unrecognized — treating as inconclusive"
        notify "⚠ hermes auto-update: exit=0 but no fresh receipt (raced?) — verify fleet manually"
        exit 1
    fi
    if [ "$OUTCOME" = "success" ] && [ "$HAS_COMPLETE" != 1 ] && [ "$SHA_ADVANCED" != 1 ]; then
        # A success receipt (even correlated) with no completion line and no SHA advance proves
        # nothing was installed. Never mark_installed or announce an update on it.
        log "⚠ exit=0, receipt=success but no completion line and no SHA advance (correlation=$CORR_STATE) — install UNPROVEN, drain_pending set"
        touch "$STATE_DIR/drain_pending"
        notify "⚠ hermes auto-update: updater exited 0 with a success receipt but no evidence of an install (no SHA change, no completion line) — verify the host (updater v${UPDATER_VERSION})"
        exit 1
    fi
    if [ "$OUTCOME" = "success" ]; then
        log "success $VERSION (receipt: success)"
        reset_real_fails
        mark_installed   # fresh, kind-checked success receipt owned by THIS run (correlated, or legacy + this run's own evidence) = proven install
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
    if [ "$OUTCOME" = "partial" ] && [ "$SHA_ADVANCED" != 1 ] && [ "$HAS_COMPLETE" != 1 ]; then
        # Legacy partial receipts may omit the SHAs. With no SHA advance AND no completion
        # line, a partial receipt proves nothing, and gateway health cannot fill the gap.
        log "⚠ exit=0, receipt=partial but no SHA advance and no completion line — install UNPROVEN, drain_pending set"
        touch "$STATE_DIR/drain_pending"
        notify "⚠ hermes auto-update: updater exited 0 with a partial receipt but no evidence of an install (no SHA change, no completion line) — verify the host (updater v${UPDATER_VERSION})"
        exit 1
    fi
    # Only "partial" with evidence may use gateway health. A failed, running, refused, or
    # unknown outcome is NOT an install, however healthy the existing gateway looks. Those
    # outcomes skip the poll and fall through to the REAL FAILURE path below.
    if [ "$OUTCOME" = "partial" ]; then
    # exit 0 and the receipt says partial (with evidence): install landed, restart may race.
    # Wait for the gateway to catch up before declaring anything.
    log "exit=0 but receipt outcome=$OUTCOME — waiting for gateway to restart"
    # Set the marker BEFORE waiting, not only after the wait times out: if this script is
    # killed mid-poll (a terminal timeout, the very restart it just triggered, a reboot)
    # the install stays flagged and the next no-update tick consumes it. Marker-on-timeout
    # only is invisible to precisely the interruption it exists to survive.
    touch "$STATE_DIR/drain_pending"
    # Install is proven here (accepted partial receipt + SHA/completion evidence gate above);
    # gateway health is separate, so record the install once now, before polling can time out.
    mark_installed
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
        clear_drain_marker
        notify "✓ hermes agent updated to ${VERSION:-unknown} — gateway restarted (updater v${UPDATER_VERSION})"
        exit 0
    fi
    # Drain can legitimately take up to 30 min (restart_after_turn_timeout) — our 3 min
    # window is only a fast-path confirmation. Timing out is NOT evidence of failure.
    # The next tick only re-verifies because recheck_drain_marker() runs on the no-update
    # path; a dead gateway keeps the marker and re-alerts on the 1st/3rd/6th tick.
    touch "$STATE_DIR/drain_pending"
    log "⚠ install ok, gateway not confirmed within 3 min (still draining?) — drain_pending set, next tick re-verifies"
    notify "⚠ hermes auto-update: installed $VERSION, gateway restart still draining (no failure) — re-check next tick"
    exit 0
    fi
    # Reaching here means exit 0 with outcome failed/running/refused/unknown. The success/partial
    # race block below does not match, so this falls through to REAL FAILURE.
fi

# Nonzero exit: could be a real failure OR the STALE race (update complete, restart
# still draining when the fleet check ran — exit 1, receipt outcome=partial/pending).
# Only a FRESH receipt is evidence about this run ("stale" = pre-run data, ignore it).
if [ "$OUTCOME" = "success" ] || [ "$OUTCOME" = "partial" ]; then
    # Install demonstrably landed. Primary evidence = the receipt's MACHINE fields:
    # post_update.short_sha advanced past pre_update.short_sha proves code landed.
    # Text ("Update complete") is only a fallback when the SHAs are unavailable —
    # never the primary signal (upstream rewords banners; machine fields don't drift).
    # SHA_ADVANCED comes from the SAME snapshot as OUTCOME (no reread of latest.json). The
    # text fallback is the line-anchored RE_COMPLETE (HAS_COMPLETE), never a substring match.
    if [ "$SHA_ADVANCED" = "1" ] || [ "$HAS_COMPLETE" = "1" ]; then
        log "success $VERSION (exit=$STATUS but receipt=$OUTCOME, code landed per SHA advance/text — restart race, not failure)"
        reset_real_fails
        if [ "$SHA_ADVANCED" = "1" ] || [ "$HAS_COMPLETE" = "1" ]; then mark_installed; fi
        # DO NOT clear the drain marker here: the race means the gateway was NOT
        # confirmed current — the receipt froze stale. Keep/refresh the marker so the
        # next no-update tick re-verifies (recheck_drain_marker); erasing it here
        # reproduced Nova's Defect-2 class in this branch (gateway dies → silence).
        touch "$STATE_DIR/drain_pending"
        notify "✓ hermes agent updated to ${VERSION:-unknown} (exit=$STATUS race; fleet catches up on next restart) (updater v${UPDATER_VERSION})"
        exit 0
    fi
fi

# Real failure. First failure of a streak alerts at once; a persisting failure re-alerts by wall
# clock every AU_REALERT_SECS (default ~3 days) — a tick count here (the old "every 12th") meant
# every 12 DAYS on the daily schedule. See real_fail_alert().
real_failure_exit

