#!/bin/bash
# Scenario matrix for the auto_update.sh harness. Prints what each scenario did next to
# what it MUST do; every line is checkable by eye. No real hermes, gateway or Telegram.
#
# Usage:  bash stub_matrix.sh          (after stub_setup.sh, uses HARNESS_ROOT)
set -u
ROOT="${HARNESS_ROOT:-/tmp/au-harness}"
AU="$ROOT/au.sh"
test -x "$AU" || { echo "run stub_setup.sh first" >&2; exit 1; }
ST="$ROOT/home/.hermes/state/auto_update"
LG="$ROOT/home/.hermes/logs/auto_update.log"
PASS=0; FAIL=0

reset_home() {
  rm -rf "$ROOT/home"
  mkdir -p "$ROOT/home/.hermes/logs/update_receipts" "$ROOT/home/.hermes/state/auto_update"
  printf 'TELEGRAM_BOT_TOKEN=123:FAKE\nTELEGRAM_ALLOWED_USERS=999\nTELEGRAM_PROXY=http://127.0.0.1:1\n' > "$ROOT/home/.hermes/.env"
  # the health predicate reads gateway_state.json: designs that resolve it through $HOME
  # need it inside the fake home; designs with a hardcoded path use the real one and ignore this
  printf '{"code_sha":"%s"}\n' "$(git -C "$ROOT/repo" rev-parse HEAD)" > "$ROOT/home/.hermes/gateway_state.json"
  rm -f "$ROOT/notify.calls" "$ROOT/curl_fail" "$ROOT/gw_down" "$ROOT/gw_flip_after" "$ROOT/gw_calls"
}
# Every scenario goes through these, and they ALWAYS pass the poll knobs.
# Default-fast, opt-in-slow: any implementation that runs a catch-up poll on more paths
# than you remembered (e.g. after a restart race) would otherwise sit in its default
# window — 20 minutes in one design — and the matrix would look "hung" instead of failing.
run() { HOME=$ROOT/home PATH=$ROOT/bin:/usr/bin:/bin AU_APPLY="${AU_APPLY:-1}" AU_POLL_EVERY="${AU_POLL_EVERY:-0}" AU_POLL_TRIES="${AU_POLL_TRIES:-1}" AU_SETTLE_SECONDS="${AU_SETTLE_SECONDS:-0}" bash "$AU" >/dev/null 2>&1; echo -n "$?"; }
runenv() { HOME=$ROOT/home PATH=$ROOT/bin:/usr/bin:/bin AU_APPLY="${AU_APPLY:-1}" AU_POLL_EVERY="${1:-0}" AU_POLL_TRIES="${2:-2}" AU_SETTLE_SECONDS="${AU_SETTLE_SECONDS:-0}" bash "$AU" >/dev/null 2>&1; echo -n "$?"; }
notifies() { [ -f "$ROOT/notify.calls" ] && wc -l < "$ROOT/notify.calls" || echo 0; }
counter() { cat "$ST/$1" 2>/dev/null || echo 0; }
# different builds name the same counter differently (consec_real_fails vs consec_update_fails)
counter_any() { local f; for f in "$@"; do [ -f "$ST/$f" ] && { cat "$ST/$f"; return; }; done; echo 0; }
check() { # $1 label  $2 expected  $3 actual
  if [ "$2" = "$3" ]; then echo "   PASS  $1: $3"; PASS=$((PASS+1));
  else echo "   FAIL  $1: expected [$2], got [$3]"; FAIL=$((FAIL+1)); fi
}
check_le() { # $1 label  $2 max  $3 actual
  if [ "$3" -le "$2" ] 2>/dev/null; then echo "   PASS  $1: $3 (<= $2)"; PASS=$((PASS+1));
  else echo "   FAIL  $1: expected <= $2, got [$3]"; FAIL=$((FAIL+1)); fi
}

echo "S1  up-to-date -> silent, exit 0"
reset_home; echo uptodate > "$ROOT/mode"
check "exit"   0 "$(run)"
check "notify" 0 "$(notifies)"

echo "S2  update available + exit0 + fresh success receipt -> one checkmark, marker consumed"
reset_home; echo ok > "$ROOT/mode"
check "exit"   0 "$(run)"
check "notify" 1 "$(notifies)"
# R3: C2's fix must CONSUME the marker on a healthy success (in-line recheck), not leave it.
check "marker consumed on healthy success" absent "$([ -f "$ST/drain_pending" ] && echo PRESENT || echo absent)"

