#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:3000}"
BASE_URL="${BASE_URL%/}"
SERVICE_NAME="university-record-service"
REQUESTS="${REQUESTS:-24}"
REMOVAL_TIMEOUT_SECONDS="${REMOVAL_TIMEOUT_SECONDS:-20}"

die() {
  echo "FAIL: $*" >&2
  exit 1
}

get_setting() {
  local env_text="$1"
  local key="$2"
  local default_value="$3"
  local value

  value="$(printf '%s\n' "$env_text" |
    sed -n "s/^${key}=//p" | tail -n 1)"

  printf '%s' "${value:-$default_value}"
}

for command_name in docker curl; do
  command -v "$command_name" >/dev/null 2>&1 ||
    die "$command_name is required."
done

[[ "$REQUESTS" =~ ^[0-9]+$ ]] && (( REQUESTS >= 12 )) ||
  die "REQUESTS must be an integer greater than or equal to 12."

[[ "$REMOVAL_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] &&
  (( REMOVAL_TIMEOUT_SECONDS >= 1 )) ||
  die "REMOVAL_TIMEOUT_SECONDS must be a positive integer."

TMP_DIR="$(mktemp -d)"
PAUSED_CONTAINER=""

cleanup() {
  local exit_code=$?
  trap - EXIT

  if [[ -n "$PAUSED_CONTAINER" ]]; then
    echo
    echo "Cleanup: attempting to unpause $PAUSED_CONTAINER ..."
    docker unpause "$PAUSED_CONTAINER" >/dev/null 2>&1 || true
  fi

  rm -rf "$TMP_DIR"
  exit "$exit_code"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "========== Discover the running Compose stack =========="

GATEWAY_CONTAINER="$(
  docker ps \
    --filter 'label=com.docker.compose.service=gateway' \
    --filter 'publish=3000' \
    --format '{{.Names}}' | head -n 1
)"

[[ -n "$GATEWAY_CONTAINER" ]] ||
  die "No running Gateway publishing port 3000 was found."

PROJECT_NAME="$(
  docker inspect --format \
    '{{ index .Config.Labels "com.docker.compose.project" }}' \
    "$GATEWAY_CONTAINER"
)"

SD_CONTAINER="$(
  docker ps \
    --filter "label=com.docker.compose.project=$PROJECT_NAME" \
    --filter 'label=com.docker.compose.service=service-discovery' \
    --format '{{.Names}}' | head -n 1
)"

[[ -n "$SD_CONTAINER" ]] ||
  die "Service Discovery was not found in the Gateway's Compose project."

REPLICA_NAMES="$(
  docker ps \
    --filter "label=com.docker.compose.project=$PROJECT_NAME" \
    --filter "label=com.docker.compose.service=$SERVICE_NAME" \
    --format '{{.Names}}'
)"

REPLICA_COUNT="$(
  printf '%s\n' "$REPLICA_NAMES" |
    awk 'NF { count++ } END { print count + 0 }'
)"

(( REPLICA_COUNT >= 2 )) ||
  die "At least two running University Record replicas are required."

TARGET_CONTAINER="$(
  printf '%s\n' "$REPLICA_NAMES" | awk 'NF { print; exit }'
)"

TARGET_HOSTNAME="$(
  docker inspect --format '{{.Config.Hostname}}' "$TARGET_CONTAINER"
)"

TARGET_INSTANCE_ID="${SERVICE_NAME}-${TARGET_HOSTNAME}"

GATEWAY_ENV="$(
  docker inspect --format \
    '{{range .Config.Env}}{{println .}}{{end}}' "$GATEWAY_CONTAINER"
)"

SD_ENV="$(
  docker inspect --format \
    '{{range .Config.Env}}{{println .}}{{end}}' "$SD_CONTAINER"
)"

SERVICE_TOKEN="$(get_setting "$GATEWAY_ENV" SERVICE_TOKEN '')"
[[ -n "$SERVICE_TOKEN" ]] ||
  die "The Gateway's SERVICE_TOKEN is missing."

RULES_CONTAINERS="$(
  docker ps \
    --filter "label=com.docker.compose.project=$PROJECT_NAME" \
    --filter 'label=com.docker.compose.service=server-rules-service' \
    --format '{{.Names}}'
)"

