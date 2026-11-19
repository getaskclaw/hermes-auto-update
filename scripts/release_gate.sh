#!/bin/bash
# Release gate: run the pre-publish recipe against THIS directory and fail loudly on anything
# that would break for the recipient. Run it from an EXTRACTED copy of the bundle:
#
#   cd "$(mktemp -d)" && <extract the bundle> && bash scripts/release_gate.sh
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
# The stub harness root, shared by the matrix and every probe below (each self-seeds it). An
# explicit HARNESS_ROOT wins; otherwise it lives in the private gate scratch, never a fixed /tmp
# path, and is exported so no probe falls back to its own default.
if [ -z "${HARNESS_ROOT:-}" ]; then HARNESS_ROOT="$GATE_TMP/au-harness"; fi
export HARNESS_ROOT

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
if ( cd verify && rm -rf "$HARNESS_ROOT" \
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

step "3c/4 upstream print corpus: every official release's print() templates vs the real rules"
# (a) no --check conclusion template of any official release may judge `unknown` unless registered;
# (b) every line the --yes error rule hits must be reviewed (error / exempt), exempt samples must
# pass and every error line must still be vetoed. Runs on the stored snapshot (the recipient has no
# upstream checkout); refresh it with: python3 -I scripts/upstream_print_corpus.py --write-snapshot
printf -- "-- %s\n" scripts/upstream_print_corpus.py
if out=$(python3 -I scripts/upstream_print_corpus.py ./auto_update.sh --gate 2>&1); then
    printf '%s\n' "$out" | grep -E '^\((a|b)\)|^  \(a\) REGISTERED|^UPSTREAM CORPUS'
else
    echo "PROBE FAILED: scripts/upstream_print_corpus.py"; printf '%s\n' "$out" | tail -15; FAIL=1
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
    # PATCH4 rule 1: the --yes error veto removed (an error line no longer fails a no-receipt run)
    "yeserror": ('        if [ -n "$YES_ERR" ]; then\n', '        if false; then\n'),
    # PATCH4 rule 3: the HEAD comparison removed (a moved checkout passes as a no-op)
    "headcompare": ('        if [ "$PRE_HEAD" != "$POST_HEAD" ]; then\n', '        if false; then\n'),
    # PATCH4 rule 2: unreadable HEAD no longer inconclusive (falls through to the comparison)
    "headunknown": ('        if [ -z "$PRE_HEAD" ] || [ -z "$POST_HEAD" ]; then\n', '        if false; then\n'),
    # PATCH4 stuck guard removed (available + nothing to do, forever, silently). PATCH5: the anchor
    # moved into the proven-no-op branch (4a, one indent deeper); same guard.
    "stuckguard": ('            available_noop_count "$UPDATE_OUT"\n', '            :\n'),
    # PATCH5 (option D): CORR_STATE=match dropped from PROVEN_NOOP (a receipt without OUR id silences)
    "corrmatch": ('[ "$RECEIPT_OUTCOME" = "success" ] && [ "$CORR_STATE" = "match" ] \\\n',
                  '[ "$RECEIPT_OUTCOME" = "success" ] \\\n'),
    # PATCH5: the unproven no-op reminder removed (an unproven no-op goes quiet again)
    "unprovenremind": ('        unproven_noop_remind "$UPDATE_OUT"\n', '        :\n'),
    # PATCH5: the unproven no-op resets the real-failure streak again (B1100's 8 -> 0)
    "unprovenreset": ('        recheck_drain_marker\n        unproven_noop_remind "$UPDATE_OUT"\n',
                      '        recheck_drain_marker\n        reset_real_fails\n        unproven_noop_remind "$UPDATE_OUT"\n'),
    # PATCH5: a receipt owing followups / a user action counts as proof of a clean no-op again
    "followups": ('          and not d.get("followups") and not d.get("user_action")\n', ''),
    # PATCH5 B1201: back to "only a line that STARTS with ✗"
    "midlinex": ('    case "$t" in *"✗"*) printf', '    case "$t" in "✗"*) printf'),
    # v5.16: the owed-action reminder removed (the 2026-11-18 silence returns)
    "owednotice": ('    out=$(receipt_owed_text "${1:-}" "${VERSION:-}" "$UPDATER_VERSION")\n', '    out=""\n'),
    # v5.16: the per-update_id dedupe removed (the same receipt reminds on every install of it)
    "owededupe": ('        if [ -f "$OWED_SENT" ] && grep -qxF -- "$key" "$OWED_SENT" 2>/dev/null; then rm -f -- "$f"; log "owed-action reminder $key already delivered — not repeated"; continue; fi\n', ''),
    # v5.16: the dedupe key / pending removal written although delivery failed (reminder lost)
    "owedstamp": ('        if notify "$(head -c 4000 -- "$f")"; then\n', '        notify "$(head -c 4000 -- "$f")"; if true; then\n'),
    # v5.16: the tick-start retry of an undelivered reminder removed
    "owedretry": ("# the run killed mid-poll) is retried first, on every tick, until it is delivered.\nowed_action_flush\n",
                  "# the run killed mid-poll) is retried first, on every tick, until it is delivered.\n:\n"),
    # v5.16 B1300: receipt_sha_advanced back to the v5.15 short_sha string inequality
    "shaadvance": ('    (pre, ok1), (post, ok2) = ident(d.get("pre_update")), ident(d.get("post_update"))\n'
                   '    n = min(len(pre), len(post))\n'
                   '    print(1 if (ok1 and ok2 and n >= 7 and pre[:n] != post[:n]) else 0)\n',
                   '    pre = ((d.get("pre_update") or {}).get("short_sha") or "").strip()\n'
                   '    post = ((d.get("post_update") or {}).get("short_sha") or "").strip()\n'
                   '    print(1 if (pre and post and pre != post) else 0)\n'),
    # PATCH4 stuck guard not cleared by a proven install (next streak alerts too early)
    "stuckclear": ('mark_installed() { date +%s > "$STATE_DIR/last_install_ts"; clear_available_noop; }',
                   'mark_installed() { date +%s > "$STATE_DIR/last_install_ts"; }'),
    # PATCH4 exemption table widened to any line (whole-sentence exemption lost)
    "exemptwhole": ('    [ -n "$V_YES_EXEMPT" ] && [[ $1 =~ $V_YES_EXEMPT ]]\n', '    [ -n "$V_YES_EXEMPT" ]\n'),
    # B800: the available verdict no longer anchored at the start of the line
    "availanchor": ('V_AVAILABLE="^(→ Selected release available: ', 'V_AVAILABLE="(→ Selected release available: '),
    # B501/B600: the daily check re-alert default back to a zero-margin 86400
    "checkinterval": ('"${AU_CHECK_ALERT_INTERVAL-}" 82800)', '"${AU_CHECK_ALERT_INTERVAL-}" 86400)'),
    # B601: "No newer release" accepts the short label again
    "noneweraheadonly": ('✓ No newer release: $_V_LBL_AHEAD\\.|', '✓ No newer release: ($_V_LBL|$_V_LBL_AHEAD)\\.|'),
    # B306: the --yes no-op exit no longer resets the real-failure streak. PATCH5: the proven-no-op
    # branch (4a) is where the reset lives now (one indent deeper).
    "noopreset": ('            reset_real_fails\n            available_noop_count "$UPDATE_OUT"\n',
                  '            available_noop_count "$UPDATE_OUT"\n'),
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
neuter_and_run errorword "B300 --check error-word veto removed -> StrictVerdicts must FAIL" "$PY_PROBE" StrictVerdicts.test_error_and_unknown_shapes_fail_closed
neuter_and_run yeserror "PATCH4 --yes error veto removed -> YesErrorVeto must FAIL" "$PY_PROBE" YesErrorVeto.test_error_line_is_a_real_failure
neuter_and_run headcompare "PATCH4 HEAD comparison removed -> YesHeadState must FAIL" "$PY_PROBE" YesHeadState.test_head_moved_without_receipt_is_unproven
neuter_and_run headunknown "PATCH4 unreadable HEAD not inconclusive -> YesHeadState must FAIL" "$PY_PROBE" YesHeadState.test_head_unreadable_is_inconclusive
neuter_and_run stuckguard "PATCH4 stuck guard removed -> StuckGuard must FAIL" "$PY_PROBE" StuckGuard.test_third_consecutive_noop_alerts_with_output_then_daily StuckGuard.test_b500_no_error_rows_alert_on_the_third_tick
neuter_and_run stuckclear "PATCH4 stuck guard not cleared by a proven install -> StuckGuard must FAIL" "$PY_PROBE" StuckGuard.test_proven_install_clears
neuter_and_run exemptwhole "PATCH4 exemption no longer whole-sentence -> YesErrorVeto must FAIL" "$PY_PROBE" YesErrorVeto.test_error_line_is_a_real_failure
neuter_and_run exemptwhole "PATCH4 exemption no longer whole-sentence -> the upstream corpus gate must FAIL" scripts/upstream_print_corpus.py --gate
neuter_and_run availanchor "B800 available verdict matched after a prefix -> StrictVerdicts must FAIL" "$PY_PROBE" StrictVerdicts.test_error_and_unknown_shapes_fail_closed
neuter_and_run checkinterval "B501 zero-margin daily check re-alert -> Cadence jitter must FAIL" "$PY_PROBE" Cadence.test_daily_ticks_with_start_jitter_alert_every_day
neuter_and_run noneweraheadonly "B601 short label after No newer release -> StrictVerdicts must FAIL" "$PY_PROBE" StrictVerdicts.test_error_and_unknown_shapes_fail_closed
neuter_and_run noopreset "B306 proven --yes no-op keeps the real-failure streak -> NoopResetsRealFails must FAIL" "$PY_PROBE" NoopResetsRealFails.test_yes_noop_proven_receipt
# PATCH5 (option D) teeth
neuter_and_run corrmatch "PATCH5 CORR_STATE=match dropped from PROVEN_NOOP -> OptionD must FAIL" "$PY_PROBE" OptionD.test_gen2_style_receipt_without_our_id_reminds
neuter_and_run unprovenremind "PATCH5 unproven no-op reminder removed -> OptionD must FAIL" "$PY_PROBE" OptionD.test_source_repair_still_unhealthy_reminds_then_throttles OptionD.test_wordgap_without_receipt_reminds_on_the_first_tick OptionD.test_legacy_noop_reminds_by_design
neuter_and_run unprovenreset "PATCH5 unproven no-op resets the streak -> NoopResetsRealFails / OptionD must FAIL" "$PY_PROBE" NoopResetsRealFails.test_yes_noop_missing_receipt_keeps_streak OptionD.test_source_repair_still_unhealthy_reminds_then_throttles
neuter_and_run followups "PATCH5 receipt owing followups accepted as proof -> OptionD must FAIL" "$PY_PROBE" OptionD.test_gen3_without_usable_receipt_reminds
neuter_and_run midlinex "PATCH5 B1201 mid-line ✗ no longer vetoed -> YesErrorVeto must FAIL" "$PY_PROBE" YesErrorVeto.test_error_line_is_a_real_failure
# PATCH5 B1102: the corpus tool itself, neutered so a parse error / an empty corpus no longer fails.
# The probe is the CorpusToolFailsClosed class, pointed at the neutered tool by AU_CORPUS_TOOL.
neuter_tool_and_run() { # $1 = kind  $2 = label  $3.. = selectors
    local kind="$1" label="$2"; shift 2
    local neut="$GATE_TMP/corpus_neut.py"
    python3 - "$kind" scripts/upstream_print_corpus.py "$neut" <<'PY' || { echo "NEUTER FAILED: $label"; FAIL=1; return; }
import sys
kind, src, dst = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(src, encoding="utf-8").read()
EDITS = {
    # a parse error is reported but not counted (B1102 as found by r6A)
    "parseerror": ('                rep.append("  FAIL parse error(s) in %s: %s" % (tag, "; ".join(map(str, errs)))); fails += 1\n',
                   '                rep.append("  FAIL parse error(s) in %s: %s" % (tag, "; ".join(map(str, errs))))\n'),
    # a tag with 0 print() templates is reported but not counted
    "zeroprints": ('                rep.append("  FAIL tag %s: 0 print() templates found (unreadable or moved source)" % tag); fails += 1\n',
                   '                rep.append("  FAIL tag %s: 0 print() templates found (unreadable or moved source)" % tag)\n'),
    # an empty (a) corpus passes again
    "emptya": ('        rep.append("  (a) VACUOUS: no --check template line / no conclusion line was checked")\n        fails += 1\n',
               '        rep.append("  (a) VACUOUS: no --check template line / no conclusion line was checked")\n'),
}
a, b = EDITS[kind]
assert s.count(a) == 1, "%s neuter: anchor found %d times (need exactly 1)" % (kind, s.count(a))
open(dst, "w", encoding="utf-8").write(s.replace(a, b))
PY
    if cmp -s scripts/upstream_print_corpus.py "$neut"; then echo "NEUTER IS A NO-OP: $label"; FAIL=1; return; fi
    if env -u AU_APPLY AU_CORPUS_TOOL="$neut" python3 "$PY_PROBE" ./auto_update.sh "$@" >/dev/null 2>&1; then
        echo "NO TEETH: $label — probe passed on a broken build"; FAIL=1
    else
        echo "teeth ok: $label (probe fails on the neutered build)"
    fi
}
neuter_tool_and_run parseerror "PATCH5 B1102 corpus parse error not counted -> CorpusToolFailsClosed must FAIL" CorpusToolFailsClosed.test_scan_parse_error_fails CorpusToolFailsClosed.test_gate_vacuous_or_broken_snapshot_fails
neuter_tool_and_run zeroprints "PATCH5 B1102 zero-print tag not counted -> CorpusToolFailsClosed must FAIL" CorpusToolFailsClosed.test_scan_zero_print_tag_fails
neuter_tool_and_run emptya "PATCH5 B1102 empty (a) corpus passes -> CorpusToolFailsClosed must FAIL" CorpusToolFailsClosed.test_gate_vacuous_or_broken_snapshot_fails
# v5.16 teeth: owed-action reminder after a proven install, its dedupe / delivery stamp / retry, B1300
neuter_and_run owednotice "v5.16 owed-action reminder removed -> OwedActionNotice must FAIL" "$PY_PROBE" OwedActionNotice.test_incident_partial_sha_advance_user_action_reminds_once OwedActionNotice.test_correlated_success_with_followups_reminds
neuter_and_run owededupe "v5.16 owed-action dedupe removed -> OwedActionNotice must FAIL" "$PY_PROBE" OwedActionNotice.test_incident_partial_sha_advance_user_action_reminds_once
neuter_and_run owedstamp "v5.16 owed-action stamped although undelivered -> OwedActionNotice must FAIL" "$PY_PROBE" OwedActionNotice.test_undelivered_reminder_keeps_install_and_retries_until_delivered
neuter_and_run owedretry "v5.16 undelivered owed-action reminder never retried -> OwedActionNotice must FAIL" "$PY_PROBE" OwedActionNotice.test_undelivered_reminder_keeps_install_and_retries_until_delivered
neuter_and_run shaadvance "B1300 receipt_sha_advanced back to short_sha string inequality -> ShaAdvanceB1300 must FAIL" "$PY_PROBE" ShaAdvanceB1300.test_forged_short_length_change_is_not_an_install ShaAdvanceB1300.test_malformed_side_is_not_an_advance
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