echo "S3  exit1 + fresh partial + 'Update complete' (restart race) -> checkmark, not failure"
reset_home; echo race > "$ROOT/mode"
check "exit"   0 "$(run)"
check "notify" 1 "$(notifies)"

echo "S4  pull-stage failure with a STALE success receipt, x3 -> alert on the 1st, then deduped"
echo "      (the invariant is 'not one alert per tick'; the exact cadence is 1+12th"
echo "       here, so 3 ticks give 1 alert - a 1+3rd cadence gives 2)"
reset_home; echo fail > "$ROOT/mode"
python3 -c "import json;json.dump({'finished_at':'2026-09-01T00:00:00+00:00','outcome':'success'},open('$ROOT/home/.hermes/logs/update_receipts/latest.json','w'))"
for _ in 1 2 3; do run >/dev/null; done
check "real-failure counter" 3 "$(counter_any consec_real_fails consec_update_fails)"
check_le "alerts (deduped)" 2 "$(notifies)"

echo "S5  *** stall guard *** unrecognized --check output x4 -> counter must accumulate, alert on the 3rd"
echo "      (v4 as shipped: counter stuck at 1, zero alerts = the guard is dead code)"
reset_home; echo weird > "$ROOT/mode"
for _ in 1 2 3 4; do run >/dev/null; done
check "check_fails counter" 4 "$(counter consec_check_fails)"
check "alerts"              1 "$(notifies)"

echo "S6  check failing x3 -> alert only on the 3rd"
reset_home; echo checkfail > "$ROOT/mode"
for _ in 1 2 3; do run >/dev/null; done
check "check_fails counter" 3 "$(counter consec_check_fails)"
check "alerts"              1 "$(notifies)"

echo "S7  bare env (env -i) -> must still run"
reset_home; echo uptodate > "$ROOT/mode"
env -i PATH=$ROOT/bin:/usr/bin:/bin HOME=$ROOT/home AU_APPLY=1 bash "$AU" >/dev/null 2>&1
check "exit" 0 "$?"

echo "S8  Telegram creds removed -> must leave a trace (logged and/or counted), never silent"
reset_home; echo ok > "$ROOT/mode"
printf 'TELEGRAM_ALLOWED_USERS=999\n' > "$ROOT/home/.hermes/.env"
run >/dev/null
check "creds loss leaves a trace" yes "$(grep -qE 'creds missing|notify skipped|pruned' "$LG" && echo yes || echo no)"

echo "S9  code landed but gateway never healthy -> neutral exit 0 + drain_pending marker"
echo "      (partial receipt, so the implementation cannot short-circuit on a success receipt)"
AU9="$AU"
if grep -q 'for _ in 1 2 3 4 5 6; do' "$AU"; then
  sed -e 's/for _ in 1 2 3 4 5 6; do/for _ in 1 2; do/' -e 's/^ *sleep 30 *$/        sleep 0/' "$AU" > "$ROOT/au_fast.sh"
  chmod +x "$ROOT/au_fast.sh"; AU9="$ROOT/au_fast.sh"
  echo "      (this build has no poll knob: exercising the timeout branch on a copy with"
  echo "       the loop shortened 6x30s -> 2x0s; that is a test-only transformation)"
fi
reset_home; echo partial0 > "$ROOT/mode"; touch "$ROOT/gw_down"
HOME=$ROOT/home PATH=$ROOT/bin:/usr/bin:/bin AU_POLL_EVERY=0 AU_POLL_TRIES=2 AU_APPLY=1 bash "$AU9" >/dev/null 2>&1
check "exit" 0 "$?"
check "marker" PRESENT "$([ -f "$ST/drain_pending" ] && echo PRESENT || echo absent)"

echo "S10 *** drain marker IS re-verified on the otherwise-silent no-update tick ***"
echo uptodate > "$ROOT/mode"; rm -f "$ROOT/notify.calls"
for _ in 1 2 3; do run >/dev/null; done
check "drain counter" 3 "$(counter consec_drain_pending)"
check "alerts (1st + 3rd)" 2 "$(notifies)"
check "marker kept while unhealthy" PRESENT "$([ -f "$ST/drain_pending" ] && echo PRESENT || echo absent)"

echo "S11 gateway recovers -> marker cleared, silent"
rm -f "$ROOT/gw_down" "$ROOT/notify.calls"
check "exit" 0 "$(run)"
check "marker" absent "$([ -f "$ST/drain_pending" ] && echo PRESENT || echo absent)"
check "alerts" 0 "$(notifies)"

