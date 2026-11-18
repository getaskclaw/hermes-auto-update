#!/bin/bash
# Fault-injection probe: prove the updater survives corrupted counter files.
# Usage: bash counter_sanity.sh /path/to/auto_update.sh
#
# The probe must drive a path that actually READS a counter, or it proves nothing:
# the up-to-date path WRITES consec_check_fails without reading it, so a tick in that
# mode passes even with the sanitizer removed (verified — an earlier version of this
# probe had no teeth). The check-failure path reads consec_check_fails; a missing-token
# notify exercises consec_notify_fails.
#
# Two failure classes are covered, because they are indistinguishable at the exit code:
#   (a) non-numeric garbage  -> arithmetic on garbage under `set -u`
#   (b) a LONG all-digit value that overflows SILENTLY ($((10#...)) wraps to a small or
#       NEGATIVE value, rc=0, no stderr) — a clamp applied AFTER the arithmetic misses it
#       entirely. Assertion: a long value must land on 1, never on a negative number.
set -u
SRC="${1:?usage: bash counter_sanity.sh /path/to/auto_update.sh}"
ROOT="${HARNESS_ROOT:-/tmp/au-harness}"
HERE="$(cd "$(dirname "$0")" && pwd)"
bash "$HERE/../verify/stub_setup.sh" "$SRC" >/dev/null || exit 1
ST="$ROOT/home/.hermes/state/auto_update"
mkdir -p "$ST" || exit 1
fail=0

# AU_APPLY=1 is REQUIRED: since v5.9 the updater is report-only without it, so the probe would
# drive a no-op tick and report a false "counter not sanitized" (nothing was ever written).
echo uptodate > "$ROOT/mode"
HOME="$ROOT/home" PATH="$ROOT/bin:/usr/bin:/bin" AU_APPLY=1 bash "$ROOT/au.sh" >/dev/null 2>&1   # warm-up
# SHORT garbage on purpose. With the length clamp running BEFORE the arithmetic, a long garbage
# string (>6 chars) is zeroed by the clamp and never reaches $((10#...)) — so a clamp-first build
# would hide a removed sanitizer and this probe would go toothless. A short non-numeric value
# ('x!') passes the length clamp, so it still reaches the arithmetic and still aborts a build
# with `tr -cd '0-9'` removed. Verified by the gate's teeth step.
for f in consec_check_fails consec_notify_fails consec_real_fails consec_drain_pending; do
  printf 'x!' > "$ST/$f"
done
echo checkfail > "$ROOT/mode"
ERR="$ROOT/cs_check.err"   # inside the harness root, not a fixed /tmp path
HOME="$ROOT/home" PATH="$ROOT/bin:/usr/bin:/bin" AU_APPLY=1 bash "$ROOT/au.sh" >/dev/null 2>"$ERR"
rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL: updater exited $rc on corrupted counters (check-failure path)"; fail=1; }
v=$(cat "$ST/consec_check_fails" 2>/dev/null)
case "$v" in ''|*[!0-9]*) echo "FAIL: consec_check_fails = [$v] (not sanitized)"; fail=1 ;; esac
# Teeth (stderr dimension): a numeric END value is indistinguishable between sanitized and
# unsanitized reads — bash replaces a failed $((10#...)) with 1, which is also numeric. The
# only observable that separates them is the arithmetic error escaping to stderr. A build
# with the sanitizer removed MUST trip this; the sanitized build must be silent (0 bytes).
if grep -q 'value too great for base' "$ERR" 2>/dev/null; then
  echo "FAIL: arithmetic error escaped to stderr — sanitizer not effective on this path"; fail=1
fi

# (b) LENGTH-OVERFLOW: a 20-digit all-digit value. The clean read is exactly 1 (the length clamp
# zeroes it, then the check-failure path increments). A clamp placed AFTER the arithmetic yields
# 4 or -4 with no stderr — invisible to the assertion above, which is why this case exists and
# why it asserts the exact value rather than a bound (4 also satisfies "<= 6").
printf '18446744073709551619' > "$ST/consec_check_fails"
HOME="$ROOT/home" PATH="$ROOT/bin:/usr/bin:/bin" AU_APPLY=1 bash "$ROOT/au.sh" >/dev/null 2>&1
v=$(cat "$ST/consec_check_fails" 2>/dev/null)
[ "$v" = "1" ] || { echo "FAIL: overflowing counter -> [$v], expected 1 (clamp must run BEFORE the arithmetic)"; fail=1; }

printf 'garbage!!' > "$ST/consec_notify_fails"
printf 'TELEGRAM_ALLOWED_USERS=9\n' > "$ROOT/home/.hermes/.env"   # no token -> notify path
echo ok > "$ROOT/mode"
HOME="$ROOT/home" PATH="$ROOT/bin:/usr/bin:/bin" AU_APPLY=1 bash "$ROOT/au.sh" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL: updater exited $rc on corrupted notify counter"; fail=1; }
v=$(cat "$ST/consec_notify_fails" 2>/dev/null)
case "$v" in ''|*[!0-9]*) echo "FAIL: consec_notify_fails = [$v] (not sanitized)"; fail=1 ;; esac

