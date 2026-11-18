"""Child half of receipt_noop_probe.py: the REAL update_completion._finish of the exported tag in its
own interpreter (as upstream's completion child is).  Only the post-commit tail `_complete_selected`
(bytecode sweep / launchers / build / maintenance / fleet restart) is stubbed and
hermes_cli.update_cmd (Windows resume + gateway exit-code writer) to no-ops.
PROBE_TAIL=clean (default): the tail completed with no step failure.
PROBE_TAIL=dependencies_owed: the tail reports one failed step through the REAL
  update_receipt.record_followup, exactly as the real _complete_selected does for a failed step.
usage: python3 -I receipt_noop_child.py <src> <request.json> <result.json>"""
import json, os, sys, types
from pathlib import Path

src, req, res = sys.argv[1:4]
sys.path.insert(0, src)
m = types.ModuleType("hermes_cli.update_cmd")
m._resume_windows_gateways_after_update = lambda token: None
m._write_gateway_update_exit_code = lambda ok: None
sys.modules["hermes_cli.update_cmd"] = m
import hermes_cli.update_completion as uc   # REAL
from hermes_cli import update_receipt as ur  # REAL
def tail(request):
    if os.environ.get("PROBE_TAIL") == "dependencies_owed":
        ur.record_followup("dependencies", "probe: dependency sync failed")
    return True
uc._complete_selected = tail
request = json.loads(Path(req).read_text(encoding="utf-8-sig"))
raise SystemExit(uc._finish(request, Path(res)))
