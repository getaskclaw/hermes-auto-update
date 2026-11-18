#!/bin/bash
# Build a hermetic harness for an auto_update.sh: stub hermes / curl / systemctl,
# a fake HOME (log + state + receipt land there), and a scratch git repo.
# The real hermes binary is never reached: the stub is made the FIRST absolute-path
# candidate, which is the only way to win the candidate race.
#
# Usage:  bash stub_setup.sh /path/to/auto_update.sh
# Env:    HARNESS_ROOT (default $TMPDIR/au-harness; the release gate exports a mktemp dir)
set -u
ROOT="${HARNESS_ROOT:-${TMPDIR:-/tmp}/au-harness}"
SRC="${1:?usage: bash stub_setup.sh /path/to/auto_update.sh}"
test -r "$SRC" || { echo "cannot read $SRC" >&2; exit 1; }
# Record where the source script (and thus its bundle) lives, so artifact checks in the
# matrix can inspect install.sh / crontab.txt / README.md without guessing a path.
BUNDLE_DIR="$(cd "$(dirname "$SRC")" && pwd)"
rm -rf "$ROOT"; mkdir -p "$ROOT/bin" "$ROOT/stub" "$ROOT/repo"

cat > "$ROOT/bin/curl" <<EOF
#!/bin/bash
# Log each invocation on exactly ONE line: escape backslashes first, then CR/LF, so a
# multi-line alert payload never splits one notify into several lines. Spaces are kept
# verbatim so substring greps (updated/success/...) still match.
a="\$*"; bs='\'; nl=\$'\n'; cr=\$'\r'; rn='\n'; rr='\r'
a="\${a//"\$bs"/"\$bs\$bs"}"; a="\${a//"\$nl"/"\$rn"}"; a="\${a//"\$cr"/"\$rr"}"
{ printf '%s | ' "\$(cat $ROOT/mode)"; printf '%s\n' "\$a"; } >> $ROOT/notify.calls
[ -f $ROOT/curl_fail ] && exit 22
# A real API answers with a JSON body; a blocked bot reports ok:false on HTTP 200.
# Emit a realistic body so the delivery check (D2) is exercised, not bypassed.
if [ -f $ROOT/tg_reject ]; then
  echo '{"ok":false,"error_code":403,"description":"Forbidden: bot was blocked by the user"}'
else
  echo '{"ok":true,"result":{"message_id":1}}'
fi
exit 0
EOF
cat > "$ROOT/bin/systemctl" <<EOF
#!/bin/bash
# stateful so a scenario can have the gateway come back DURING a poll:
#   gw_down        -> always inactive
#   gw_flip_after=N-> inactive for the first N calls, active after
n=\$(cat $ROOT/gw_calls 2>/dev/null || echo 0); n=\$((n+1)); echo \$n > $ROOT/gw_calls
[ -f $ROOT/gw_down ] && { echo inactive; exit 0; }
if [ -f $ROOT/gw_flip_after ]; then
  [ "\$n" -lt "\$(cat $ROOT/gw_flip_after)" ] && { echo inactive; exit 0; }
fi
echo active
exit 0
EOF
chmod +x "$ROOT/bin/curl" "$ROOT/bin/systemctl"

cat > "$ROOT/stub/hermes" <<EOF
#!/bin/bash
MODE=\$(cat $ROOT/mode)
H=$ROOT/home
R=$ROOT/repo
# Real checkout movement for the SHA-bearing modes: race_sha ADVANCES the scratch repo (a new
# commit), race_same leaves it put. Both record the actual before/after HEADs, so the receipt
# carries real hashes that the updater can correlate with its own read-only rev-parse.
heads_before() { git -C "\$R" rev-parse HEAD > $ROOT/stub_pre_head || exit 3; }
heads_after()  { git -C "\$R" rev-parse HEAD > $ROOT/stub_post_head || exit 3; }
advance_repo() {
  heads_before
  git -C "\$R" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "stub update \$(date +%s%N)" || exit 3
  heads_after
}
hold_repo() { heads_before; heads_after; }
receipt() {
  mkdir -p "\$H/.hermes/logs/update_receipts"
  python3 - "\$1" "\$(cat $ROOT/stub_pre_head 2>/dev/null)" "\$(cat $ROOT/stub_post_head 2>/dev/null)" <<'PY'
import json,sys,datetime,os
outcome = sys.argv[1]
d = {"schema":1,"started_at":"2026-09-11T00:00:00+00:00",
     "finished_at":datetime.datetime.now(datetime.timezone.utc).isoformat(),
     "outcome":outcome}
# SHA-bearing modes exercise the machine-field discriminator (R1 coverage):
# pre != post proves the install landed; pre == post means it did not.
# NOTE: the outcome field stays "partial" — the SHA pair is the only difference,
# exactly like the real receipt (a mode name is not a receipt outcome).
# The SHAs are the REAL scratch-repo HEADs recorded around the stub's checkout move
# (argv 2/3), never constants, so checkout-proof correlation is exercised for real.
if outcome == "partial_sha":
    d["outcome"] = "partial"
    pre, post = sys.argv[2].strip(), sys.argv[3].strip()
    if not (pre and post and pre != post):
        raise SystemExit("stub: race_sha did not advance the scratch repo")
    d["pre_update"] = {"short_sha": pre[:8]}
    d["post_update"] = {"short_sha": post[:8]}
    cid = os.environ.get("HERMES_UPDATE_CORRELATION_ID", "").strip()
    if not cid:
        raise SystemExit("stub: race_sha needs HERMES_UPDATE_CORRELATION_ID from the updater")
    d["correlation_id"] = cid
elif outcome == "partial_same":
    d["outcome"] = "partial"
    pre, post = sys.argv[2].strip(), sys.argv[3].strip()
    if not (pre and pre == post):
        raise SystemExit("stub: race_same moved the scratch repo")
    d["pre_update"] = {"short_sha": pre[:8]}
    d["post_update"] = {"short_sha": post[:8]}
json.dump(d, open("$ROOT/home/.hermes/logs/update_receipts/latest.json","w"))
PY
}
if [ "\${1:-}" = "update" ] && [ "\${2:-}" = "--check" ]; then
  case "\$MODE" in
    uptodate)  echo "✓ Already up to date."; exit 0 ;;
    checkfail) echo "✗ fetch failed"; exit 1 ;;
    weird)     echo "⚕ Something else entirely"; exit 0 ;;
    checkwedge) echo "→ fetching (wedged check, will not return)"; trap "" TERM; ( trap "" TERM; sleep 600 ) & while :; do sleep 5; done ;;
    *)         echo "⚕ Update available: 3 commits behind origin/main."; echo "  Run 'hermes update' to install."; exit 0 ;;
  esac