# (c) TIMESTAMP state files (v5.15, issue #1). Re-alert stamps and last_install_ok are read by
# read_epoch(). A bad stamp must neither abort the script nor SUPPRESS the alert it gates —
# the failure mode of a time-based throttle is silence, so every case asserts the alert WENT
# OUT. Each pair drives the branch that actually READS that stamp (same rule as above):
#   checkfail    + streak 5 -> check_alert reads check_last_alert AND last_install_ok
#   fail         (stale rcpt)-> real_fail_alert reads real_last_alert
#   stable_ahead            -> the ahead reminder reads ahead_last_alert
#   ok + curl_fail + 5 prior notify failures -> the dead-channel re-alert reads notify_last_alert
#                              (its "alert" is the local dead-letter line)
# Cases: short garbage (reaches the arithmetic), empty, 20-digit overflow, a FUTURE stamp
# (now+10d: would hold the alert back for 10 days), whitespace-padded digits.
printf 'TELEGRAM_BOT_TOKEN=1:F\nTELEGRAM_ALLOWED_USERS=9\n' > "$ROOT/home/.hermes/.env"
tick() { HOME="$ROOT/home" PATH="$ROOT/bin:/usr/bin:/bin" AU_APPLY=1 AU_SETTLE_SECONDS=0 \
         AU_POLL_EVERY=0 AU_POLL_TRIES=1 "$@" bash "$ROOT/au.sh" >/dev/null 2>"$ERR"; }
stderr_clean() { ! grep -qE 'syntax error|integer expression|value too great|unbound variable|invalid arithmetic|operand expected' "$ERR"; }
FUTURE=$(( $(date +%s) + 864000 ))
for pair in checkfail:check_last_alert fail:real_last_alert stable_ahead:ahead_last_alert ok:notify_last_alert; do
  mode=${pair%%:*}; stamp=${pair#*:}
  for val in 'x!' '' '18446744073709551619' "$FUTURE" ' 12 34 '; do
    rm -f "$ROOT/notify.calls" "$ROOT/curl_fail" "$ST/notify_dead_letter.log" \
          "$ST/check_last_alert" "$ST/real_last_alert" "$ST/ahead_last_alert" "$ST/notify_last_alert"
    rm -f "$ROOT/home/.hermes/logs/update_receipts/latest.json"
    # An earlier install tick leaves drain_pending set (this probe has no gateway fixture), and
    # the no-install branches correctly exit 1 while it cannot be verified — not our subject.
    rm -f "$ST/drain_pending"
    echo "$mode" > "$ROOT/mode"
    printf '%s' "$val" > "$ST/$stamp"
    printf '%s' "$val" > "$ST/last_install_ok"
    case "$mode" in
      checkfail) echo 5 > "$ST/consec_check_fails" ;;
      fail) python3 -c "import json;json.dump({'finished_at':'2026-09-01T00:00:00+00:00','outcome':'success'},open('$ROOT/home/.hermes/logs/update_receipts/latest.json','w'))" ;;
      ok) touch "$ROOT/curl_fail"; echo 5 > "$ST/consec_notify_fails" ;;
    esac
    tick; rc=$?
    want_rc=0; [ "$mode" = fail ] && want_rc=1
    [ "$rc" -eq "$want_rc" ] || { echo "FAIL: $stamp=[$val] ($mode): exit $rc, expected $want_rc"; fail=1; }
    stderr_clean || { echo "FAIL: $stamp=[$val] ($mode): arithmetic/test error escaped to stderr: $(head -2 "$ERR" | tr '\n' ' ')"; fail=1; }
    if [ "$mode" = ok ]; then
      [ -s "$ST/notify_dead_letter.log" ] || { echo "FAIL: $stamp=[$val]: corrupt stamp suppressed the dead-channel re-alert"; fail=1; }
    else
      [ -s "$ROOT/notify.calls" ] || { echo "FAIL: $stamp=[$val] ($mode): corrupt stamp suppressed the alert"; fail=1; }
    fi
  done
done
rm -f "$ROOT/curl_fail"

# (d) Re-alert interval KNOBS from the environment: garbage must fall back to the DEFAULT
# (3 days / 7 days), never abort and never become 0 (= page every tick). Probe: with a stamp
# written 1 hour ago, a sane default suppresses the alert; an alert here means the knob
# collapsed to ~0. With no stamp, the alert must still go out.
echo checkfail > "$ROOT/mode"
for knob in 'abc' '-5' '99999999999999999999' '' '1e3'; do
  echo 5 > "$ST/consec_check_fails"; rm -f "$ROOT/notify.calls" "$ST/check_last_alert"
  tick env AU_REALERT_SECS="$knob"; rc=$?
  if [ "$rc" -ne 0 ] || ! stderr_clean; then
    echo "FAIL: AU_REALERT_SECS=[$knob]: exit $rc / stderr: $(head -2 "$ERR" | tr '\n' ' ')"; fail=1
  fi
  [ -s "$ROOT/notify.calls" ] || { echo "FAIL: AU_REALERT_SECS=[$knob]: first alert suppressed"; fail=1; }
  echo $(( $(date +%s) - 3600 )) > "$ST/check_last_alert"; rm -f "$ROOT/notify.calls"
  tick env AU_REALERT_SECS="$knob"
  [ -s "$ROOT/notify.calls" ] && { echo "FAIL: AU_REALERT_SECS=[$knob]: re-alerted after 1h (knob collapsed instead of using the default)"; fail=1; }
done
echo stable_ahead > "$ROOT/mode"; rm -f "$ROOT/notify.calls" "$ST/ahead_last_alert" "$ST/drain_pending"
tick env AU_AHEAD_REMIND_SECS='garbage!'; rc=$?
if [ "$rc" -ne 0 ] || ! stderr_clean || [ ! -s "$ROOT/notify.calls" ]; then
  echo "FAIL: AU_AHEAD_REMIND_SECS=garbage: rc=$rc, stderr or no first reminder"; fail=1
fi

[ "$fail" -eq 0 ] && echo "PASS: corrupted counters and timestamps survive the paths that read them" || exit 1
