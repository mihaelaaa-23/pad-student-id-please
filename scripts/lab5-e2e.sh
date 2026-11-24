#!/usr/bin/env bash
# Lab 5, grade 10: the whole stack end to end. Exits non-zero on the first failure.
#   1. docker compose pull && docker compose up -d (skip with E2E_SKIP_UP=1)
#   2. wait for the Gateway's and every service's /status through the Gateway, then until
#      one traced request's lines are in Loki, in order (the gateway collection downloads them)
#   3. every Postman collection with newman
#   4. the five demo scripts, with NONINTERACTIVE=1
#   5. every Prometheus target is up
#
#   bash scripts/lab5-e2e.sh
#
# Settings: E2E_SKIP_UP=1 (use the stack as it is), E2E_SKIP_DEMOS=1, STATUS_TIMEOUT_S (300),
# LOGS_TIMEOUT_S (180: how long to wait for a traced request's lines in Loki).
# Needs Node.js for newman (npx downloads it on the first run).
NONINTERACTIVE=1
source "$(dirname "$0")/lab5-lib.sh"
export NONINTERACTIVE

command -v npx >/dev/null 2>&1 || die "npx (Node.js) is required for newman."

STATUS_TIMEOUT_S="${STATUS_TIMEOUT_S:-300}"
PROMETHEUS_URL="${PROMETHEUS_URL:-http://localhost:$(env_value HOST_PROMETHEUS_PORT 9090)}"
SERVICES="player session applicant credential server-rules university-record moderation discord-dms"
DEMOS="lab5-grade4-etl lab5-grade5-failover lab5-grade7-ring lab5-grade8-2pc lab5-grade9-saga"
RESULTS=()

passed() { RESULTS+=("PASS  $1"); ok "$1"; }

summary() {
  echo
  echo "${BOLD}== Summary ==${RESET}"
  local line
  for line in ${RESULTS[@]+"${RESULTS[@]}"}; do echo "  $line"; done
}
fail() {
  RESULTS+=("FAIL  $1")
  summary
  die "$1"
}

# ---------------------------------------------------------------- 1. the stack

if [[ "${E2E_SKIP_UP:-0}" != "1" ]]; then
  step "Pull every image and start the stack"
  run docker compose pull --quiet || fail "docker compose pull"
  run docker compose up -d --remove-orphans || fail "docker compose up -d"
  passed "stack started"
fi

compose_rc="$(compose config --images | grep -c -- '-rc' || true)"
if [[ "$compose_rc" != "0" ]]; then
  info "note: $compose_rc image(s) in compose are still release candidates:"
  compose config --images | grep -- '-rc' | sed 's/^/  /'
fi

# ---------------------------------------------------------------- 2. /status

step "Wait for the Gateway and every service's /status"
gateway_up() {
  [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$BASE_URL/status")" == "200" ]]
}
wait_until "$STATUS_TIMEOUT_S" "Gateway /status" gateway_up
for service in $SERVICES; do
  service_up() {
    [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Authorization: Bearer $SERVICE_TOKEN" "$BASE_URL/$service/status")" == "200" ]]
  }
  wait_until "$STATUS_TIMEOUT_S" "/$service/status" service_up
done
passed "every /status answers 200"

# ---------------------------------------------------------------- 2b. logs in Loki

# On fresh volumes Alloy is still catching up when the services answer /status. The gateway
# collection's "Download Logs - One Request" downloads the lines of one request and needs
# them from the Broker and from Applicant, oldest first. So: send one such request with a
# known X-Request-Id and wait until /logs/download returns its lines from both, in order.
step "Wait until a traced request's lines are in Loki (Alloy -> Loki), from the Broker and Applicant, in order"
LOGS_TIMEOUT_S="${LOGS_TIMEOUT_S:-180}"
PROBE_ID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
show "curl -s $BASE_URL/applicant/applicants/00000000-0000-4000-8000-000000000000 -H \"Authorization: Bearer \$SERVICE_TOKEN\" -H 'Cache-Control: no-cache' -H 'X-Request-Id: $PROBE_ID'"
curl -s -o /dev/null --max-time 10 -H "Authorization: Bearer $SERVICE_TOKEN" -H 'Cache-Control: no-cache' \
  -H "X-Request-Id: $PROBE_ID" "$BASE_URL/applicant/applicants/00000000-0000-4000-8000-000000000000" || true