echo "S12 *** interrupted mid-poll -> the flag must survive the interruption ***"
echo "      (kills the script while it waits for the gateway; a marker written only ON"
echo "       timeout is invisible here - which is exactly the case it exists for)"
reset_home; echo partial0 > "$ROOT/mode"; touch "$ROOT/gw_down"
timeout -s KILL 8 env HOME="$ROOT/home" PATH="$ROOT/bin:/usr/bin:/bin" \
        AU_POLL_EVERY=5 AU_POLL_TRIES=40 AU_APPLY=1 bash "$AU" >/dev/null 2>&1
check "marker survives an interrupted poll" PRESENT "$([ -f "$ST/drain_pending" ] && echo PRESENT || echo absent)"

echo "S13 *** the exit!=0 restart-race branch must LEAVE the marker set ***"
echo "      (that branch means the gateway was NOT confirmed current - the receipt froze"
echo "       stale. Clearing the marker there erases the re-verify hook, i.e. the same"
echo "       'silent forever' class the marker exists to prevent.)"
echo "      (poll knobs are passed: an implementation that polls after EVERY landed install"
echo "       would otherwise sit in its default window here)"
reset_home; echo race > "$ROOT/mode"; touch "$ROOT/gw_down"
HOME="$ROOT/home" PATH="$ROOT/bin:/usr/bin:/bin" AU_POLL_EVERY=0 AU_POLL_TRIES=1 AU_APPLY=1 bash "$AU" >/dev/null 2>&1
check "marker set by the race branch" PRESENT "$([ -f "$ST/drain_pending" ] && echo PRESENT || echo absent)"
rm -f "$ROOT/notify.calls"; echo uptodate > "$ROOT/mode"
run >/dev/null
check "next tick re-verifies (exactly 1 alert)" 1 "$(notifies)"

echo "S14 *** the common real path: gateway comes back DURING the catch-up poll ***"
echo "      (inactive for the first 2 polls then active -> must report success and CLEAR the"
echo "       marker, i.e. the in-run catch-up; not the neutral-drain branch, and not a"
echo "       marker left behind for the next tick)"
reset_home; echo partial0 > "$ROOT/mode"; echo 2 > "$ROOT/gw_flip_after"; rm -f "$ROOT/notify.calls"
HOME="$ROOT/home" PATH="$ROOT/bin:/usr/bin:/bin" AU_POLL_EVERY=1 AU_POLL_TRIES=6 AU_APPLY=1 bash "$AU" >/dev/null 2>&1
check "exit" 0 "$?"
check "marker cleared after the in-run catch-up" absent "$([ -f "$ST/drain_pending" ] && echo PRESENT || echo absent)"
check "alerts (one success)" 1 "$(notifies)"

echo "S15 *** hermes binary missing -> must alert and exit 1 (install broken) ***"
reset_home
sed 's#^\(for cand in\).*#for cand in /nonexistent/hermes; do#' "$AU" > "$ROOT/au_nobin.sh"
rm -f "$ROOT/notify.calls"
PATH="$ROOT/bin:/usr/bin:/bin" HOME="$ROOT/home" bash "$ROOT/au_nobin.sh" >/dev/null 2>&1
check "exit" 1 "$?"
check "alerts" 1 "$(notifies)"

echo "S16 *** exit0 + stale receipt + unrecognized output -> inconclusive, alert + exit 1 ***"
reset_home; echo weirdyes > "$ROOT/mode"
python3 -c "import json;json.dump({'finished_at':'2026-09-01T00:00:00+00:00','outcome':'success'},open('$ROOT/home/.hermes/logs/update_receipts/latest.json','w'))"
rm -f "$ROOT/notify.calls"
HOME="$ROOT/home" PATH="$ROOT/bin:/usr/bin:/bin" AU_POLL_EVERY=0 AU_POLL_TRIES=1 AU_APPLY=1 bash "$AU" >/dev/null 2>&1
check "exit" 1 "$?"
check "alerts" 1 "$(notifies)"

echo "S17 *** notify delivery fails (proxy/curl down) -> counted + logged, not swallowed ***"
reset_home; echo ok > "$ROOT/mode"; touch "$ROOT/curl_fail"
rm -f "$ROOT/notify.calls"
HOME="$ROOT/home" PATH="$ROOT/bin:/usr/bin:/bin" AU_POLL_EVERY=0 AU_POLL_TRIES=1 AU_APPLY=1 bash "$AU" >/dev/null 2>&1
check "exit" 0 "$?"
check "notify-failure counter" 1 "$(counter consec_notify_fails)"
check "delivery failure logged" yes "$(grep -qE 'notify delivery failed|delivery failed' "$LG" && echo yes || echo no)"

