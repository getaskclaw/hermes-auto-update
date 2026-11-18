"""PATCH5 step 0: does `hermes update --yes` write a correlated success receipt on the
"already up to date" path?  Runs the REAL upstream functions of one tag, in isolation.

usage: python3 -I verify/receipt_probe/receipt_noop_probe.py <tag> <workdir>   (workdir is DELETED first)
       HERMES_UPSTREAM_REPO=<checkout> selects the upstream repo (only `git ls-tree/archive/show` on it);
       PROBE_TAIL=dependencies_owed makes the stubbed post-commit tail report one failed step.
Never runs `hermes update`, never touches ~/.hermes: HOME and HERMES_HOME point into <workdir>.

What is real (exact bytes from `git show <tag>:...`, imported as modules or AST-extracted):
  hermes_cli/update_receipt.py   (whole module: begin/record/finalize/persist/latest.json)
  hermes_constants.py, hermes_cli/runtime_state.py, process_identity.py, version_info.py ... (whatever
                                  update_receipt lazily imports; nothing stubbed unless listed below)
  update_cmd.py: _begin_update_receipt_and_plan, _finish_already_up_to_date, _complete_source_update
  main.py:       _finalize_update_receipt and the cmd_update receipt boundary order (scope -> impl -> finalize(0))
  update_completion.py (whole module) in a SEPARATE child interpreter: _finish -> finalize_pending_update_receipt

Stubbed (side effects: git/pip/gateway/network/desktop), each listed in the output as STUBS:
  plan inventory (read-only process scan), the post-commit tail `_complete_selected` (bytecode sweep,
  launchers, build, maintenance, fleet restart) -> returns True (tail completed), windows resume,
  fleet-restart marker, autostash notice, the Popen transport of run_completion (replaced by a direct
  child interpreter running the real update_completion._finish), publish_stage.
Environment: HOME, HERMES_HOME -> workdir; HERMES_UPDATE_CORRELATION_ID=<random>.  No network.
"""
import ast, copy, json, os, shutil, subprocess, sys, types, uuid
from pathlib import Path

TAG, WORK = sys.argv[1], Path(sys.argv[2]).resolve()
UP = os.environ.get("HERMES_UPSTREAM_REPO") or "/home/computebox/.hermes/hermes-agent"   # read-only
G = ["git", "-c", "gc.auto=0", "-c", "maintenance.auto=false"]
if WORK.exists():
    # only ever delete an empty dir or this probe's own previous workdir
    if any(WORK.iterdir()) and not ((WORK / "src").is_dir() and (WORK / "hermes_home").is_dir()):
        raise SystemExit(f"refusing to delete {WORK}: not empty and not a previous probe workdir")
    shutil.rmtree(WORK)
SRC, HOME, FAKEHOME = WORK / "src", WORK / "hermes_home", WORK / "fakehome"
for d in (SRC, HOME, FAKEHOME):
    d.mkdir(parents=True)

# 1. exact upstream tree (read-only export; the upstream repo is not modified)
top = set(subprocess.run(G + ["-C", UP, "ls-tree", "--name-only", TAG], check=True, capture_output=True,
                         text=True).stdout.split())
paths = [p for p in ("hermes_cli", "pm", "hermes_constants.py", "hermes_agent") if p in top]
arch = subprocess.run(G + ["-C", UP, "archive", TAG] + paths, check=True, capture_output=True).stdout
subprocess.run(["tar", "-x", "-C", str(SRC)], input=arch, check=True)
# a local git repo so the REAL version_info.get_code_identity sees a live checkout (pre/post sha shape)
genv = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_SYSTEM="/dev/null", HOME=str(FAKEHOME))
subprocess.run(["git", "init", "-q", str(SRC)], check=True, env=genv)
subprocess.run(["git", "-C", str(SRC), "add", "-A"], check=True, env=genv)
subprocess.run(["git", "-C", str(SRC), "-c", "user.name=probe", "-c", "user.email=probe@invalid",
                "commit", "-qm", f"export of {TAG}"], check=True, env=genv)