probe_logged() {
  curl -s --max-time 10 -H "Authorization: Bearer $SERVICE_TOKEN" -o "$TMP_DIR/logs.ndjson" \
    "$BASE_URL/logs/download?requestId=$PROBE_ID" &&
    python3 - "$TMP_DIR/logs.ndjson" "$PROBE_ID" <<'PY'
import json, sys
rows = []
for line in open(sys.argv[1], errors="replace"):
    try:
        rows.append(json.loads(line))
    except ValueError:
        pass
services = {r.get("service") for r in rows}
times = [r.get("timestamp") or "" for r in rows]
ok = ({"message-broker", "applicant-service"} <= services
      and all(r.get("requestId") == sys.argv[2] for r in rows)
      and times == sorted(times))
print("%d lines, services %s, in order: %s" % (len(rows), sorted(s for s in services if s), times == sorted(times)))
sys.exit(0 if ok else 1)
PY
}
show "curl -s \"$BASE_URL/logs/download?requestId=$PROBE_ID\" -H \"Authorization: Bearer \$SERVICE_TOKEN\""
info "waiting up to ${LOGS_TIMEOUT_S}s: the probe's lines from message-broker and applicant-service, oldest first"
started=$SECONDS
until probe_logged >"$TMP_DIR/probe.txt" 2>&1; do
  if (( SECONDS - started >= LOGS_TIMEOUT_S )); then
    echo "last answer: $(cat "$TMP_DIR/probe.txt")"
    fail "the probe's lines did not reach Loki from both services, in order, within ${LOGS_TIMEOUT_S}s"
  fi
  sleep 3
done
cat "$TMP_DIR/probe.txt"
passed "logs are in Loki, in order ($((SECONDS - started))s)"

# ---------------------------------------------------------------- 3. newman

step "Every Postman collection, headless through the Gateway"
for collection in postman/*.postman_collection.json; do
  name="$(basename "$collection" .postman_collection.json)"
  show "npx --yes newman run $collection --env-var serviceToken=\$SERVICE_TOKEN --bail"
  if npx --yes newman run "$collection" --env-var "serviceToken=$SERVICE_TOKEN" --bail \
      --reporters cli --reporter-cli-no-banner --reporter-cli-no-console >"$TMP_DIR/newman-$name.log" 2>&1; then
    summary_line="$(grep -E '│ +assertions' "$TMP_DIR/newman-$name.log" | head -n 1 |
      awk -F'│' '{ gsub(/ /, "", $3); gsub(/ /, "", $4); print $3 " assertions, " $4 " failed" }')"
    passed "newman $name ${summary_line:+($summary_line)}"
  else
    tail -n 60 "$TMP_DIR/newman-$name.log"
    fail "newman $name"
  fi
done

# ---------------------------------------------------------------- 4. demo scripts

if [[ "${E2E_SKIP_DEMOS:-0}" != "1" ]]; then
  for demo in $DEMOS; do
    step "Demo: $demo"
    show "NONINTERACTIVE=1 bash scripts/$demo.sh"
    if NONINTERACTIVE=1 bash "scripts/$demo.sh" >"$TMP_DIR/$demo.log" 2>&1; then
      passed "demo $demo"
    else
      tail -n 40 "$TMP_DIR/$demo.log"
      fail "demo $demo"
    fi
  done
fi

# ---------------------------------------------------------------- 5. Prometheus

step "Every Prometheus target is up"
targets_up() {
  curl -s --max-time 5 "$PROMETHEUS_URL/api/v1/targets?state=active" >"$TMP_DIR/targets.json" &&
    python3 - "$TMP_DIR/targets.json" <<'PY'
import json, sys
targets = json.load(open(sys.argv[1]))["data"]["activeTargets"]
down = [t for t in targets if t.get("health") != "up"]
for t in sorted(targets, key=lambda t: (t["labels"].get("job", ""), t["labels"].get("instance", ""))):
    print("  %-4s %-28s %s" % (t.get("health"), t["labels"].get("job", ""), t["labels"].get("instance", "")))
sys.exit(1 if down or not targets else 0)
PY
}
show "curl -s $PROMETHEUS_URL/api/v1/targets?state=active"
# Containers restarted by the demos need a scrape interval or two to be up again.
started=$SECONDS
until targets_up >/dev/null 2>&1; do
  if (( SECONDS - started >= 90 )); then
    targets_up || true
    fail "Prometheus targets: some are not up after 90 s (listed above)"
  fi
  sleep 5
done
targets_up
passed "every Prometheus target is up"

summary
echo
ok "lab 5 end-to-end passed"
