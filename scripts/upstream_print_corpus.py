#!/usr/bin/env python3
"""Read-only scan of every official upstream release for `hermes update` print() templates.

Usage:
  python3 -I scripts/upstream_print_corpus.py [auto_update.sh] [--repo PATH] [--write-snapshot] [--full-out PATH] [--list-hits]
  python3 -I scripts/upstream_print_corpus.py [auto_update.sh] --gate   # release gate: the snapshot only

Why: upstream `hermes update` has no machine-readable output, so auto_update.sh reads text in two
places: the `--check` verdict (classify_verdicts) and the `--yes` error veto (yes_error_line). This
tool answers "did ANY official release print something those rules misjudge?" for every release,
not just the newest one, and keeps a snapshot (verify/upstream_corpus.json) as the baseline for a
later daily upstream wording diff.

What it does (upstream repo is only READ: `git tag`, `git ls-tree`, `git show <tag>:<path>`; no
fetch, no checkout, one tag at a time):
  1. Lists the official release tags: vX.Y.Z and vYYYY.M.D[.N] exactly. rc / canary / abandoned /
     +build-metadata / backup / inputs-* and every other name are excluded (and counted).
  2. Per tag, reads the update source files: hermes_cli/update_cmd*.py, update_handoff.py,
     update_pause_record.py, source_releases.py (whole files), and from hermes_cli/main.py only the
     functions reachable from cmd_update / _cmd_update_impl / _cmd_update_check (same-module call
     graph: older releases kept the whole updater in main.py).
  3. Extracts every print(...) with `ast`: literal text kept, every f-string / %-format / .format /
     concatenation / non-literal operand becomes a placeholder <<expr>>. print(a, b) joins with sep.
  4. Check (a): every template reachable from _cmd_update_check (the --check code path, call graph
     over the scanned files) is split into lines, placeholders are instantiated with the real
     upstream value shapes (labels per source_releases.py, counts, refs), and each line is fed to
     the REAL classify_line of auto_update.sh (bash, the function text is extracted, not copied).
     A line that announces a check conclusion (CONCLUSION_RE) and classifies `unknown` = FAIL.
  5. Check (b): every template line (placeholders replaced by a neutral token) is fed to the REAL
     yes_error_line of auto_update.sh. Every hit is listed. A hit must be accounted for in
     verify/upstream_error_review.json: "error" = the sentence reports a failure (the veto is
     right), or "exempt" = a normal sentence that auto_update.sh's exemption table must let pass
     (the gate re-runs it and requires the shell to pass it). An unreviewed hit = FAIL.

Limits (see FIX-RESULT / README): only print() calls are seen. Output through logger, sys.stdout
.write, rich consoles, subprocesses (pip, git, npm, systemctl) and strings built far away from the
print call (a variable holding a message) is invisible or reduced to a placeholder; print(end="")
joins are not reconstructed.
"""
import argparse
import ast
import json
import os
import re
import subprocess
import sys
import warnings

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DEFAULT_REPO = "/home/computebox/.hermes/hermes-agent"
SNAPSHOT = os.path.join(ROOT, "verify", "upstream_corpus.json")
REVIEW = os.path.join(ROOT, "verify", "upstream_error_review.json")
SNAPSHOT_MAX = 512 * 1024

OFFICIAL = re.compile(r"^v(\d+\.\d+\.\d+|\d{4}\.\d{1,2}\.\d{1,2}(\.\d+)?)$")
WHOLE_FILES = re.compile(r"^hermes_cli/(update_cmd[A-Za-z0-9_]*\.py|update_handoff\.py|update_pause_record\.py|source_releases\.py)$")
MAIN_PY = "hermes_cli/main.py"
YES_ROOTS = ("cmd_update", "_cmd_update_impl")
CHECK_ROOTS = ("_cmd_update_check",)
PH_L, PH_R = "<<", ">>"
# A --check line that announces a conclusion (the verdict family). Such a line must classify as a
# verdict (or a known context line), never `unknown`.
CONCLUSION_RE = re.compile(r"(up to date|update available|release available|holding at this build|"
                           r"no newer release|newer than the selected release)", re.I)


def git(repo, *args):
    return subprocess.run(["git", "-C", repo] + list(args), capture_output=True, text=True,
                          check=True).stdout


