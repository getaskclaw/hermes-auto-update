#!/bin/bash
# Build a hermetic harness for an auto_update.sh: stub hermes / curl / systemctl,
# a fake HOME (log + state + receipt land there), and a scratch git repo.
# The real hermes binary is never reached: the stub is made the FIRST absolute-path
# candidate, which is the only way to win the candidate race.
#
# Usage:  bash stub_setup.sh /path/to/auto_update.sh
# Env:    HARNESS_ROOT (default /tmp/au-harness)
set -u
ROOT="${HARNESS_ROOT:-/tmp/au-harness}"
SRC="${1:?usage: bash stub_setup.sh /path/to/auto_update.sh}"
test -r "$SRC" || { echo "cannot read $SRC" >&2; exit 1; }
# Record where the source script (and thus its bundle) lives, so artifact checks in the
# matrix can inspect install.sh / crontab.txt / README.md without guessing a path.
BUNDLE_DIR="$(cd "$(dirname "$SRC")" && pwd)"
rm -rf "$ROOT"; mkdir -p "$ROOT/bin" "$ROOT/stub" "$ROOT/repo"

cat > "$ROOT/bin/curl" <<EOF
#!/bin/bash
{ printf '%s | ' "\$(cat $ROOT/mode)"; echo "\$@"; } >> $ROOT/notify.calls
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
receipt() {
  mkdir -p "\$H/.hermes/logs/update_receipts"
  python3 - "\$1" <<'PY'
import json,sys,datetime
outcome = sys.argv[1]
d = {"schema":1,"started_at":"2026-09-11T00:00:00+00:00",
     "finished_at":datetime.datetime.now(datetime.timezone.utc).isoformat(),
     "outcome":outcome}
# SHA-bearing modes exercise the machine-field discriminator (R1 coverage):
# pre != post proves the install landed; pre == post means it did not.
# NOTE: the outcome field stays "partial" — the SHA pair is the only difference,
# exactly like the real receipt (a mode name is not a receipt outcome).
if outcome == "partial_sha":
    d["outcome"] = "partial"
    d["pre_update"] = {"short_sha": "aaaaaaaa"}
    d["post_update"] = {"short_sha": "bbbbbbbb"}
elif outcome == "partial_same":
    d["outcome"] = "partial"
    d["pre_update"] = {"short_sha": "aaaaaaaa"}
    d["post_update"] = {"short_sha": "aaaaaaaa"}
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
    race_sha)  echo "✓ Code updated! [main @ bbbbbbbb]"; echo "→ hermes-gateway: draining"; receipt partial_sha; exit 1 ;;
    race_same) echo "✓ Code updated! [main @ aaaaaaaa]"; echo "→ hermes-gateway: draining"; receipt partial_same; exit 1 ;;
    noop)     echo "✓ Already up to date."; exit 0 ;;
    weirdyes) echo "⚕ something unexpected happened"; exit 0 ;;
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
