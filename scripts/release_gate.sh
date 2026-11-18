#!/bin/bash
# Release gate: run the pre-publish recipe against THIS directory and fail loudly on anything
# that would break for the recipient. Run it from an EXTRACTED copy of the bundle:
#
#   cd /tmp/bundle_check/x && bash scripts/release_gate.sh
#
# Why this exists: the recipe in references/bundle-verification-recipe.md was written after a
# release shipped probes that could not run (bad paths, then a missing AU_APPLY=1 opt-in).
# Writing the recipe did not prevent the next occurrence — running it does. This is that
# recipe, mechanised, so a release can be gated on it instead of on memory.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$HERE/.." && pwd)"
cd "$ROOT_DIR" || exit 1

FAIL=0
step() { printf '\n== %s\n' "$1"; }
# Private scratch for the gate's own files (matrix output, neutered copies): under $TMPDIR, never
# a fixed /tmp path (predictable, shared, world-writable). Removed on exit.
GATE_TMP=$(mktemp -d "${TMPDIR:-/tmp}/release_gate.XXXXXX") || { echo "cannot create gate scratch dir"; exit 1; }
trap 'rm -rf -- "$GATE_TMP"' EXIT

step "1/4 doc pointers resolve to real files"
python3 - <<'PY' || FAIL=1
import os, re, pathlib, sys

# A bundle reference is a path in the bundle. Rules learned the hard way:
#  - do NOT strip inline code: in this bundle every real pointer is written in backticks,
#    so stripping them made the check examine nothing (it passed while a file was missing).
#  - require the match to start a path, not continue one: `~/.hermes/scripts/auto_update.sh`
#    is a path on the TARGET machine, not a file this bundle must carry.
#  - ignore obvious placeholders (references/x.md, scripts/y.sh, scripts/<name>.sh).
# Capture the leading path fragment too: `../verify/stub_setup.sh` is bundle-relative and
# must be checked, while `~/.hermes/scripts/auto_update.sh` is the path ON THE TARGET machine
# (it names the installed file, not one this bundle carries).
REF = re.compile(r'([^\s`"\'(]*/)?(references|scripts|verify|templates)/([A-Za-z0-9._-]+)')
PLACEHOLDER = re.compile(r'^(\w|\w\w)$')      # x, y, ab — illustration stubs

def is_bundle_path(prefix, name):
    if PLACEHOLDER.match(name.rsplit(".", 1)[0]):
        return False                            # references/x.md, scripts/y.sh
    if prefix and not prefix.endswith(("../", "./")):
        return False                            # ~/.hermes/scripts/... = target-machine path
    return True

missing, checked = [], 0
for doc in ("SKILL.md", "README.md"):
    p = pathlib.Path(doc)
    if not p.exists():
        print("MISSING DOC: %s" % doc); missing.append((doc, "<doc>")); continue
    for m in REF.finditer(p.read_text()):
        prefix, d, name = m.group(1), m.group(2), m.group(3)
        if not is_bundle_path(prefix, name):
            continue
        ptr = "%s/%s" % (d, name)
        checked += 1
        if not os.path.exists(ptr):
            missing.append((doc, ptr))
for doc, ptr in missing:
    print("BROKEN POINTER: %s: %s" % (doc, ptr))
print("pointers: %d checked, %d broken" % (checked, len(missing)))
# META-GUARD: examining zero pointers means the extractor broke, not that all is well.
if checked == 0:
    print("POINTER CHECK VACUOUS: matched 0 pointers — the extractor is broken, not the docs")
    sys.exit(1)
sys.exit(1 if missing else 0)
PY

step "2/4 hermetic matrix"
if ( cd verify && rm -rf "${HARNESS_ROOT:-/tmp/au-harness}" \
     && bash stub_setup.sh ../auto_update.sh >/dev/null \
     && bash stub_matrix.sh > "$GATE_TMP/matrix.out" 2>&1 ); then
    tail -1 "$GATE_TMP/matrix.out"
else
    echo "MATRIX FAILED:"; tail -20 "$GATE_TMP/matrix.out"; FAIL=1
fi