echo "S18 *** SHA discriminator (positive): pre!=post + NO text marker -> success ***"
echo "      (neuter the SHA branch to a constant 0 and this must FAIL)"
reset_home; echo race_sha > "$ROOT/mode"
check "exit"   0 "$(run)"
check "notify" 1 "$(notifies)"

echo "S19 *** SHA discriminator (negative): pre==post + NO text marker -> real failure ***"
echo "      (the code did NOT land: must not be reported as a race success)"
reset_home; echo race_same > "$ROOT/mode"
check "exit"   1 "$(run)"
check "alerts" 1 "$(notifies)"

echo "S20 *** D1: a fresh success receipt must NOT confirm the gateway while it is down ***"
echo "      (the poll must require sha+is-active, not just a receipt)"
reset_home; echo partial0 > "$ROOT/mode"; touch "$ROOT/gw_down"
HOME=$ROOT/home PATH=$ROOT/bin:/usr/bin:/bin AU_APPLY=1 AU_POLL_EVERY=0 AU_POLL_TRIES=2 AU_SETTLE_SECONDS=0 bash "$AU" >/dev/null 2>&1
python3 -c "
import json,datetime
json.dump({'schema':1,'outcome':'success','finished_at':datetime.datetime.now(datetime.timezone.utc).isoformat()},
          open('$ROOT/home/.hermes/logs/update_receipts/latest.json','w'))"
echo uptodate > "$ROOT/mode"; rm -f "$ROOT/notify.calls"
HOME=$ROOT/home PATH=$ROOT/bin:/usr/bin:/bin AU_APPLY=1 AU_SETTLE_SECONDS=0 bash "$AU" >/dev/null 2>&1
check "marker survives receipt-fresh-but-gateway-dead" PRESENT "$([ -f "$ST/drain_pending" ] && echo PRESENT || echo absent)"

echo "S21 *** D2: Telegram 200 + ok:false is NOT delivery ***"
reset_home; echo ok > "$ROOT/mode"; touch "$ROOT/tg_reject"
run >/dev/null
check "notify-failure counter increments on ok:false" 1 "$(counter consec_notify_fails)"
check "rejection logged" yes "$(grep -q 'rejected by API' "$ROOT/home/.hermes/logs/auto_update.log" && echo yes || echo no)"
rm -f "$ROOT/tg_reject"

echo "S22 *** D3: a healthy no-update tick resets the real-failure counter ***"
reset_home; echo fail > "$ROOT/mode"; run >/dev/null
FIRST=$(counter consec_real_fails)
echo uptodate > "$ROOT/mode"; run >/dev/null
check "real-fail counter reset by a no-update tick" 0 "$(counter consec_real_fails)"
check "the failure was counted before the reset" 1 "$FIRST"

echo "S23 *** apply gate: without AU_APPLY=1 a would-be update must NOT install ***"
echo "      (running the script must never be equivalent to mutating the host)"
reset_home; echo ok > "$ROOT/mode"; rm -f "$ROOT/notify.calls"
HOME=$ROOT/home PATH=$ROOT/bin:/usr/bin:/bin AU_APPLY=0 AU_SETTLE_SECONDS=0 bash "$AU" >/dev/null 2>&1
check "apply gate exit" 0 "$?"
check "no install happened (no receipt written)" absent "$([ -f "$ROOT/home/.hermes/logs/update_receipts/latest.json" ] && echo PRESENT || echo absent)"
check "gate logged" yes "$(grep -q 'NOT applied' "$ROOT/home/.hermes/logs/auto_update.log" && echo yes || echo no)"

echo "S24 *** artifacts that TELL someone how to schedule must require AU_APPLY=1 ***"
echo "      (a schedule without it never updates — the silent twin of the apply gate)"
BUNDLE="$(cat "$ROOT/bundle_dir" 2>/dev/null || echo "")"
for art in install.sh crontab.txt README.md; do
  if [ -f "$BUNDLE/$art" ]; then
    check "$art mentions AU_APPLY" yes "$(grep -q 'AU_APPLY' "$BUNDLE/$art" && echo yes || echo no)"
  else
    check "$art present" yes "no"
  fi
done