def official_tags(repo):
    tags = [t for t in git(repo, "tag", "--list").split("\n") if t]
    keep = [t for t in tags if OFFICIAL.match(t)]
    excluded = {}
    for t in tags:
        if t in keep:
            continue
        low = t.lower()
        k = ("abandoned" if "abandoned" in low else "canary" if "canary" in low else
             "rc" if re.search(r"(^|[^a-z])rc([^a-z]|$)", low) else
             "build-metadata" if "+" in t else "not-a-version")
        excluded[k] = excluded.get(k, 0) + 1

    def key(t):
        return [int(x) for x in t[1:].split(".")]
    keep.sort(key=lambda t: (0 if len(t[1:].split(".")[0]) == 4 else 1, key(t)))
    return keep, excluded


# ---------------------------------------------------------------- template extraction
def _ph(node):
    try:
        return PH_L + ast.unparse(node) + PH_R
    except Exception:
        return PH_L + "?" + PH_R


def _pct(fmt, node):
    # "%s ..." % x -> placeholders for each conversion
    return re.sub(r"%(\([^)]*\))?[-#0 +]*(\*|\d+)?(\.(\*|\d+))?[diouxXeEfFgGcrsa%]",
                  lambda m: "%" if m.group(0) == "%%" else _ph(node), fmt)


def tmpl(node):
    """Template text of an expression that produces a string."""
    if isinstance(node, ast.Constant):
        return node.value if isinstance(node.value, str) else _ph(node)
    if isinstance(node, ast.JoinedStr):
        out = []
        for v in node.values:
            if isinstance(v, ast.Constant):
                out.append(str(v.value))
            elif isinstance(v, ast.FormattedValue):
                out.append(_ph(v.value))
            else:
                out.append(_ph(v))
        return "".join(out)
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
        return tmpl(node.left) + tmpl(node.right)
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Mod) and \
            isinstance(node.left, ast.Constant) and isinstance(node.left.value, str):
        return _pct(node.left.value, node.right)
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and \
            node.func.attr == "format" and isinstance(node.func.value, ast.Constant) and \
            isinstance(node.func.value.value, str):
        return re.sub(r"\{[^{}]*\}", PH_L + "fmt" + PH_R, node.func.value.value)
    if isinstance(node, ast.IfExp):
        # both branches are possible output: keep the first, note the second as its own print
        return tmpl(node.body)
    return _ph(node)


def print_templates(call):
    """All templates one print(...) call can produce (IfExp args fan out)."""
    sep = " "
    for kw in call.keywords:
        if kw.arg == "sep" and isinstance(kw.value, ast.Constant) and isinstance(kw.value.value, str):
            sep = kw.value.value
    variants = [[]]
    for a in call.args:
        if isinstance(a, ast.Starred):
            alts = [_ph(a.value)]
        elif isinstance(a, ast.IfExp):
            alts = [tmpl(a.body), tmpl(a.orelse)]
        else:
            alts = [tmpl(a)]
        variants = [v + [x] for v in variants for x in alts]
    return [sep.join(v) for v in variants]


def is_print(call):
    return isinstance(call.func, ast.Name) and call.func.id == "print"


def called_names(fn):
    names = set()
    for n in ast.walk(fn):
        if isinstance(n, ast.Call):
            f = n.func
            if isinstance(f, ast.Name):
                names.add(f.id)
            elif isinstance(f, ast.Attribute):
                names.add(f.attr)
    return names