fi
if [ "\${1:-}" = "update" ] && [ "\${2:-}" = "--yes" ]; then
  case "\$MODE" in
    ok)       echo "✓ Update complete! (v9.9.9)"; receipt success; exit 0 ;;
    partial0) echo "✓ Update complete! (v9.9.9)"; receipt partial; exit 0 ;;
    race)     echo "✓ Update complete! (v9.9.9)"; echo "→ hermes-gateway: draining"; receipt partial; exit 1 ;;
    race_sha)  advance_repo; echo "✓ Code updated! [main @ \$(head -c 8 $ROOT/stub_post_head)]"; echo "→ hermes-gateway: draining"; receipt partial_sha; exit 1 ;;
    race_same) hold_repo; echo "✓ Code updated! [main @ \$(head -c 8 $ROOT/stub_pre_head)]"; echo "→ hermes-gateway: draining"; receipt partial_same; exit 1 ;;
    noop)     echo "✓ Already up to date! [main @ abc1234]"; exit 0 ;;   # update_cmd.py:1730 + suffix
    weirdyes) echo "⚕ something unexpected happened"; exit 0 ;;
    erroryes) echo "⚕ Updating Hermes Agent..."; echo "  ⚠ Lazy refresh failed; rerun once resolved."; exit 0 ;;   # error word, no receipt
    moveyes)  advance_repo; echo "⚕ Updating Hermes Agent..."; exit 0 ;;   # checkout moved, no receipt
    fail)     echo "✗ Update failed: merge conflict"; exit 1 ;;
    wedged)
        # Never returns. Tolerate SIGTERM so \`timeout -k\` must escalate to SIGKILL.
        echo "→ fetching (wedged stub, will not return)"
        trap "" TERM
        # Detached orphan holding the stdout pipe: if the timeout only killed the direct
        # child, the caller's command substitution would still block on this reader.
        ( trap "" TERM; sleep 600 ) &
        while :; do sleep 5; done
        ;;
  esac
fi
echo "stub: unexpected args: \$*" >&2; exit 3
EOF
chmod +x "$ROOT/stub/hermes"

git -C "$ROOT/repo" init -q 2>/dev/null
git -C "$ROOT/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

# Point the FIRST binary candidate at the stub, and (for designs that keep a REPO variable)
# point REPO at the scratch repo so HEAD-based health checks compare like-for-like.
#   v4-style:  ... "$HOME/.hermes/venvs/hermes-dev/bin/hermes" /usr/local/lib/hermes-agent/venv/bin/hermes; do
#   v3-style:  ... "$HOME/.hermes/venvs/hermes-dev/bin/hermes" "$REPO/venv/bin/hermes"; do
sed -e "s#^REPO=.*#REPO=\"$ROOT/repo\"#" \
    -e "s#\"\$HOME/.hermes/venvs/hermes-dev/bin/hermes\"#\"$ROOT/stub/hermes\"#" \
    -e "s#/usr/local/lib/hermes-agent/venv/bin/hermes; do#$ROOT/stub/hermes; do#" \
    -e "s#\"\$REPO/venv/bin/hermes\"; do#\"$ROOT/stub/hermes\"; do#" \
    "$SRC" > "$ROOT/au.sh"
chmod +x "$ROOT/au.sh"
# The real safety property: the stub must be the FIRST candidate in the for-loop list.
if ! grep -qE "for cand in \"?$ROOT/stub/hermes" "$ROOT/au.sh"; then
  echo "WARNING: could not make the stub the first binary candidate in $SRC." >&2
  echo "         Refusing to continue: $ROOT/au.sh would resolve the REAL hermes binary" >&2
  echo "         and a 'test' run could fire a real update. Patch the candidate line by hand" >&2
  echo "         (make the stub the first element of the for-loop list) and re-run." >&2
  exit 1
fi
printf '%s\n' "$BUNDLE_DIR" > "$ROOT/bundle_dir"
echo "harness ready: $ROOT   (stub is the first candidate, real binary unreachable)"
