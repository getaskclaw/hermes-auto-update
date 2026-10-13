#!/bin/bash
# Fault-injection probe: is the RECOMMENDED schedule a schedule that actually DELIVERS its
# configuration to the updater?
# Usage: bash schedule_delivery.sh /path/to/auto_update.sh
#
# Why: a cron line can contain every value it needs and still hand the script nothing.
# `. env; AU_APPLY=1 script` sets the env file's variables in the SCHEDULER shell, which
# exits immediately, and auto_update.sh never sources the file itself — so AU_REPO_DIR,
# AU_GATEWAY_STATE and AU_HERMES_BIN silently never arrive. AU_APPLY does arrive (it is
# prefixed to the script), which is precisely why the mistake is invisible: the tick still
# installs, on the WRONG paths. S24b tests delivery of the flag only; this probe tests the
# rest of the configuration, in the shape install.sh prints and crontab.txt recommends.
#
# Assertions, each run under every shell the scheduler might use:
#   1. the shape DELIVERS the env file's values to the child
#   2. it still DELIVERS AU_APPLY to the child
#   3. with the env file ABSENT it neither aborts nor loses AU_APPLY
set -u
SRC="${1:?usage: bash schedule_delivery.sh /path/to/auto_update.sh}"
ROOT="${HARNESS_ROOT:-/tmp/au-harness}"
HERE="$(cd "$(dirname "$0")" && pwd)"
BUNDLE="$(cd "$(dirname "$SRC")" && pwd)"
PROBE="$ROOT/stub/deliveryprobe"
mkdir -p "$ROOT/stub"
fail=0

# A stand-in for the updater that reports exactly what it inherited.
cat > "$PROBE" <<'EOF'
#!/bin/sh
printf 'AU_APPLY=%s AU_REPO_DIR=%s TG_PROXY=%s\n' \
  "${AU_APPLY-UNSET}" "${AU_REPO_DIR-UNSET}" "${TG_PROXY-UNSET}" > "$DELIVERY_OUT"
EOF
chmod +x "$PROBE"

ENVFILE="$ROOT/stub/probe.env"
OUT="$ROOT/stub/delivery.out"
export DELIVERY_OUT="$OUT"
printf 'AU_REPO_DIR=/srv/hermes\nTG_PROXY=http://proxy.example:18089\n' > "$ENVFILE"

# Pull the shape out of the bundle artifacts, exactly as printed/recommended.
SHAPE="$(grep -o 'CRON_LINE="[^"]*"' "$BUNDLE/install.sh" 2>/dev/null | head -1 | sed 's/^CRON_LINE="//; s/"$//')"
if [ -z "$SHAPE" ]; then
  echo "FAIL: install.sh defines no CRON_LINE (nothing to check)"; exit 1
fi
# strip the schedule fields, point $ENV_FILE/$DEST at our stand-ins, drop literal output redirects
SHAPE="${SHAPE#*\* * * * }"
SHAPE="${SHAPE//\$ENV_FILE/$ENVFILE}"
SHAPE="${SHAPE//\$DEST/$PROBE}"
SHAPE="${SHAPE%% >\/dev\/null 2>&1}"
SHAPE="${SHAPE//>/ }"
SHAPE="${SHAPE//\/dev\/null/}"

for sh1 in bash dash sh; do
  command -v "$sh1" >/dev/null 2>&1 || continue
  rm -f "$OUT"
  timeout 10 "$sh1" -c "$SHAPE" >/dev/null 2>&1
  seen="$(cat "$OUT" 2>/dev/null || echo none)"
  echo "   $sh1: $seen"
  case "$seen" in
    *AU_REPO_DIR=/srv/hermes*) ;;
    *) echo "   FAIL: $sh1 — the env file was not DELIVERED to the script (shape: $SHAPE)"; fail=1 ;;
  esac
  case "$seen" in
    *AU_APPLY=1*) ;;
    *) echo "   FAIL: $sh1 — AU_APPLY did not reach the script"; fail=1 ;;
  esac
done

# The env file may legitimately not exist yet (install.sh creates it, but a scheduler can be
# installed first). `set -a; [ -f ... ] && . ...; set +a; AU_APPLY=1 script` must survive that:
# an unguarded `. missing` is non-zero and the flag is never delivered.
mv -f "$ENVFILE" "$ENVFILE.gone"
for sh1 in bash dash sh; do
  command -v "$sh1" >/dev/null 2>&1 || continue
  rm -f "$OUT"
  timeout 10 "$sh1" -c "$SHAPE" >/dev/null 2>&1
  seen="$(cat "$OUT" 2>/dev/null || echo none)"
  echo "   $sh1 (no env file): $seen"
  case "$seen" in
    *AU_APPLY=1*) ;;
    *) echo "   FAIL: $sh1 — AU_APPLY lost when the env file is absent"; fail=1 ;;
  esac
done
mv -f "$ENVFILE.gone" "$ENVFILE"

[ "$fail" -eq 0 ] && echo "PASS: the recommended schedule delivers the env file AND the flag" || exit 1
