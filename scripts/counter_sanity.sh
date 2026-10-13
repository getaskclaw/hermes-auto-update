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
HOME="$ROOT/home" PATH="$ROOT/bin:/usr/bin:/bin" AU_APPLY=1 bash "$ROOT/au.sh" >/dev/null 2>/tmp/cs_check.err
rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL: updater exited $rc on corrupted counters (check-failure path)"; fail=1; }
v=$(cat "$ST/consec_check_fails" 2>/dev/null)
case "$v" in ''|*[!0-9]*) echo "FAIL: consec_check_fails = [$v] (not sanitized)"; fail=1 ;; esac
# Teeth (stderr dimension): a numeric END value is indistinguishable between sanitized and
# unsanitized reads — bash replaces a failed $((10#...)) with 1, which is also numeric. The
# only observable that separates them is the arithmetic error escaping to stderr. A build
# with the sanitizer removed MUST trip this; the sanitized build must be silent (0 bytes).
if grep -q 'value too great for base' /tmp/cs_check.err 2>/dev/null; then
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

[ "$fail" -eq 0 ] && echo "PASS: corrupted counters survive the paths that read them" || exit 1