HEAD = subprocess.run(["git", "-C", str(SRC), "rev-parse", "HEAD"], capture_output=True, text=True, env=genv).stdout.strip()

CORR = "au-probe-" + uuid.uuid4().hex
os.environ.update(HOME=str(FAKEHOME), HERMES_HOME=str(HOME), HERMES_UPDATE_CORRELATION_ID=CORR,
                  GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_SYSTEM="/dev/null")
for k in ("HERMES_ACTION_ID", "PYTHONPATH"):
    os.environ.pop(k, None)
sys.path.insert(0, str(SRC))
sys.argv = ["hermes", "update", "--yes"]

STUBS = []
def stub_module(name, **attrs):
    m = types.ModuleType(name); m.__dict__.update(attrs); sys.modules[name] = m; STUBS.append(f"module {name}: {sorted(attrs)}")
# read-only process inventory (scans the real host's processes) -> empty plan
stub_module("hermes_cli.update_inventory",
            collect_runtime_inventory=lambda: types.SimpleNamespace(runtimes=[]),
            record_plan_in_receipt=lambda plan: None)
stub_module("hermes_cli.update_stage", publish_stage=lambda *a, **k: None)

from hermes_cli import update_receipt as ur          # REAL module
import hermes_cli.update_completion as uc            # REAL module (stdlib-only parent transport)

def extract(rel, names, ns):
    src = subprocess.run(G + ["-C", UP, "show", f"{TAG}:{rel}"], capture_output=True, text=True, check=True).stdout
    found = set()
    for node in ast.parse(src).body:
        if isinstance(node, ast.FunctionDef) and node.name in names:
            mod = ast.Module(body=[node], type_ignores=[]); ast.fix_missing_locations(mod)
            exec(compile(mod, f"{TAG}:{rel}:{node.name}@{node.lineno}", "exec"), ns)
            found.add(f"{rel}:{node.name}@{node.lineno}")
    missing = set(names) - {f.split(":")[1].split("@")[0] for f in found}
    assert not missing, (rel, missing)
    return sorted(found)

from contextlib import contextmanager
@contextmanager
def _best_effort(msg):  # same contract as update_cmd_common._best_effort: swallow + debug
    try:
        yield
    except Exception as exc:
        print("best_effort swallowed:", msg % exc)

CHILD_LOG = []
def run_completion(request):
    """run_completion's Popen transport, minus pre-install/lock fds: a REAL separate interpreter runs
    the REAL update_completion._finish on the request; then the parent's own validation (copied
    verbatim from run_completion) decides."""
    rq, rs = WORK / "request.json", WORK / "result.json"
    rq.write_text(json.dumps(request, default=str))
    p = subprocess.run([sys.executable, "-I", str(Path(__file__).with_name("receipt_noop_child.py")), str(SRC), str(rq), str(rs)],
                       capture_output=True, text=True, env=dict(os.environ))
    CHILD_LOG.append({"rc": p.returncode, "stdout": p.stdout, "stderr": p.stderr[-4000:]})
    code = p.returncode
    result = json.loads(rs.read_text(encoding="utf-8-sig"))
    if result["schema"] != 1 or result["update_id"] != request["receipt"]["update_id"]:
        raise ValueError("completion response identity mismatch")
    if result["exit_code"] != code:
        raise ValueError("completion response disagrees with process exit")
    receipt = result.get("receipt")
    if receipt is not None and (receipt.get("update_id") != request["receipt"]["update_id"]
                                or not receipt.get("finished_at")
                                or (code == 0) != (receipt.get("outcome") == "success")):
        raise ValueError("completion receipt does not attest this outcome")
    if code == 0 and receipt is None:
        raise ValueError("completion did not publish a terminal receipt")
    return result

