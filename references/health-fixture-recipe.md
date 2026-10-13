# Health-check fixture recipe (sealed S10/S11)

The env knobs (`AU_REPO_DIR` / `AU_GATEWAY_STATE` / `AU_GATEWAY_UNIT`, real-machine defaults) exist so the matrix's marker-clear scenarios can run against deliberate fixtures instead of this machine's live health. Use them whenever you change anything in the gateway-confirmation path:

```bash
# 1. Build a fixture repo + gateway_state whose sha MATCHES (healthy):
rm -rf /tmp/au-fixtures && mkdir -p /tmp/au-fixtures/repo
git -C /tmp/au-fixtures/repo init -q
git -C /tmp/au-fixtures/repo -c user.email=t@t -c user.name=t commit -q --allow-empty -m x
H=$(git -C /tmp/au-fixtures/repo rev-parse HEAD)
printf '{"pid":1,"code_sha":"%s"}' "$H" > /tmp/au-fixtures/gateway_state

# 2. Seed a marker, run the no-update tick with fixtures sealed in:
echo uptodate > /tmp/au-harness/mode
touch /tmp/au-harness/home/.hermes/state/auto_update/drain_pending
HOME=/tmp/au-harness/home PATH=/tmp/au-harness/bin:/usr/bin:/bin \
  AU_REPO_DIR=/tmp/au-fixtures/repo AU_GATEWAY_STATE=/tmp/au-fixtures/gateway_state \
  bash /tmp/au-harness/au.sh >/dev/null 2>&1
# Healthy fixture -> marker CLEARED (verified against the fixture, not the real machine).

# 3. Flip the fixture to UNHEALTHY (sha mismatch) and confirm the marker SURVIVES:
printf '{"pid":1,"code_sha":"deadbeef"}' > /tmp/au-fixtures/gateway_state
touch /tmp/au-harness/home/.hermes/state/auto_update/drain_pending
HOME=/tmp/au-harness/home PATH=/tmp/au-harness/bin:/usr/bin:/bin \
  AU_REPO_DIR=/tmp/au-fixtures/repo AU_GATEWAY_STATE=/tmp/au-fixtures/gateway_state \
  bash /tmp/au-harness/au.sh >/dev/null 2>&1
# Unhealthy fixture -> marker PRESENT (kept; re-alert per the 1st/3rd/6th cadence).
```

Assert BOTH directions: healthy-fixture clears AND unhealthy-fixture keeps. A sealed test that only asserts the happy direction still borrows machine health.