[[ -n "$RULES_CONTAINERS" ]] ||
  die "No running Server Rules instance was found."

RULES_ENV=""
RULES_COUNT=0

while IFS= read -r rules_container; do
  [[ -n "$rules_container" ]] || continue

  rules_env="$(
    docker inspect --format \
      '{{range .Config.Env}}{{println .}}{{end}}' "$rules_container"
  )"

  rules_mode="$(get_setting "$rules_env" BREAKER_MODE log)"
  rules_token="$(get_setting "$rules_env" SERVICE_TOKEN '')"

  [[ "$rules_mode" == "remove" ]] ||
    die "$rules_container has BREAKER_MODE=$rules_mode; expected remove."

  [[ "$rules_token" == "$SERVICE_TOKEN" ]] ||
    die "$rules_container and Gateway do not share the same service token."

  if [[ -z "$RULES_ENV" ]]; then
    RULES_ENV="$rules_env"
  fi

  RULES_COUNT=$((RULES_COUNT + 1))
done <<< "$RULES_CONTAINERS"

RULES_TIMEOUT_MS="$(
  get_setting "$RULES_ENV" HTTP_TIMEOUT_MS 2500
)"

[[ "$RULES_TIMEOUT_MS" =~ ^[0-9]+$ ]] &&
  (( RULES_TIMEOUT_MS > 200 )) ||
  die "Invalid Server Rules HTTP_TIMEOUT_MS."

BREAKER_WINDOW_MS=$(( RULES_TIMEOUT_MS * 35 / 10 ))

HEALTH_INTERVAL_MS="$(get_setting "$SD_ENV" HEALTH_INTERVAL_MS 5000)"
HEALTH_SUCCESSES_TO_READMIT="$(
  get_setting "$SD_ENV" HEALTH_SUCCESSES_TO_READMIT 3
)"
REMOVED_MIN_MS="$(get_setting "$SD_ENV" REMOVED_MIN_MS 30000)"

for value in "$HEALTH_INTERVAL_MS" \
             "$HEALTH_SUCCESSES_TO_READMIT" "$REMOVED_MIN_MS"; do
  [[ "$value" =~ ^[0-9]+$ ]] ||
    die "Invalid Service Discovery recovery configuration."
done

RECOVERY_TIMEOUT_SECONDS=$(( (REMOVED_MIN_MS + HEALTH_INTERVAL_MS * HEALTH_SUCCESSES_TO_READMIT + 999) / 1000 + 15 ))

CURL_CONFIG="$TMP_DIR/curl.conf"

# Keep the token in a private temporary file instead of printing it
# or placing it directly in curl's command-line arguments.
printf 'header = "Authorization: Bearer %s"\n' \
  "$SERVICE_TOKEN" > "$CURL_CONFIG"
chmod 600 "$CURL_CONFIG"

registry_state() {
  docker exec "$SD_CONTAINER" python -c '
import json
import sys
import urllib.request

target_id = sys.argv[1]

with urllib.request.urlopen(
    "http://localhost:3010/services", timeout=3
) as response:
    data = json.load(response)

instances = data.get("services", {}).get(
    "university-record-service", []
)
matches = [item for item in instances
           if item.get("instanceId") == target_id]

print(matches[0].get("state", "unknown") if matches else "missing")
' "$TARGET_INSTANCE_ID"
}

wait_for_state() {
  local expected="$1"
  local timeout_seconds="$2"
  local elapsed=0
  local current=""
  local previous=""

  while (( elapsed <= timeout_seconds )); do
    current="$(registry_state 2>/dev/null || printf 'error')"

    if [[ "$current" != "$previous" ]]; then
      echo "  Registry state: $current"
      previous="$current"
    fi

    [[ "$current" == "$expected" ]] && return 0

    sleep 1
    elapsed=$((elapsed + 1))
  done

  return 1
}

echo "Gateway:           $GATEWAY_CONTAINER"
echo "Service Discovery: $SD_CONTAINER"
echo "Server Rules count: $RULES_COUNT"
echo "Target container:  $TARGET_CONTAINER"
echo "Target instance:   $TARGET_INSTANCE_ID"
echo "Server Rules mode: remove"
echo "Breaker window:    ${BREAKER_WINDOW_MS}ms"
echo "Concurrent calls:  $REQUESTS"