ns = {
    "_best_effort": _best_effort, "_completion_receipt": ur, "os": os, "sys": sys,
    "_record_update_initiator": None,  # replaced by the real one below
    "run_completion": run_completion, "_accept_completion_pm_receipt": lambda *a, **k: None,
    "_unrestored_autostash_notice": lambda: None,
    "_write_fleet_restart_pending_marker": lambda **k: None,
    "_current_checkout_sha": lambda: HEAD,
    "_capture_head_sha": lambda git_cmd, root: HEAD,
    "_moves_for": lambda token: None,
    "_settle_windows_resume": lambda request: None,
    "stop_for_relaunch": lambda **k: (_ for _ in ()).throw(SystemExit(1)),
    "_m": lambda: types.SimpleNamespace(PROJECT_ROOT=SRC, _resume_windows_gateways_after_update=lambda t: None,
                                        _restore_stashed_changes=lambda *a, **k: None),
}
# update_cmd.py imports adopt_retired_channel at module top; give the extracted functions the REAL one.
try:
    from hermes_cli.update_channel import adopt_retired_channel as _arc
    ns["adopt_retired_channel"] = _arc
except Exception as exc:  # recorded, never hidden
    STUBS.append(f"adopt_retired_channel NOT importable here ({type(exc).__name__}: {exc}) - left undefined")
STUBS += ["update_cmd globals: _unrestored_autostash_notice->None, _write_fleet_restart_pending_marker->noop, "
          "_accept_completion_pm_receipt->noop, _settle_windows_resume->noop, run_completion transport->child interpreter"]
real_fns = extract("hermes_cli/update_cmd.py", {"_begin_update_receipt_and_plan", "_record_update_initiator",
                                               "_finish_already_up_to_date", "_complete_source_update"}, ns)
mns = {"__builtins__": __builtins__}
real_fns += extract("hermes_cli/main.py", {"_finalize_update_receipt"}, mns)

# 2. the no-op run, in cmd_update's order: receipt scope -> impl (begin ... already-up-to-date) -> finalize(0)
printed = []
import io, contextlib
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    with ur.update_receipt_scope():
        try:
            print("☤ Updating Hermes Agent...")
            plan = ns["_begin_update_receipt_and_plan"](types.SimpleNamespace(yes=True))
            _plan = types.SimpleNamespace(auto_stash_ref=None, parked_branch_switched=False, upstream_checked=True,
                                          switch_block_reason="")
            request = {"source": str(SRC), "home": str(HOME), "windows_resume": None, "gateway_mode": False,
                       "branch": "main", "plan": None, "sibling_snapshots": {}, "apply_mode": "git", "desktop": False}
            ns["_finish_already_up_to_date"](["git"], "main", "main", _plan, gw_input_fn=input,
                                              completion_request=request)
        except SystemExit as e:
            code = e.code if isinstance(e.code, int) else 1
            mns["_finalize_update_receipt"](code, f"sys.exit({code})")
            raise
        else:
            mns["_finalize_update_receipt"](0, ur.COMMAND_BOUNDARY_STOP_REASON)

rdir = HOME / "logs" / "update_receipts"
files = sorted(p.name for p in rdir.glob("*.json")) if rdir.exists() else []
latest = json.loads((rdir / "latest.json").read_text()) if (rdir / "latest.json").exists() else None
out = {
    "tag": TAG, "HERMES_UPDATE_CORRELATION_ID": CORR, "checkout_head": HEAD,
    "real_functions": real_fns, "stubs": STUBS, "parent_stdout": buf.getvalue(), "child": CHILD_LOG,
    "receipt_files": files, "latest": latest,
    "verdict": {
        "receipt_written": latest is not None,
        "outcome": (latest or {}).get("outcome"),
        "correlation_id_matches_env": (latest or {}).get("correlation_id") == CORR,
        "finished_at": (latest or {}).get("finished_at"),
        "pre_short_sha": ((latest or {}).get("pre_update") or {}).get("short_sha"),
        "post_short_sha": ((latest or {}).get("post_update") or {}).get("short_sha"),
        "followups": (latest or {}).get("followups"),
        "has_kind_field": "kind" in (latest or {}),
    },
}
print(json.dumps(out, indent=2, ensure_ascii=False, default=str))
