#!/bin/bash
# Adversarial marker-lifecycle sweep: for EVERY branch that can set or clear drain_pending,
# run it with the gateway deliberately unhealthy and assert the marker survives; then assert
# a healthy recheck clears it. Mechanical version of the manual sweep — run after any patch.
set -u
SRC="${1:?usage: bash marker_lifecycle_sweep.sh /path/to/auto_update.sh}"
ROOT="${HARNESS_ROOT:-/tmp/au-harness}"
HERE="$(cd "$(dirname "$0")" && pwd)"
bash "$HERE/../verify/stub_setup.sh" "$SRC" >/dev/null || exit 1
ST="$ROOT/home/.hermes/state/auto_update"
PASS=0; FAIL=0
assert_present() {
  if [ -f "$ST/drain_pending" ]; then PASS=$((PASS+1)); return 0; fi
  # Distinguish "the marker was erased" from "no install ever ran, so it was never set".
  # The second is a harness/opt-in bug (e.g. AU_APPLY missing), not a script defect, and
  # reporting it as "erased" sends the reader hunting the wrong bug.
  if ! grep -qE "update exit=|success |install ok" "$ROOT/home/.hermes/logs/auto_update.log" 2>/dev/null; then
    echo "FAIL (no install ran — did the tick opt in with AU_APPLY=1?): $1"; FAIL=$((FAIL+1))
  else
    echo "FAIL (marker erased): $1"; FAIL=$((FAIL+1))
  fi
}
assert_absent()  { if [ -f "$ST/drain_pending" ]; then echo "FAIL (marker kept): $1"; FAIL=$((FAIL+1)); else PASS=$((PASS+1)); fi; }
# Rebuild the home fixture this sweep needs (do not depend on the matrix having run):
# gateway_state is written from the scratch repo's HEAD so the health check can succeed.
reset_home() {
  rm -rf "$ROOT/home"
  mkdir -p "$ST" "$ROOT/home/.hermes/logs/update_receipts"
  printf 'TELEGRAM_BOT_TOKEN=1:F\nTELEGRAM_ALLOWED_USERS=9\n' > "$ROOT/home/.hermes/.env"
  h=$(git -C "$ROOT/repo" rev-parse HEAD 2>/dev/null)
  printf '{"pid":1,"code_sha":"%s"}' "$h" > "$ROOT/home/.hermes/gateway_state.json"
}
# AU_APPLY=1 is REQUIRED: since v5.9 the updater is report-only without it, so a sweep tick
# would install nothing, never set the marker, and then fail with a false "marker erased".
# Any probe that drives the install path must opt in explicitly.
run_tick() { HOME="$ROOT/home" PATH="$ROOT/bin:/usr/bin:/bin" AU_APPLY=1 AU_SETTLE_SECONDS="${AU_SETTLE_SECONDS:-0}" bash "$ROOT/au.sh" >/dev/null 2>&1; }

reset_home; echo uptodate > "$ROOT/mode"; run_tick
echo race > "$ROOT/mode"; touch "$ROOT/gw_down"; run_tick
assert_present "race branch (gateway dead) keeps the marker"

reset_home; echo ok > "$ROOT/mode"; touch "$ROOT/gw_down"; run_tick
assert_present "receipt=success branch keeps the marker (restart issued != gateway verified)"

echo partial0 > "$ROOT/mode"; touch "$ROOT/gw_down"
AU_POLL_EVERY=0 AU_POLL_TRIES=1 HOME="$ROOT/home" PATH="$ROOT/bin:/usr/bin:/bin" AU_APPLY=1 AU_SETTLE_SECONDS=0 bash "$ROOT/au.sh" >/dev/null 2>&1
assert_present "drain-timeout branch keeps the marker"

rm -f "$ROOT/gw_down"; echo uptodate > "$ROOT/mode"; run_tick
assert_absent "healthy recheck clears the marker"

echo "==== $PASS passed, $FAIL failed ===="
[ "$FAIL" -eq 0 ] || exit 1
