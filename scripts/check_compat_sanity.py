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
STABLE_AVAIL = BANNER + "⬆ Selected release available: v1.3.0 (current v1.2.3)\n"
LEGACY_AVAIL = "⚕ Update available: 3 commits behind origin/main.\n  Run 'hermes update' to install.\n"
DONE_NEW = "→ Fetching v1.3.0\n✓ Update complete! (v1.2.3 → v1.3.0) [detached @ abc1234]\n"
DONE_OLD = "✓ Update complete! (v9.9.9)\n"
NOOP = "✓ Already up to date.\n"
GOOD = {"kind": "update", "outcome": "success",
        "pre_update": {"short_sha": "aaaaaaaa"}, "post_update": {"short_sha": "bbbbbbbb"}}
CHECK_FAIL = "✗ fetch failed: HTTP 429\n"
ALERT = "⚠ hermes auto-update: update check"


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

    def scenario(self, check, rc=0, yes=None, yes_rc=0, receipt=None):
        sc = {"check": {"out": check, "rc": rc}}
        if yes is not None:
            sc["yes"] = {"out": yes, "rc": yes_rc, "receipt": receipt}
        self._w(os.path.join(self.root, "scenario.json"), json.dumps(sc))

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
        for out in (BANNER + "✓ Up to date with the latest release (v1.2.3)\n",
                    BANNER + "→ No newer release than v1.2.3\n", NOOP):
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
        b.scenario(BANNER + "→ Holding at this build (v1.2.3, channel pinned)\n", yes=DONE_NEW, receipt=GOOD)
        p = b.run(apply="1")
        self.assertEqual(p.returncode, 0, b.log())
        self.assertFalse(b.yes_called())
        self.assertEqual(b.texts(), [])
        self.assertEqual(b.st("consec_check_fails"), "0")
        self.assertIn("held (benign", b.log())

    def test_rollback_never_installs_and_notifies_once(self):
        b = self.box()
        b.scenario(BANNER + "→ This checkout is newer than the selected release (v1.3.0)\n", yes=DONE_NEW, receipt=GOOD)
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
        b, _ = self.refused("✓ Up to date with the latest release\n⬆ Selected release available: v1.3.0\n")
        self.assertEqual(b.st("consec_check_fails"), "1")

    def test_error_line_beside_available_fails_closed(self):
        b, _ = self.refused("⬆ Selected release available: v1.3.0\n✗ signature verification failed\n")
        self.assertEqual(b.st("consec_check_fails"), "1")

    def test_nonzero_check_fails_closed_despite_available_text(self):
        b, _ = self.refused("⬆ Selected release available: v1.3.0\n✗ fetch failed: HTTP 429\n", rc=1)
        self.assertEqual(b.st("consec_check_fails"), "1")
        self.assertIn("check failed (exit 1)", b.log())

    NOISY = (BANNER + "\nDEBUG: fetched tags in 0.2s\n   ⬆  Selected release available: v1.3.0\r\n"
             "  Run 'hermes update' to install.\n")

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
        for now, want in ((first + 3600, 1), (first + DAY - 1, 1), (first + DAY, 2),
                          (first + DAY + 3600, 2), (first + 2 * DAY - 1, 2), (first + 2 * DAY, 3)):
            b.run(now=now)
            self.assertEqual(len(b.alerts()), want, "at +%ds" % (now - first))
        self.assertEqual(b.st("check_alert_last_ts"), str(first + 2 * DAY))

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

    def test_noop_without_fresh_receipt_is_silent_and_unmarked(self):
        # Intentional conservative behaviour: nothing proven installed, nothing claimed.
        for label, rc, old in self.cases():
            for out in (NOOP, "→ Holding at this build (v1.2.3)\n"):
                with self.subTest(receipt=label, out=out):
                    b = self.box()
                    if old:
                        b.old_receipt(old)
                    b.scenario(STABLE_AVAIL, yes=out, receipt=rc)
                    p = b.run(apply="1")
                    self.assertTrue(b.yes_called())
                    self.assertEqual(p.returncode, 0, b.log())
                    self.assertEqual(b.texts(), [])
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
    AV = "⬆ Selected release available: v1.3.0\n"

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
        b, _ = self.go(LEGACY_AVAIL, yes="→ Fetching origin/main\n", receipt={"outcome": "success"})
        self.assertTrue(b.yes_called())
        self.no_success(b)

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
        b.scenario(STABLE_AVAIL, yes=NOOP)
        b.run(apply="1")
        self.assertTrue(b.yes_called())
        self.no_success(b)
        self.assertEqual(b.texts(), [])

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
            '    step["receipt"] = dict(step.get("receipt") or {}, pre_sha=pre, post_sha=h())\n')
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
                self.assertEqual(r.returncode, 1, b.log())
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
        self.assertEqual((rec.get("pre_sha"), rec.get("post_sha")), (before, after))
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
        for rec in ({"outcome": "success", "pre_sha": "a" * 40, "post_sha": "a" * 40}, {"outcome": "success"}):
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
    prog = unittest.main(argv=[sys.argv[0]], exit=False, verbosity=1)
    ok = prog.result.wasSuccessful()
    sys.stderr.flush()
    print("compat sanity: %s (%d tests, src=%s)" % ("PASS" if ok else "FAIL", prog.result.testsRun, SRC))
    sys.stdout.flush()
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
