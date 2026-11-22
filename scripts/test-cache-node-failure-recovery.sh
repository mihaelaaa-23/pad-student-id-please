#!/usr/bin/env bash
set -euo pipefail

# End-to-end test of the Gateway's sharded Valkey cache.
#
# The script temporarily pauses one cache node, verifies that the Gateway
# continues serving requests and ejects the failed node, then unpauses it.
# The Gateway must PING and FLUSHDB the recovered node before re-adding it.
#
# WARNING: the recovered node's cache contents are intentionally flushed.
# This affects disposable cache entries only, not application database data.
#
# Requires:
#   - A running Compose stack with a cache-enabled Gateway.
#   - Three running Valkey cache nodes.
#   - A service token configured in the Gateway.
#   - Docker, curl, and Python 3 on the host.

BASE_URL="${BASE_URL:-http://localhost:3000}"
BASE_URL="${BASE_URL%/}"
CURL_TIMEOUT_SECONDS="${CURL_TIMEOUT_SECONDS:-10}"
ALLOW_CACHE_FLUSH="${ALLOW_CACHE_FLUSH:-}"

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

header_value() {
  local headers_file="$1"
  local wanted="$2"

  awk -v name="$wanted" '
    tolower($1) == tolower(name ":") {
      gsub("\r", "", $2)
      value = $2
    }
    END { print value }
  ' "$headers_file"
}

for command_name in docker curl python3; do
  command -v "$command_name" >/dev/null 2>&1 ||
    die "$command_name is required."
done

[[ "$ALLOW_CACHE_FLUSH" == "YES" ]] ||
  die "This test pauses a Valkey node and flushes its cache on recovery. Review the script, then rerun with ALLOW_CACHE_FLUSH=YES to confirm."

[[ "$CURL_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] &&
  (( CURL_TIMEOUT_SECONDS >= 1 )) ||
  die "CURL_TIMEOUT_SECONDS must be a positive integer."

TMP_DIR="$(mktemp -d)"
PAUSED_CONTAINER=""
CURL_CONFIG="$TMP_DIR/curl.conf"

cleanup() {
  local exit_code=$?
  trap - EXIT

  if [[ -n "$PAUSED_CONTAINER" ]]; then
    echo
    echo "Cleanup: attempting to unpause $PAUSED_CONTAINER ..."

    if [[ "$(docker inspect --format '{{.State.Paused}}' \
      "$PAUSED_CONTAINER" 2>/dev/null || true)" == "true" ]]; then
      docker unpause "$PAUSED_CONTAINER" >/dev/null 2>&1 || {
        echo "WARNING: automatic unpause failed." >&2
        echo "Run: docker unpause $PAUSED_CONTAINER" >&2
        exit_code=1
      }
    fi
  fi

  rm -rf "$TMP_DIR"
  exit "$exit_code"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "========== DISCOVER THE RUNNING COMPOSE STACK =========="

GATEWAY_CONTAINER="${GATEWAY_CONTAINER:-}"

if [[ -n "$GATEWAY_CONTAINER" ]]; then
  docker inspect "$GATEWAY_CONTAINER" >/dev/null 2>&1 ||
    die "The specified GATEWAY_CONTAINER does not exist."

  [[ "$(docker inspect --format '{{.State.Running}}' "$GATEWAY_CONTAINER")" == "true" ]] ||
    die "The specified GATEWAY_CONTAINER is not running."
else
  GATEWAY_CONTAINER="$(
    docker ps \
      --filter 'label=com.docker.compose.service=gateway' \
      --filter 'publish=3000' \
      --format '{{.Names}}' | sed -n '1p'
  )"
fi

[[ -n "$GATEWAY_CONTAINER" ]] ||
  die "No running Gateway was found. Set GATEWAY_CONTAINER to select one explicitly."

GATEWAY_IMAGE="$(
  docker inspect --format '{{.Config.Image}}' "$GATEWAY_CONTAINER"
)"

[[ "$GATEWAY_IMAGE" =~ (^|/)gateway:5\. ]] ||
  die "Gateway image '$GATEWAY_IMAGE' is not a Lab 5 cache-enabled 5.x image."

PROJECT_NAME="$(
  docker inspect --format \
    '{{ index .Config.Labels "com.docker.compose.project" }}' \
    "$GATEWAY_CONTAINER"
)"

[[ -n "$PROJECT_NAME" ]] ||
  die "Could not determine the Gateway's Compose project."