echo "S24b *** the recommended schedule must DELIVER AU_APPLY, not merely mention it ***"
echo "      (a flag prefixed to the sourced env file binds to the source builtin and is"
echo "       NEVER exported to the child script on any shell -> silent never-update)"
# Probe: a stand-in for the updater that reports whether it inherited AU_APPLY.
PROBE="$ROOT/stub/applyprobe"
printf '#!/bin/sh\nprintf "%%s" "${AU_APPLY-UNSET}" > "%s/applyseen"\n' "$ROOT" > "$PROBE"
chmod +x "$PROBE"
# Build the shape install.sh recommends, substituting real paths for its $ENV_FILE/$DEST.
LINE="$(grep -o 'CRON_LINE="[^"]*"' "$BUNDLE/install.sh" 2>/dev/null | head -1 | sed 's/^CRON_LINE="//; s/"$//')"
if [ -z "$LINE" ]; then
    check "install.sh defines CRON_LINE" yes "absent-line"
else
    : > "$ROOT/stub/probe.env"
    # drop the "MM HH * * * " schedule fields; point env/dest at our stand-ins
    SHAPE="${LINE#*\* * * * }"
    SHAPE="${SHAPE//\$ENV_FILE/$ROOT/stub/probe.env}"
    SHAPE="${SHAPE//\$DEST/$PROBE}"
    # drop the literal output redirection tail, then any stray > or /dev/null
    SHAPE="${SHAPE%% >\/dev\/null 2>&1}"
    SHAPE="${SHAPE//>/ }"
    SHAPE="${SHAPE//\/dev\/null/}"
    for sh1 in bash dash; do
        command -v "$sh1" >/dev/null 2>&1 || continue
        rm -f "$ROOT/applyseen"
        timeout 10 "$sh1" -c "$SHAPE" >/dev/null 2>&1
        check "$sh1 delivers AU_APPLY to the script" 1 "$(cat "$ROOT/applyseen" 2>/dev/null || echo none)"
    done
fi

echo
echo "S25 *** a WEDGED updater must be bounded and loud, not a silent forever-skip ***"
echo "      (unbounded update --yes holds the flock: every later tick skips with no alert)"
reset_home; echo wedged > "$ROOT/mode"; rm -f "$ROOT/notify.calls"
t0=$(date +%s)
timeout 60 env HOME="$ROOT/home" PATH="$ROOT/bin:/usr/bin:/bin" \
    AU_APPLY=1 AU_UPDATE_TIMEOUT=1 AU_UPDATE_KILL=2 AU_SETTLE_SECONDS=0 \
    bash "$AU" >/dev/null 2>&1
rc=$?
t1=$(date +%s)
check "wedged updater exit=1 (REAL FAILURE)" 1 "$rc"
check "returned within the test guard (<60s)" yes "$( [ $(( t1 - t0 )) -lt 60 ] && echo yes || echo no )"
check "logged the wedge (not a silent skip)" yes "$(grep -q 'WEDGED\|exceeded' "$ROOT/home/.hermes/logs/auto_update.log" && echo yes || echo no)"
check "alerted on the wedged updater" yes "$(grep -q 'WEDGED' "$ROOT/notify.calls" 2>/dev/null && echo yes || echo no)"
check "drain marker left set (next tick re-verifies)" PRESENT "$([ -f "$ROOT/home/.hermes/state/auto_update/drain_pending" ] && echo PRESENT || echo absent)"

echo "S26 *** a WEDGED --check must be bounded too (it fetches while holding the lock) ***"
reset_home; echo checkwedge > "$ROOT/mode"; rm -f "$ROOT/notify.calls"
t0=$(date +%s)
timeout 60 env HOME="$ROOT/home" PATH="$ROOT/bin:/usr/bin:/bin" \
    AU_APPLY=1 AU_CHECK_TIMEOUT=1 AU_UPDATE_KILL=2 AU_SETTLE_SECONDS=0 \
    bash "$AU" >/dev/null 2>&1
rc=$?
t1=$(date +%s)
check "wedged check returns promptly" yes "$( [ $(( t1 - t0 )) -lt 60 ] && echo yes || echo no )"
check "wedged check counted as a check failure (exit 0, transient)" 0 "$rc"
check "wedged check logged" yes "$(grep -q 'check failed' "$ROOT/home/.hermes/logs/auto_update.log" && echo yes || echo no)"
check "no install attempted after a failed check" absent "$([ -f "$ROOT/home/.hermes/logs/update_receipts/latest.json" ] && echo PRESENT || echo absent)"

echo "==== $PASS passed, $FAIL failed ===="
[ "$FAIL" -eq 0 ] || { echo "log tail:"; tail -5 "$LG"; }
exit $((FAIL > 0))