class TagScan:
    def __init__(self, repo, tag):
        self.repo, self.tag = repo, tag
        self.funcs = {}      # name -> [(path, FunctionDef)]
        self.trees = {}      # path -> ast.Module
        self.errors = []

    def load(self):
        paths = [p for p in git(self.repo, "ls-tree", "-r", "--name-only", self.tag, "--", "hermes_cli").split("\n") if p]
        for p in paths:
            if not (WHOLE_FILES.match(p) or p == MAIN_PY):
                continue
            try:
                src = git(self.repo, "show", "%s:%s" % (self.tag, p))
                with warnings.catch_warnings():   # upstream's own invalid-escape warnings
                    warnings.simplefilter("ignore", SyntaxWarning)
                    tree = ast.parse(src)
            except Exception as e:  # syntax a newer/older Python cannot parse, unreadable blob
                self.errors.append("%s: %s" % (p, type(e).__name__))
                continue
            self.trees[p] = tree
            for n in ast.walk(tree):
                if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)):
                    self.funcs.setdefault(n.name, []).append((p, n))
            del src

    def closure(self, roots):
        seen, todo = set(), [r for r in roots if r in self.funcs]
        while todo:
            name = todo.pop()
            if name in seen:
                continue
            seen.add(name)
            for _, fn in self.funcs.get(name, ()):
                for c in called_names(fn):
                    if c in self.funcs and c not in seen:
                        todo.append(c)
        return seen

    def prints(self):
        """[(path, line, template, reach)] with reach a subset of {'check', 'yes'}."""
        yes_set, check_set = self.closure(YES_ROOTS), self.closure(CHECK_ROOTS)
        owner = {}  # id(print node) -> innermost function name
        for p, tree in self.trees.items():
            def walk(node, fn_name):
                for ch in ast.iter_child_nodes(node):
                    nm = ch.name if isinstance(ch, (ast.FunctionDef, ast.AsyncFunctionDef)) else fn_name
                    if isinstance(ch, ast.Call) and is_print(ch):
                        owner[id(ch)] = (p, nm, ch)
                    walk(ch, nm)
            walk(tree, None)
        out = []
        for p, fn_name, call in owner.values():
            reach = set()
            if fn_name in yes_set:
                reach.add("yes")
            if fn_name in check_set:
                reach.add("check")
            if p == MAIN_PY and not reach:
                continue   # main.py: only the updater's own functions
            for t in print_templates(call):
                out.append((p, call.lineno, t, sorted(reach)))
        out.sort(key=lambda x: (x[0], x[1]))
        return out


# ---------------------------------------------------------------- shell rules (the REAL code)
def shell_fn_text(script, names):
    """Extract top-level shell function / variable definitions from auto_update.sh verbatim."""
    src = open(script, encoding="utf-8").read().split("\n")
    out = []
    for name in names:
        fn = re.compile(r"^%s\(\) \{" % re.escape(name))
        var = re.compile(r"^%s=" % re.escape(name))
        found = False
        for i, line in enumerate(src):
            if fn.match(line):
                j = i
                while src[j] != "}":
                    j += 1
                out.extend(src[i:j + 1]); found = True; break
            if var.match(line):
                out.append(line); found = True; break
        if not found:
            raise SystemExit("auto_update.sh: definition of %s not found" % name)
    return "\n".join(out) + "\n"


CHECK_DEFS = ("_V_LBL", "_V_LBL_AHEAD", "_V_REF", "V_UPTODATE", "V_HELD", "V_ROLLBACK", "V_AVAILABLE",
              "V_CONTEXT", "classify_line")
YES_DEFS = ("RE_YES_ERROR", "V_YES_EXEMPT", "yes_trim", "yes_exempt_line", "yes_error_line")