TARGET_STATE="$(registry_state)"
[[ "$TARGET_STATE" == "healthy" ]] ||
  die "The target must initially be healthy; found $TARGET_STATE."

TARGET_PROBE="$(
  docker exec "$SD_CONTAINER" python -c '
import json
import sys
import urllib.request

target_id = sys.argv[1]

with urllib.request.urlopen(
    "http://localhost:3010/services", timeout=3
) as response:
    data = json.load(response)

instances = data.get("services", {}).get(
    "university-record-service", []
)
matches = [item for item in instances
           if item.get("instanceId") == target_id]

if not matches:
    raise SystemExit("Target is missing from the registry.")

url = matches[0]["url"].rstrip("/") + "/status"

with urllib.request.urlopen(url, timeout=3) as response:
    print(response.status)
' "$TARGET_INSTANCE_ID"
)" || die "The target failed its direct health probe."

[[ "$TARGET_PROBE" == "200" ]] ||
  die "The target's direct health probe did not return HTTP 200."

EVALUATE_URL="$BASE_URL/server-rules/rules/evaluate"
STATUS_URL="$BASE_URL/university-record/status"

# A valid, read-only evaluation request; it does not create an applicant.
PAYLOAD="$TMP_DIR/evaluate.json"
printf '%s\n' \
  '{"applicantId":"00000000-0000-4000-8000-000000000001","applicant":{"previousBan":false}}' \
  > "$PAYLOAD"

echo
echo "========== Baseline checks =========="

STATUS_CODE="$(
  curl --config "$CURL_CONFIG" \
    --silent --show-error --max-time 5 \
    --output /dev/null --write-out '%{http_code}' \
    "$STATUS_URL"
)" || die "The baseline University Record status request failed."

[[ "$STATUS_CODE" == "200" ]] ||
  die "Expected HTTP 200 from University Record status; got $STATUS_CODE."

BASELINE_CODE="$(
  curl --config "$CURL_CONFIG" \
    --silent --show-error --max-time 15 \
    --header 'Content-Type: application/json' \
    --request POST --data-binary "@$PAYLOAD" \
    --output "$TMP_DIR/baseline.body" \
    --write-out '%{http_code}' \
    "$EVALUATE_URL"
)" || die "The baseline Server Rules evaluation request failed."

[[ "$BASELINE_CODE" =~ ^2[0-9][0-9]$ ]] ||
  die "Baseline evaluation must succeed; got HTTP $BASELINE_CODE."

STARTED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

echo
echo "========== Inject a downstream failure =========="
echo "Pausing $TARGET_CONTAINER ..."
docker pause "$TARGET_CONTAINER" >/dev/null
PAUSED_CONTAINER="$TARGET_CONTAINER"

echo "Sending $REQUESTS concurrent POST /rules/evaluate requests ..."
PIDS=()

for ((i = 1; i <= REQUESTS; i++)); do
  (
    code="$(
      curl --config "$CURL_CONFIG" \
        --silent --show-error --max-time 15 \
        --header 'Content-Type: application/json' \
        --request POST --data-binary "@$PAYLOAD" \
        --output "$TMP_DIR/body.$i" \
        --write-out '%{http_code}' \
        "$EVALUATE_URL" \
        2>"$TMP_DIR/error.$i"
    )" || code="000"

    printf '%s\n' "$code" > "$TMP_DIR/status.$i"
  ) &
  PIDS+=("$!")
done

for pid in "${PIDS[@]}"; do
  wait "$pid" || true
done

COMPLETED=0
FAILURE_RESPONSES=0

for ((i = 1; i <= REQUESTS; i++)); do
  code="$(cat "$TMP_DIR/status.$i" 2>/dev/null || printf '000')"
  printf 'Evaluation %02d: HTTP=%s\n' "$i" "$code"

  if [[ "$code" != "000" ]]; then
    COMPLETED=$((COMPLETED + 1))
  fi

  if [[ "$code" =~ ^5[0-9][0-9]$ ]]; then
    FAILURE_RESPONSES=$((FAILURE_RESPONSES + 1))
  fi
done