step "3/4 every probe runs and passes (each self-seeds its harness)"
for probe in scripts/*.sh; do
    [ "$(basename "$probe")" = "release_gate.sh" ] && continue
    printf -- "-- %s\n" "$probe"
    # env -u AU_APPLY: a leftover export must not mask a probe that forgot to opt in.
    if out=$(env -u AU_APPLY bash "$probe" ./auto_update.sh 2>&1); then
        printf '%s\n' "$out" | tail -1
    else
        echo "PROBE FAILED: $probe"; printf '%s\n' "$out" | tail -5; FAIL=1
    fi
done

step "3b/4 python compat probe (explicit: the loop above only globs scripts/*.sh)"
printf -- "-- %s\n" scripts/check_compat_sanity.py
if out=$(env -u AU_APPLY python3 scripts/check_compat_sanity.py ./auto_update.sh 2>&1); then
    printf '%s\n' "$out" | tail -1
else
    echo "PROBE FAILED: scripts/check_compat_sanity.py"; printf '%s\n' "$out" | tail -15; FAIL=1
fi

step "4/4 teeth: neutered builds must FAIL the probe that guards them"
# A green probe proves the toolchain runs, not that it catches anything. For each guard
# with a known neuter, break the source, feed the BROKEN copy to the probe, and require
# the probe to FAIL. A probe that still passes on broken code has no teeth (③, round 2).
# Neuter by TEXT EDIT, not by a sed expression pasted into a double-quoted argument: bash
# expands `$((10#...))` and `${#v}` inside double quotes, so the expression above reached sed
# mangled (and printed `10#: invalid integer constant` on the way). It still reported "teeth ok"
# — the probe failed on a copy broken in some OTHER way, which is a false teeth pass: exactly
# what this step exists to prevent. The python edit asserts the source text was really changed.
neuter() { # $1 = kind  $2 = src  $3 = dst
    python3 - "$1" "$2" "$3" <<'PY'
import sys
kind, src, dst = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(src, encoding="utf-8").read()
# kind -> (anchor that must occur EXACTLY once, replacement)
EDITS = {
    "sanitizer": ("tr -cd '0-9'", "cat"),
    "clamporder": ('    if [ "${#v}" -gt 6 ]; then v=0; fi\n    v=$((10#$v))\n',
                   '    v=$((10#$v))\n    if [ "${#v}" -gt 6 ]; then v=0; fi\n'),
    "alertstamp": ('    if notify "$msg"; then\n        echo "$TICK_TS" > "$STATE_DIR/check_alert_last_ts"\n',
                   '    notify "$msg"; if true; then\n        echo "$TICK_TS" > "$STATE_DIR/check_alert_last_ts"\n'),
    "applygate": ('if [ "${AU_APPLY:-0}" != "1" ]; then', 'if [ "${AU_APPLY:-1}" != "1" ]; then'),
    # B300: whole-line anchoring of the no-update sentences (prefix match instead)
    "anchor": ('|✓ Already up to date\\.)\\$"', '|✓ Already up to date\\.)"'),
    # B300: an unrecognized non-empty line no longer makes the output unknown
    "unknownline": ("            error|unknown) bad=1 ;;\n", "            error) bad=1 ;;\n            unknown) ;;\n"),
    # B300/B301: the error / failed / timed out word veto removed
    "errorword": ('    case "${l,,}" in *error*|*failed*|*"timed out"*) return 0 ;; esac\n', ""),
    # B301: --yes no-op accepted without the veto
    "noopveto": ('            if VETO=$(yes_noop_veto "$UPDATE_OUT"); then\n',
                 '            if false; then VETO=\n'),
    # B306: the --yes no-op exit no longer resets the real-failure streak
    "noopreset": ('            recheck_drain_marker; DRAIN_RC=$?\n            reset_real_fails\n',
                  '            recheck_drain_marker; DRAIN_RC=$?\n'),
    # B303: real-failure re-alert back to "first failure only"
    "realclock": ('    if [ "$REAL_F" -eq 1 ] || interval_due real_alert_last_ts "$AU_REALERT_SECS"; then\n',
                  '    if [ "$REAL_F" -eq 1 ]; then\n'),
    # B304: rollback reminder back to a one-shot marker
    "remindclock": ('        if interval_due rollback_remind_ts "$AU_ROLLBACK_REMIND_SECS"; then\n',
                    '        if [ ! -f "$STATE_DIR/rollback_remind_ts" ]; then\n'),
    # B302: summary no longer prioritizes error lines (plain head)
    "summarypriority": ("            if (!pri[i]) continue\n", "            continue\n"),
    # B307: receipt_checkout_agrees constant false
    "checkoutproof": ("    print(1 if ok else 0)\n", "    print(0)\n"),
}
if kind not in EDITS:
    raise SystemExit("unknown neuter kind: " + kind)
a, b = EDITS[kind]
n = s.count(a)
assert n == 1, "%s neuter: anchor found %d times (need exactly 1)" % (kind, n)
open(dst, "w", encoding="utf-8").write(s.replace(a, b))
PY
}
neuter_and_run() { # $1 = kind  $2 = label  [$3 = probe, default counter_sanity.sh]  [$4.. = probe test selectors]
    local kind="$1" label="$2" probe="${3:-scripts/counter_sanity.sh}"
    shift 3 2>/dev/null || shift $#
    local neut="$GATE_TMP/au_neut.sh"
    neuter "$kind" auto_update.sh "$neut" || { echo "NEUTER FAILED: $label"; FAIL=1; return; }
    if cmp -s auto_update.sh "$neut"; then
        echo "NEUTER IS A NO-OP: $label — the copy equals the source, so this proves nothing"; FAIL=1; return
    fi
    bash -n "$neut" || { echo "neutered copy not bash-clean: $label"; FAIL=1; return; }
    local runner=bash
    case "$probe" in *.py) runner=python3 ;; esac
    if env -u AU_APPLY "$runner" "$probe" "$neut" "$@" >/dev/null 2>&1; then
        echo "NO TEETH: $label — probe passed on a broken build"; FAIL=1
    else
        echo "teeth ok: $label (probe fails on the neutered build)"
    fi
}
PY_PROBE=scripts/check_compat_sanity.py
# guard: the counter sanitizer. Neuter = pass the raw value through (tr -cd '0-9' -> cat).
neuter_and_run sanitizer "counter sanitizer removed -> counter_sanity must FAIL"
# guard: the LENGTH CLAMP ORDER. Neuter = put the clamp back after the arithmetic, which is
# exactly the defect this round fixed: a long all-digit value then wraps silently instead of
# being zeroed, and the counter lands on 4 / -4. Without this neuter the gate proved only that
# the probe RUNS, not that it would catch the order regression returning.
neuter_and_run clamporder "length clamp moved AFTER the arithmetic -> counter_sanity must FAIL"
# guards (issue #1): check-alert timestamp written only on delivery; AU_APPLY gate closed by default.
neuter_and_run alertstamp "check alert stamped although notify failed -> check_compat_sanity must FAIL" "$PY_PROBE" Cadence
neuter_and_run applygate "AU_APPLY gate defaulted open -> check_compat_sanity must FAIL" "$PY_PROBE" Banners
# guards (v5.15): each selector names the regression that owns the guard, so a pass of SOME
# other test cannot stand in for it.
neuter_and_run anchor "B300 no-update sentence matched as a prefix -> StrictVerdicts must FAIL" "$PY_PROBE" StrictVerdicts.test_error_and_unknown_shapes_fail_closed
neuter_and_run unknownline "B300 unknown line ignored -> StrictVerdicts must FAIL" "$PY_PROBE" StrictVerdicts.test_error_and_unknown_shapes_fail_closed
neuter_and_run errorword "B300/B301 error-word veto removed -> StrictVerdicts + YesNoopVeto must FAIL" "$PY_PROBE" StrictVerdicts.test_error_and_unknown_shapes_fail_closed YesNoopVeto.test_vetoed_noop_is_a_real_failure
neuter_and_run noopveto "B301 --yes no-op veto removed -> YesNoopVeto must FAIL" "$PY_PROBE" YesNoopVeto
neuter_and_run noopreset "B306 --yes no-op keeps the real-failure streak -> NoopResetsRealFails must FAIL" "$PY_PROBE" NoopResetsRealFails.test_yes_noop_missing_receipt
neuter_and_run realclock "B303 real failure re-alert by count/never -> RealFailureCadence must FAIL" "$PY_PROBE" RealFailureCadence
neuter_and_run remindclock "B304 rollback reminder one-shot -> RollbackReminder must FAIL" "$PY_PROBE" RollbackReminder.test_weekly_reminder_never_installs
neuter_and_run summarypriority "B302 summary without error priority -> AlertSummary must FAIL" "$PY_PROBE" AlertSummary
neuter_and_run checkoutproof "B307 receipt_checkout_agrees constant false -> ReceiptBinding must FAIL" "$PY_PROBE" ReceiptBinding.test_legacy_exit0_real_move_matching_receipt_is_install

step "gate"
if [ "$FAIL" -eq 0 ]; then
    echo "RELEASE GATE: PASS"
else
    echo "RELEASE GATE: FAIL"
fi
exit "$FAIL"

