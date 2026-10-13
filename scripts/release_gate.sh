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
     && bash stub_matrix.sh > /tmp/release_gate_matrix.out 2>&1 ); then
    tail -1 /tmp/release_gate_matrix.out
else
    echo "MATRIX FAILED:"; tail -20 /tmp/release_gate_matrix.out; FAIL=1
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

step "4/4 teeth: neutered builds must FAIL the probe that guards them"
# A green probe proves the toolchain runs, not that it catches anything. For each guard
# with a known neuter, break the source, feed the BROKEN copy to the probe, and require
# the probe to FAIL. A probe that still passes on broken code has no teeth (③, round 2).
mkdir -p /tmp/gate_neut
# Neuter by TEXT EDIT, not by a sed expression pasted into a double-quoted argument: bash
# expands `$((10#...))` and `${#v}` inside double quotes, so the expression above reached sed
# mangled (and printed `10#: invalid integer constant` on the way). It still reported "teeth ok"
# — the probe failed on a copy broken in some OTHER way, which is a false teeth pass: exactly
# what this step exists to prevent. The python edit asserts the source text was really changed.
neuter() { # $1 = kind  $2 = src  $3 = dst
    python3 - "$1" "$2" "$3" <<'PY'
import sys
kind, src, dst = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(src).read()
if kind == "sanitizer":
    new = s.replace("tr -cd '0-9'", "cat")
    assert new != s, "sanitizer neuter did not apply (anchor missing)"
elif kind == "clamporder":
    a = '    if [ "${#v}" -gt 6 ]; then v=0; fi\n    v=$((10#$v))\n'
    b = '    v=$((10#$v))\n    if [ "${#v}" -gt 6 ]; then v=0; fi\n'
    assert a in s, "clamp-order neuter: anchored pair not found"
    new = s.replace(a, b)
else:
    raise SystemExit("unknown neuter kind: " + kind)
open(dst, "w").write(new)
PY
}
neuter_and_run() { # $1 = kind  $2 = label  [$3 = probe, default counter_sanity.sh]
    local probe="${3:-scripts/counter_sanity.sh}"
    neuter "$1" auto_update.sh /tmp/gate_neut/au_neut.sh || { echo "NEUTER FAILED: $2"; FAIL=1; return; }
    if cmp -s auto_update.sh /tmp/gate_neut/au_neut.sh; then
        echo "NEUTER IS A NO-OP: $2 — the copy equals the source, so this proves nothing"; FAIL=1; return
    fi
    bash -n /tmp/gate_neut/au_neut.sh || { echo "neutered copy not bash-clean: $2"; FAIL=1; return; }
    if env -u AU_APPLY bash "$probe" /tmp/gate_neut/au_neut.sh >/dev/null 2>&1; then
        echo "NO TEETH: $2 — probe passed on a broken build"; FAIL=1
    else
        echo "teeth ok: $2 (probe fails on the neutered build)"
    fi
}
# guard: the counter sanitizer. Neuter = pass the raw value through (tr -cd '0-9' -> cat).
neuter_and_run sanitizer "counter sanitizer removed -> counter_sanity must FAIL"
# guard: the LENGTH CLAMP ORDER. Neuter = put the clamp back after the arithmetic, which is
# exactly the defect this round fixed: a long all-digit value then wraps silently instead of
# being zeroed, and the counter lands on 4 / -4. Without this neuter the gate proved only that
# the probe RUNS, not that it would catch the order regression returning.
neuter_and_run clamporder "length clamp moved AFTER the arithmetic -> counter_sanity must FAIL"

step "gate"
if [ "$FAIL" -eq 0 ]; then
    echo "RELEASE GATE: PASS"
else
    echo "RELEASE GATE: FAIL"
fi
exit "$FAIL"