GATEWAY_ENV="$(
  docker inspect --format \
    '{{range .Config.Env}}{{println .}}{{end}}' \
    "$GATEWAY_CONTAINER"
)"

SERVICE_TOKEN="$(get_setting "$GATEWAY_ENV" SERVICE_TOKEN '')"
[[ -n "$SERVICE_TOKEN" ]] ||
  die "The Gateway's SERVICE_TOKEN is missing."

FAILURES_TO_EJECT="$(
  get_setting "$GATEWAY_ENV" CACHE_NODE_FAILURES_TO_EJECT 3
)"
CACHE_RETRY_S="$(
  get_setting "$GATEWAY_ENV" CACHE_NODE_RETRY_S 10
)"

[[ "$FAILURES_TO_EJECT" =~ ^[0-9]+$ ]] &&
  (( FAILURES_TO_EJECT >= 1 )) ||
  die "Invalid CACHE_NODE_FAILURES_TO_EJECT."

if ! RECOVERY_TIMEOUT_SECONDS="$(
  python3 - "$CACHE_RETRY_S" <<'PY'
import math
import sys

try:
    retry = float(sys.argv[1])
except ValueError:
    raise SystemExit("Invalid CACHE_NODE_RETRY_S")

if not math.isfinite(retry) or retry <= 0:
    raise SystemExit("CACHE_NODE_RETRY_S must be positive and finite")

print(math.ceil(retry) + 20)
PY
)"; then
  die "Could not calculate the cache-node recovery timeout."
fi

MAX_EJECTION_REQUESTS=$((FAILURES_TO_EJECT + 4))

# Keep the service token out of command-line arguments and terminal output.
printf 'header = "Authorization: Bearer %s"\n' \
  "$SERVICE_TOKEN" > "$CURL_CONFIG"
chmod 600 "$CURL_CONFIG"

echo "Gateway:             $GATEWAY_CONTAINER"
echo "Compose project:     $PROJECT_NAME"
echo "Failure threshold:   $FAILURES_TO_EJECT"
echo "Retry interval:      ${CACHE_RETRY_S}s"
echo "Recovery timeout:    ${RECOVERY_TIMEOUT_SECONDS}s"
echo "Gateway URL:         $BASE_URL"

perform_rules_request() {
  local probe="$1"
  local url="${BASE_URL}/server-rules/rules/current?cacheProbe=${probe}"

  if ! HTTP_CODE="$(
    curl --config "$CURL_CONFIG" \
      --silent --show-error \
      --max-time "$CURL_TIMEOUT_SECONDS" \
      -H 'Cache-Control: max-age=60' \
      -D "$TMP_DIR/headers" \
      -o "$TMP_DIR/body" \
      -w '%{http_code}' \
      "$url"
  )"; then
    die "Could not reach the Gateway for the Server Rules request."
  fi

  X_CACHE="$(header_value "$TMP_DIR/headers" X-Cache)"
  X_CACHE_NODE="$(header_value "$TMP_DIR/headers" X-Cache-Node)"
}

ring_node_state() {
  local code

  if ! code="$(
    curl --config "$CURL_CONFIG" \
      --silent --show-error \
      --max-time "$CURL_TIMEOUT_SECONDS" \
      -o "$TMP_DIR/ring.json" \
      -w '%{http_code}' \
      "$BASE_URL/cache/ring"
  )"; then
    die "Could not query the Gateway cache ring."
  fi

  [[ "$code" == "200" ]] || {
    echo "Cache ring response:" >&2
    sed -n '1,30p' "$TMP_DIR/ring.json" >&2
    die "GET /cache/ring returned HTTP $code. Is the cache-enabled Gateway running?"
  }

  python3 - "$TMP_DIR/ring.json" "$TARGET_NODE" <<'PY'
import json
import sys

path, wanted = sys.argv[1:3]

with open(path, encoding="utf-8") as source:
    payload = json.load(source)

matches = [
    node.get("state")
    for node in payload.get("nodes", [])
    if node.get("node") == wanted
]

if len(matches) != 1:
    raise SystemExit(f"Expected exactly one ring entry for {wanted}; got {len(matches)}")

print(matches[0])
PY
}