def run_shell(defs, body, lines):
    data = "\n".join(l.replace("\n", " ") for l in lines) + "\n"
    p = subprocess.run(["bash", "-c", defs + body], input=data, capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    if p.returncode != 0:
        raise SystemExit("shell rule runner failed: %s" % p.stderr[-500:])
    res = p.stdout.split("\n")[:len(lines)]
    if len(res) != len(lines):
        raise SystemExit("shell rule runner returned %d results for %d lines" % (len(res), len(lines)))
    return res


def classify_lines(script, lines):
    body = 'while IFS= read -r l; do classify_line "$l"; printf "%s\\n" "$CL"; done\n'
    return run_shell(shell_fn_text(script, CHECK_DEFS), body, lines)


def error_lines(script, lines, exempt=True):
    """yes_error_line verdict per line. exempt=False runs the bare word rule (V_YES_EXEMPT emptied),
    so the review covers every line the rule itself hits."""
    body = 'while IFS= read -r l; do if yes_error_line "$l" >/dev/null; then echo hit; else echo pass; fi; done\n'
    defs = shell_fn_text(script, YES_DEFS) + ("" if exempt else "V_YES_EXEMPT=''\n")
    return run_shell(defs, body, lines)


# ---------------------------------------------------------------- placeholder instantiation
LABEL = "stable v0.23.2 (ae2a81ccc00e)"
AHEAD = ("stable v0.23.2; this checkout is newer and waits for the next release "
         "(`hermes update --set-channel main` follows every commit)")
PH = re.compile(re.escape(PH_L) + r"(.*?)" + re.escape(PH_R))


def instantiate_check(line):
    """Real value shapes for --check placeholders (source_releases.py:61-65 labels, counts, refs)."""
    def sub(m):
        e = m.group(1).lower()
        if "label" in e:
            return AHEAD if "no newer release" in line.lower() else LABEL
        # the plural word: f"{behind} {commits_word}" / f"{'commit' if behind == 1 else 'commits'}"
        if "word" in e or "'commit'" in e or '"commit"' in e:
            return "commits"
        if re.search(r"count|behind|\bn\b|len\(", e):
            return "3"
        if "'s' if" in e or '"s" if' in e:
            return "s"
        if "remote" in e:
            return "origin"
        if re.search(r"ref|branch|upstream|compare|target", e):
            return "origin/main"
        if "channel" in e:
            return "stable"
        if "sha" in e or "commit" in e:
            return "ae2a81ccc00e"
        if "cmd" in e or "command" in e:
            return "hermes update"
        return "X"
    return PH.sub(sub, line)


def neutral(line):
    return PH.sub("◇", line)


# ---------------------------------------------------------------- main
def scan(repo, full_out=None):
    tags, excluded = official_tags(repo)
    corpus = {}
    for tag in tags:                      # serial: the host is memory-tight
        ts = TagScan(repo, tag)
        ts.load()
        corpus[tag] = {"prints": [["%s:%d" % (p, ln), t, r] for p, ln, t, r in ts.prints()],
                       "errors": ts.errors}
        del ts
    if full_out:
        with open(full_out, "w", encoding="utf-8") as f:
            json.dump({t: [[w, s] for w, s, _ in v["prints"]] for t, v in corpus.items()}, f,
                      ensure_ascii=False, indent=0)
    return tags, excluded, corpus


def dedupe(tags, excluded, corpus):
    order = {t: i for i, t in enumerate(tags)}
    seen = {}
    for tag in tags:
        for where, t, reach in corpus[tag]["prints"]:
            e = seen.setdefault(t, {"t": t, "reach": set(), "first": tag, "last": tag, "n": 0, "at": {}})
            e["reach"].update(reach)
            if order[tag] < order[e["first"]]:
                e["first"] = tag
            if order[tag] > order[e["last"]]:
                e["last"] = tag
            e["n"] += 1 if tag not in e.setdefault("_tags", set()) else 0
            e["_tags"].add(tag)
            e["at"][tag] = where
    out = []
    for e in seen.values():
        at = e["at"]
        out.append({"t": e["t"], "reach": sorted(e["reach"]), "first": e["first"], "last": e["last"],
                    "tags": len(e["_tags"]), "at": "%s@%s" % (at[e["last"]], e["last"])})
    out.sort(key=lambda x: (x["at"], x["t"]))
    return {"schema": 1, "tool": "scripts/upstream_print_corpus.py", "tags": tags,
            "excluded_tags": excluded, "parse_errors": {t: v["errors"] for t, v in corpus.items() if v["errors"]},
            "prints_per_tag": {t: len(corpus[t]["prints"]) for t in tags},
            "templates": out}


def rv_get(review, ln):
    return (review.get("lines", {}).get(ln) or {}).get("verdict")


def vacuity(snap):
    """B1102 (PATCH5): a scan that could not read a source, found no print() in a tag, or produced an
    empty (a) / (b) corpus proves nothing; it must fail, never PASS. Returns (report lines, fails).
    Missing keys count as failures too (a hand-edited or truncated snapshot)."""
    rep, fails = [], 0
    pe = snap.get("parse_errors")
    if not isinstance(pe, dict):
        rep.append("  VACUOUS: snapshot has no parse_errors table"); fails += 1
    else:
        for tag, errs in sorted(pe.items()):
            if errs:
                rep.append("  FAIL parse error(s) in %s: %s" % (tag, "; ".join(map(str, errs)))); fails += 1
    ppt = snap.get("prints_per_tag")
    tags = snap.get("tags") or []
    if not isinstance(ppt, dict) or not tags:
        rep.append("  VACUOUS: snapshot has no tags / prints_per_tag"); fails += 1
    else:
        for tag in tags:
            if not ppt.get(tag):
                rep.append("  FAIL tag %s: 0 print() templates found (unreadable or moved source)" % tag); fails += 1
    if not snap.get("templates"):
        rep.append("  VACUOUS: 0 distinct templates"); fails += 1
    return rep, fails


def checks(snap, script, review):
    """Run (a) and (b) on the deduplicated templates. Returns (report lines, fail count)."""
    rep, fails = vacuity(snap)
    # (a) --check templates
    a_rows = []
    for e in snap["templates"]:
        if "check" not in e["reach"]:
            continue
        for ln in e["t"].split("\n"):
            if ln.strip():
                a_rows.append((e, ln, instantiate_check(ln)))
    cls = classify_lines(script, [r[2] for r in a_rows])
    registered = review.get("check_registered", {})
    a_bad = []
    verdict_count = {}
    for (e, ln, inst), cl in zip(a_rows, cls):
        if CONCLUSION_RE.search(inst):
            verdict_count[cl] = verdict_count.get(cl, 0) + 1
            if cl == "unknown":
                a_bad.append((e, ln, inst))
    rep.append("(a) --check templates: %d lines from %d templates; conclusion lines by verdict: %s"
               % (len(a_rows), len({id(r[0]) for r in a_rows}), json.dumps(verdict_count, sort_keys=True)))
    if not a_rows or not verdict_count:
        rep.append("  (a) VACUOUS: no --check template line / no conclusion line was checked")
        fails += 1
    for e, ln, inst in a_bad:
        if ln in registered:
            # A known finding, registered for adjudication (the --check rules are not changed by
            # this tool's author). Stays visible in every run.
            rep.append("  (a) REGISTERED (not fixed, fails closed): %r  [%s, tags %s..%s] — %s"
                       % (inst, e["at"], e["first"], e["last"], registered[ln].get("why", "")))
        else:
            rep.append("  (a) FAIL conclusion judged unknown: %r  [%s, tags %s..%s]" % (inst, e["at"], e["first"], e["last"]))
            fails += 1
    # (b) error rule over every template line
    b_rows = []
    for e in snap["templates"]:
        for ln in e["t"].split("\n"):
            if ln.strip():
                b_rows.append((e, ln, neutral(ln)))
    if not b_rows:
        rep.append("  (b) VACUOUS: no template line was checked")
        fails += 1
    res = error_lines(script, [r[2] for r in b_rows], exempt=False) if b_rows else []
    hits = {}
    for (e, ln, nl), r in zip(b_rows, res):
        if r == "hit":
            hits.setdefault(ln, e)
    # With the exemption table active, every line reviewed as an error must STILL be vetoed (the
    # table must not swallow a failure line).
    err_lines = [ln for ln in hits if rv_get(review, ln) == "error"]
    swallowed = []
    if err_lines:
        for ln, r in zip(err_lines, error_lines(script, [neutral(l) for l in err_lines])):
            if r != "hit":
                swallowed.append(ln)
    rv = review.get("lines", {})
    unreviewed, exempt_bad, n_err, n_ex = [], [], 0, 0
    for ln, e in sorted(hits.items(), key=lambda kv: kv[1]["at"]):
        v = rv.get(ln)
        if v is None:
            unreviewed.append((ln, e))
        elif v.get("verdict") == "error":
            n_err += 1
        elif v.get("verdict") == "exempt":
            n_ex += 1
        else:
            unreviewed.append((ln, e))
    # exempt sentences must really pass the shell (instantiated with the reviewed sample)
    ex_samples = [(ln, v["sample"]) for ln, v in rv.items() if v.get("verdict") == "exempt"]
    if ex_samples:
        res2 = error_lines(script, [s for _, s in ex_samples])
        for (ln, s), r in zip(ex_samples, res2):
            if r != "pass":
                exempt_bad.append((ln, s))
    stale = [ln for ln in rv if ln not in hits]
    rep.append("(b) error rule: %d template lines scanned, %d distinct lines hit: %d reviewed as error, "
               "%d exempt (normal sentence), %d UNREVIEWED; %d review entries no longer hit"
               % (len(b_rows), len(hits), n_err, n_ex, len(unreviewed), len(stale)))
    for ln, e in unreviewed:
        rep.append("  (b) FAIL unreviewed hit: %r  [%s, tags %s..%s]" % (ln, e["at"], e["first"], e["last"]))
        fails += 1
    for ln, s in exempt_bad:
        rep.append("  (b) FAIL exempt sentence still vetoed by auto_update.sh: %r (sample %r)" % (ln, s))
        fails += 1
    for ln in swallowed:
        rep.append("  (b) FAIL error line passed by the exemption table: %r" % ln)
        fails += 1
    rep.append("(b) with the exemption table active: %d/%d exempt samples pass, %d/%d error lines still vetoed"
               % (len(ex_samples) - len(exempt_bad), len(ex_samples), len(err_lines) - len(swallowed), len(err_lines)))
    for ln in stale:
        rep.append("  (b) note: review entry no longer produced by any scanned template: %r" % ln)
    return rep, fails, hits


def main():
    ap = argparse.ArgumentParser(description="Read-only scan of every official upstream release's update print() templates.")
    ap.add_argument("--repo", default=DEFAULT_REPO)
    ap.add_argument("script", nargs="?", default=os.path.join(ROOT, "auto_update.sh"),
                    help="the auto_update.sh whose rules are checked (default: the bundle's)")
    ap.add_argument("--snapshot", default=SNAPSHOT)
    ap.add_argument("--review", default=REVIEW)
    ap.add_argument("--write-snapshot", action="store_true")
    ap.add_argument("--full-out", default=None, help="also write the full corpus tag -> [file:line, template]")
    ap.add_argument("--gate", action="store_true", help="check the stored snapshot only (no upstream repo needed)")
    ap.add_argument("--list-hits", action="store_true")
    a = ap.parse_args()

    review = json.load(open(a.review, encoding="utf-8")) if os.path.exists(a.review) else {"lines": {}}
    if a.gate:
        snap = json.load(open(a.snapshot, encoding="utf-8"))
        print("snapshot: %s (%d bytes), %d official tags %s..%s, %d distinct templates"
              % (os.path.relpath(a.snapshot, ROOT), os.path.getsize(a.snapshot), len(snap["tags"]),
                 snap["tags"][0], snap["tags"][-1], len(snap["templates"])))
        if len(snap["tags"]) < 2:
            print("SNAPSHOT VACUOUS: fewer than 2 tags"); return 1
    else:
        tags, excluded, corpus = scan(a.repo, a.full_out)
        if not tags:
            print("UPSTREAM CORPUS: FAIL (no official release tag in %s)" % a.repo)
            return 1
        snap = dedupe(tags, excluded, corpus)
        print("upstream: %s" % a.repo)
        print("official tags: %d (%s .. %s); excluded: %s"
              % (len(tags), tags[0], tags[-1], json.dumps(excluded, sort_keys=True)))
        print("prints per tag: min %d, max %d; distinct templates %d; tags with parse errors: %d"
              % (min(snap["prints_per_tag"].values()), max(snap["prints_per_tag"].values()),
                 len(snap["templates"]), len(snap["parse_errors"])))
        for t in tags:
            print("  %-14s prints=%d" % (t, snap["prints_per_tag"][t]))
        if a.write_snapshot:
            body = json.dumps(snap, ensure_ascii=False, indent=0, sort_keys=True)
            if len(body.encode()) > SNAPSHOT_MAX:
                raise SystemExit("snapshot %d bytes > %d" % (len(body.encode()), SNAPSHOT_MAX))
            with open(a.snapshot, "w", encoding="utf-8") as f:
                f.write(body + "\n")
            print("snapshot written: %s (%d bytes)" % (a.snapshot, len(body.encode()) + 1))
    rep, fails, hits = checks(snap, a.script, review)
    for l in rep:
        print(l)
    if a.list_hits:
        for ln, e in sorted(hits.items(), key=lambda kv: kv[1]["at"]):
            print("HIT\t%s\t%s..%s\t%s" % (e["at"], e["first"], e["last"], ln))
    print("UPSTREAM CORPUS: %s" % ("PASS" if fails == 0 else "FAIL (%d)" % fails))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
