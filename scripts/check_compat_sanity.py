#!/usr/bin/env python3
"""Hermetic compat probe for auto_update.sh (issue #1 behaviour).

Usage: python3 scripts/check_compat_sanity.py path/to/auto_update.sh

Runs the REAL script, unmodified, as a bash subprocess. Each scenario gets a fresh root from
tempfile.mkdtemp() (honours TMPDIR, no hardcoded /tmp) holding a fake HOME. Stubs for
hermes / curl / systemctl / date sit FIRST on PATH, and the hermes stub is also installed as
the script's FIRST absolute candidate ($HOME/.hermes/venvs/hermes-dev/bin/hermes), so the
real binary cannot win. Every run asserts the stub was invoked. No network, no real systemd.

No-op output without a fresh install receipt (exit 0, silent, nothing marked installed) is the
INTENDED conservative behaviour; completion text without a fresh receipt is UNPROVEN.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

SRC = ""
BASH = shutil.which("bash") or "/bin/bash"
REAL_DATE = shutil.which("date") or "/bin/date"
T0 = 1800000000
DAY = 86400
CHECK_INTERVAL = DAY - 3600   # AU_CHECK_ALERT_INTERVAL default since PATCH2 (B501/B600)

HERMES = r'''#!@PY@ -I
import datetime, json, os, sys
ROOT = @ROOT@
args = sys.argv[1:]
with open(os.path.join(ROOT, "hermes.calls"), "a") as f:
    f.write(" ".join(args) + "\n")
sc = json.load(open(os.path.join(ROOT, "scenario.json")))
key = {"--check": "check", "--yes": "yes"}.get(args[1] if len(args) > 1 and args[0] == "update" else "")
if key not in sc:
    sys.stderr.write("stub: unexpected args %r\n" % args)
    sys.exit(3)
step = sc[key]
if step.get("receipt") is not None:
    d = dict(step["receipt"])
    # PATCH5 harness options, both opt-in per step (upstream behaviour proven in evidence-patch5):
    #   correlate: copy the launcher's HERMES_UPDATE_CORRELATION_ID into correlation_id, as
    #              update_receipt.py:141,159 (v0.21.6..v0.23.2) does;
    #   head_sha:  pre_update / post_update = the checkout HEAD (sha + 8-char short_sha), as the
    #              real no-op receipt records it (version_info.get_code_identity).
    if step.get("correlate"):
        d["correlation_id"] = os.environ.get("HERMES_UPDATE_CORRELATION_ID", "")
    if step.get("head_sha"):
        import subprocess
        h = subprocess.run(["git", "-C", os.environ["AU_REPO_DIR"], "rev-parse", "HEAD"],
                           capture_output=True, text=True, check=True).stdout.strip()
        for side in ("pre_update", "post_update"):
            d[side] = dict(d.get(side) or {}, sha=h, short_sha=h[:8])
    d.setdefault("finished_at", datetime.datetime.now(datetime.timezone.utc).isoformat())
    p = os.path.join(ROOT, "home", ".hermes", "logs", "update_receipts")
    os.makedirs(p, exist_ok=True)
    with open(os.path.join(p, "latest.json"), "w") as f:
        json.dump(d, f)
sys.stdout.write(step.get("out", ""))
sys.stdout.flush()
sys.exit(step.get("rc", 0))
'''

CURL = r'''#!@PY@ -I
import json, os, sys
ROOT = @ROOT@
a = sys.argv[1:]
text = None
for i in range(len(a) - 1):
    if a[i] == "--data-urlencode" and a[i + 1].startswith("text="):
        text = a[i + 1][5:]
with open(os.path.join(ROOT, "curl.calls"), "a") as f:
    f.write(json.dumps({"args": a, "text": text}) + "\n")
if os.path.exists(os.path.join(ROOT, "curl_fail")):
    sys.exit(7)
print('{"ok":true,"result":{"message_id":1}}')
'''

SYSTEMCTL = '''#!/bin/sh
case " $* " in *" --quiet "*) exit 0 ;; esac
echo active
'''

DATE = '''#!/bin/sh
if [ "$#" -eq 1 ] && [ "$1" = "+%s" ] && [ -s "@ROOTSH@/now" ]; then cat "@ROOTSH@/now"; exit 0; fi
exec "@DATE@" "$@"
'''

BANNER = "→ Update channel: stable\n"
# Exact upstream shape (update_cmd_check.py:123; label per source_releases.py:61-65).
STABLE_AVAIL = BANNER + "→ Selected release available: stable v1.3.0 (abc1234def56)\n"
LEGACY_AVAIL = "⚕ Update available: 3 commits behind origin/main.\n  Run 'hermes update' to install.\n"
DONE_NEW = "→ Fetching v1.3.0\n✓ Update complete! (v1.2.3 → v1.3.0) [detached @ abc1234]\n"
DONE_OLD = "✓ Update complete! (v9.9.9)\n"
NOOP = "✓ Already up to date.\n"   # --check sentence ONLY (update_cmd_check.py:200/:208/:222)
GOOD = {"kind": "update", "outcome": "success",
        "pre_update": {"short_sha": "aaaaaaaa"}, "post_update": {"short_sha": "bbbbbbbb"}}
CHECK_FAIL = "✗ fetch failed: HTTP 429\n"
ALERT = "⚠ hermes auto-update: update check"

# Exact upstream `hermes update --check` shapes (hermes_cli/update_cmd_check.py; labels from
# source_releases.py:61-65). Used by the v5.15 regressions below.
LBL = "stable v0.23.1 (ae2a81ccc00e)"
AHEAD_LBL = ("stable v0.23.1; this checkout is newer and waits for the next release"
             " (`hermes update --set-channel main` follows every commit)")
UP_AVAIL = BANNER + "→ Selected release available: %s\n  Run `hermes update` to install it.\n" % LBL
UP_HELD = (BANNER + "→ Holding at this build: %s predates the gateway runtime your sessions use.\n"
           "  `hermes update` stays on this build; the next release that includes the runtime installs"
           " normally (`hermes update --set-channel main` follows every commit).\n" % LBL)
UP_ROLLBACK = (BANNER + "→ This checkout is newer than the selected release: %s.\n"
               "  `hermes update` moves it back to that release (`hermes update --set-channel main`"
               " follows every commit).\n" % LBL)
# Verbatim capture of a real `hermes update --check` (stable channel, v0.23.2 available).
REAL_CHECK = ("→ Update channel: stable\n→ Selected release available: stable v0.23.2 (ae2a81ccc00e)\n"
              "  Run `hermes update` to install it.\n")
# --yes no-op conclusions, exactly as upstream prints them (update_cmd.py:1730/:1731/:1915 at
# origin/main 67e4d22; :1726/:1727/:1911 in v0.23.1), optional " [<branch> @ <sha>]" suffix from
# _print_update_completion (update_cmd_maint.py:304-311, update_cmd_git.py:172-175).
YES_NOOP = "✓ Already up to date!\n"
YES_HELD = "✓ Holding at this build until a newer stable release ships.\n"
YES_FORK = "✓ Up to date with your fork (official repo not checked). [main @ 1a2b3c4]\n"
# A complete no-op `hermes update --yes` run, line by line in upstream print order (origin/main):
#   update_cmd.py:1810-1811 banner; update_cmd_maint.py:708/:737-740 pre-update backup;
#   update_cmd_check.py:252 channel, :267 "Latest release"; update_cmd.py:1893 fetch;
#   commit_count == 0 -> _finish_already_up_to_date -> completion tail: update_cmd_maint.py:1022
#   history, :1030 model catalog, :1047-1049 skills (+ :516), update_cmd_config.py:180-181/:256
#   config, :1062-1063 conclusion line; then the fleet restart, update_cmd_fleet.py:1627-1629.
REAL_YES_NOOP = (
    "☤ Updating Hermes Agent...\n\n"
    "◆ Creating pre-update backup...\n"
    "  Saved:    ~/hermes-backups/pre-update-20261118.zip (12.0 MB, 1.2s)\n"
    "  Restore:  hermes import ~/hermes-backups/pre-update-20261118.zip\n"
    "  Disable:  set updates.pre_update_backup: quick (or off) in config.yaml\n\n"
    "→ Update channel: stable\n"
    "→ Latest release: stable v0.23.2 (ae2a81ccc00e)\n"
    "→ Fetching updates...\n"
    "  ✓ Fetched release history (commits only) for version identity\n"
    "  ✓ Model catalog cache refreshed from checkout\n\n"
    "→ Syncing bundled skills...\n"
    "  ✓ Skills are up to date\n\n"
    "→ Checking configuration for new options...\n"
    "  ✓ Configuration is up to date\n\n"
    "✓ Already up to date! [detached @ ae2a81c]\n\n"
    "  ✓ Restarted hermes-gateway.service\n")
# The held no-op: hold_channel_release_behind_runtime (update_cmd_check.py:323-326) then the
# held_message conclusion (update_cmd.py:1915), same tail.
REAL_YES_HELD = (
    "☤ Updating Hermes Agent...\n\n"
    "→ Update channel: stable\n"
    "→ Latest release: stable v0.23.1 (ae2a81ccc00e)\n"
    "→ Fetching updates...\n"
    "→ This build is newer than the stable release ae2a81ccc00e: that release predates the gateway"
    " runtime your sessions use, so there is nothing to update to yet.\n"
    "  Hermes stays on 67e4d22d83b2 until a newer stable release ships. To follow every commit"
    " instead: `hermes update --set-channel main`.\n\n"
    "→ Syncing bundled skills...\n"
    "  ✓ Skills are up to date\n\n"
    "→ Checking configuration for new options...\n"
    "  ✓ Configuration is up to date\n\n"
    "✓ Holding at this build until a newer stable release ships. [detached @ 67e4d22]\n")
# B701: the two former REAL_YES_FORK ingredients come from DIFFERENT control flows, so they are two
# fixtures now. Each follows one upstream path (origin/main 67e4d22); the step tail is the same
# composed tail as above, not a recorded run.
# (a) The forward-only "ahead" default subscription: update_cmd_check.py:267 "Release: <ahead
#     label>"; release_sha with target_is_head -> no fetch (update_cmd.py:1881-1883); the release
#     plan returns upstream_checked=True (update_cmd.py:1399-1405), so the conclusion is
#     "Already up to date!" (:1730), never the fork sentence (r4A fixture-consistency.py).
REAL_YES_AHEAD = (
    "☤ Updating Hermes Agent...\n\n"
    "→ Update channel: stable\n"
    "→ Release: stable v0.23.2; this checkout is newer and waits for the next release"
    " (`hermes update --set-channel main` follows every commit)\n\n"
    "→ Syncing bundled skills...\n"
    "  ✓ Skills are up to date\n\n"
    "✓ Already up to date! [main @ 1a2b3c4]\n")
# (b) A fork on the main channel with no upstream remote, run with --yes: the main channel prints
#     only the channel line (no release target), "→ Fetching updates..." (update_cmd.py:1893),
#     commit_count == 0 and is_fork and branch == "main" and not release_tag -> fork sync
#     (update_cmd.py:1440) -> no upstream remote -> _offer_upstream_remote prints the notice and,
#     because assume_yes, skips at update_cmd_git.py:343-349 (never reaching :362 "Adding upstream
#     remote") and returns False -> upstream_checked=False -> update_cmd.py:1731.
REAL_YES_FORK = (
    "☤ Updating Hermes Agent...\n\n"
    "→ Update channel: main\n"
    "→ Fetching updates...\n\n"
    "ℹ Your fork is not tracking the official Hermes repository.\n"
    "  This means you may miss updates from NousResearch/hermes-agent.\n\n"
    "  Skipping upstream setup (non-interactive run).\n"
    "  Add it later with: git remote add upstream https://github.com/NousResearch/hermes-agent.git\n\n"
    "→ Syncing bundled skills...\n"
    "  ✓ Skills are up to date\n\n"
    "✓ Up to date with your fork (official repo not checked). [main @ 1a2b3c4]\n")
# B700: legacy no-op runs. stdout of the REAL functions, extracted and executed by r4A
# (evidence-r4A/legacy-noop.py, healthy commit_count == 0 branch, side effects faked):
#   v2026.7.20 hermes_cli/main.py _cmd_update_impl :9958 banner, :10083 fetch, :10256 conclusion
#   v2026.3.12 hermes_cli/main.py cmd_update :1608 banner, :1639 fetch, :1667 conclusion
LEGACY_YES_NOOP_0720 = "⚕ Updating Hermes Agent...\n\n→ Fetching updates...\n✓ Already up to date!\n"
LEGACY_YES_NOOP_0312 = "⚕ Updating Hermes Agent...\n\n→ Fetching updates...\n✓ Already up to date!\n"
# The no-op tail with every keyword-bearing upstream step report it can print, each verbatim:
# update_receipt.py:1244 fleet row, update_cmd_maint.py:185-195 search-index notice (printed by
# _print_post_update_notices_and_self_heals after the conclusion, update_cmd_maint.py:1072),
# source_build.py:276/:282/:350, update_cmd_git.py:421.
REAL_YES_NOOP_TAIL = (REAL_YES_NOOP
    + "  ✓ default (pid 4242) @ ae2a81c — up to date\n"
    "  ✓ TUI is up to date\n  ✓ Web UI is up to date\n"
    "  ✓ Desktop app is up to date: no desktop build input changed since ae2a81ccc00e\n"
    "  ✓ Fork is up to date with upstream\n"
    "◆ Search index update available\n"
    "  Your search index is on the compact layout from an earlier optimization, but a later"
    " release changed it. Running the command again rebuilds it in the current layout.\n"
    "  Run when convenient:  hermes sessions optimize-storage\n")
# A real INSTALL run in upstream print order: update_cmd.py:1893 fetch, :1931 switch, :1940 pull,
# update_completion.py:427 announce "\n✓ Code updated!", the completion tail, and
# _update_complete_message (update_cmd_maint.py:356) + suffix.
REAL_YES_INSTALL = (
    "☤ Updating Hermes Agent...\n\n"
    "→ Update channel: stable\n"
    "→ Latest release: stable v0.23.2 (ae2a81ccc00e)\n"
    "→ Fetching updates...\n"
    "→ Switching to source commit ae2a81ccc0\n"
    "→ Pulling updates...\n\n"
    "✓ Code updated!\n"
    "  ✓ Fetched release history (commits only) for version identity\n\n"
    "→ Syncing bundled skills...\n"
    "  ↑ 2 updated: github-pr-workflow, plan\n\n"
    "→ Checking configuration for new options...\n"
    "  ✓ Configuration is up to date\n\n"
    "✓ Update complete! (v0.23.1 → v0.23.2) [detached @ ae2a81c]\n\n"
    "  ✓ Restarted hermes-gateway.service\n")
# A real INSTALL on a shallow main checkout: the count is unknown, so update_cmd.py:1938 prints
# "→ Updates available (…)" before :1940 "→ Pulling updates..."; the post-update notice
# update_cmd_maint.py:185 "◆ Search index update available" follows the completion line. Both
# carry an "available" keyword; the install path never goes through the no-op veto.
REAL_YES_INSTALL_SHALLOW = (
    "☤ Updating Hermes Agent...\n\n"
    "→ Update channel: main\n"
    "→ Fetching updates...\n"
    "→ Updates available (commit count unknown on this shallow checkout)\n"
    "→ Pulling updates...\n\n"
    "✓ Code updated!\n\n"
    "→ Syncing bundled skills...\n"
    "  ✓ Skills are up to date\n\n"
    "✓ Update complete! (v0.23.1 → v0.23.2) [main @ ae2a81c]\n"
    "◆ Search index update available\n"
    "  Run when convenient:  hermes sessions optimize-storage\n\n"
    "  ✓ Restarted hermes-gateway.service\n")
YES_FAIL = "✗ dependency install failed\n"
REALERT_DEFAULT = 3 * DAY - 3600         # AU_REALERT_SECS default
REMIND_DEFAULT = 7 * DAY - 3600          # AU_ROLLBACK_REMIND_SECS default

# ===================== PATCH5 (option D) fixtures: silence needs positive evidence ==============
# The REAL third-generation "already up to date" receipts: written by the exported v0.23.2 / v0.21.6
# trees' own functions (update_cmd._begin_update_receipt_and_plan / _finish_already_up_to_date /
# _complete_source_update, update_completion._finish in a child interpreter, update_receipt whole
# module), side effects stubbed, HERMES_UPDATE_CORRELATION_ID set (evidence-patch5/probes/
# receipt_noop_probe.py). Kept verbatim; the tests only re-stamp finished_at, correlation_id and the
# SHAs for their own run.
FIXTURES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "verify", "fixtures")


def real_receipt(name, now=None, **over):
    with open(os.path.join(FIXTURES, name), encoding="utf-8") as f:
        d = json.load(f)
    d.pop("finished_at", None)   # the stub stamps "now" (real clock) unless the fake clock is used
    if now is not None:
        d["finished_at"] = time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime(now + 1))
    d.update(over)
    return d


GEN3_NOOP = "receipt_noop_v0.23.2.json"
GEN3_NOOP_0216 = "receipt_noop_v0.21.6.json"
GEN3_DEPS_OWED = "receipt_noop_deps_owed_v0.23.2.json"   # same no-op, dependency step failed: still "success"
UNPROVEN = "left no receipt of this run"                   # the step-4b reminder
# evidence-r6A/source-repair.json: stdout of the REAL v2026.7.20 repair path (main.py:10245-10258,
# _venv_core_imports_healthy + _install_python_dependencies_with_optional_fallback), exit 0.
SRC_REPAIR_STILL_UNHEALTHY = (
    "⚕ Updating Hermes Agent...\n\n→ Fetching updates...\n⚠ Checkout is current, but the venv is unhealthy:\n"
    "  fastapi: No module named 'fastapi'; uvicorn: No module named 'uvicorn'; pydantic: No module named"
    " 'pydantic'; openai: No module named 'openai'\n→ Repairing Python dependencies...\n"
    "⚠ Venv still unhealthy after repair: fastapi: No module named 'fastapi'; uvicorn: No module named"
    " 'uvicorn'; pydantic: No module named 'pydantic'; openai: No module named 'openai'\n"
    "  Close all Hermes windows/gateways and re-run: hermes update\n")
# r6B (evidence-r6B-retry/harness/driver4.sh case wordgap, B1202): v0.23.2 update_cmd_maint.py:448/:925.
WORDGAP = "⚠ state.db is corrupted after update (v0.23.2): bad page\n⚠ hermes-plugin was not installed: boom\n"


class Box:
    def __init__(self):
        self.root = r = tempfile.mkdtemp(prefix="au-compat-")
        self.home = os.path.join(r, "home")
        self.state = os.path.join(self.home, ".hermes", "state", "auto_update")
        self.rdir = os.path.join(self.home, ".hermes", "logs", "update_receipts")
        venv = os.path.join(self.home, ".hermes", "venvs", "hermes-dev", "bin")
        self.repo = os.path.join(r, "repo")
        for d in (self.state, self.rdir, venv, self.repo, os.path.join(r, "bin"),
                  os.path.join(r, "tmp"), os.path.join(r, "run")):
            os.makedirs(d, exist_ok=True)
        self._w(os.path.join(self.home, ".hermes", ".env"),
                "TELEGRAM_BOT_TOKEN=123:stub\nTELEGRAM_ALLOWED_USERS=42\n")
        self.stub_hermes = os.path.join(venv, "hermes")
        b = os.path.join(r, "bin")
        for path, tmpl in ((self.stub_hermes, HERMES), (os.path.join(b, "hermes"), HERMES),
                           (os.path.join(b, "curl"), CURL), (os.path.join(b, "systemctl"), SYSTEMCTL),
                           (os.path.join(b, "date"), DATE)):
            for k, v in (("@PY@", sys.executable), ("@ROOTSH@", r), ("@ROOT@", repr(r)), ("@DATE@", REAL_DATE)):
                tmpl = tmpl.replace(k, v)
            self._w(path, tmpl)
            os.chmod(path, 0o755)
        sha = ""
        git = shutil.which("git")
        if git:
            ge = dict(os.environ, HOME=self.home, GIT_CONFIG_NOSYSTEM="1")
            subprocess.run([git, "-C", self.repo, "init", "-q"], env=ge, capture_output=True)
            subprocess.run([git, "-C", self.repo, "-c", "user.email=t@t", "-c", "user.name=t",
                            "commit", "-q", "--allow-empty", "-m", "init"], env=ge, capture_output=True)
            sha = subprocess.run([git, "-C", self.repo, "rev-parse", "HEAD"], env=ge,
                                 capture_output=True, text=True).stdout.strip()
        self.gw = os.path.join(r, "gateway_state.json")
        self._w(self.gw, json.dumps({"code_sha": sha}))

    def _w(self, p, s):
        with open(p, "w", encoding="utf-8") as f:
            f.write(s)

    def _lines(self, name):
        p = os.path.join(self.root, name)
        if not os.path.exists(p):
            return []
        with open(p, encoding="utf-8") as f:
            return f.read().splitlines()

    def st(self, name):
        p = os.path.join(self.state, name)
        if not os.path.exists(p):
            return None
        with open(p, encoding="utf-8") as f:
            return f.read().strip()

    def seed(self, name, v):
        self._w(os.path.join(self.state, name), v)

    def old_receipt(self, d):
        self._w(os.path.join(self.rdir, "latest.json"), json.dumps(d))

    def scenario(self, check, rc=0, yes=None, yes_rc=0, receipt=None, correlate=False, head_sha=False):
        sc = {"check": {"out": check, "rc": rc}}
        if yes is not None:
            sc["yes"] = {"out": yes, "rc": yes_rc, "receipt": receipt,
                         "correlate": correlate, "head_sha": head_sha}
        self._w(os.path.join(self.root, "scenario.json"), json.dumps(sc))

    def proven(self, check, yes, now=None, fixture=GEN3_NOOP, **over):
        """--yes writes the REAL gen-3 no-op receipt, correlated to this run, SHAs = the checkout."""
        self.scenario(check, yes=yes, receipt=real_receipt(fixture, now, **over), correlate=True, head_sha=True)

    def reminders(self):
        return [t for t in self.texts() if UNPROVEN in t]

    def notify_fails(self, on):
        p = os.path.join(self.root, "curl_fail")
        if on:
            self._w(p, "1")
        elif os.path.exists(p):
            os.remove(p)

    def yes_called(self):
        return any(l.startswith("update --yes") for l in self._lines("hermes.calls"))

    def texts(self):
        out = []
        for l in self._lines("curl.calls"):
            t = json.loads(l)["text"]
            if t is not None:
                out.append(t)
        return out

    def alerts(self):
        return [t for t in self.texts() if t.startswith(ALERT)]

    def log(self):
        p = os.path.join(self.home, ".hermes", "logs", "auto_update.log")
        if not os.path.exists(p):
            return ""
        with open(p, encoding="utf-8", errors="replace") as f:
            return f.read()

    def run(self, apply=None, now=None, **extra):
        nf = os.path.join(self.root, "now")
        if now is None:
            if os.path.exists(nf):
                os.remove(nf)
        else:
            self._w(nf, "%d\n" % now)
        env = {"HOME": self.home,
               "PATH": os.path.join(self.root, "bin") + ":" + os.environ.get("PATH", "/usr/bin:/bin"),
               "TMPDIR": os.path.join(self.root, "tmp"), "XDG_RUNTIME_DIR": os.path.join(self.root, "run"),
               "TZ": "UTC", "LC_ALL": "C.UTF-8", "TG_PROXY": "", "AU_CRON_UNIT": "",
               "AU_REPO_DIR": self.repo, "AU_GATEWAY_STATE": self.gw, "AU_GATEWAY_UNIT": "hermes-gateway",
               "AU_HERMES_BIN": self.stub_hermes, "AU_SETTLE_SECONDS": "0", "AU_POLL_EVERY": "0",
               "AU_POLL_TRIES": "1", "AU_CHECK_TIMEOUT": "30", "AU_UPDATE_TIMEOUT": "30", "AU_UPDATE_KILL": "5"}
        if apply is not None:
            env["AU_APPLY"] = apply
        env.update(extra)
        before = len(self._lines("hermes.calls"))
        p = subprocess.run([BASH, SRC], env=env, cwd=self.root, capture_output=True,
                           encoding="utf-8", errors="replace", timeout=120)
        if len(self._lines("hermes.calls")) <= before:
            raise AssertionError("stub hermes NOT invoked (rc=%d) - harness not sealed\n%s%s\n%s"
                                 % (p.returncode, p.stdout, p.stderr, self.log()))
        return p


class T(unittest.TestCase):
    def box(self):
        b = Box()
        self.addCleanup(shutil.rmtree, b.root, True)
        return b


class Verdicts(T):
    def test_stable_and_legacy_uptodate(self):
        # "No newer release" is printed only when target.ahead (update_cmd_check.py:109-110), whose
        # label is always the long form (source_releases.py:62-64).
        for out in (BANNER + "✓ Up to date with the latest release (stable v1.2.3 (abc1234def56)).\n",
                    BANNER + "✓ No newer release: stable v1.2.3; this checkout is newer and waits for the"
                    " next release (`hermes update --set-channel main` follows every commit).\n", NOOP):
            with self.subTest(out=out):
                b = self.box()
                b.scenario(out, yes=DONE_NEW, receipt=GOOD)
                p = b.run(apply="1")
                self.assertEqual(p.returncode, 0, b.log())
                self.assertFalse(b.yes_called())
                self.assertEqual(b.st("consec_check_fails"), "0")
                self.assertEqual(b.texts(), [])

    def test_stable_available_installs_to_arrow_destination(self):
        b = self.box()
        b.scenario(STABLE_AVAIL, yes=DONE_NEW, receipt=GOOD)
        p = b.run(apply="1")
        self.assertEqual(p.returncode, 0, b.log())
        self.assertTrue(b.yes_called())
        self.assertTrue(any("updated to v1.3.0" in t for t in b.texts()), b.texts())
        self.assertRegex(b.st("last_install_ts") or "", r"^[0-9]{9,}$")

    def test_legacy_available_installs_with_legacy_completion(self):
        b = self.box()
        b.scenario(LEGACY_AVAIL, yes=DONE_OLD, receipt={"outcome": "success"})
        p = b.run(apply="1")
        self.assertEqual(p.returncode, 0, b.log())
        self.assertTrue(b.yes_called())
        self.assertTrue(any("updated to" in t and "v9.9.9" in t for t in b.texts()), b.texts())
        self.assertRegex(b.st("last_install_ts") or "", r"^[0-9]{9,}$")

    def test_held_is_benign(self):
        b = self.box()
        b.scenario(BANNER + "→ Holding at this build: stable v1.2.3 (abc1234def56) predates the gateway"
                   " runtime your sessions use.\n", yes=DONE_NEW, receipt=GOOD)
        p = b.run(apply="1")
        self.assertEqual(p.returncode, 0, b.log())
        self.assertFalse(b.yes_called())
        self.assertEqual(b.texts(), [])
        self.assertEqual(b.st("consec_check_fails"), "0")
        self.assertIn("held (benign", b.log())

    def test_rollback_never_installs_and_notifies_once(self):
        b = self.box()
        b.scenario(BANNER + "→ This checkout is newer than the selected release: stable v1.3.0 (abc1234def56).\n",
                   yes=DONE_NEW, receipt=GOOD)
        for _ in range(2):
            self.assertEqual(b.run(apply="1").returncode, 0, b.log())
        self.assertFalse(b.yes_called())
        t = b.texts()
        self.assertEqual(len(t), 1, t)
        self.assertIn("NOT moved back", t[0])
        self.assertIsNone(b.st("last_install_ts"))


class Banners(T):
    def refused(self, out, rc=0, apply="1"):
        b = self.box()
        b.scenario(out, rc=rc, yes=DONE_NEW, receipt=GOOD)
        p = b.run(apply=apply)
        self.assertEqual(p.returncode, 0, b.log())
        self.assertFalse(b.yes_called(), "installed on: %r" % out)
        self.assertIsNone(b.st("last_install_ts"))
        return b, p

    def test_quoted_banner_is_not_a_verdict(self):
        b, _ = self.refused(BANNER + 'hint: upstream printed "Update available: v2" earlier\n'
                            "  log: cached 'Selected release available' text\n")
        self.assertEqual(b.st("consec_check_fails"), "1")

    def test_conflicting_verdicts_fail_closed(self):
        b, _ = self.refused("✓ Up to date with the latest release (stable v1.2.3 (abc1234def56)).\n"
                            "→ Selected release available: stable v1.3.0 (abc1234def56)\n")
        self.assertEqual(b.st("consec_check_fails"), "1")

    def test_error_line_beside_available_fails_closed(self):
        b, _ = self.refused("→ Selected release available: stable v1.3.0 (abc1234def56)\n✗ signature verification failed\n")
        self.assertEqual(b.st("consec_check_fails"), "1")

    def test_nonzero_check_fails_closed_despite_available_text(self):
        b, _ = self.refused("→ Selected release available: stable v1.3.0 (abc1234def56)\n✗ fetch failed: HTTP 429\n", rc=1)
        self.assertEqual(b.st("consec_check_fails"), "1")
        self.assertIn("check failed (exit 1)", b.log())

    # Noise that upstream really prints around a verdict: blank line, a `  (…)` cleanup line
    # (update_cmd_check.py:49), indentation, CRLF, and the stable hint line (:124). Indentation and
    # CRLF are normalization tests, not a verbatim capture.
    NOISY = (BANNER + "\n  (removed stale git lock: .git/shallow.lock)\n"
             "   → Selected release available: stable v1.3.0 (abc1234def56)\r\n"
             "  Run `hermes update` to install it.\n")
    # The same noise around the main-channel verdict with ITS hint (update_cmd_check.py:212/:215,
    # "  Run '{recommended_update_command()}' to install.").
    NOISY_MAIN = ("\n  (removed stale git lock: .git/shallow.lock)\n"
                  "   ⚕ Update available: 3 commits behind origin/main.\r\n"
                  "  Run 'hermes update' to install.\n")
    # The pre-5.15 NOISY input: an unrecognized line beside the verdict is unknown since v5.15.
    NOISY_UNKNOWN = (BANNER + "\nDEBUG: fetched tags in 0.2s\n"
                     "   → Selected release available: stable v1.3.0 (abc1234def56)\r\n"
                     "  Run `hermes update` to install it.\n")

    def test_noisy_main_available_installs_with_apply(self):
        b = self.box()
        b.scenario(self.NOISY_MAIN, yes=DONE_OLD, receipt={"outcome": "success"})
        self.assertEqual(b.run(apply="1").returncode, 0, b.log())
        self.assertTrue(b.yes_called())

    def test_noisy_with_unrecognized_line_fails_closed(self):
        b, _ = self.refused(self.NOISY_UNKNOWN)
        self.assertEqual(b.st("consec_check_fails"), "1")

    def test_noisy_available_is_report_only_without_apply(self):
        for apply in (None, "0", "yes", "true"):
            with self.subTest(apply=apply):
                b, p = self.refused(self.NOISY, apply=apply)
                self.assertIn("not applied", p.stdout)
                self.assertEqual(b.st("consec_check_fails"), "0")

    def test_noisy_available_installs_with_apply(self):
        b = self.box()
        b.scenario(self.NOISY, yes=DONE_NEW, receipt=GOOD)
        self.assertEqual(b.run(apply="1").returncode, 0, b.log())
        self.assertTrue(b.yes_called())


class Cadence(T):
    def failing(self):
        b = self.box()
        b.scenario(CHECK_FAIL, rc=1)
        return b

    def test_first_alert_at_third_then_daily_on_hourly_ticks(self):
        b = self.failing()
        for i in range(3):
            self.assertEqual(b.run(now=T0 + 3600 * i).returncode, 0, b.log())
            self.assertEqual(len(b.alerts()), 1 if i == 2 else 0, "after run %d" % (i + 1))
        first = T0 + 7200
        self.assertIn("(3 consecutive)", b.alerts()[0])
        self.assertEqual(b.st("check_alert_last_ts"), str(first))
        # PATCH2 (B501/B600, orchestrator ruling in ADJUDICATION-MAIN.md): the 7d2f640 assertion
        # "first + DAY - 1 is still suppressed" encoded exactly the defect being fixed: with a
        # zero-margin 86400 default, a daily tick that starts 1s early (cross-second start jitter)
        # or 1h early (local-time cron across DST) is suppressed and the reminder slips a day. The
        # default is now CHECK_INTERVAL = 86400 - 3600; these are the same assertions at that
        # boundary: CHECK_INTERVAL - 1 suppressed, CHECK_INTERVAL alerts.
        for now, want in ((first + 3600, 1), (first + CHECK_INTERVAL - 1, 1), (first + CHECK_INTERVAL, 2),
                          (first + CHECK_INTERVAL + 3600, 2), (first + 2 * CHECK_INTERVAL - 1, 2),
                          (first + 2 * CHECK_INTERVAL, 3)):
            b.run(now=now)
            self.assertEqual(len(b.alerts()), want, "at +%ds" % (now - first))
        self.assertEqual(b.st("check_alert_last_ts"), str(first + 2 * CHECK_INTERVAL))

    def test_daily_ticks_with_start_jitter_alert_every_day(self):
        # r3A check-start-jitter-daily-alert: the first tick starts 1s late, the next ones on time
        # (86399s apart). Every daily tick of a persisting failure must alert.
        b = self.failing()
        b.seed("consec_check_fails", "2")
        for i, now in enumerate((T0 + 1, T0 + DAY, T0 + 2 * DAY)):
            self.assertEqual(b.run(now=now).returncode, 0, b.log())
            self.assertEqual(len(b.alerts()), i + 1, "daily tick %d (+%ds)\n%s" % (i + 1, now - T0, b.log()))
        self.assertEqual(b.st("check_alert_last_ts"), str(T0 + 2 * DAY))

    def test_dst_short_day_still_alerts(self):
        # A local-time daily cron across the spring DST change: two ticks 23h (82800s) apart.
        b = self.failing()
        b.seed("consec_check_fails", "2")
        b.run(now=T0)
        b.run(now=T0 + 82800)
        self.assertEqual(len(b.alerts()), 2, b.log())

    def test_failed_and_unknown_share_one_counter(self):
        b = self.failing()
        b.run(now=T0)
        b.run(now=T0 + 3600)
        b.scenario("⚕ Something else entirely\n")
        b.run(now=T0 + 7200)
        a = b.alerts()
        self.assertEqual(len(a), 1, a)
        self.assertIn("unrecognized", a[0])

    def test_migration_n34_without_timestamp(self):
        b = self.failing()
        b.seed("consec_check_fails", "34")
        b.run(now=T0)
        a = b.alerts()
        self.assertEqual(len(a), 1, a)
        self.assertIn("(35 consecutive)", a[0])
        self.assertEqual(b.st("check_alert_last_ts"), str(T0))
        b.run(now=T0 + 3600)
        self.assertEqual(len(b.alerts()), 1)

    def test_garbage_overflow_future_timestamps_alert_and_self_heal(self):
        for ts in ("garbage", "", "-5", "12abc", "99999999999999999999", str(T0 + 100000)):
            with self.subTest(ts=ts):
                b = self.failing()
                b.seed("consec_check_fails", "10")
                b.seed("check_alert_last_ts", ts)
                self.assertEqual(b.run(now=T0).returncode, 0, b.log())
                self.assertEqual(len(b.alerts()), 1)
                self.assertEqual(b.st("check_alert_last_ts"), str(T0))

    def test_recent_valid_timestamp_suppresses(self):
        b = self.failing()
        b.seed("consec_check_fails", "10")
        b.seed("check_alert_last_ts", str(T0 - 100))
        b.run(now=T0)
        self.assertEqual(b.alerts(), [])
        self.assertEqual(b.st("check_alert_last_ts"), str(T0 - 100))
        self.assertEqual(b.st("consec_check_fails"), "11")
        self.assertIn("alert suppressed", b.log())

    def test_failed_notify_retries_next_tick_without_stamping(self):
        b = self.failing()
        b.seed("consec_check_fails", "2")
        b.notify_fails(True)
        b.run(now=T0)
        self.assertEqual(len(b.alerts()), 1)
        self.assertIsNone(b.st("check_alert_last_ts"), "stamped although delivery failed")
        b.run(now=T0 + 3600)
        self.assertEqual(len(b.alerts()), 2, "undelivered alert must retry next tick")
        self.assertIsNone(b.st("check_alert_last_ts"))
        b.notify_fails(False)
        b.run(now=T0 + 7200)
        self.assertEqual(len(b.alerts()), 3)
        self.assertEqual(b.st("check_alert_last_ts"), str(T0 + 7200))
        b.run(now=T0 + 10800)
        self.assertEqual(len(b.alerts()), 3)


class Summary(T):
    def test_last_install_time_and_multiline_summary(self):
        b = self.box()
        b.scenario(BANNER + "\n✗ fetch failed: HTTP 503\n  upstream: Service Unavailable\n\n  retry-after: 120\n", rc=1)
        e = 1790000000
        b.seed("last_install_ts", str(e))
        b.seed("consec_check_fails", "2")
        b.run(now=T0)
        a = b.alerts()
        self.assertEqual(len(a), 1, a)
        lines = a[0].split("\n")
        self.assertIn("(3 consecutive)", lines[0])
        self.assertEqual(lines[1], "last successful install: "
                         + time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime(e)))
        self.assertEqual(lines[2:], ["✗ fetch failed: HTTP 503", "  upstream: Service Unavailable",
                                     "  retry-after: 120"])
        self.assertNotIn("Update channel", a[0])

    def test_unknown_install_and_bounded_summary(self):
        b = self.box()
        out = "err line 01 " + "x" * 300 + "\n" + "".join("err line %02d\n" % i for i in range(2, 21))
        b.scenario(out, rc=1)
        b.seed("consec_check_fails", "2")
        b.run(now=T0)
        a = b.alerts()
        self.assertEqual(len(a), 1, a)
        lines = a[0].split("\n")
        self.assertEqual(lines[1], "last successful install: unknown")
        self.assertEqual(len(lines), 8, lines)
        self.assertTrue(all(len(l) <= 200 for l in lines[2:]))
        self.assertIn("err line 06", a[0])
        self.assertNotIn("err line 07", a[0])


class Receipts(T):
    STALE = dict(GOOD, finished_at="2020-01-01T00:00:00+00:00")

    def cases(self):
        # (label, receipt written by --yes, receipt already on disk)
        return (("missing", None, None), ("stale", None, self.STALE),
                ("foreign", {"kind": "plugin-check", "outcome": "success"}, None))

    def test_noop_without_fresh_receipt_reminds_and_unmarked(self):
        # Nothing proven installed, nothing claimed. PATCH2 (B500): the --yes inputs are upstream's
        # own --yes no-op sentences. PATCH4: sentences are no longer judged at all (YesHeadState).
        # PATCH5 (assertion changed, spec-driven; was test_noop_without_fresh_receipt_is_silent_and_
        # unmarked: exit 0, no text): no receipt of this run proves the no-op, so it is never silent:
        # one ⚠ reminder, exit 1, still never marked installed and no drain marker.
        for label, rc, old in self.cases():
            for out in (YES_NOOP, YES_HELD):
                with self.subTest(receipt=label, out=out):
                    b = self.box()
                    if old:
                        b.old_receipt(old)
                    b.scenario(STABLE_AVAIL, yes=out, receipt=rc)
                    p = b.run(apply="1")
                    self.assertTrue(b.yes_called())
                    self.assertEqual(p.returncode, 1, b.log())
                    self.assertEqual(len(b.texts()), 1, b.texts())
                    self.assertEqual(len(b.reminders()), 1, b.texts())
                    self.assertIn(out.strip(), b.reminders()[0])
                    self.assertIsNone(b.st("last_install_ts"))
                    self.assertIsNone(b.st("drain_pending"))

    def test_noop_with_proven_receipt_is_silent_and_unmarked(self):
        # PATCH5: the same upstream sentences, now with THIS run's real gen-3 receipt: silent, exit 0.
        for fixture in (GEN3_NOOP, GEN3_NOOP_0216):
            for out in (YES_NOOP, YES_HELD):
                with self.subTest(fixture=fixture, out=out):
                    b = self.box()
                    b.proven(STABLE_AVAIL, out, fixture=fixture)
                    p = b.run(apply="1")
                    self.assertEqual(p.returncode, 0, b.log())
                    self.assertEqual(b.texts(), [])
                    self.assertIn("PROVEN by this run's receipt", b.log())
                    self.assertIsNone(b.st("last_install_ts"))
                    self.assertIsNone(b.st("drain_pending"))

    def test_completion_without_fresh_receipt_is_unproven(self):
        for label, rc, old in self.cases():
            with self.subTest(receipt=label):
                b = self.box()
                if old:
                    b.old_receipt(old)
                b.scenario(STABLE_AVAIL, yes=DONE_NEW, receipt=rc)
                p = b.run(apply="1")
                self.assertEqual(p.returncode, 1, b.log())
                t = b.texts()
                self.assertEqual(len(t), 1, t)
                self.assertIn("unproven", t[0])
                self.assertIn("v1.3.0", t[0])
                self.assertNotIn("updated to", t[0])
                self.assertIsNotNone(b.st("drain_pending"))
                self.assertIsNone(b.st("last_install_ts"))


class Hardening(T):
    AV = "→ Selected release available: stable v1.3.0 (abc1234def56)\n"

    def go(self, check, **kw):
        b = self.box()
        b.scenario(check, **kw)
        return b, b.run(apply="1")

    def no_success(self, b):
        self.assertIsNone(b.st("last_install_ts"))
        self.assertFalse(any("updated to" in t for t in b.texts()), b.texts())

    def test_available_with_warn_or_arrow_error_does_not_install(self):
        for line in ("⚠ ✗ signature verification failed\n", "→ ✗ download failed\n"):
            with self.subTest(line=line):
                b, _ = self.go(self.AV + line, yes=DONE_NEW, receipt=GOOD)
                self.assertFalse(b.yes_called())
                self.no_success(b)

    def test_quoted_diagnostic_verdict_with_available_does_not_install(self):
        for line in ('  hint: earlier run said "✗ fetch failed: HTTP 429"\n',
                     "  log: cached '✓ Up to date with the latest release'\n"):
            with self.subTest(line=line):
                b, _ = self.go(self.AV + line, yes=DONE_NEW, receipt=GOOD)
                self.assertFalse(b.yes_called())
                self.no_success(b)

    def test_legacy_fresh_success_without_completion_or_movement_not_marked(self):
        b, p = self.go(LEGACY_AVAIL, yes="→ Fetching origin/main\n", receipt={"outcome": "success"})
        self.assertTrue(b.yes_called())
        self.no_success(b)
        # N402: the legacy receipt is demoted to "uncorrelated" (no install evidence of its own)
        # -> the no-receipt rules. NO drain marker either way: without the demotion it would reach
        # the "success receipt, no evidence" branch (drain marker set, exit 1, alert).
        # PATCH4 (assertion changed, spec-driven): the no-receipt rules no longer read sentences;
        # no error line + HEAD unchanged = no-op. Before PATCH4 the unrecognized text made this the
        # inconclusive exit (exit 1, one alert).
        # PATCH5 (assertion changed, spec-driven; was exit 0 / no text): a legacy receipt (no
        # correlation_id) never proves the no-op -> UNPROVEN: exit 1, one ⚠ reminder.
        self.assertEqual(p.returncode, 1, b.log())
        self.assertEqual(len(b.reminders()), 1, b.texts())
        self.assertEqual(len(b.texts()), 1, b.texts())
        self.assertIsNone(b.st("drain_pending"), b.log())
        self.assertIn("correlation=legacy", b.log())
        self.assertIn("no-op: checkout unchanged", b.log())
        self.assertIn("UNPROVEN", b.log())
        self.assertEqual(b.st("consec_available_noop"), "1", b.log())

    def test_fresh_non_success_outcomes_never_success(self):
        for o in ("failed", "refused", "running", "mystery"):
            with self.subTest(outcome=o):
                b, _ = self.go(STABLE_AVAIL, yes=DONE_NEW, receipt=dict(GOOD, outcome=o))
                self.assertTrue(b.yes_called())
                self.no_success(b)

    def test_partial_nonzero_with_quoted_completion_only_no_success(self):
        b, _ = self.go(LEGACY_AVAIL, yes='warn: cached "✓ Update complete! (v9.9.9)" ignored\n',
                       yes_rc=1, receipt={"outcome": "partial"})
        self.assertTrue(b.yes_called())
        self.no_success(b)

    def test_unchanged_recent_success_receipt_plus_noop_not_marked(self):
        b = self.box()
        b.old_receipt(dict(GOOD, finished_at=time.strftime("%Y-%m-%dT%H:%M:%S+00:00",
                                                           time.gmtime(time.time() - 30))))
        b.scenario(STABLE_AVAIL, yes=YES_NOOP)   # PATCH2 (B500): upstream --yes sentence, was NOOP
        b.run(apply="1")
        self.assertTrue(b.yes_called())
        self.no_success(b)
        # PATCH5 (assertion changed, spec-driven; was texts == []): the unchanged receipt is not this
        # run's, so the no-op is UNPROVEN -> exactly one ⚠ reminder naming receipt=unchanged.
        self.assertEqual(len(b.texts()), 1, b.texts())
        self.assertEqual(len(b.reminders()), 1, b.texts())
        self.assertIn("receipt=unchanged", b.reminders()[0])

    def test_accepted_legacy_partial_completion_marks_install(self):
        for rc in (0, 1):
            with self.subTest(yes_rc=rc):
                b, _ = self.go(LEGACY_AVAIL, yes=DONE_OLD, yes_rc=rc, receipt={"outcome": "partial"})
                self.assertTrue(b.yes_called())
                self.assertRegex(b.st("last_install_ts") or "", r"^[0-9]{9,}$")


class RealMovement(T):
    MOVE = ('import subprocess\n'
            'if key == "yes":\n'
            '    G = [%r, "-C", %r]\n'
            '    h = lambda: subprocess.run(G + ["rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()\n'
            '    pre = h()\n'
            '    subprocess.run(G + ["-c", "user.name=stub", "-c", "user.email=stub@invalid", "commit", "-q", "--allow-empty", "-m", "stub"], check=True, capture_output=True)\n'
            # Production schema (hermes_cli/update_receipt.py:148-154; read by receipt_sha_advanced /
            # receipt_checkout_agrees): pre_update.short_sha / post_update.short_sha.
            '    step["receipt"] = dict(step.get("receipt") or {}, pre_update={"short_sha": pre[:8]},'
            ' post_update={"short_sha": h()[:8]})\n')
    CORR = ('    for k, v in os.environ.items():\n'
            '        if "CORRELATION" in k.upper():\n'
            '            d["correlation_id"] = v\n')

    def test_completed_or_completeness_near_miss_no_movement_exit1(self):
        for out in ("✓ Update completed (v9.9.9)\n", "✓ Update completeness check\n"):
            with self.subTest(out=out):
                b = self.box()
                b.scenario(LEGACY_AVAIL, yes=out, receipt={"outcome": "partial"})
                r = b.run(apply="1")
                self.assertTrue(b.yes_called())
                # PATCH4 (assertion changed, spec-driven; name kept so the audit trail stays): the
                # near-miss is not a completion line, the legacy partial receipt is demoted, and the
                # no-receipt rules judge state: no error line + HEAD unchanged = no-op.
                # PATCH5 (assertion changed, spec-driven; PATCH4 had exit 0): nothing proves the
                # no-op -> UNPROVEN, exit 1 with one ⚠ reminder. Never an install, as before.
                self.assertEqual(r.returncode, 1, b.log())
                self.assertIn("no-op: checkout unchanged", b.log())
                self.assertEqual(len(b.reminders()), 1, b.texts())
                self.assertIsNone(b.st("last_install_ts"))
                self.assertFalse(any("updated to" in t for t in b.texts()), b.texts())

    def test_legacy_nonzero_real_head_move_without_completion_exit1(self):
        b = self.box()
        git = shutil.which("git")
        head = lambda: subprocess.run([git, "-C", b.repo, "rev-parse", "HEAD"], capture_output=True,
                                      text=True, check=True).stdout.strip()
        with open(b.stub_hermes) as f:
            s = f.read()
        a = "step = sc[key]\n"
        self.assertEqual(s.count(a), 1)
        with open(b.stub_hermes, "w") as f:
            f.write(s.replace(a, a + self.MOVE % (git, b.repo), 1))
        before = head()
        b.scenario(LEGACY_AVAIL, yes="→ Fetching origin/main\n", yes_rc=1, receipt={"outcome": "partial"})
        r = b.run(apply="1")
        self.assertTrue(b.yes_called())
        after = head()
        self.assertNotEqual(after, before)
        with open(os.path.join(b.root, "home", ".hermes", "logs", "update_receipts", "latest.json")) as f:
            rec = json.load(f)
        self.assertEqual(((rec.get("pre_update") or {}).get("short_sha"),
                          (rec.get("post_update") or {}).get("short_sha")), (before[:8], after[:8]))
        self.assertEqual(r.returncode, 1, b.log())
        self.assertIsNone(b.st("last_install_ts"))
        self.assertFalse(any("updated to" in t for t in b.texts()), b.texts())

    def test_accepted_legacy_partial_gateway_inactive_keeps_drain(self):
        b = self.box()
        mark = os.path.join(b.root, "systemctl.calls")
        p = os.path.join(b.root, "bin", "systemctl")
        with open(p, "w") as f:
            f.write('#!/bin/sh\necho "$*" >> "%s"\necho inactive\nexit 3\n' % mark)
        os.chmod(p, 0o755)
        b.scenario(LEGACY_AVAIL, yes=DONE_OLD, receipt={"outcome": "partial"})
        b.run(apply="1")
        self.assertTrue(b.yes_called())
        self.assertTrue(os.path.exists(mark), b.log())
        self.assertRegex(b.st("last_install_ts") or "", r"^[0-9]{9,}$")
        self.assertIsNotNone(b.st("drain_pending"), b.log())
        self.assertTrue(b.texts(), b.log())
        self.assertFalse(any("updated to" in t or "✗" in t for t in b.texts()), b.texts())

    def test_correlated_success_unchanged_or_missing_sha_no_completion_exit1(self):
        for rec in ({"outcome": "success", "pre_update": {"short_sha": "a" * 8},
                     "post_update": {"short_sha": "a" * 8}}, {"outcome": "success"}):
            with self.subTest(rec=rec):
                b = self.box()
                with open(b.stub_hermes) as f:
                    s = f.read()
                a = '    d = dict(step["receipt"])\n'
                self.assertEqual(s.count(a), 1)
                with open(b.stub_hermes, "w") as f:
                    f.write(s.replace(a, a + self.CORR, 1))
                b.scenario(LEGACY_AVAIL, yes="→ Fetching origin/main\n", receipt=rec)
                r = b.run(apply="1")
                self.assertTrue(b.yes_called())
                with open(os.path.join(b.root, "home", ".hermes", "logs", "update_receipts", "latest.json")) as f:
                    self.assertTrue(json.load(f).get("correlation_id"), b.log())
                self.assertEqual(r.returncode, 1, b.log())
                self.assertIsNone(b.st("last_install_ts"))
                self.assertFalse(any("updated to" in t for t in b.texts()), b.texts())



# ===================== v5.15 regressions (issue #1 follow-up on 7d2f640) =====================

class StrictVerdicts(T):
    """B300: whole-line upstream verdicts; any error word / unknown line -> unknown (fail closed)."""
    POSITIVE = (
        ("stable-no-newer-ahead", BANNER + "✓ No newer release: %s.\n" % AHEAD_LBL, "uptodate"),
        ("stable-latest", BANNER + "✓ Up to date with the latest release (%s).\n" % LBL, "uptodate"),
        ("stable-held", UP_HELD, "held"),
        ("stable-rollback", UP_ROLLBACK, "rollback"),
        ("stable-available", UP_AVAIL, "available"),
        ("stable-retired-cleanup-crlf",
         "  (removed stale git lock: .git/shallow.lock)\r\n  (removed 2 aborted-fetch pack temp file(s))\r\n"
         "  (git cleanup: erased 1 duplicate pack(s), 12 MB freed; merged 0; 3 left)\r\n"
         + BANNER + "→ beta retired; source destination: stable\r\n"
         "  → Selected release available: stable v0.23.1\r\n  Run `hermes update` to install it.\r\n",
         "available"),
        ("real-check-sample", REAL_CHECK, "available"),
        ("main-current", "→ Fetching from origin...\n✓ Already up to date.\n", "uptodate"),
        ("main-behind-count", "→ Fetching from upstream...\n" + LEGACY_AVAIL, "available"),
        ("main-behind-one", "⚕ Update available: 1 commit behind origin/main.\n  Run 'hermes update' to install.\n",
         "available"),
        ("main-behind-shallow", "  (pruned 3 stale shallow graft(s) left by past depth-1 checks)\n"
         "⚕ Update available (behind origin/main).\n  Run 'hermes update' to install.\n", "available"),
        ("main-older-glyph", "☤ Update available: 2 commits behind origin/main.\n", "available"),
    )
    NEGATIVE = (
        # r2A B300 reproductions
        ("prefix-nearmiss", "✓ No newer releases could be resolved: error: timed out\n"),
        ("prefix-diagnostic", "No newer release check failed: error: timed out\n"),
        ("mixed-error-no-symbol", NOOP + "error: could not verify release signature\n"),
        ("mixed-available-error", "→ Selected release available: stable v0.23.1\n"
                                  "error: could not verify release signature\n"),
        # work-order cases
        ("noop-suffix-error", "✓ Already up to date. Error: signature mismatch\n"),
        ("available-paren-error", "⚕ Update available (error: compare API unreachable).\n"),
        # unknown line next to a valid verdict, any case of the veto words, glyph-less / wrong glyph
        ("unknown-line-beside-available", UP_AVAIL + "DEBUG: fetched tags in 0.2s\n"),
        ("upper-case-failed", BANNER + "✓ No newer release: %s.\nFETCH FAILED (cached verdict)\n" % AHEAD_LBL),
        ("timed-out-word", "✓ Already up to date.\n  (git cleanup timed out)\n"),
        # a context-shaped line still carries the veto words (only the word veto catches this)
        ("context-line-failed", "  (removed stale git lock: .git/index.lock; removal failed)\n✓ Already up to date.\n"),
        # whole-line anchoring: a suffix after the fixed sentence is not the sentence
        ("noop-suffix-cached", "✓ Already up to date. (cached result from yesterday)\n"),
        ("glyphless-legacy", "Update available: 3 commits behind origin/main.\n"),
        ("wrong-glyph", BANNER + "⬆ Selected release available: %s\n" % LBL),
        ("label-shape", BANNER + "→ Selected release available: soon, maybe\n"),
        ("sentence-tail", BANNER + "→ Holding at this build: %s (channel pinned)\n" % LBL),
        ("two-verdicts", BANNER + "✓ No newer release: %s.\n→ Selected release available: %s\n" % (AHEAD_LBL, LBL)),
        ("banner-only", BANNER),
        # B601: "No newer release" is printed only with the ahead label (update_cmd_check.py:109-110,
        # source_releases.py:62-64); the short label never follows it.
        ("no-newer-short-label", BANNER + "✓ No newer release: %s.\n" % LBL),
        # B800: the available verdict is anchored at the start too (a prefix is not the sentence)
        ("prefix-available", "cached: → Selected release available: stable v0.23.2 (ae2a81ccc00e)\n"),
        ("prefix-available-glued", BANNER + "(stale)→ Selected release available: %s\n" % LBL),
        ("prefix-main-available", "cached ⚕ Update available: 3 commits behind origin/main.\n"),
    )

    def run_check(self, out, rc=0):
        b = self.box()
        b.scenario(out, rc=rc, yes=DONE_NEW, receipt=GOOD)
        return b, b.run(apply="1")

    def test_upstream_shapes_classify(self):
        for name, out, want in self.POSITIVE:
            with self.subTest(name=name):
                b, p = self.run_check(out)
                self.assertEqual(p.returncode, 0, b.log())
                self.assertEqual(b.st("consec_check_fails"), "0", b.log())
                self.assertEqual(b.yes_called(), want == "available", b.log())
                if want == "available":
                    self.assertRegex(b.st("last_install_ts") or "", r"^[0-9]{9,}$")
                    self.assertTrue(any("updated to v1.3.0" in t for t in b.texts()), b.texts())
                else:
                    self.assertIsNone(b.st("last_install_ts"))
                if want in ("uptodate", "held"):
                    self.assertEqual(b.texts(), [])
                if want == "held":
                    self.assertIn("held (benign", b.log())
                if want == "rollback":
                    t = b.texts()
                    self.assertEqual(len(t), 1, t)
                    self.assertIn("NOT moved back", t[0])

    def test_error_and_unknown_shapes_fail_closed(self):
        for name, out in self.NEGATIVE:
            with self.subTest(name=name):
                b, p = self.run_check(out)
                self.assertEqual(p.returncode, 0, b.log())
                self.assertFalse(b.yes_called(), "installed on %r" % out)
                self.assertIsNone(b.st("last_install_ts"))
                self.assertEqual(b.st("consec_check_fails"), "1", b.log())
                self.assertEqual(b.texts(), [])
                self.assertIn("unrecognized --check output", b.log())

    def test_unknown_three_times_alerts_with_offending_line(self):
        b = self.box()
        b.scenario(NOOP + "error: could not verify release signature\n")
        for i in range(3):
            b.run(now=T0 + i * DAY)
        a = b.alerts()
        self.assertEqual(len(a), 1, a)
        self.assertIn("unrecognized", a[0])
        self.assertIn("error: could not verify release signature", a[0])


class YesErrorVeto(T):
    """PATCH4 rule 1: exit 0 without an install receipt of this run, and the output carries an error
    line (a line starting with ✗, or an error word as a whole word, any case, after SGR/CR/space
    removal) -> REAL FAILURE: counted, alerted with the line, exit 1, the streak is NOT reset."""
    VETOED = (
        ("noop-plus-x", YES_NOOP + "✗ dependency repair failed\n", None),
        ("hold-plus-x", YES_HELD + "✗ checkout repair failed\n", None),
        ("foreign-noop-plus-x", YES_NOOP + "✗ repair failed\n", {"kind": "plugin-check", "outcome": "failed"}),
        ("x-without-error-word", "  ✗ Snapshot copy ALSO broke\n" + YES_NOOP, None),
        ("sgr-wrapped-x", YES_NOOP + "\x1b[31m  ✗ something\x1b[0m\r\n", None),
        ("timed-out", YES_NOOP + "  warning: fleet restart timed out\n", None),
        ("timed-out-spaces", YES_NOOP + "  restart TIMED   OUT\n", None),
        ("error-word", "→ Fetching updates... error 502\n" + YES_NOOP, None),
        ("failed-word", YES_NOOP + "  ⚠ Lazy refresh failed; rerun `hermes update` once resolved.\n", None),
        ("failure-word", YES_NOOP + "  dependency FAILURE\n", None),
        ("cannot", YES_NOOP + "  cannot reach the gateway\n", None),
        ("couldnt-ascii", YES_NOOP + "  Hermes couldn't drop the saved stash entry\n", None),
        ("couldnt-typographic", YES_NOOP + "  Hermes couldn’t drop the saved stash entry\n", None),
        ("unable-to", YES_NOOP + "  Unable to   verify the checkout\n", None),
        ("traceback", "Traceback (most recent call last):\n" + YES_NOOP, None),
        ("hyphen-boundary", YES_NOOP + "  systemctl --user reset-failed hermes-gateway\n", None),
        ("profile-sync-error", REAL_YES_NOOP.replace("✓ Already up to date!", "→ Syncing bundled skills to all profiles...\n"
                                                    "  reviewer: error (permission denied)\n✓ Already up to date!"), None),
        # a whole word, so "0 failed" hits: no upstream release prints it on a normal path (corpus)
        ("zero-failed", YES_NOOP + "  0 failed\n", None),
        # B500 (r3A evidence-r3A/noop-prefix.py) rows 1 and 3 carry an error word
        ("b500-question", "✓ Already up to date? Could not determine release status.\n", None),
        ("b500-unverified", "✓ Already up to date. Cached verdict could not be verified.\n", None),
        # the exemption is the whole sentence with a settled active / inactive state only
        ("exempt-shape-failed-state", YES_NOOP + "  ⏳ systemctl restart hermes-gateway.service timed out after 90s;"
                                                  " systemd finished the job after 104s (failed)\n", None),
        ("exempt-sentence-tail", YES_NOOP + "  ℹ Got updates from upstream but couldn't push to fork (no write access?) (retry failed)\n", None),
        # PATCH5 B1201: a ✗ anywhere in the line (after SGR / CR removal), no error word needed
        ("b1201-mid-line-x", YES_NOOP + "  legend: ✓ done ✗ skipped\n", None),
        ("b1201-cr-overwrite", YES_NOOP + "  ok\r✗ dependency repair\n", None),
        ("b1201-sgr-mid-line-x", YES_NOOP + "  step 3/4 \x1b[31m✗\x1b[0m venv sync\n", None),
    )

    NEEDLE = {'noop-plus-x': '✗ dependency repair failed', 'hold-plus-x': '✗ checkout repair failed', 'foreign-noop-plus-x': '✗ repair failed', 'x-without-error-word': '✗ Snapshot copy ALSO broke', 'sgr-wrapped-x': '✗ something', 'timed-out': 'warning: fleet restart timed out', 'timed-out-spaces': 'restart TIMED   OUT', 'error-word': '→ Fetching updates... error 502', 'failed-word': '⚠ Lazy refresh failed', 'failure-word': 'dependency FAILURE', 'cannot': 'cannot reach the gateway', 'couldnt-ascii': "Hermes couldn't drop", 'couldnt-typographic': 'Hermes couldn’t drop', 'unable-to': 'Unable to   verify the checkout', 'traceback': 'Traceback (most recent call last):', 'hyphen-boundary': 'reset-failed hermes-gateway', 'profile-sync-error': 'reviewer: error (permission denied)', 'zero-failed': '0 failed', 'b500-question': '✓ Already up to date? Could not determine release status.', 'b500-unverified': '✓ Already up to date. Cached verdict could not be verified.', 'exempt-shape-failed-state': 'systemd finished the job after 104s (failed)', 'exempt-sentence-tail': '(no write access?) (retry failed)', 'b1201-mid-line-x': 'legend: ✓ done ✗ skipped', 'b1201-cr-overwrite': 'ok ✗ dependency repair', 'b1201-sgr-mid-line-x': 'step 3/4 ✗ venv sync'}

    def test_error_line_is_a_real_failure(self):
        for name, out, rec in self.VETOED:
            with self.subTest(name=name):
                b = self.box()
                b.seed("consec_real_fails", "8")
                b.seed("real_alert_last_ts", str(T0 - 100))   # old streak, alerted recently
                b.seed("drain_pending", "1")
                b.scenario(UP_AVAIL, yes=out, receipt=rec)
                p = b.run(apply="1", now=T0)
                self.assertTrue(b.yes_called())
                self.assertEqual(p.returncode, 1, b.log())
                self.assertEqual(b.st("consec_real_fails"), "9", b.log())
                self.assertIsNone(b.st("last_install_ts"))
                self.assertEqual(b.st("drain_pending"), "1", b.log())       # no drain recheck/clear
                self.assertIn("error in --yes output", b.log())
                self.assertNotIn("no-op: checkout unchanged", b.log())
                self.assertIsNone(b.st("consec_available_noop"), b.log())  # not a no-op
                self.assertFalse(any("updated to" in t for t in b.texts()), b.texts())

    def test_error_alerts_at_once_with_the_line(self):
        for name, out, rec in self.VETOED:
            with self.subTest(name=name):
                b = self.box()
                b.scenario(UP_AVAIL, yes=out, receipt=rec)
                p = b.run(apply="1", now=T0)
                self.assertEqual(p.returncode, 1, b.log())
                t = b.texts()
                self.assertEqual(len(t), 1, t)
                self.assertIn("attempt 1", t[0])
                self.assertIn("error in --yes output", t[0])
                self.assertIn(self.NEEDLE[name], t[0])

    def test_error_line_vetoes_even_with_proven_receipt(self):
        # PATCH5: a receipt that proves the no-op does not silence an error line (only adds alerts).
        for name, out, rec in self.VETOED:
            if rec is not None:
                continue
            with self.subTest(name=name):
                b = self.box()
                b.seed("consec_real_fails", "8")
                b.seed("real_alert_last_ts", str(T0 - 100))
                b.proven(UP_AVAIL, out, now=T0)
                p = b.run(apply="1", now=T0)
                self.assertEqual(p.returncode, 1, b.log())
                self.assertEqual(b.st("consec_real_fails"), "9", b.log())
                self.assertIn("error in --yes output", b.log())
                self.assertNotIn("no-op: checkout unchanged", b.log())

    def test_word_boundaries_without_error_words_pass(self):
        # Not error words (whole-word rule): "errors", "failures", "unfailed", "cannotx". HEAD
        # unchanged and THIS run's receipt proves the no-op -> silent no-op.
        # PATCH5 (changed, spec-driven): was test_word_boundaries_and_mid_line_glyph with a third input
        # "legend: ✓ done ✗ skipped" that had to PASS; B1201 makes a mid-line ✗ a veto, so that input
        # moved to VETOED (b1201-mid-line-x). The two remaining inputs now carry a proven receipt (no
        # receipt = an unproven reminder, YesHeadState).
        for out in (YES_NOOP + "  ✓ 0 errors, 0 failures\n", YES_NOOP + "  unfailed cannotx errorless\n"):
            with self.subTest(out=out):
                b = self.box()
                b.proven(UP_AVAIL, out, now=T0)
                p = b.run(apply="1", now=T0)
                self.assertEqual(p.returncode, 0, b.log())
                self.assertEqual(b.texts(), [])
                self.assertIn("no-op: checkout unchanged", b.log())
                self.assertIn("PROVEN by this run's receipt", b.log())

    def test_exempt_whole_sentences_pass(self):
        # The four normal upstream sentences that contain an error word (verify/upstream_error_review.json).
        # PATCH5 (changed, spec-driven): with THIS run's proven receipt (was: no receipt), so "pass" still
        # means silent exit 0.
        for line in ("  ⏳ systemctl restart hermes-gateway.service timed out after 90s; systemd finished the job after 104s (active)",
                     "  ⏳ systemctl stop hermes-gateway.service timed out after 90s; systemd finished the job after 91s (inactive)",
                     "  ℹ Got updates from upstream but couldn't push to fork (no write access?)",
                     "→ Windows: hermes.exe cannot replace itself while it runs; finishing the dependency install under the venv Python.",
                     "→ Windows: hermes.exe cannot replace itself while it runs; the update"):
            with self.subTest(line=line):
                b = self.box()
                b.proven(UP_AVAIL, REAL_YES_NOOP + line + "\n", now=T0)
                p = b.run(apply="1", now=T0)
                self.assertEqual(p.returncode, 0, b.log())
                self.assertEqual(b.texts(), [])
                self.assertIn("no-op: checkout unchanged", b.log())


class YesHeadState(T):
    """PATCH4 rules 2-4: no error line -> the observable checkout HEAD decides. Unchanged (both
    readable) = legitimate no-op whatever the sentences say; moved = install UNPROVEN; unreadable on
    either side = inconclusive."""
    # r5A evidence-r5A/new-regressions.py: stdout of the REAL upstream functions (origin/main 67e4d22)
    R5A_TAIL = ("  ✓ Fetched release history (commits only) for version identity\n"
                "  ✓ Model catalog cache refreshed from checkout\n\n→ Syncing bundled skills...\n"
                "  ✓ Skills are up to date\n\n")
    R5A = (
        ("r5a-default-profile", R5A_TAIL + "→ Syncing bundled skills to all profiles...\n  default: up to date\n\n"
                                "✓ Already up to date! [detached @ ae2a81c]\n"),
        ("r5a-named-profile", R5A_TAIL + "→ Syncing bundled skills to all profiles...\n  reviewer: up to date\n\n"
                              "✓ Already up to date! [detached @ ae2a81c]\n"),
        ("r5a-dashboard-action-id", R5A_TAIL + "✓ Already up to date! [detached @ ae2a81c]\n"
                                    "=== hermes-update completed aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ===\n"),
        ("r5a-profile-and-action", R5A_TAIL + "→ Syncing bundled skills to all profiles...\n  reviewer: up to date\n\n"
                                   "✓ Already up to date! [detached @ ae2a81c]\n"
                                   "=== hermes-update completed aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ===\n"),
    )
    UPSTREAM = (
        ("noop", REAL_YES_NOOP), ("noop-crlf", REAL_YES_NOOP.replace("\n", "\r\n")), ("held", REAL_YES_HELD),
        ("stable-ahead", REAL_YES_AHEAD), ("fork-main-no-upstream", REAL_YES_FORK),
        ("noop-full-tail", REAL_YES_NOOP_TAIL),
        ("legacy-v2026.7.20", LEGACY_YES_NOOP_0720), ("legacy-v2026.3.12", LEGACY_YES_NOOP_0312),
        ("sgr-banner", "\x1b[1m⚕ Updating Hermes Agent...\x1b[0m\n" + YES_NOOP), ("bare", YES_NOOP),
    )
    # Former PATCH2/PATCH3 sentence-shape vetoes WITHOUT an error word: the checkout did not move, so
    # nothing was installed. They are no longer real failures; the stuck guard (StuckGuard) is what
    # surfaces a run that keeps "having nothing to do" while --check says available.
    NO_ERROR_SHAPES = (
        ("b500-cached-suffix", "✓ Already up to date. (cached result from yesterday)\n"),
        ("b500-holding-question", "→ Holding at this build? Channel status unavailable.\n"),
        ("check-period-form", NOOP),
        ("post-swap-then-noop", "→ Post-swap hand-off: completing the update in a fresh interpreter"
                                " (/home/u/.hermes/update-handoff.json)\n" + YES_NOOP),
        ("available-beside-noop", YES_NOOP + "→ Selected release available: stable v0.23.1\n"),
        ("no-conclusion-at-all", "⚕ something unexpected happened\n"),
        ("empty-output", ""),
    )

    def noop_ok(self, out, check=UP_AVAIL, rec=None, healthy=True, prep=None, proven=True):
        """PATCH5 (changed, spec-driven): PATCH4's single expectation "no error + HEAD unchanged =
        silent legitimate no-op, streak reset" now holds only with THIS run's proven receipt
        (proven=True: the real gen-3 fixture). proven=False (no receipt / the given rec) asserts the
        UNPROVEN branch instead: one ⚠ reminder carrying the --yes tail, exit 1, consec_real_fails and
        real_alert_last_ts untouched, no ✗, never an error, never installed. Both share the drain
        recheck and the stuck-guard count."""
        b = self.box()
        if prep:
            prep(b)
        b.seed("consec_real_fails", "8")
        b.seed("real_alert_last_ts", str(T0 - 100))
        b.seed("drain_pending", "1")
        if not healthy:
            with open(b.gw, "w") as f:
                f.write('{"code_sha": "0000000000000000000000000000000000000000"}')
        if proven:
            b.proven(check, out, now=T0)
        else:
            b.scenario(check, yes=out, receipt=rec)
        p = b.run(apply="1", now=T0)
        self.assertTrue(b.yes_called())
        self.assertIn("no-op: checkout unchanged", b.log())
        self.assertNotIn("error in --yes output", b.log())
        self.assertIsNone(b.st("last_install_ts"))
        self.assertEqual(b.st("consec_available_noop"), "1", b.log())
        if proven:
            self.assertIn("PROVEN by this run's receipt", b.log())
            self.assertEqual(b.st("consec_real_fails"), "0", b.log())
            self.assertIsNone(b.st("real_alert_last_ts"))
            if healthy:
                self.assertEqual(p.returncode, 0, b.log())
                self.assertEqual(b.texts(), [])
                self.assertIsNone(b.st("drain_pending"), b.log())
            else:
                self.assertEqual(p.returncode, 1, b.log())        # the drain recheck, not the no-op, fails
                self.assertIsNotNone(b.st("drain_pending"), b.log())
        else:
            self.assertIn("UNPROVEN", b.log())
            self.assertEqual(p.returncode, 1, b.log())
            self.assertEqual(b.st("consec_real_fails"), "8", b.log())          # not a failure, no reset
            self.assertEqual(b.st("real_alert_last_ts"), str(T0 - 100), b.log())
            r = b.reminders()
            self.assertEqual(len(r), 1, b.texts())
            self.assertTrue(r[0].startswith("⚠ hermes auto-update:"), r[0])
            self.assertNotIn("✗ hermes", r[0])
            self.assertIn("last --yes output:", r[0])
            tail = [l for l in out.replace("\r", "").split("\n") if l.strip()]
            if tail:
                self.assertIn(tail[-1][:60], r[0])       # the --yes tail (yes_tail_summary) is attached
            self.assertEqual(b.st("available_noop_alert_last_ts"), str(T0), b.log())
            if healthy:
                self.assertEqual(b.texts(), r)
                self.assertIsNone(b.st("drain_pending"), b.log())       # the drain recheck still ran
            else:
                self.assertIsNotNone(b.st("drain_pending"), b.log())
                self.assertTrue(any("never came back" in t for t in b.texts()), b.texts())
        return b

    def test_r5a_profile_and_dashboard_noops_are_legitimate(self):
        # B900/B1000/B901 stay closed: these normal lines are never an error; proven = silent.
        for name, out in self.R5A:
            for healthy in (True, False):
                for proven in (True, False):
                    with self.subTest(name=name, healthy=healthy, proven=proven):
                        self.noop_ok(out, healthy=healthy, proven=proven)

    def test_upstream_noop_runs_are_legitimate(self):
        # Legacy builds (v2026.7.20 / v2026.3.12, r4A legacy-noop.py) write no correlated receipt: by
        # design they always take the UNPROVEN reminder, never a ✗, counters kept.
        for name, out in self.UPSTREAM:
            legacy = name.startswith("legacy")
            for proven in ((False,) if legacy else (True, False)):
                with self.subTest(name=name, proven=proven):
                    self.noop_ok(out, check=LEGACY_AVAIL if legacy else UP_AVAIL, proven=proven)

    def test_stale_or_foreign_receipt_noop_is_unproven(self):
        # PATCH5 (changed, spec-driven): was ..._is_legitimate (silent, reset). A stale or foreign
        # receipt is not this run's: UNPROVEN reminder.
        for rec in ({"kind": "plugin-check", "outcome": "success"}, None):
            with self.subTest(rec=rec):
                prep = (lambda b: b.old_receipt(dict(GOOD, finished_at="2020-01-01T00:00:00+00:00"))) if rec is None else None
                self.noop_ok(REAL_YES_NOOP, rec=rec, prep=prep, proven=False)

    def test_no_error_shapes_judged_by_head_not_by_sentence(self):
        for name, out in self.NO_ERROR_SHAPES:
            for proven in (True, False):
                with self.subTest(name=name, proven=proven):
                    self.noop_ok(out, proven=proven)

    def move_stub(self, b, snippet):
        with open(b.stub_hermes) as f:
            s = f.read()
        a = "step = sc[key]\n"
        self.assertEqual(s.count(a), 1)
        with open(b.stub_hermes, "w") as f:
            f.write(s.replace(a, a + snippet, 1))

    def git(self, b, *args):
        return subprocess.run([shutil.which("git"), "-C", b.repo] + list(args), capture_output=True,
                              text=True, check=True).stdout.strip()

    def test_head_moved_without_receipt_is_unproven(self):
        for out in (YES_NOOP, REAL_YES_NOOP, "⚕ something unexpected happened\n", ""):
            with self.subTest(out=out[:30]):
                b = self.box()
                b.seed("consec_real_fails", "8")
                b.seed("consec_available_noop", "2")
                before = self.git(b, "rev-parse", "HEAD")
                self.move_stub(b, 'if key == "yes":\n    import subprocess\n    subprocess.run([%r, "-C", %r, "-c", '
                                  '"user.name=stub", "-c", "user.email=stub@invalid", "commit", "-q", "--allow-empty",'
                                  ' "-m", "stub"], check=True, capture_output=True)\n' % (shutil.which("git"), b.repo))
                b.scenario(UP_AVAIL, yes=out)
                p = b.run(apply="1", now=T0)
                self.assertNotEqual(self.git(b, "rev-parse", "HEAD"), before)
                self.assertEqual(p.returncode, 1, b.log())
                t = b.texts()
                self.assertEqual(len(t), 1, t)
                self.assertIn("checkout moved", t[0])
                self.assertIn("install unproven", t[0])
                self.assertIsNotNone(b.st("drain_pending"), b.log())
                self.assertIsNone(b.st("last_install_ts"))
                self.assertEqual(b.st("consec_real_fails"), "8", b.log())     # not a no-op, not a failure
                self.assertEqual(b.st("consec_available_noop"), "2", b.log())  # not counted, not cleared
                self.assertNotIn("no-op: checkout unchanged", b.log())

    def test_head_unreadable_is_inconclusive(self):
        # An unborn HEAD (refs/heads/<nothing>) makes rev-parse --verify fail inside a REAL repo, so
        # git cannot fall back to an enclosing repository. Before --yes, after --yes, or both.
        for side in ("before", "after", "both"):
            with self.subTest(side=side):
                b = self.box()
                headf = os.path.join(b.repo, ".git", "HEAD")
                with open(headf) as f:
                    good = f.read()
                bad = "ref: refs/heads/au-unborn-test\n"
                if side in ("before", "both"):
                    with open(headf, "w") as f:
                        f.write(bad)
                after = good if side == "before" else bad
                self.move_stub(b, 'if key == "yes":\n    open(%r, "w").write(%r)\n' % (headf, after))
                b.seed("consec_real_fails", "8")
                b.scenario(UP_AVAIL, yes=REAL_YES_NOOP)
                p = b.run(apply="1", now=T0)
                self.assertEqual(p.returncode, 1, b.log())
                t = b.texts()
                self.assertEqual(len(t), 1, t)
                self.assertIn("HEAD could not be read", t[0])
                self.assertIn("inconclusive", b.log())
                self.assertIsNone(b.st("last_install_ts"))
                self.assertEqual(b.st("consec_real_fails"), "8", b.log())
                self.assertIsNone(b.st("consec_available_noop"), b.log())
                self.assertNotIn("no-op: checkout unchanged", b.log())

    def test_completion_line_without_receipt_stays_unproven(self):
        # Rule 0 is unchanged: a completion line with no receipt is UNPROVEN even if HEAD did not move.
        b = self.box()
        b.scenario(UP_AVAIL, yes=REAL_YES_INSTALL)
        p = b.run(apply="1", now=T0)
        self.assertEqual(p.returncode, 1, b.log())
        t = b.texts()
        self.assertEqual(len(t), 1, t)
        self.assertIn("unproven", t[0])
        self.assertIsNotNone(b.st("drain_pending"))
        self.assertIsNone(b.st("last_install_ts"))

    def test_real_upstream_install_run_installs(self):
        # Install output never reaches the no-receipt rules: the receipt decides. The shallow run also
        # prints two upstream lines with an "available" keyword (update_cmd.py:1938, update_cmd_maint.py:185).
        for name, rec, out in (("legacy-receipt", GOOD, REAL_YES_INSTALL), ("correlated", None, REAL_YES_INSTALL),
                               ("shallow-legacy", GOOD, REAL_YES_INSTALL_SHALLOW),
                               ("shallow-correlated", None, REAL_YES_INSTALL_SHALLOW)):
            with self.subTest(name=name):
                b = self.box()
                b.seed("consec_available_noop", "2")
                if rec is None:
                    with open(b.stub_hermes) as f:
                        s = f.read()
                    a = '    d = dict(step["receipt"])\n'
                    self.assertEqual(s.count(a), 1)
                    with open(b.stub_hermes, "w") as f:
                        f.write(s.replace(a, a + RealMovement.CORR, 1))
                    rec = GOOD
                b.scenario(UP_AVAIL, yes=out, receipt=rec)
                p = b.run(apply="1")   # real clock: the stub's receipt finished_at is "now"
                self.assertEqual(p.returncode, 0, b.log())
                self.assertRegex(b.st("last_install_ts") or "", r"^[0-9]{9,}$")
                t = b.texts()
                self.assertEqual(len(t), 1, t)
                self.assertIn("updated to v0.23.2", t[0])
                self.assertNotIn("error in --yes output", b.log())
                self.assertEqual(b.st("consec_available_noop"), "0", b.log())   # a proven install clears


class StuckGuard(T):
    """PATCH4 rule 5: --check says available and --yes is a legitimate no-op, again and again. From the
    3rd consecutive such tick: alert, then by wall clock every AU_CHECK_ALERT_INTERVAL (82800) s.
    Cleared by a proven install and by a no-install check verdict (up to date / held / rollback)."""

    def noop_tick(self, b, now, out=YES_NOOP):
        # PATCH5 (changed, spec-driven): the stuck guard counts PROVEN no-ops (this run's real gen-3
        # receipt); an unproven no-op reminds from the first tick (test_unproven_* below).
        b.proven(UP_AVAIL, out, now=now)
        p = b.run(apply="1", now=now)
        self.assertEqual(p.returncode, 0, b.log())
        return p

    def unproven_tick(self, b, now, out=YES_NOOP, rec=None):
        b.scenario(UP_AVAIL, yes=out, receipt=rec)
        p = b.run(apply="1", now=now)
        self.assertEqual(p.returncode, 1, b.log())
        return p

    def test_unproven_noop_reminds_from_the_first_tick_then_daily(self):
        b = self.box()
        b.seed("consec_real_fails", "8")
        self.unproven_tick(b, T0, out=REAL_YES_NOOP)
        self.assertEqual(len(b.reminders()), 1, b.texts())
        self.assertIn("(1 consecutive)", b.reminders()[0])
        self.assertIn("check: → Selected release available: %s" % LBL, b.reminders()[0])
        self.assertIn("✓ Already up to date! [detached @ ae2a81c]", b.reminders()[0])
        self.assertEqual(b.st("available_noop_alert_last_ts"), str(T0))
        # within the interval: suppressed (logged), counters untouched
        self.unproven_tick(b, T0 + 3600)
        self.assertEqual(len(b.reminders()), 1, b.texts())
        self.assertIn("reminder suppressed", b.log())
        self.unproven_tick(b, T0 + CHECK_INTERVAL)
        self.assertEqual(len(b.reminders()), 2, b.texts())
        self.assertIn("(3 consecutive)", b.reminders()[1])
        self.assertEqual(b.st("consec_real_fails"), "8", b.log())
        self.assertIsNone(b.st("last_install_ts"))
        self.assertEqual(self.stuck(b), [])          # the reminder, not the proven-noop stuck alert

    def test_unproven_undelivered_reminder_retries_next_tick(self):
        b = self.box()
        b.notify_fails(True)
        self.unproven_tick(b, T0)
        self.assertIsNone(b.st("available_noop_alert_last_ts"))
        self.assertIn("reminder #1 not delivered", b.log())
        b.notify_fails(False)
        self.unproven_tick(b, T0 + 60)
        self.assertEqual(b.st("available_noop_alert_last_ts"), str(T0 + 60))
        self.assertEqual(len(b.reminders()), 2)      # the failed attempt (curl stub logs it) + the retry

    def stuck(self, b):
        return [t for t in b.texts() if "suspected stuck" in t]

    def test_third_consecutive_noop_alerts_with_output_then_daily(self):
        b = self.box()
        for i in range(2):
            self.noop_tick(b, T0 + i * DAY, out=REAL_YES_NOOP)
        self.assertEqual(b.st("consec_available_noop"), "2")
        self.assertEqual(b.texts(), [])
        self.noop_tick(b, T0 + 2 * DAY, out=REAL_YES_NOOP)
        a = self.stuck(b)
        self.assertEqual(len(a), 1, b.texts())
        self.assertIn("3 consecutive", a[0])
        self.assertIn("check: → Selected release available: %s" % LBL, a[0])
        self.assertIn("last --yes output:", a[0])
        self.assertIn("✓ Already up to date! [detached @ ae2a81c]", a[0])
        self.assertIn("Restarted hermes-gateway.service", a[0])
        self.assertEqual(b.st("available_noop_alert_last_ts"), str(T0 + 2 * DAY))
        # same day: suppressed; one interval later (start jitter included): re-alert
        self.noop_tick(b, T0 + 2 * DAY + 3600)
        self.assertEqual(len(self.stuck(b)), 1)
        self.assertIn("alert suppressed", b.log())
        self.noop_tick(b, T0 + 2 * DAY + 82800)
        self.assertEqual(len(self.stuck(b)), 2)
        self.assertEqual(b.st("consec_available_noop"), "5")

    def test_b500_no_error_rows_alert_on_the_third_tick(self):
        # B500 rows 2 and 4 carry no error word: with HEAD unchanged they are legitimate no-ops now; the
        # stuck guard is what makes a repeating one visible.
        for out in ("✓ Already up to date. (cached result from yesterday)\n",
                    "→ Holding at this build? Channel status unavailable.\n"):
            with self.subTest(out=out):
                b = self.box()
                for i in range(3):
                    self.noop_tick(b, T0 + i * DAY, out=out)
                a = self.stuck(b)
                self.assertEqual(len(a), 1, b.texts())
                self.assertIn(out.strip(), a[0])

    def test_undelivered_alert_retries_next_tick(self):
        b = self.box()
        for i in range(2):
            self.noop_tick(b, T0 + i * DAY)
        b.notify_fails(True)
        self.noop_tick(b, T0 + 2 * DAY)
        self.assertIsNone(b.st("available_noop_alert_last_ts"))
        b.notify_fails(False)
        self.noop_tick(b, T0 + 2 * DAY + 60)
        self.assertEqual(len(self.stuck(b)), 2)   # the failed attempt (curl stub logs it too) + the retry
        self.assertEqual(b.st("available_noop_alert_last_ts"), str(T0 + 2 * DAY + 60))

    def test_proven_install_clears(self):
        b = self.box()
        for i in range(2):
            self.noop_tick(b, T0 + i * DAY)
        b.seed("available_noop_alert_last_ts", str(T0))
        b.scenario(STABLE_AVAIL, yes=DONE_NEW, receipt=GOOD)
        p = b.run(apply="1")
        self.assertEqual(p.returncode, 0, b.log())
        self.assertEqual(b.st("consec_available_noop"), "0")
        self.assertIsNone(b.st("available_noop_alert_last_ts"))
        for i in range(2):
            self.noop_tick(b, T0 + (5 + i) * DAY)
        self.assertEqual(self.stuck(b), [])
        self.assertEqual(b.st("consec_available_noop"), "2")

    def test_no_install_check_verdicts_clear(self):
        for name, check in (("uptodate", BANNER + "✓ Up to date with the latest release (%s).\n" % LBL),
                            ("held", UP_HELD), ("rollback", UP_ROLLBACK)):
            with self.subTest(name=name):
                b = self.box()
                for i in range(2):
                    self.noop_tick(b, T0 + i * DAY)
                b.scenario(check)
                b.run(apply="1", now=T0 + 2 * DAY)
                self.assertEqual(b.st("consec_available_noop"), "0")
                self.noop_tick(b, T0 + 3 * DAY)
                self.noop_tick(b, T0 + 4 * DAY)
                self.assertEqual(self.stuck(b), [])

    def test_failures_between_noops_do_not_clear(self):
        # The streak counts available-then-nothing-to-do ticks since the last install or no-install
        # verdict. A failed check or a failed install in between proves nothing moved, so it neither
        # counts nor clears: an intermittent failure cannot hide a stuck installer.
        b = self.box()
        self.noop_tick(b, T0)
        b.scenario(CHECK_FAIL, rc=1)
        b.run(apply="1", now=T0 + DAY)
        b.scenario(UP_AVAIL, yes=YES_FAIL, yes_rc=1)
        b.run(apply="1", now=T0 + 2 * DAY)
        self.assertEqual(b.st("consec_available_noop"), "1")
        self.noop_tick(b, T0 + 3 * DAY)
        self.noop_tick(b, T0 + 4 * DAY)
        self.assertEqual(len(self.stuck(b)), 1, b.texts())


class NoopResetsRealFails(T):
    """B306: every legitimate no-op exit ends the real-failure streak (after the drain recheck).
    PATCH5 (changed, spec-driven): "legitimate" now means PROVEN by this run's receipt, or a
    check-time no-install verdict. A --yes no-op with a missing / stale / foreign receipt is UNPROVEN
    and keeps the streak (test_yes_noop_*_receipt_keeps_streak; they were test_yes_noop_*_receipt,
    asserting the reset)."""

    def sequence_kept(self, noop_scenario):
        b = self.box()
        b.seed("consec_real_fails", "8")
        b.seed("real_alert_last_ts", str(T0 - 100))
        noop_scenario(b)
        p = b.run(apply="1", now=T0)
        self.assertEqual(p.returncode, 1, b.log())
        self.assertEqual(b.st("consec_real_fails"), "8", b.log())
        self.assertEqual(b.st("real_alert_last_ts"), str(T0 - 100))
        self.assertEqual(len(b.reminders()), 1, b.texts())
        before = len(b.texts())
        b.scenario(UP_AVAIL, yes=YES_FAIL, yes_rc=1)
        p = b.run(apply="1", now=T0 + 60)
        self.assertEqual(p.returncode, 1, b.log())
        self.assertEqual(b.st("consec_real_fails"), "9", b.log())   # the streak continues
        self.assertEqual(b.texts()[before:], [], b.log())           # inside the re-alert interval

    def test_yes_noop_proven_receipt(self):
        self.sequence(lambda b: b.proven(UP_AVAIL, YES_NOOP, now=T0))

    def test_yes_noop_missing_receipt_keeps_streak(self):
        self.sequence_kept(lambda b: b.scenario(UP_AVAIL, yes=YES_NOOP))

    def test_yes_noop_stale_receipt_keeps_streak(self):
        def s(b):
            b.old_receipt(dict(GOOD, finished_at="2020-01-01T00:00:00+00:00"))
            b.scenario(UP_AVAIL, yes=YES_NOOP)
        self.sequence_kept(s)

    def test_yes_noop_foreign_receipt_keeps_streak(self):
        self.sequence_kept(lambda b: b.scenario(UP_AVAIL, yes=YES_NOOP, receipt={"kind": "plugin-check", "outcome": "success"}))

    def sequence(self, noop_scenario):
        b = self.box()
        # old streak: 8 failures, last alert just now -> the next failure would be suppressed
        b.seed("consec_real_fails", "8")
        b.seed("real_alert_last_ts", str(T0 - 100))
        noop_scenario(b)
        p = b.run(apply="1", now=T0)
        self.assertEqual(p.returncode, 0, b.log())
        self.assertEqual(b.st("consec_real_fails"), "0", b.log())
        self.assertIsNone(b.st("real_alert_last_ts"))
        before = len(b.texts())
        b.scenario(UP_AVAIL, yes=YES_FAIL, yes_rc=1)
        p = b.run(apply="1", now=T0 + 60)
        self.assertEqual(p.returncode, 1, b.log())
        self.assertEqual(b.st("consec_real_fails"), "1", b.log())
        new = b.texts()[before:]
        self.assertEqual(len(new), 1, b.log())
        self.assertIn("attempt 1", new[0])

    def test_check_time_uptodate_held_rollback(self):
        for out in (BANNER + "✓ No newer release: %s.\n" % AHEAD_LBL, UP_HELD, UP_ROLLBACK):
            with self.subTest(out=out):
                self.sequence(lambda b, o=out: b.scenario(o))


class AlertSummary(T):
    """B302: the real error is selected before the size bound."""

    def test_error_after_ninth_line_survives(self):
        b = self.box()
        out = (BANNER + "".join("  (removed stale git lock: lock%d)\n" % i for i in range(9))
               + "✗ Could not resolve the stable source channel: Command timed out after 10 seconds\n")
        b.scenario(out, rc=1)
        b.seed("consec_check_fails", "2")
        b.run(now=T0)
        a = b.alerts()
        self.assertEqual(len(a), 1, a)
        lines = a[0].split("\n")
        self.assertEqual(lines[2], "✗ Could not resolve the stable source channel: Command timed out after 10 seconds")
        self.assertLessEqual(len(lines), 8, lines)
        self.assertIn("  (removed stale git lock: lock0)", lines)

    def test_error_word_without_glyph_is_prioritized_with_one_context_line(self):
        b = self.box()
        out = ("".join("noise %02d\n" % i for i in range(12))
               + "fatal: unable to access origin: Failed to connect\n  hint: proxy 127.0.0.1:18089\n"
               + "noise tail\n")
        b.scenario(out, rc=1)
        b.seed("consec_check_fails", "2")
        b.run(now=T0)
        lines = b.alerts()[0].split("\n")
        self.assertEqual(lines[2:4], ["fatal: unable to access origin: Failed to connect", "  hint: proxy 127.0.0.1:18089"])
        self.assertEqual(lines[4:], ["noise 00", "noise 01", "noise 02", "noise 03"])


class RealFailureCadence(T):
    """B303: real failures re-alert by wall clock (AU_REALERT_SECS), first failure at once."""

    def failing(self):
        b = self.box()
        b.scenario(UP_AVAIL, yes=YES_FAIL, yes_rc=1)
        return b

    def test_daily_failures_realert_on_wall_clock(self):
        b = self.failing()
        want = {0: 1, 1: 1, 2: 1, 3: 2, 4: 2, 5: 2, 6: 3}
        for day in range(7):
            self.assertEqual(b.run(apply="1", now=T0 + day * DAY).returncode, 1, b.log())
            self.assertEqual(len(b.texts()), want[day], "day %d\n%s" % (day, b.log()))
        self.assertEqual(b.st("consec_real_fails"), "7")
        self.assertEqual(b.st("real_alert_last_ts"), str(T0 + 6 * DAY))
        self.assertIn("attempt 4", b.texts()[1])

    def test_realert_after_4_days(self):
        b = self.failing()
        for day in (0, 4):
            b.run(apply="1", now=T0 + day * DAY)
        self.assertEqual(len(b.texts()), 2, b.log())
        self.assertEqual(b.st("consec_real_fails"), "2")

    def test_corrupt_or_future_stamp_alerts_and_self_heals(self):
        for ts in ("garbage", "", "-5", "12abc", "9" * 40, str(T0 + 100000)):
            with self.subTest(ts=ts):
                b = self.failing()
                b.seed("consec_real_fails", "5")
                b.seed("real_alert_last_ts", ts)
                p = b.run(apply="1", now=T0)
                self.assertEqual(p.returncode, 1, b.log())
                self.assertEqual(p.stderr, "")
                self.assertEqual(len(b.texts()), 1)
                self.assertEqual(b.st("real_alert_last_ts"), str(T0))

    def test_recent_stamp_suppresses_and_undelivered_first_alert_retries(self):
        b = self.failing()
        b.seed("consec_real_fails", "5")
        b.seed("real_alert_last_ts", str(T0 - 100))
        b.run(apply="1", now=T0)
        self.assertEqual(b.texts(), [])
        self.assertIn("notify suppressed", b.log())
        b2 = self.failing()
        b2.notify_fails(True)
        b2.run(apply="1", now=T0)
        self.assertIsNone(b2.st("real_alert_last_ts"), "stamped although delivery failed")
        b2.notify_fails(False)
        b2.run(apply="1", now=T0 + 3600)
        self.assertEqual(b2.st("real_alert_last_ts"), str(T0 + 3600))
        self.assertTrue(any("attempt 2" in t for t in b2.texts()), b2.texts())

    def test_knob_override_and_garbage(self):
        b = self.failing()
        b.seed("consec_real_fails", "5")
        b.seed("real_alert_last_ts", str(T0 - 120))
        b.run(apply="1", now=T0, AU_REALERT_SECS="60")
        self.assertEqual(len(b.texts()), 1, b.log())
        for v in ("0", "-1", "abc", "", "9" * 30):
            with self.subTest(v=v):
                b = self.failing()
                b.seed("consec_real_fails", "5")
                b.seed("real_alert_last_ts", str(T0 - 120))
                p = b.run(apply="1", now=T0, AU_REALERT_SECS=v)
                self.assertEqual(p.stderr, "")
                self.assertEqual(b.texts(), [], "garbage knob must fall back to the default")


class NotifyFailureCadence(T):
    """B303/N403: notify-failure dead letter + meta-alert by wall clock, first at the 3rd failure."""

    def dead(self, b):
        # one entry per "[YYYY-MM-DD HH:MM:SS] N consecutive delivery failures" line (the unsent
        # message itself is multi-line)
        return [l for l in b._lines(os.path.join("home", ".hermes", "state", "auto_update",
                                                 "notify_dead_letter.log"))
                if l.startswith("[") and "consecutive delivery failures" in l]

    def test_dead_letter_realerts_after_days_not_ticks(self):
        b = self.box()
        b.scenario(CHECK_FAIL, rc=1)
        b.seed("consec_check_fails", "5")        # every tick tries to alert (undelivered = no stamp)
        b.seed("consec_notify_fails", "2")
        b.notify_fails(True)
        want = ((0, 3, 1), (1, 4, 1), (2, 5, 1), (3, 6, 2), (4, 7, 2))
        for day, n, letters in want:
            p = b.run(now=T0 + day * DAY)
            self.assertEqual(p.returncode, 0, b.log())
            self.assertEqual(b.st("consec_notify_fails"), str(n))
            self.assertEqual(len(self.dead(b)), letters, "day %d" % day)
        self.assertEqual(b.st("notify_alert_last_ts"), str(T0 + 3 * DAY))
        b.notify_fails(False)
        b.run(now=T0 + 5 * DAY)
        self.assertEqual(b.st("consec_notify_fails"), "0")
        self.assertIsNone(b.st("notify_alert_last_ts"))


class RollbackReminder(T):
    """B304: low-frequency reminder while the checkout stays newer; never installs, never counts."""

    def test_weekly_reminder_never_installs(self):
        b = self.box()
        b.scenario(UP_ROLLBACK, yes=DONE_NEW, receipt=GOOD)
        counts = []
        for day in range(15):
            self.assertEqual(b.run(apply="1", now=T0 + day * DAY).returncode, 0, b.log())
            counts.append(len(b.texts()))
        self.assertEqual(counts[0], 1)
        self.assertEqual(counts[6], 1)
        self.assertEqual(counts[7], 2)
        self.assertEqual(counts[14], 3)
        self.assertFalse(b.yes_called())
        self.assertEqual(b.st("consec_check_fails"), "0")
        self.assertIsNone(b.st("last_install_ts"))
        self.assertTrue(all("NOT moved back" in t for t in b.texts()))
        self.assertEqual(b.st("rollback_remind_ts"), str(T0 + 14 * DAY))

    def test_undelivered_reminder_retries_and_corrupt_stamp_self_heals(self):
        b = self.box()
        b.scenario(UP_ROLLBACK)
        b.notify_fails(True)
        b.run(apply="1", now=T0)
        self.assertIsNone(b.st("rollback_remind_ts"))
        b.notify_fails(False)
        b.run(apply="1", now=T0 + DAY)
        self.assertEqual(b.st("rollback_remind_ts"), str(T0 + DAY))
        for ts in ("garbage", "", "9" * 30, str(T0 + 10 * DAY)):
            with self.subTest(ts=ts):
                b = self.box()
                b.scenario(UP_ROLLBACK)
                b.seed("rollback_remind_ts", ts)
                p = b.run(apply="1", now=T0)
                self.assertEqual(p.stderr, "")
                self.assertEqual(len(b.texts()), 1)
                self.assertEqual(b.st("rollback_remind_ts"), str(T0))

    def test_legacy_one_shot_marker_migrates_and_state_change_clears(self):
        b = self.box()
        b.seed("rollback_notified", "")
        b.scenario(UP_ROLLBACK)
        b.run(apply="1", now=T0)
        self.assertEqual(len(b.texts()), 1, "pre-5.15 marker must not silence the reminder forever")
        self.assertIsNone(b.st("rollback_notified"))
        b.scenario(BANNER + "✓ No newer release: %s.\n" % AHEAD_LBL)
        b.run(apply="1", now=T0 + DAY)
        self.assertIsNone(b.st("rollback_remind_ts"))
        b.scenario(UP_ROLLBACK)
        b.run(apply="1", now=T0 + 2 * DAY)
        self.assertEqual(len(b.texts()), 2, "re-entering the state reminds again")

    def test_knob(self):
        b = self.box()
        b.scenario(UP_ROLLBACK)
        b.run(apply="1", now=T0, AU_ROLLBACK_REMIND_SECS="3600")
        b.run(apply="1", now=T0 + 3599, AU_ROLLBACK_REMIND_SECS="3600")
        b.run(apply="1", now=T0 + 3600, AU_ROLLBACK_REMIND_SECS="3600")
        self.assertEqual(len(b.texts()), 2)
        self.assertEqual(REMIND_DEFAULT, 601200)
        self.assertEqual(REALERT_DEFAULT, 255600)


class ReceiptBinding(T):
    """B307 / N401: production receipt schema; legacy checkout proof both ways; foreign correlation."""
    MOVE = ('if key == "yes":\n'
            '    import subprocess\n'
            '    G = [%r, "-C", %r]\n'
            '    h = lambda: subprocess.run(G + ["rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()\n'
            '    pre = h()\n'
            '    if %r:\n'
            '        subprocess.run(G + ["-c", "user.name=stub", "-c", "user.email=stub@invalid", "commit", "-q", "--allow-empty", "-m", "stub"], check=True, capture_output=True)\n'
            '    post = h()\n'
            '    step["receipt"] = {"outcome": "success", "pre_update": {"short_sha": %s},'
            ' "post_update": {"short_sha": %s}}\n')

    def legacy(self, move=True, pre="pre[:8]", post="post[:8]"):
        b = self.box()
        git = shutil.which("git")
        with open(b.stub_hermes) as f:
            s = f.read()
        a = "step = sc[key]\n"
        self.assertEqual(s.count(a), 1)
        with open(b.stub_hermes, "w") as f:
            f.write(s.replace(a, a + self.MOVE % (git, b.repo, move, pre, post), 1))
        b.scenario(UP_AVAIL, yes="→ Fetching new code\n", receipt={})
        return b, b.run(apply="1")

    def test_legacy_exit0_real_move_matching_receipt_is_install(self):
        b, p = self.legacy()
        self.assertEqual(p.returncode, 0, b.log())
        self.assertRegex(b.st("last_install_ts") or "", r"^[0-9]{9,}$")
        self.assertIn("agrees=1", b.log())
        self.assertTrue(any("updated to" in t for t in b.texts()), b.texts())

    def test_legacy_mismatched_or_unmoved_is_not_install(self):
        for kw in ({"post": "'deadbeef'"}, {"move": False, "post": "'cafebabe'"}, {"move": False}):
            with self.subTest(**{k: str(v) for k, v in kw.items()}):
                b, p = self.legacy(**kw)
                self.assertIsNone(b.st("last_install_ts"))
                self.assertFalse(any("updated to" in t for t in b.texts()), b.texts())
                # PATCH4 (assertion changed, spec-driven): the demoted legacy receipt leaves the run to
                # the no-receipt rules. The checkout moved -> install UNPROVEN (exit 1, marker); it did
                # not move -> no-op (was: unrecognized text -> inconclusive exit 1).
                # PATCH5 (assertion changed, spec-driven; PATCH4 had exit 0 for the unmoved rows): an
                # uncorrelated receipt never proves the no-op -> exit 1, one ⚠ reminder, no marker.
                if kw.get("move", True):
                    self.assertEqual(p.returncode, 1, b.log())
                    self.assertTrue(any("checkout moved" in t for t in b.texts()), b.texts())
                    self.assertIsNotNone(b.st("drain_pending"), b.log())
                else:
                    self.assertEqual(p.returncode, 1, b.log())
                    self.assertIn("no-op: checkout unchanged", b.log())
                    self.assertEqual(len(b.reminders()), 1, b.texts())
                    self.assertIsNone(b.st("drain_pending"), b.log())

    def test_foreign_correlation_id_is_not_install_evidence(self):
        b = self.box()
        b.scenario(UP_AVAIL, yes=DONE_NEW, receipt=dict(GOOD, correlation_id="au-someone-else-1"))
        p = b.run(apply="1")
        self.assertEqual(p.returncode, 1, b.log())
        self.assertIsNone(b.st("last_install_ts"))
        self.assertFalse(any("updated to" in t for t in b.texts()), b.texts())
        t = b.texts()
        self.assertEqual(len(t), 1, t)
        self.assertIn("unproven", t[0])
        # the first-layer guard (receipt_outcome_fresh) must classify it, not only the fallback
        self.assertIn("receipt=stale", t[0])
        self.assertIsNotNone(b.st("drain_pending"))


class OptionD(T):
    """PATCH5 (option D, WO-HAU-MAIN-PATCH5 acceptance): silence needs positive evidence.
    Promise 1: without a receipt of this run, never silent. Promise 2: without evidence, never
    mark_installed. The gen-3 receipts are the REAL ones (verify/fixtures, evidence-patch5)."""
    # update_receipt.record_followup's line (v0.23.2 update_receipt.py:426) with the retry text of
    # update_completion._settle_after_commit for "dependencies". Reason chosen WITHOUT an error word:
    # with one (e.g. "... failed") the error veto already makes it a counted real failure.
    FOLLOWUP_LINE = ("  ⚠ Update follow-up 'dependencies' did not finish: No module named 'fastapi'"
                     " (dependencies not installed yet — the next launch retries)\n")

    def seeded(self):
        b = self.box()
        b.seed("consec_real_fails", "8")
        b.seed("real_alert_last_ts", str(T0 - 100))
        b.seed("drain_pending", "1")
        return b

    def assert_unproven(self, b, p, n_reminders=1):
        self.assertEqual(p.returncode, 1, b.log())
        self.assertEqual(len(b.reminders()), n_reminders, b.texts())
        self.assertFalse(any(t.startswith("✗") for t in b.texts()), b.texts())
        self.assertEqual(b.st("consec_real_fails"), "8", b.log())
        self.assertEqual(b.st("real_alert_last_ts"), str(T0 - 100), b.log())
        self.assertIsNone(b.st("last_install_ts"))
        self.assertIn("UNPROVEN", b.log())
        self.assertNotIn("error in --yes output", b.log())

    def test_source_repair_still_unhealthy_reminds_then_throttles(self):
        # evidence-r6A/probes/source-repair.py still-unhealthy (v2026.7.20, no receipt): B1100.
        b = self.seeded()
        b.scenario(LEGACY_AVAIL, yes=SRC_REPAIR_STILL_UNHEALTHY)
        p = b.run(apply="1", now=T0)
        self.assert_unproven(b, p)
        self.assertIn("Venv still unhealthy after repair", b.reminders()[0])
        self.assertIsNone(b.st("drain_pending"), b.log())   # healthy gateway: the drain recheck cleared it
        # again within 24h: throttled, logged, still nothing counted or reset
        b.scenario(LEGACY_AVAIL, yes=SRC_REPAIR_STILL_UNHEALTHY)
        p = b.run(apply="1", now=T0 + 6 * 3600)
        self.assert_unproven(b, p, n_reminders=1)
        self.assertIn("reminder suppressed", b.log())
        self.assertEqual(b.st("consec_available_noop"), "2", b.log())

    def test_source_repair_then_check_up_to_date(self):
        # The sent reminder stands. The up-to-date check keeps its PRE-EXISTING rule (D3, v5.15 check
        # path: a conclusive no-install verdict resets consec_real_fails and ends the available streak).
        # So the NEXT unproven no-op reminds at once instead of waiting for the interval.
        b = self.seeded()
        b.scenario(LEGACY_AVAIL, yes=SRC_REPAIR_STILL_UNHEALTHY)
        self.assert_unproven(b, b.run(apply="1", now=T0))
        b.scenario(NOOP)
        p = b.run(apply="1", now=T0 + 3600)
        self.assertEqual(p.returncode, 0, b.log())
        self.assertEqual(len(b.reminders()), 1, b.texts())
        self.assertEqual(b.st("consec_real_fails"), "0", b.log())      # existing check-path rule
        self.assertEqual(b.st("consec_available_noop"), "0", b.log())
        self.assertIsNone(b.st("available_noop_alert_last_ts"))
        b.scenario(LEGACY_AVAIL, yes=SRC_REPAIR_STILL_UNHEALTHY)
        p = b.run(apply="1", now=T0 + 7200)
        self.assertEqual(p.returncode, 1, b.log())
        self.assertEqual(len(b.reminders()), 2, b.texts())              # not throttled by the old stamp

    def test_legacy_noop_reminds_by_design(self):
        # r4A legacy-noop.py: v2026.7.20's normal no-op, --check said available.
        b = self.seeded()
        b.scenario(LEGACY_AVAIL, yes=LEGACY_YES_NOOP_0720)
        p = b.run(apply="1", now=T0)
        self.assert_unproven(b, p)
        self.assertIn("✓ Already up to date!", b.reminders()[0])

    def test_gen3_proven_noop_is_silent_and_resets(self):
        for fixture in (GEN3_NOOP, GEN3_NOOP_0216):
            with self.subTest(fixture=fixture):
                b = self.seeded()
                b.proven(UP_AVAIL, REAL_YES_NOOP, now=T0, fixture=fixture)
                p = b.run(apply="1", now=T0)
                self.assertEqual(p.returncode, 0, b.log())
                self.assertEqual(b.texts(), [])
                self.assertEqual(b.st("consec_real_fails"), "0", b.log())
                self.assertIsNone(b.st("last_install_ts"))
                self.assertIsNone(b.st("drain_pending"), b.log())
                self.assertIn("PROVEN by this run's receipt", b.log())
                with open(os.path.join(b.rdir, "latest.json")) as f:
                    rec = json.load(f)
                self.assertTrue(rec["correlation_id"].startswith("au-"), rec)   # really this run's id
                self.assertEqual(rec["stages"], real_receipt(fixture)["stages"])   # the real shape

    def test_gen3_without_usable_receipt_reminds(self):
        def other_sha(b):   # the fixture's own (foreign) SHAs, not this checkout's
            b.scenario(UP_AVAIL, yes=REAL_YES_NOOP, receipt=real_receipt(GEN3_NOOP, T0), correlate=True)
        cases = (
            ("missing", lambda b: b.scenario(UP_AVAIL, yes=REAL_YES_NOOP)),
            ("id-mismatch", lambda b: b.scenario(UP_AVAIL, yes=REAL_YES_NOOP, head_sha=True,
                                                 receipt=real_receipt(GEN3_NOOP, T0, correlation_id="au-1-2-3"))),
            ("id-null-manual-run", lambda b: b.scenario(UP_AVAIL, yes=REAL_YES_NOOP, head_sha=True,
                                                        receipt=real_receipt(GEN3_NOOP, T0, correlation_id=None))),
            ("stale", lambda b: b.scenario(UP_AVAIL, yes=REAL_YES_NOOP, correlate=True, head_sha=True,
                                           receipt=dict(real_receipt(GEN3_NOOP), finished_at="2020-01-01T00:00:00+00:00"))),
            ("followups-owed", lambda b: b.proven(UP_AVAIL, REAL_YES_NOOP + self.FOLLOWUP_LINE, now=T0,
                                                  fixture=GEN3_DEPS_OWED)),
            ("user-action-owed", lambda b: b.proven(UP_AVAIL, REAL_YES_NOOP, now=T0,
                                                    user_action={"step": "stash", "reason": "parked"})),
            ("sha-not-this-checkout", other_sha),
        )
        for name, setup in cases:
            with self.subTest(case=name):
                b = self.seeded()
                setup(b)
                p = b.run(apply="1", now=T0)
                self.assert_unproven(b, p)

    def test_gen2_style_receipt_without_our_id_reminds(self):
        # A success receipt with the real no-op shape and this checkout's SHAs but NO correlation id
        # (second generation v2026.8.19..v2026.9.24, or a hand-run third-generation update). The gate
        # neuter "corrmatch" (CORR_STATE=match removed from PROVEN_NOOP) must turn this red.
        b = self.seeded()
        rec = real_receipt(GEN3_NOOP, T0)
        rec.pop("correlation_id")
        b.scenario(UP_AVAIL, yes=REAL_YES_NOOP, receipt=rec, head_sha=True)
        p = b.run(apply="1", now=T0)
        self.assert_unproven(b, p)
        self.assertIn("correlation=legacy", b.log())

    def test_wordgap_without_receipt_reminds_on_the_first_tick(self):
        # r6B B1202: no error word in either line; no receipt -> the FIRST tick reminds (was the 3rd).
        b = self.seeded()
        b.scenario(LEGACY_AVAIL, yes=WORDGAP)
        p = b.run(apply="1", now=T0)
        self.assert_unproven(b, p)
        self.assertIn("state.db is corrupted after update", b.reminders()[0])



# ===================== v5.16: owed actions after a proven install + B1300 =====================
# The 2026-11-18 install (v0.23.1 -> v0.23.2): `hermes update --yes` exit 1, receipt outcome=partial,
# SHA advanced, user_action {"step": "local_changes", ...} with the stash ref. verify/fixtures/
# receipt_partial_user_action_v0.23.2.json is that receipt with its field structure kept and host
# paths / profile names / the launcher's correlation id replaced. Its --yes tail as logged (profile
# rows trimmed): no completion line, so the SHA advance is the only install evidence.
GEN3_USER_ACTION = "receipt_partial_user_action_v0.23.2.json"
STASH_REF = "db17cef519b64af49b09d3741e9e4df709a23acc"
INCIDENT_YES = (
    "→ Checking configuration for new options...\n  ✓ Configuration is up to date\n\n"
    "⚠ hermes update stashed 1 local modification(s) and did NOT restore them.\n"
    "  Stash ref: %s\n  Review with: git stash show --stat %s\n"
    "  Re-apply with: git stash show -p %s | git apply --3way [detached @ ae2a81ccc0]\n\n"
    "Fleet version check:\n  ✓ default (pid 4242) @ ae2a81cc — up to date\n" % (STASH_REF, STASH_REF, STASH_REF))
OWED = "receipt says something is still owed"


class OwedActionNotice(T):
    """v5.16: every path that reaches mark_installed relays the receipt's user_action / followups as
    ONE ⚠ reminder per update_id (delivered after the ✓ notice, retried until delivered), and changes
    nothing else: same install verdict, counters, exit code and ✓ text as without the fields."""

    def owed(self, b):
        return [t for t in b.texts() if OWED in t]

    def ok_install(self, b, p, rc=0):
        self.assertEqual(p.returncode, rc, b.log())
        self.assertRegex(b.st("last_install_ts") or "", r"^[0-9]{9,}$", b.log())
        self.assertEqual(b.st("consec_real_fails"), "0", b.log())
        self.assertEqual(b.st("consec_available_noop"), "0", b.log())
        self.assertTrue(any(t.startswith("✓ hermes agent updated") for t in b.texts()), b.texts())
        self.assertNotIn("Traceback", p.stderr)

    def incident(self, b, yes_rc=1, **over):
        b.scenario(UP_AVAIL, yes=INCIDENT_YES, yes_rc=yes_rc, correlate=True,
                   receipt=real_receipt(GEN3_USER_ACTION, **over))

    def test_incident_partial_sha_advance_user_action_reminds_once(self):
        # The real sequence: exit 1 + partial + SHA advance (race path), then the same update_id again.
        b = self.box()
        b.seed("consec_real_fails", "2")
        b.seed("consec_available_noop", "2")
        self.incident(b)
        p = b.run(apply="1")
        self.ok_install(b, p)
        self.assertIn("exit=1 but receipt=partial", b.log())
        o = self.owed(b)
        self.assertEqual(len(o), 1, b.texts())
        self.assertEqual(len(b.texts()), 2, b.texts())                       # ✓ + ⚠, nothing else
        self.assertTrue(b.texts()[0].startswith("✓ hermes agent updated"), b.texts())
        for want in ("user action [local_changes]", "Stash ref: " + STASH_REF,
                     "Re-apply with: git stash show -p " + STASH_REF + " | git apply --3way",
                     "outcome=partial", "update_id=a1873614d1af42e9a639deff0f4f861c", "updater v5.16"):
            self.assertIn(want, o[0])
        self.assertNotIn("✗", o[0])
        self.assertEqual(b.st("owed_action_notified"), "id-a1873614d1af42e9a639deff0f4f861c", b.log())
        self.assertEqual(os.listdir(os.path.join(b.state, "owed_action_pending")), [])
        # same receipt (update_id) again: still an install, no second reminder
        self.incident(b)
        p = b.run(apply="1")
        self.ok_install(b, p)
        self.assertEqual(len(self.owed(b)), 1, b.texts())
        self.assertEqual(len(b.texts()), 3, b.texts())                       # only the second ✓
        self.assertIn("already delivered — not repeated", b.log())

    def test_partial_exit0_paths_remind(self):
        # partial + exit 0: gateway confirmed (healthy), and the drain-timeout branch (unhealthy).
        for healthy in (True, False):
            with self.subTest(healthy=healthy):
                b = self.box()
                if not healthy:
                    with open(b.gw, "w") as f:
                        f.write('{"code_sha": "0000000000000000000000000000000000000000"}')
                self.incident(b, yes_rc=0)
                p = b.run(apply="1")
                self.assertEqual(p.returncode, 0, b.log())
                self.assertRegex(b.st("last_install_ts") or "", r"^[0-9]{9,}$")
                self.assertEqual(len(self.owed(b)), 1, b.texts())
                self.assertIn("Stash ref: " + STASH_REF, self.owed(b)[0])
                self.assertEqual(len(b.texts()), 2, b.texts())
                if healthy:
                    self.assertTrue(b.texts()[0].startswith("✓ hermes agent updated"), b.texts())
                else:
                    self.assertIn("still draining", b.texts()[0])

    def test_correlated_success_with_followups_reminds(self):
        fu = [{"step": "dependencies", "reason": "No module named 'fastapi'", "at": "2026-11-18T21:24:38+00:00"},
              {"step": "build", "reason": "web UI build exited 1", "at": "2026-11-18T21:27:40+00:00"}]
        for out, rc in ((REAL_YES_INSTALL, 0), (INCIDENT_YES, 0), (REAL_YES_INSTALL, 1)):
            with self.subTest(out=out[:20], rc=rc):
                b = self.box()
                b.scenario(UP_AVAIL, yes=out, yes_rc=rc, correlate=True,
                           receipt=real_receipt(GEN3_USER_ACTION, outcome="success", user_action=None, followups=fu))
                p = b.run(apply="1")
                self.ok_install(b, p)
                o = self.owed(b)
                self.assertEqual(len(o), 1, b.texts())
                self.assertEqual(len(b.texts()), 2, b.texts())
                self.assertIn("follow-up [dependencies]: No module named 'fastapi'", o[0])
                self.assertIn("follow-up [build]: web UI build exited 1", o[0])
                self.assertIn("outcome=success", o[0])
                self.assertNotIn("user action", o[0])

    def test_legacy_install_with_user_action_reminds(self):
        # A legacy receipt (no correlation_id) accepted on this run's own completion line.
        b = self.box()
        b.scenario(LEGACY_AVAIL, yes=DONE_OLD, receipt={"outcome": "success",
                   "user_action": {"step": "local_changes", "reason": "Stash ref: " + STASH_REF}})
        p = b.run(apply="1")
        self.ok_install(b, p)
        self.assertEqual(len(self.owed(b)), 1, b.texts())
        self.assertIn(STASH_REF, self.owed(b)[0])
        self.assertTrue(self.owed(b)[0].startswith("⚠ hermes auto-update: Hermes was updated to (v9.9.9)"), self.owed(b)[0])
        self.assertTrue(b.st("owed_action_notified", ).startswith("sha-"), b.log())   # no update_id: digest key

    def test_nothing_owed_is_exactly_as_before(self):
        # No / empty user_action and followups: the same single ✓ notice, exit code and state as v5.15,
        # and no owed-action state is created at all.
        empties = ({}, {"user_action": None, "followups": None}, {"user_action": {}, "followups": []},
                   {"user_action": "", "followups": ""}, {"user_action": False, "followups": False},
                   {"user_action": 0, "followups": 0})
        paths = (("success-exit0", REAL_YES_INSTALL, 0, "success"), ("partial-exit0", INCIDENT_YES, 0, "partial"),
                 ("race-exit1", INCIDENT_YES, 1, "partial"))
        for name, out, rc, outcome in paths:
            for i, e in enumerate(empties):
                with self.subTest(path=name, empty=i):
                    b = self.box()
                    rec = real_receipt(GEN3_USER_ACTION, outcome=outcome)
                    rec.pop("user_action")
                    rec.update(e)
                    b.scenario(UP_AVAIL, yes=out, yes_rc=rc, correlate=True, receipt=rec)
                    p = b.run(apply="1")
                    self.ok_install(b, p)
                    self.assertEqual(len(b.texts()), 1, b.texts())
                    self.assertEqual(self.owed(b), [])
                    self.assertIsNone(b.st("owed_action_notified"))
                    self.assertFalse(os.path.exists(os.path.join(b.state, "owed_action_pending")), b.log())
                    self.assertNotIn("owed action", b.log())

    def test_malformed_fields_never_crash_never_silent(self):
        long = "Stash ref: " + STASH_REF + " " + "x" * 100000
        cases = (
            ("ua-string", {"user_action": "re-apply stash " + STASH_REF}, STASH_REF),
            ("ua-list", {"user_action": ["local_changes", STASH_REF]}, STASH_REF),
            ("ua-true", {"user_action": True}, "user action: true"),
            ("ua-number", {"user_action": 7}, "user action: 7"),
            ("ua-dict-no-fields", {"user_action": {"foo": "bar"}}, '"foo": "bar"'),
            ("ua-dict-empty-fields", {"user_action": {"step": "", "reason": None}}, "user action"),
            ("ua-reason-nested", {"user_action": {"step": ["a"], "reason": {"ref": STASH_REF}}}, STASH_REF),
            ("ua-overlong", {"user_action": {"step": "s" * 5000, "reason": long}}, "Stash ref: " + STASH_REF),
            ("ua-control-chars", {"user_action": {"step": "local\x1b[31m_changes\x07",
                                                  "reason": "line1\nline2\r\x00\x1b]0;title\x07 " + STASH_REF}}, STASH_REF),
            ("fu-dict", {"followups": {"step": "build", "reason": "owed"}}, "follow-up [build]: owed"),
            ("fu-string", {"followups": "dependencies still owed"}, "follow-up: dependencies still owed"),
            ("fu-mixed-items", {"followups": [None, 5, "text", {"step": None}, [], {"name": "n", "detail": "d"}]},
             "follow-up [n]: d"),
            ("fu-only-empty-items", {"followups": [None, "", {}]}, "follow-up: (no details in the receipt)"),
            ("fu-huge", {"followups": [{"step": "s%d" % i, "reason": "r" * 400} for i in range(1000)]}, "more follow-up entries"),
            ("uid-traversal", {"user_action": {"step": "x", "reason": "y"}, "update_id": "../../../etc/x"}, "update_id=../../../etc/x"),
            ("uid-number", {"user_action": {"step": "x", "reason": "y"}, "update_id": 12345}, "update_id=12345"),
            ("uid-overlong", {"user_action": {"step": "x", "reason": "y"}, "update_id": "a" * 5000}, "user action [x]: y"),
            ("uid-missing", {"user_action": {"step": "x", "reason": "y"}, "update_id": None}, "update_id=none"),
        )
        for name, over, want in cases:
            with self.subTest(case=name):
                b = self.box()
                self.incident(b, **over)
                p = b.run(apply="1")
                self.ok_install(b, p)
                o = self.owed(b)
                self.assertEqual(len(o), 1, (b.texts(), b.log()[-2000:]))
                self.assertIn(want, o[0])
                self.assertLessEqual(len(o[0].encode("utf-8")), 3500)
                self.assertNotIn("\x1b", o[0])
                self.assertNotIn("\x00", o[0])
                key = b.st("owed_action_notified")
                self.assertRegex(key or "", r"^(id-[0-9A-Za-z_-]{1,128}|sha-[0-9a-f]{64})$")
                self.assertEqual(os.listdir(os.path.join(b.state, "owed_action_pending")), [])
                self.assertFalse(os.path.exists(os.path.join(b.root, "etc")), b.root)

    def test_undelivered_reminder_keeps_install_and_retries_until_delivered(self):
        b = self.box()
        b.notify_fails(True)
        self.incident(b)
        p = b.run(apply="1")
        self.assertEqual(p.returncode, 0, b.log())                            # install verdict unchanged
        self.assertRegex(b.st("last_install_ts") or "", r"^[0-9]{9,}$")
        self.assertEqual(b.st("consec_real_fails"), "0", b.log())
        self.assertIn("owed-action reminder NOT delivered", b.log())
        self.assertIsNone(b.st("owed_action_notified"))                       # stamped only on delivery
        pend = os.path.join(b.state, "owed_action_pending")
        self.assertEqual(os.listdir(pend), ["id-a1873614d1af42e9a639deff0f4f861c"])
        self.assertGreaterEqual(int(b.st("consec_notify_fails")), 2, b.log())   # notify()'s own failure path
        # next tick: nothing to install (check up to date), channel still dead -> still pending
        b.scenario(NOOP)
        p = b.run(apply="1")
        self.assertEqual(p.returncode, 0, b.log())
        self.assertEqual(os.listdir(pend), ["id-a1873614d1af42e9a639deff0f4f861c"])
        # channel back: delivered at the start of the next tick, exactly once
        b.notify_fails(False)
        b.scenario(NOOP)
        p = b.run(apply="1")
        self.assertEqual(p.returncode, 0, b.log())
        delivered = [t for t in self.owed(b) if "Stash ref: " + STASH_REF in t]
        self.assertGreaterEqual(len(delivered), 1, b.texts())
        self.assertEqual(os.listdir(pend), [])
        self.assertEqual(b.st("owed_action_notified"), "id-a1873614d1af42e9a639deff0f4f861c")
        n = len(self.owed(b))
        b.scenario(NOOP)
        b.run(apply="1")
        self.assertEqual(len(self.owed(b)), n, b.texts())                     # never again

    def test_noop_and_failure_paths_do_not_use_the_install_reminder(self):
        # The reminder belongs to proven installs only: a receipt owing an action on a no-op / unproven /
        # failed run keeps its existing handling (PATCH5 reminder or real failure), no owed-action text.
        for name, setup, rc in (
            ("proven-shape-noop-owing", lambda b: b.proven(UP_AVAIL, REAL_YES_NOOP, now=T0,
                                                         user_action={"step": "stash", "reason": "parked"}), 1),
            ("failed-outcome", lambda b: b.scenario(UP_AVAIL, yes=YES_FAIL, yes_rc=1, correlate=True,
                                                    receipt=real_receipt(GEN3_USER_ACTION, T0, outcome="failed")), 1)):
            with self.subTest(case=name):
                b = self.box()
                setup(b)
                p = b.run(apply="1", now=T0)
                self.assertEqual(p.returncode, rc, b.log())
                self.assertIsNone(b.st("last_install_ts"))
                self.assertEqual(self.owed(b), [], b.texts())


class ShaAdvanceB1300(T):
    """B1300 (verdict-r7A): receipt_sha_advanced compares full SHAs when both sides carry one, else the
    common prefix; a short_sha length change (7 vs 8) of the SAME commit is not an advance. Entry
    sequence of evidence-r7A/entry_probes.py forged-short-length-change, plus the short-only variant."""

    def forged(self, sides, out=YES_NOOP):
        b = self.box()
        b.seed("consec_real_fails", "8")
        h = subprocess.run([shutil.which("git"), "-C", b.repo, "rev-parse", "HEAD"], capture_output=True,
                           text=True, check=True).stdout.strip()
        rec = real_receipt(GEN3_NOOP, T0)
        pre, post = sides(h)
        rec["pre_update"], rec["post_update"] = pre, post
        b.scenario(REAL_CHECK, yes=out, receipt=rec, correlate=True)
        return b, b.run(apply="1", now=T0), h

    def test_forged_short_length_change_is_not_an_install(self):
        cases = (
            ("r7A-full-equal-short-7-8", lambda h: ({"sha": h, "short_sha": h[:7]}, {"sha": h, "short_sha": h[:8]})),
            ("short-only-7-8", lambda h: ({"short_sha": h[:7]}, {"short_sha": h[:8]})),
            ("short-only-8-12", lambda h: ({"short_sha": h[:12]}, {"short_sha": h[:8]})),
            ("short-vs-full", lambda h: ({"short_sha": h[:8]}, {"sha": h})),
            ("case-only", lambda h: ({"short_sha": h[:8].upper()}, {"short_sha": h[:8]})),
            ("full-equal-short-garbage", lambda h: ({"sha": h, "short_sha": "0000000"}, {"sha": h, "short_sha": h[:8]})),
            ("non-hex-shorts", lambda h: ({"short_sha": "pre-sha"}, {"short_sha": "post-sha"})),
            ("six-hex-shorts", lambda h: ({"short_sha": "abcdef"}, {"short_sha": "123456"})),
            ("non-string-shas", lambda h: ({"sha": 1, "short_sha": ["a" * 8]}, {"sha": None, "short_sha": 12345678})),
        )
        for out in (YES_NOOP, "→ Fetching updates...\n"):
            for name, sides in cases:
                with self.subTest(case=name, out=out.strip()):
                    b, p, _h = self.forged(sides, out)
                    self.assertIsNone(b.st("last_install_ts"), b.log())
                    self.assertFalse(any("updated to" in t for t in b.texts()), b.texts())
                    self.assertNotIn("success $", b.log())
                    if name == "case-only":
                        # same commit in both cases: a genuine no-op receipt (PROVEN, silent) — or, with no
                        # no-op line, still never an install
                        continue
                    self.assertEqual(p.returncode, 1, b.log())
                    self.assertTrue(b.texts(), b.log())                       # never silent either
                    self.assertNotIn("PROVEN by this run's receipt", b.log())

    def test_real_advance_still_installs(self):
        # Positive controls on the discriminating output (no completion line): only the SHAs decide.
        other = "1234567890abcdef1234567890abcdef12345678"
        for name, sides in (
            ("full-differ", lambda h: ({"sha": h, "short_sha": h[:8]}, {"sha": other, "short_sha": other[:8]})),
            ("short-only-differ", lambda h: ({"short_sha": h[:8]}, {"short_sha": other[:8]})),
            ("full-differ-same-short-prefix", lambda h: ({"sha": h}, {"sha": h[:8] + other[8:]})),
            ("mixed-full-short", lambda h: ({"sha": h}, {"short_sha": other[:8]}))):
            with self.subTest(case=name):
                b, p, _h = self.forged(sides, "→ Fetching updates...\n")
                self.assertEqual(p.returncode, 0, b.log())
                self.assertRegex(b.st("last_install_ts") or "", r"^[0-9]{9,}$", b.log())
                self.assertTrue(any("updated to" in t for t in b.texts()), b.texts())

    def test_malformed_side_is_not_an_advance(self):
        # A short_sha that is not a prefix of its own side's full sha: malformed receipt, no evidence.
        other = "1234567890abcdef1234567890abcdef12345678"
        b, p, _h = self.forged(lambda h: ({"sha": h, "short_sha": h[:8]}, {"sha": other, "short_sha": "deadbeef"}),
                               "→ Fetching updates...\n")
        self.assertEqual(p.returncode, 1, b.log())
        self.assertIsNone(b.st("last_install_ts"), b.log())


class CorpusToolFailsClosed(T):
    """PATCH5 B1102: scripts/upstream_print_corpus.py must fail (non-zero) on a source it cannot
    parse, on a tag with 0 print() templates, and on an empty (a)/(b) corpus, in the scan mode and in
    --gate mode. AU_CORPUS_TOOL selects the tool under test (the release gate's neuter)."""
    TOOL = os.environ.get("AU_CORPUS_TOOL") or os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                            "upstream_print_corpus.py")
    GOOD = ("def _cmd_update_check():\n    print('✓ Already up to date.')\n\n"
            "def _cmd_update_impl():\n    print('→ Fetching updates...')\n")

    def tool(self, *args):
        d = tempfile.mkdtemp(prefix="au-corpus-")
        self.addCleanup(shutil.rmtree, d, True)
        return subprocess.run([sys.executable, "-I", self.TOOL, SRC, "--review", os.path.join(d, "none.json")] + list(args),
                              capture_output=True, text=True, timeout=300)

    def repo(self, versions):
        r = tempfile.mkdtemp(prefix="au-corpus-repo-")
        self.addCleanup(shutil.rmtree, r, True)
        env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
        g = lambda *a: subprocess.run(["git", "-C", r] + list(a), env=env, check=True, capture_output=True)
        g("init", "-q")
        os.makedirs(os.path.join(r, "hermes_cli"))
        for tag, body in versions:
            with open(os.path.join(r, "hermes_cli", "update_cmd.py"), "w", encoding="utf-8") as f:
                f.write(body)
            g("add", "-A")
            g("-c", "user.name=t", "-c", "user.email=t@invalid", "commit", "-q", "--allow-empty", "-m", tag)
            g("tag", tag)
        return r

    def snapshot(self, **over):
        d = tempfile.mkdtemp(prefix="au-corpus-snap-")
        self.addCleanup(shutil.rmtree, d, True)
        snap = {"schema": 1, "tags": ["v1.0.0", "v1.0.1"], "excluded_tags": {}, "parse_errors": {},
                "prints_per_tag": {"v1.0.0": 2, "v1.0.1": 2},
                "templates": [{"t": "✓ Already up to date.", "reach": ["check"], "first": "v1.0.0", "last": "v1.0.1",
                               "tags": 2, "at": "hermes_cli/update_cmd.py:2@v1.0.1"},
                              {"t": "→ Fetching updates...", "reach": ["yes"], "first": "v1.0.0", "last": "v1.0.1",
                               "tags": 2, "at": "hermes_cli/update_cmd.py:5@v1.0.1"}]}
        snap.update(over)
        p = os.path.join(d, "snap.json")
        with open(p, "w", encoding="utf-8") as f:
            json.dump(snap, f, ensure_ascii=False)
        return p

    def test_scan_good_fixture_passes(self):
        q = self.tool("--repo", self.repo([("v1.0.0", self.GOOD), ("v1.0.1", self.GOOD)]))
        self.assertEqual(q.returncode, 0, q.stdout + q.stderr)
        self.assertIn("UPSTREAM CORPUS: PASS", q.stdout)

    def test_scan_parse_error_fails(self):
        q = self.tool("--repo", self.repo([("v1.0.0", self.GOOD), ("v1.0.1", "def broken(:\n    print('x'\n")]))
        self.assertNotEqual(q.returncode, 0, q.stdout + q.stderr)
        self.assertIn("parse error", q.stdout)
        self.assertIn("v1.0.1", q.stdout)

    def test_scan_zero_print_tag_fails(self):
        q = self.tool("--repo", self.repo([("v1.0.0", self.GOOD), ("v1.0.1", "def _cmd_update_check():\n    return 0\n")]))
        self.assertNotEqual(q.returncode, 0, q.stdout + q.stderr)
        self.assertIn("0 print() templates", q.stdout)

    def test_scan_no_release_tag_fails(self):
        q = self.tool("--repo", self.repo([("not-a-release", self.GOOD)]))
        self.assertNotEqual(q.returncode, 0, q.stdout + q.stderr)

    def test_gate_good_snapshot_passes(self):
        q = self.tool("--gate", "--snapshot", self.snapshot())
        self.assertEqual(q.returncode, 0, q.stdout + q.stderr)

    def test_gate_vacuous_or_broken_snapshot_fails(self):
        for name, over in (("parse-errors", {"parse_errors": {"v1.0.1": ["hermes_cli/update_cmd.py: SyntaxError"]}}),
                           ("zero-prints", {"prints_per_tag": {"v1.0.0": 2, "v1.0.1": 0}}),
                           ("no-templates", {"templates": []}),
                           ("no-check-lines", {"templates": [{"t": "→ Fetching updates...", "reach": ["yes"],
                                                              "first": "v1.0.0", "last": "v1.0.1", "tags": 2,
                                                              "at": "hermes_cli/update_cmd.py:5@v1.0.1"}]}),
                           ("no-parse-error-table", {"parse_errors": None})):
            with self.subTest(case=name):
                q = self.tool("--gate", "--snapshot", self.snapshot(**over))
                self.assertNotEqual(q.returncode, 0, q.stdout + q.stderr)
                self.assertIn("UPSTREAM CORPUS: FAIL", q.stdout)


def main():
    global SRC
    if len(sys.argv) < 2 or not os.path.isfile(sys.argv[1]):
        sys.stderr.write("usage: check_compat_sanity.py path/to/auto_update.sh\n")
        return 2
    SRC = os.path.abspath(sys.argv[1])
    for tool in ("flock", "timeout"):
        if not shutil.which(tool):
            sys.stderr.write("missing required tool: %s\n" % tool)
            return 2
    # Optional extra arguments select tests (e.g. "RollbackReminder" or "Verdicts.test_held_is_benign").
    prog = unittest.main(argv=[sys.argv[0]] + sys.argv[2:], exit=False, verbosity=1)
    ok = prog.result.wasSuccessful()
    sys.stderr.flush()
    print("compat sanity: %s (%d tests, src=%s)" % ("PASS" if ok else "FAIL", prog.result.testsRun, SRC))
    sys.stdout.flush()
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