echo
verify_initial_ring() {
  local code

  if ! code="$(
    curl --config "$CURL_CONFIG" \
      --silent --show-error \
      --max-time "$CURL_TIMEOUT_SECONDS" \
      -o "$TMP_DIR/initial-ring.json" \
      -w '%{http_code}' \
      "$BASE_URL/cache/ring"
  )"; then
    die "Could not inspect the initial cache ring."
  fi

  [[ "$code" == "200" ]] ||
    die "Initial cache ring returned HTTP $code."

  python3 - "$TMP_DIR/initial-ring.json" <<'PYRING'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    payload = json.load(source)

nodes = payload.get("nodes", [])
expected = {"cache-1", "cache-2", "cache-3"}
actual = {node.get("node") for node in nodes}

if len(nodes) != 3 or actual != expected:
    raise SystemExit(f"Expected exactly {sorted(expected)}; got {nodes}")

for node in nodes:
    if node.get("state") != "up":
        raise SystemExit(f"Cache node is not UP: {node}")

    print(f'  {node["node"]}: {node["state"]}')

print("PASS: exactly three cache nodes are UP.")
PYRING
}

verify_initial_ring

echo "========== VERIFY NORMAL CACHE OPERATION =========="

PROBE="cache-node-recovery-${PROJECT_NAME}-$$-$(date +%s)"

perform_rules_request "$PROBE"

[[ "$HTTP_CODE" == "200" ]] || {
  sed -n '1,20p' "$TMP_DIR/body" >&2
  die "Initial Server Rules request returned HTTP $HTTP_CODE."
}

[[ "$X_CACHE" == "MISS" ]] ||
  die "Expected initial X-Cache: MISS; received '${X_CACHE:-missing}'. The Gateway may not have the Lab 5 cache enabled."

[[ -n "$X_CACHE_NODE" ]] ||
  die "Initial cache MISS did not include X-Cache-Node."

TARGET_NODE="$X_CACHE_NODE"

perform_rules_request "$PROBE"

[[ "$HTTP_CODE" == "200" && "$X_CACHE" == "HIT" &&
   "$X_CACHE_NODE" == "$TARGET_NODE" ]] ||
  die "The repeated Server Rules request did not HIT the same cache node."

echo "PASS: Server Rules cache MISS followed by HIT on $TARGET_NODE."

echo
echo "========== FIND THE SELECTED VALKEY CONTAINER =========="

TARGET_CONTAINER="$(
  docker ps \
    --filter "label=com.docker.compose.project=$PROJECT_NAME" \
    --filter "label=com.docker.compose.service=$TARGET_NODE" \
    --format '{{.Names}}' | sed -n '1p'
)"

[[ -n "$TARGET_CONTAINER" ]] ||
  die "Could not find the running Compose container for $TARGET_NODE."

SENTINEL_KEY="lab5:cache-recovery-sentinel:${PROJECT_NAME}:$$:$(date +%s)"
SENTINEL_VALUE="must-be-flushed"

docker exec "$TARGET_CONTAINER" \
  valkey-cli SET "$SENTINEL_KEY" "$SENTINEL_VALUE" EX 3600 \
  >/dev/null

STORED_SENTINEL="$(
  docker exec "$TARGET_CONTAINER" \
    valkey-cli --raw GET "$SENTINEL_KEY" | tr -d '\r\n'
)"

[[ "$STORED_SENTINEL" == "$SENTINEL_VALUE" ]] ||
  die "Could not verify the recovery sentinel on $TARGET_NODE."

echo "Selected node:     $TARGET_NODE"
echo "Selected container: $TARGET_CONTAINER"
echo "PASS: recovery sentinel stored on the selected node."

echo
echo "========== PAUSE THE SELECTED CACHE NODE =========="

# Set this before pausing so the EXIT trap also handles an interrupted pause.
PAUSED_CONTAINER="$TARGET_CONTAINER"
docker pause "$TARGET_CONTAINER" >/dev/null

[[ "$(docker inspect --format '{{.State.Paused}}' \
  "$TARGET_CONTAINER")" == "true" ]] ||
  die "Docker did not report the selected cache node as paused."

echo "Paused $TARGET_CONTAINER."

echo
echo "========== VERIFY FAIL-OPEN AND NODE EJECTION =========="

EJECTED=false

for ((attempt = 1; attempt <= MAX_EJECTION_REQUESTS; attempt++)); do
  perform_rules_request "$PROBE"

  [[ "$HTTP_CODE" == "200" ]] || {
    sed -n '1,20p' "$TMP_DIR/body" >&2
    die "Gateway returned HTTP $HTTP_CODE while a cache node was paused."
  }

  echo "Request $attempt: HTTP=$HTTP_CODE X-Cache=${X_CACHE:-MISSING} X-Cache-Node=${X_CACHE_NODE:-MISSING}"

  CURRENT_STATE="$(ring_node_state)"
  echo "  $TARGET_NODE state: $CURRENT_STATE"

  if [[ "$CURRENT_STATE" == "down" ]]; then
    EJECTED=true
    break
  fi

  sleep 0.1
