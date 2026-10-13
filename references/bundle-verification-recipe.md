# Verifying a release bundle before shipping it

The failure this prevents: a bundle whose docs reference files it does not contain, or
whose newly added tools cannot start. Both look fine in the working tree and break for
the recipient. Run this from the *extracted* copy, never the working tree.

## Recipe

```bash
# 1. pack to a scratch path, extract, and work only inside the extraction
#    PACK/EXTRACT with python, not `zip`/`unzip`: hosts such as the to6429 VPS ship neither
#    binary, and a `zip: command not found` under `set -e` aborts mid-command — leaving a
#    stale bundle from the previous release on disk for the next step to "verify".
#    external_attr MUST be set or every +x bit is lost on extract (silently: the files
#    still run under `bash scripts/x.sh` and under the gate, so only `./scripts/x.sh` and
#    `install.sh` break for the recipient).
rm -rf "$HOME/.hermes/profiles/firefly/cache/scratch/bundle_check" && mkdir -p "$HOME/.hermes/profiles/firefly/cache/scratch/bundle_check/x"
python3 - "$OUT" <<'PY'
import sys, zipfile, os, time
out = sys.argv[1]; root = os.getcwd()
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for dp, dn, fns in os.walk(root):
        dn[:] = [d for d in dn if d != '.git']
        for fn in sorted(fns):
            if fn.endswith('.bak') or 'bak-v' in fn:
                continue
            full = os.path.join(dp, fn); rel = os.path.relpath(full, root); st = os.stat(full)
            zi = zipfile.ZipInfo(rel); zi.date_time = time.localtime(st.st_mtime)[:6]
            zi.external_attr = (st.st_mode & 0xFFFF) << 16   # WITHOUT THIS the +x bits are lost
            zi.compress_type = zipfile.ZIP_DEFLATED
            with open(full, 'rb') as fh:
                z.writestr(zi, fh.read())
PY
B="$HOME/.hermes/profiles/firefly/cache/scratch/bundle_check"
python3 -c "import zipfile;zipfile.ZipFile('$OUT').extractall('$B/x')"
chmod -R u+rwX "$B/x"      # python's extractall does NOT apply external_attr
cd "$B/x" && diff -r --exclude=.git -q "$PUBDIR" . && echo "byte-identical to source"

# 1b. the modes STORED IN THE ARCHIVE are what a real unzip will apply.
#     Compare against the SOURCE tree, never the python-extracted one: that copy is 0644
#     everywhere, so a check run there reports every executable as a mismatch (false red).
python3 - "$OUT" "$PUBDIR" <<'PY'
import sys, zipfile, os
z = zipfile.ZipFile(sys.argv[1]); root = sys.argv[2]; bad = n = 0
for i in z.infolist():
    stored = (i.external_attr >> 16) & 0o777
    src = os.path.join(root, i.filename); n += 1
    if not os.path.exists(src):
        print(f"MISSING IN SOURCE {i.filename}"); bad += 1; continue
    want = os.stat(src).st_mode & 0o777
    if (stored & 0o111) != (want & 0o111):
        print(f"MODE MISMATCH {i.filename}: archive {oct(stored)} vs source {oct(want)}"); bad += 1
print(f"mode check: {n} entries, {bad} mismatched")
sys.exit(1 if bad else 0)
PY

# 2. every doc pointer resolves to a real file
#    - strip inline-code spans first: a path written as an example (`references/x.md`) is
#      not a packaging obligation
#    - resolve each pointer from BOTH the bundle root and its own directory, or a real
#      reference like scripts/auto_update.sh (a root file named from a prose sentence)
#      reports as broken
python3 - <<'PY'
import os, re, pathlib
missing = []
for doc in ("SKILL.md", "README.md"):
    text = pathlib.Path(doc).read_text()
    text = re.sub(r'`[^`]*`', ' ', text)          # drop inline-code spans
    for ptr in sorted(set(re.findall(r'(?:references|scripts|verify|templates)/[A-Za-z0-9._-]+', text))):
        if not (os.path.exists(ptr) or os.path.exists(os.path.basename(ptr))):
            missing.append((doc, ptr))
for doc, ptr in missing:
    print(f"BROKEN POINTER: {doc}: {ptr}")
print("pointer check: %d broken" % len(missing))
PY

# 3. every executable support file actually runs (not just exists)
#    Probe scripts self-seed the harness and set their own AU_APPLY=1 — run them plainly.
cd verify && bash stub_setup.sh ../auto_update.sh >/dev/null && bash stub_matrix.sh | tail -1
cd .. && for p in scripts/*.sh; do echo "== $p"; bash "$p" ./auto_update.sh || echo "PROBE FAILED: $p"; done
```

## One command

`scripts/release_gate.sh` runs the whole recipe against the current directory and exits
non-zero on any failure:

```bash
bash scripts/release_gate.sh          # from the bundle root
```

It (1) checks doc pointers, (2) runs the matrix, (3) runs every probe, (4) runs teeth: for each known guard, a NEUTERED build is fed to the probe that guards it and the probe must FAIL (a probe that passes on broken code has no teeth). Adding a new guard means adding its neuter to the gate the same round. Run it from the
*extracted* copy — a green gate on the working tree says nothing about the bundle.

## Rules

- Never ship a zip that lost its +x bits. A python-written archive without `external_attr`
  extracts every file 0644 for a real `unzip` user — and the gate still passes, because it
  invokes scripts as `bash scripts/release_gate.sh`. Recipients then hit
  `./install.sh: Permission denied`.
  **Verify the modes stored IN the archive** (`zipfile`'s `external_attr>>16`, or `unzip -Z`),
  never the extracted tree: Python's own `extractall()` does not apply `external_attr`, so a
  python-side check reports 0644 for a perfectly good archive and proves nothing either way.
  When extracting with python, `chmod -R u+rwX` before trusting any `./script` invocation.
- Pack, extract, verify — in that order. Verifying the working tree proves nothing about
the bundle.
- A check that examines nothing must FAIL, not pass. The pointer check first stripped inline
  code to kill false positives — and since every real pointer is written in backticks, it then
  matched zero paths and cheerfully reported 0 broken while a referenced file was missing. Keep
  a counter of what was actually examined and fail when it is zero; a permanently-green check
  is more dangerous than no check, because it manufactures confidence.
- Classify a path before checking it: `../verify/x.sh` is bundle-relative (check it),
  `~/.hermes/scripts/x.sh` is the path ON THE TARGET machine (skip it), `references/x.md` is a
  placeholder in prose (skip it).
- Re-derive the file list from the docs' pointers; do not trust a hand-maintained list.
  A pointer added to a doc is a packaging obligation created at that moment.
- Bulk-syncing directories (`cp -r src/. dest/`) can revert a newer fix with a stale copy.
  After any bulk sync, `grep` for the fix's distinctive line in the shipped copy and re-run
  the affected probe.
- Refresh evidence files (logs, receipts, timestamps) at pack time and stamp when they were
  captured — stale evidence is indistinguishable from fabricated evidence to a reviewer. The
  bundle's OWN version identity counts as evidence and is the item most easily forgotten: the
  README title, the `UPDATER_VERSION` line in its file list, and the sha256 line all name the
  previous release after a bump. Re-derive all three from the artifact in the same pass, and
  record where each came from — a self-consistent but stale document passes every check.
- Support scripts must resolve siblings from their own location (`HERE="$(cd "$(dirname "$0")" && pwd)"`)
  and build their own fixtures; a script that only works when the matrix ran first is broken
  for the recipient.
- Teeth checks neuter the SOURCE and pass its path to the probe — never pre-neuter the harness
  copy. A probe that self-seeds rebuilds `$HARNESS_ROOT` from its `$1` argument and silently
  overwrites anything you patched there, so the teeth measure the UNBROKEN code and pass. Copy
  the source, sed the neuter into the copy, `bash -n` it, then hand the copy's path to the probe.
