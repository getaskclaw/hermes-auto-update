#!/bin/bash
# hermes-auto-update installer — PRECONDITIONS ONLY. Never runs the updater as a test
# (it has no dry-run mode; "test it" would mean "perform a real update").
set -u
ENV_FILE="$HOME/.hermes/scripts/auto_update.env"
DEST="$HOME/.hermes/scripts/auto_update.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }
# Create the per-host env file with a documented template. A bare `touch` leaves it EMPTY,
# which is how a host ends up with no override channel at rest: the script then keeps its
# hardcoded TG_PROXY default, and if that endpoint does not exist on this machine every
# notification silently degrades to proxy-fail-then-direct (see "notify via proxy failed" in
# the log). ~/.hermes/.env is NOT read for this — that file is credentials-only to the script.
if [ ! -f "$ENV_FILE" ]; then
  cat > "$ENV_FILE" <<ENVEOF
# Hermes auto-update per-host overrides. The scheduler sources THIS file (set -a) BEFORE the
# script, and the script never sources ~/.hermes/.env — values put there never arrive.
# Uncomment and set what differs on this host:
# AU_REPO_DIR=$HOME/.hermes/hermes-agent
# AU_HERMES_BIN=/usr/local/lib/hermes-agent/venv/bin/hermes
# AU_CRON_UNIT=            # empty when the host OS does the scheduling (WSL Task Scheduler)
# AU_GATEWAY_STATE=$HOME/.hermes/gateway_state.json
# AU_GATEWAY_UNIT=hermes-gateway.service
# TG_PROXY=                # EMPTY = direct connection. Leave it set for any host that reaches
#                         # api.telegram.org directly; omitting the line makes the script fall
#                         # back to the server's xray proxy address, which is not there.
TG_PROXY=
ENVEOF
  echo "created $ENV_FILE (template; TG_PROXY pre-set empty = direct)"
else
  echo "NOTE: $ENV_FILE exists — verify it sets TG_PROXY (empty = direct), not only comments."
  grep -qE '^[[:space:]]*(export[[:space:]]+)?TG_PROXY=' "$ENV_FILE" \
    || echo "WARN: no active TG_PROXY line — the script will use its hardcoded default proxy."
fi
command -v git >/dev/null || fail "git not found"
if ! command -v hermes >/dev/null && [ ! -x /usr/local/lib/hermes-agent/venv/bin/hermes ]; then
  fail "hermes binary not found — set AU_HERMES_BIN in $ENV_FILE"
fi
systemctl --user is-active hermes-gateway >/dev/null 2>&1 || echo "NOTE: hermes-gateway user unit not active — restart/verify will not work (WSL: check [boot] systemd=true)"
# cron line the scheduler should carry:
#   the flag ON the script (never prefixed to a sourced env file), AND
#   `set -a` around the source, or the env file delivers NOTHING — a bare `. env; AU_APPLY=1
#   script` leaves every value in the scheduler shell that exits immediately, and the script
#   itself never sources the file (verified). AU_APPLY still arrives (it is prefixed to the
#   script), which is exactly why that mistake stays invisible: the tick installs while
#   AU_REPO_DIR / AU_GATEWAY_STATE / AU_HERMES_BIN silently do not.
#   `[ -f ]` guard: without it a missing env file makes `.` non-zero, and under `sh -e`-style
#   scheduling the line dies before the flag is delivered.
CRON_LINE="set -a; [ -f $ENV_FILE ] && . $ENV_FILE; set +a; AU_APPLY=1 $DEST >/dev/null 2>&1"
echo "recommended cron line:"
echo "  $CRON_LINE"
echo "preconditions OK — copy auto_update.sh to $DEST and add the cron line yourself."