done

[[ "$EJECTED" == "true" ]] ||
  die "$TARGET_NODE was not ejected after $MAX_EJECTION_REQUESTS requests."

echo "PASS: Gateway continued serving HTTP 200 and ejected $TARGET_NODE."

echo
echo "========== VERIFY CACHE SERVICE ON THE REMAINING NODES =========="

FALLBACK_PROBE="${PROBE}-fallback"

perform_rules_request "$FALLBACK_PROBE"

[[ "$HTTP_CODE" == "200" && "$X_CACHE" == "MISS" &&
   -n "$X_CACHE_NODE" && "$X_CACHE_NODE" != "$TARGET_NODE" ]] ||
  die "A request did not use a healthy fallback cache node after ejection."

FALLBACK_NODE="$X_CACHE_NODE"

perform_rules_request "$FALLBACK_PROBE"

[[ "$HTTP_CODE" == "200" && "$X_CACHE" == "HIT" &&
   "$X_CACHE_NODE" == "$FALLBACK_NODE" ]] ||
  die "The fallback cache node did not return a HIT on the repeated request."

echo "PASS: fallback cache MISS followed by HIT on $FALLBACK_NODE."

echo
echo "========== UNPAUSE AND WAIT FOR NODE RECOVERY =========="

docker unpause "$TARGET_CONTAINER" >/dev/null
PAUSED_CONTAINER=""

RESTORED=false

for ((elapsed = 0; elapsed <= RECOVERY_TIMEOUT_SECONDS; elapsed++)); do
  CURRENT_STATE="$(ring_node_state)"

  if [[ "$CURRENT_STATE" == "up" ]]; then
    RESTORED=true
    echo "Node state: $CURRENT_STATE after approximately ${elapsed}s."
    break
  fi

  if (( elapsed % 5 == 0 )); then
    echo "Waiting for $TARGET_NODE: state=$CURRENT_STATE (${elapsed}s elapsed)."
  fi

  sleep 1
done

[[ "$RESTORED" == "true" ]] ||
  die "$TARGET_NODE was not restored within ${RECOVERY_TIMEOUT_SECONDS}s."

echo "PASS: Gateway automatically re-added $TARGET_NODE to the ring."

echo
echo "========== VERIFY STALE CACHE DATA WAS FLUSHED =========="

REMAINING_SENTINEL="$(
  docker exec "$TARGET_CONTAINER" \
    valkey-cli --raw GET "$SENTINEL_KEY" | tr -d '\r\n'
)"

[[ -z "$REMAINING_SENTINEL" ]] ||
  die "Recovery sentinel still exists. The node may have been re-added without FLUSHDB."

echo "PASS: recovery sentinel was removed before the node rejoined the ring."

echo
echo "========== VERIFY CACHE USE AFTER RECOVERY =========="

RECOVERED_CACHE=false

for ((attempt = 1; attempt <= 24; attempt++)); do
  RECOVERED_PROBE="${PROBE}-restored-${attempt}"

  perform_rules_request "$RECOVERED_PROBE"

  [[ "$HTTP_CODE" == "200" ]] ||
    die "Server Rules returned HTTP $HTTP_CODE after cache-node recovery."

  if [[ "$X_CACHE_NODE" != "$TARGET_NODE" ]]; then
    continue
  fi

  [[ "$X_CACHE" == "MISS" ]] ||
    die "Expected a fresh MISS on restored node $TARGET_NODE; received $X_CACHE."

  perform_rules_request "$RECOVERED_PROBE"

  [[ "$HTTP_CODE" == "200" && "$X_CACHE" == "HIT" &&
     "$X_CACHE_NODE" == "$TARGET_NODE" ]] ||
    die "Restored node did not serve a HIT for the repeated request."

  RECOVERED_CACHE=true
  break
done

[[ "$RECOVERED_CACHE" == "true" ]] ||
  die "Could not find a Server Rules cache key assigned to restored node $TARGET_NODE."

echo "PASS: restored node served MISS followed by HIT."

echo
echo "PASS: I-G10 cache-node failure and recovery test completed."