(( COMPLETED >= 3 )) ||
  die "Too few evaluation requests completed to verify the fault injection."

(( FAILURE_RESPONSES >= 3 )) ||
  die "Expected at least three HTTP 5xx responses during the fault injection."

echo
echo "========== Verify circuit-breaker removal =========="

if ! wait_for_state "removed" "$REMOVAL_TIMEOUT_SECONDS"; then
  die "The target did not reach removed within ${REMOVAL_TIMEOUT_SECONDS}s."
fi

echo "PASS: Service Discovery marked the target removed."

echo
echo "========== Verify the surviving replica still serves traffic =========="
sleep 3

SURVIVOR_CONFIRMED=0

for ((attempt = 1; attempt <= 15; attempt++)); do
  code="$(
    curl --config "$CURL_CONFIG" \
      --silent --show-error --max-time 4 \
      --dump-header "$TMP_DIR/survivor.headers" \
      --output /dev/null \
      --write-out '%{http_code}' \
      "$STATUS_URL" 2>/dev/null
  )" || code="000"

  instance_id="$(
    awk 'tolower($1) == "x-instance-id:" {
      gsub("\r", "", $2)
      value = $2
    } END { print value }' \
      "$TMP_DIR/survivor.headers" 2>/dev/null || true
  )"

  if [[ "$code" == "200" &&
        -n "$instance_id" &&
        "$instance_id" != "$TARGET_INSTANCE_ID" ]]; then
    echo "PASS: HTTP 200 from surviving instance $instance_id."
    SURVIVOR_CONFIRMED=1
    break
  fi

  sleep 1
done

(( SURVIVOR_CONFIRMED == 1 )) ||
  die "The surviving replica did not serve a successful status request."

echo
echo "========== Restore the paused replica =========="
docker unpause "$TARGET_CONTAINER" >/dev/null
PAUSED_CONTAINER=""

echo "Waiting for recovery; configured minimum removed duration is ${REMOVED_MIN_MS}ms."
if ! wait_for_state "healthy" "$RECOVERY_TIMEOUT_SECONDS"; then
  die "The target did not recover to healthy within ${RECOVERY_TIMEOUT_SECONDS}s."
fi

echo "PASS: Service Discovery marked the target healthy again."

echo
echo "========== Verify the recovered replica returns to routing =========="

TARGET_ROUTED_AGAIN=0

for ((attempt = 1; attempt <= 15; attempt++)); do
  code="$(
    curl --config "$CURL_CONFIG" \
      --silent --show-error --max-time 5 \
      --dump-header "$TMP_DIR/recovery.headers" \
      --output /dev/null \
      --write-out '%{http_code}' \
      "$STATUS_URL" 2>/dev/null
  )" || code="000"

  instance_id="$(
    awk 'tolower($1) == "x-instance-id:" {
      gsub("\r", "", $2)
      value = $2
    } END { print value }' \
      "$TMP_DIR/recovery.headers" 2>/dev/null || true
  )"

  if [[ "$code" == "200" &&
        "$instance_id" == "$TARGET_INSTANCE_ID" ]]; then
    echo "PASS: Recovered target is serving traffic again."
    TARGET_ROUTED_AGAIN=1
    break
  fi

  sleep 1
done

(( TARGET_ROUTED_AGAIN == 1 )) ||
  die "The recovered target did not return to Gateway routing."

echo
echo "========== Verify Service Discovery alerts =========="

docker logs --since "$STARTED_AT" "$SD_CONTAINER" \
  > "$TMP_DIR/service-discovery.log" 2>&1

grep -F 'health alert' "$TMP_DIR/service-discovery.log" |
  grep -F "$TARGET_INSTANCE_ID" \
  > "$TMP_DIR/target-alerts.log" || true

ALERT_COUNT="$(
  awk 'NF { count++ } END { print count + 0 }' \
    "$TMP_DIR/target-alerts.log"
)"

if (( ALERT_COUNT < 2 )); then
  cat "$TMP_DIR/target-alerts.log"
  die "Expected at least two health-alert log entries for the target; found $ALERT_COUNT."
fi

cat "$TMP_DIR/target-alerts.log"

echo
echo "PASS: Circuit-breaker failure and recovery test completed."
