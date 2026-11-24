#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HAPROXY_CONFIG="$REPO_ROOT/infra/pg-router/haproxy.cfg"

ETCD_TIMEOUT_SECONDS="${ETCD_TIMEOUT_SECONDS:-90}"
POSTGRES_TIMEOUT_SECONDS="${POSTGRES_TIMEOUT_SECONDS:-360}"
ELECTION_TIMEOUT_SECONDS="${ELECTION_TIMEOUT_SECONDS:-120}"
RECOVERY_TIMEOUT_SECONDS="${RECOVERY_TIMEOUT_SECONDS:-180}"

die() {
  echo "FAIL: $*" >&2
  exit 1
}

for command_name in docker openssl; do
  command -v "$command_name" >/dev/null 2>&1 ||
    die "$command_name is required."
done

[[ -r "$HAPROXY_CONFIG" ]] ||
  die "Missing HAProxy configuration: $HAPROXY_CONFIG"

for value in \
  "$ETCD_TIMEOUT_SECONDS" \
  "$POSTGRES_TIMEOUT_SECONDS" \
  "$ELECTION_TIMEOUT_SECONDS" \
  "$RECOVERY_TIMEOUT_SECONDS"; do
  [[ "$value" =~ ^[0-9]+$ ]] && (( value > 0 )) ||
    die "Timeout settings must be positive integers."
done

docker version >/dev/null 2>&1 ||
  die "Docker Engine is unavailable."

TMP_BASE="${TMPDIR:-/tmp}"
TMP_DIR="$(mktemp -d "${TMP_BASE%/}/pad-postgres-ha-failover.XXXXXX")"

PROJECT_NAME="pad-postgres-ha-failover-$$-$RANDOM"
PG_SUPERUSER_PASSWORD="$(openssl rand -hex 32)"
PG_ADMIN_PASSWORD="$(openssl rand -hex 32)"
PG_REPLICATION_PASSWORD="$(openssl rand -hex 32)"
PROBE_ID="probe-${PROJECT_NAME}"

ENV_FILE="$TMP_DIR/.env"
PAUSED_CONTAINER=""
STACK_CREATED=0

{
  printf 'PG_SUPERUSER_PASSWORD=%s\n' "$PG_SUPERUSER_PASSWORD"
  printf 'PG_ADMIN_PASSWORD=%s\n' "$PG_ADMIN_PASSWORD"
  printf 'PG_REPLICATION_PASSWORD=%s\n' "$PG_REPLICATION_PASSWORD"
  printf 'PG_ROUTER_CONFIG=%s\n' "$HAPROXY_CONFIG"
} > "$ENV_FILE"
chmod 600 "$ENV_FILE"

# Export the same values as a fallback for Compose commands during cleanup.
# This is particularly important for older Docker Compose releases.
export PG_SUPERUSER_PASSWORD
export PG_ADMIN_PASSWORD
export PG_REPLICATION_PASSWORD
export PG_ROUTER_CONFIG="$HAPROXY_CONFIG"

compose() {
  docker compose \
    --env-file "$ENV_FILE" \
    --project-name "$PROJECT_NAME" \
    --file "$TMP_DIR/compose.yml" \
    "$@"
}

container_id_for() {
  local service="$1"

  docker ps -aq \
    --filter "label=com.docker.compose.project=$PROJECT_NAME" \
    --filter "label=com.docker.compose.service=$service" |
    head -n 1
}

cleanup() {
  local exit_code=$?
  local cleanup_failed=0
  local paused_state="false"

  trap - EXIT INT TERM

  echo
  echo "========== CLEANUP: isolated PostgreSQL HA project =========="

  if [[ -n "$PAUSED_CONTAINER" ]]; then
    paused_state="$(
      docker inspect --format '{{.State.Paused}}' \
        "$PAUSED_CONTAINER" 2>/dev/null || printf 'unknown'
    )"

    if [[ "$paused_state" == "true" ]]; then
      echo "Unpausing test container $PAUSED_CONTAINER ..."
      docker unpause "$PAUSED_CONTAINER" >/dev/null ||
        cleanup_failed=1
    fi
  fi

  if (( STACK_CREATED == 1 )); then
    echo "Removing Compose project $PROJECT_NAME and its volumes ..."
    compose down --volumes --remove-orphans ||
      cleanup_failed=1

    remaining_containers="$(
      docker ps -aq --filter "label=com.docker.compose.project=$PROJECT_NAME"
    )"
    remaining_volumes="$(
      docker volume ls -q --filter "label=com.docker.compose.project=$PROJECT_NAME"
    )"
    remaining_networks="$(
      docker network ls -q --filter "label=com.docker.compose.project=$PROJECT_NAME"
    )"

    if [[ -n "$remaining_containers" ||
          -n "$remaining_volumes" ||
          -n "$remaining_networks" ]]; then
      echo "WARNING: Resources remain for Compose project $PROJECT_NAME." >&2
      [[ -z "$remaining_containers" ]] ||
        printf 'Remaining containers:\\n%s\\n' "$remaining_containers" >&2
      [[ -z "$remaining_volumes" ]] ||
        printf 'Remaining volumes:\\n%s\\n' "$remaining_volumes" >&2
      [[ -z "$remaining_networks" ]] ||
        printf 'Remaining networks:\\n%s\\n' "$remaining_networks" >&2
      cleanup_failed=1
    else
      echo "PASS: No containers, volumes, or networks remain for the test project."
    fi
  fi

  if (( cleanup_failed == 0 )); then
    rm -rf "$TMP_DIR"
    echo "PASS: Temporary containers, network, and volumes removed."
  else
    echo "WARNING: Automatic cleanup was incomplete." >&2
    echo "Temporary files retained at: $TMP_DIR" >&2
    echo "Project name: $PROJECT_NAME" >&2
    echo "After checking the containers, retry cleanup with:" >&2
    echo "docker compose --env-file '$ENV_FILE' -p '$PROJECT_NAME' -f '$TMP_DIR/compose.yml' down --volumes --remove-orphans" >&2

    if (( exit_code == 0 )); then
      exit_code=1
    fi
  fi

  exit "$exit_code"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

cat > "$TMP_DIR/compose.yml" <<'COMPOSE'
services:
  etcd:
    image: quay.io/coreos/etcd:v3.5.17
    restart: "no"
    mem_limit: 192m
    cpus: 0.25
    command:
      - etcd
      - --name=etcd
      - --data-dir=/etcd-data
      - --listen-client-urls=http://0.0.0.0:2379
      - --advertise-client-urls=http://etcd:2379
      - --listen-peer-urls=http://0.0.0.0:2380
      - --initial-advertise-peer-urls=http://etcd:2380
      - --initial-cluster=etcd=http://etcd:2380
      - --initial-cluster-state=new
    volumes:
      - etcd_data:/etcd-data
    healthcheck:
      test: ["CMD", "etcdctl", "--endpoints=http://localhost:2379", "endpoint", "health"]
      interval: 5s
      timeout: 5s
      retries: 10

  university-record-db-1: &university-record-db
    image: ghcr.io/zalando/spilo-16:3.3-p1
    restart: "no"
    mem_limit: 640m
    cpus: 0.75
    hostname: university-record-db-1
    environment: &university-record-db-env
      SCOPE: university-record-db
      PGVERSION: "16"
      ETCD3_HOST: etcd:2379
      SPILO_PROVIDER: local
      PGPASSWORD_SUPERUSER: "${PG_SUPERUSER_PASSWORD}"
      PGPASSWORD_ADMIN: "${PG_ADMIN_PASSWORD}"
      PGPASSWORD_STANDBY: "${PG_REPLICATION_PASSWORD}"
      ALLOW_NOSSL: "true"
      SPILO_CONFIGURATION: |
        restapi:
          connect_address: university-record-db-1:8008
        postgresql:
          connect_address: university-record-db-1:5432
          parameters:
            shared_buffers: 128MB
    volumes:
      - postgres1_data:/home/postgres/pgdata
    healthcheck:
      test: ["CMD", "python3", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:8008/health', timeout=2)"]
      interval: 5s
      timeout: 5s
      retries: 30
      start_period: 30s
    depends_on:
      etcd:
        condition: service_healthy

  university-record-db-2:
    <<: *university-record-db
    hostname: university-record-db-2
    environment:
      <<: *university-record-db-env
      SPILO_CONFIGURATION: |
        restapi:
          connect_address: university-record-db-2:8008
        postgresql:
          connect_address: university-record-db-2:5432
          parameters:
            shared_buffers: 128MB
    volumes:
      - postgres2_data:/home/postgres/pgdata

  university-record-db-3:
    <<: *university-record-db
    hostname: university-record-db-3
    environment:
      <<: *university-record-db-env
      SPILO_CONFIGURATION: |
        restapi:
          connect_address: university-record-db-3:8008
        postgresql:
          connect_address: university-record-db-3:5432
          parameters:
            shared_buffers: 128MB
    volumes:
      - postgres3_data:/home/postgres/pgdata

  pg-router:
    image: haproxy:3.0-alpine
    restart: "no"
    mem_limit: 96m
    cpus: 0.25
    volumes:
      - "${PG_ROUTER_CONFIG}:/usr/local/etc/haproxy/haproxy.cfg:ro"
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1:8404/ || exit 1"]
      interval: 5s
      timeout: 3s
      retries: 10

volumes:
  etcd_data:
  postgres1_data:
  postgres2_data:
  postgres3_data:
COMPOSE

chmod 600 "$TMP_DIR/compose.yml"

echo "========== ISOLATED UNIVERSITY RECORD POSTGRESQL HA TEST =========="
echo "Compose project: $PROJECT_NAME"
echo "Patroni scope:   university-record-db"
echo "PostgreSQL:      16"
echo "Members:         3"
echo "Write endpoint:  pg-router:5406"
echo
echo "Existing Compose projects will not be modified."

echo
echo "========== START ISOLATED ETCD, SPILO, AND HAPROXY =========="

STACK_CREATED=1
compose up -d

ETCD_CONTAINER="$(container_id_for etcd)"
NODE1_CONTAINER="$(container_id_for university-record-db-1)"
NODE2_CONTAINER="$(container_id_for university-record-db-2)"
NODE3_CONTAINER="$(container_id_for university-record-db-3)"
ROUTER_CONTAINER="$(container_id_for pg-router)"

[[ -n "$ETCD_CONTAINER" ]] ||
  die "Could not find the etcd container."
[[ -n "$NODE1_CONTAINER" && -n "$NODE2_CONTAINER" && -n "$NODE3_CONTAINER" ]] ||
  die "Could not find all three Spilo containers."
[[ -n "$ROUTER_CONTAINER" ]] ||
  die "Could not find the HAProxy container."

wait_for_health() {
  local container="$1"
  local label="$2"
  local timeout_seconds="$3"
  local elapsed=0
  local status=""

  while (( elapsed <= timeout_seconds )); do
    status="$(
      docker inspect --format \
        '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
        "$container" 2>/dev/null || true
    )"

    if [[ "$status" == "healthy" ]]; then
      echo "PASS: $label is healthy."
      return 0
    fi

    if [[ "$status" == "exited" || "$status" == "dead" ]]; then
      echo "Container logs for $label:"
      docker logs "$container" 2>&1 | tail -n 80
      return 1
    fi

    if (( elapsed % 15 == 0 )); then
      echo "  Waiting for $label: ${status:-unknown} (${elapsed}s)"
    fi

    sleep 1
    elapsed=$((elapsed + 1))
  done

  echo "Timed out waiting for $label."
  docker logs "$container" 2>&1 | tail -n 80
  return 1
}

echo
echo "========== WAIT FOR ETCD =========="
wait_for_health "$ETCD_CONTAINER" "etcd" "$ETCD_TIMEOUT_SECONDS" ||
  die "etcd did not become healthy."

echo
echo "========== WAIT FOR THREE SPILO NODES =========="
wait_for_health "$NODE1_CONTAINER" "university-record-db-1" "$POSTGRES_TIMEOUT_SECONDS" ||
  die "Spilo member 1 did not become healthy."
wait_for_health "$NODE2_CONTAINER" "university-record-db-2" "$POSTGRES_TIMEOUT_SECONDS" ||
  die "Spilo member 2 did not become healthy."
wait_for_health "$NODE3_CONTAINER" "university-record-db-3" "$POSTGRES_TIMEOUT_SECONDS" ||
  die "Spilo member 3 did not become healthy."

echo
echo "========== WAIT FOR HAPROXY =========="
wait_for_health "$ROUTER_CONTAINER" "pg-router" 90 ||
  die "HAProxy did not become healthy."

psql_query() {
  local container="$1"
  local host="$2"
  local port="$3"
  local sql="$4"

  docker exec \
    -e PGPASSWORD="$PG_SUPERUSER_PASSWORD" \
    -e PGCONNECT_TIMEOUT=3 \
    "$container" \
    psql -X -q -w -v ON_ERROR_STOP=1 \
      -U postgres -h "$host" -p "$port" -d postgres \
      -A -t -c "$sql"
}

node_role() {
  local container="$1"

  psql_query "$container" localhost 5432 \
    "SELECT CASE WHEN pg_is_in_recovery() THEN 'replica' ELSE 'primary' END"
}

echo
echo "========== VERIFY INITIAL PATRONI LEADER AND REPLICAS =========="

PRIMARY_SERVICE=""
PRIMARY_CONTAINER=""
INITIAL_ROLES=""

for ((second = 0; second <= POSTGRES_TIMEOUT_SECONDS; second++)); do
  ROLE1="$(node_role "$NODE1_CONTAINER" 2>/dev/null || true)"
  ROLE2="$(node_role "$NODE2_CONTAINER" 2>/dev/null || true)"
  ROLE3="$(node_role "$NODE3_CONTAINER" 2>/dev/null || true)"

  if [[ "$ROLE1" == "primary" &&
        "$ROLE2" == "replica" &&
        "$ROLE3" == "replica" ]]; then
    PRIMARY_SERVICE="university-record-db-1"
    PRIMARY_CONTAINER="$NODE1_CONTAINER"
    INITIAL_ROLES="db-1=primary db-2=replica db-3=replica"
    break
  fi

  if [[ "$ROLE2" == "primary" &&
        "$ROLE1" == "replica" &&
        "$ROLE3" == "replica" ]]; then
    PRIMARY_SERVICE="university-record-db-2"
    PRIMARY_CONTAINER="$NODE2_CONTAINER"
    INITIAL_ROLES="db-1=replica db-2=primary db-3=replica"
    break
  fi

  if [[ "$ROLE3" == "primary" &&
        "$ROLE1" == "replica" &&
        "$ROLE2" == "replica" ]]; then
    PRIMARY_SERVICE="university-record-db-3"
    PRIMARY_CONTAINER="$NODE3_CONTAINER"
    INITIAL_ROLES="db-1=replica db-2=replica db-3=primary"
    break
  fi

  if (( second % 10 == 0 )); then
    echo "  Waiting for one leader and two replicas (${second}s) ..."
  fi

  sleep 1
done

[[ -n "$PRIMARY_CONTAINER" ]] ||
  die "The cluster did not reach exactly one primary and two replicas."

echo "Initial roles: $INITIAL_ROLES"
echo "Initial leader: $PRIMARY_SERVICE"
echo "PASS: One leader and two replicas are available."

# Run HAProxy client commands from a surviving database container.
# Never use the container that will be paused as the test command executor.
case "$PRIMARY_SERVICE" in
  university-record-db-1)
    ROUTER_CLIENT_CONTAINER="$NODE2_CONTAINER"
    ;;
  university-record-db-2|university-record-db-3)
    ROUTER_CLIENT_CONTAINER="$NODE1_CONTAINER"
    ;;
  *)
    die "Unexpected initial primary: $PRIMARY_SERVICE"
    ;;
esac

echo "HAProxy test client: $ROUTER_CLIENT_CONTAINER"

echo
echo "========== VERIFY HAProxy WRITE ROUTING =========="

ROUTE_ROLE=""

for ((second = 0; second <= 90; second++)); do
  ROUTE_ROLE="$(
    psql_query "$ROUTER_CLIENT_CONTAINER" pg-router 5406 \
      "SELECT CASE WHEN pg_is_in_recovery() THEN 'replica' ELSE 'primary' END" \
      2>/dev/null || true
  )"

  [[ "$ROUTE_ROLE" == "primary" ]] && break
  sleep 1
done

[[ "$ROUTE_ROLE" == "primary" ]] ||
  die "HAProxy port 5406 did not route to the current primary."

echo "PASS: HAProxy port 5406 routes writes to the leader."

echo
echo "========== CREATE BASELINE PROBE THROUGH HAPROXY =========="

psql_query "$ROUTER_CLIENT_CONTAINER" pg-router 5406 \
  "CREATE TABLE public.failover_probes (id text PRIMARY KEY, phase text NOT NULL)" \
  >/dev/null ||
  die "Could not create the failover probe table through HAProxy."

BASELINE_VALUE="$(
  psql_query "$ROUTER_CLIENT_CONTAINER" pg-router 5406 \
    "INSERT INTO public.failover_probes(id, phase) VALUES ('$PROBE_ID', 'before-failover') RETURNING phase"
)" || die "Baseline write through HAProxy failed."

[[ "$BASELINE_VALUE" == "before-failover" ]] ||
  die "Unexpected baseline write result: $BASELINE_VALUE"

echo "PASS: Baseline write committed through HAProxy."

echo
echo "========== PAUSE THE CURRENT PATRONI LEADER =========="

# Set before pausing so the EXIT handler always attempts to restore the node.
PAUSED_CONTAINER="$PRIMARY_CONTAINER"

docker pause "$PRIMARY_CONTAINER" >/dev/null ||
  die "Could not pause the initial primary."

echo "Paused: $PRIMARY_SERVICE"

echo
echo "========== WAIT FOR PATRONI TO ELECT A NEW LEADER =========="

NEW_PRIMARY_SERVICE=""
NEW_PRIMARY_CONTAINER=""

for ((second = 0; second <= ELECTION_TIMEOUT_SECONDS; second++)); do
  ROLE1=""
  ROLE2=""
  ROLE3=""

  if [[ "$PRIMARY_SERVICE" != "university-record-db-1" ]]; then
    ROLE1="$(node_role "$NODE1_CONTAINER" 2>/dev/null || true)"
  fi
  if [[ "$PRIMARY_SERVICE" != "university-record-db-2" ]]; then
    ROLE2="$(node_role "$NODE2_CONTAINER" 2>/dev/null || true)"
  fi
  if [[ "$PRIMARY_SERVICE" != "university-record-db-3" ]]; then
    ROLE3="$(node_role "$NODE3_CONTAINER" 2>/dev/null || true)"
  fi

  NEW_PRIMARY_SERVICE=""
  NEW_PRIMARY_CONTAINER=""

  if [[ "$ROLE1" == "primary" ]]; then
    NEW_PRIMARY_SERVICE="university-record-db-1"
    NEW_PRIMARY_CONTAINER="$NODE1_CONTAINER"
  elif [[ "$ROLE2" == "primary" ]]; then
    NEW_PRIMARY_SERVICE="university-record-db-2"
    NEW_PRIMARY_CONTAINER="$NODE2_CONTAINER"
  elif [[ "$ROLE3" == "primary" ]]; then
    NEW_PRIMARY_SERVICE="university-record-db-3"
    NEW_PRIMARY_CONTAINER="$NODE3_CONTAINER"
  fi

  if [[ -n "$NEW_PRIMARY_CONTAINER" ]]; then
    break
  fi

  if (( second % 5 == 0 )); then
    echo "  Waiting for replacement leader (${second}s) ..."
  fi

  sleep 1
done

[[ -n "$NEW_PRIMARY_CONTAINER" ]] ||
  die "No replacement primary was elected within ${ELECTION_TIMEOUT_SECONDS}s."

[[ "$NEW_PRIMARY_CONTAINER" != "$PRIMARY_CONTAINER" ]] ||
  die "The paused node was incorrectly identified as the replacement primary."

echo "New leader: $NEW_PRIMARY_SERVICE"
echo "PASS: Patroni elected a different primary."

echo
echo "========== VERIFY HAPROXY MOVED TO THE NEW LEADER =========="

ROUTE_ROLE=""

for ((second = 0; second <= ELECTION_TIMEOUT_SECONDS; second++)); do
  ROUTE_ROLE="$(
    psql_query "$ROUTER_CLIENT_CONTAINER" pg-router 5406 \
      "SELECT CASE WHEN pg_is_in_recovery() THEN 'replica' ELSE 'primary' END" \
      2>/dev/null || true
  )"

  [[ "$ROUTE_ROLE" == "primary" ]] && break

  if (( second % 5 == 0 )); then
    echo "  Waiting for HAProxy leader route (${second}s) ..."
  fi

  sleep 1
done

[[ "$ROUTE_ROLE" == "primary" ]] ||
  die "HAProxy did not route to the replacement primary."

echo "PASS: HAProxy port 5406 follows the new leader."

echo
echo "========== WRITE DURING FAILOVER THROUGH HAPROXY =========="

FAILOVER_VALUE="$(
  psql_query "$ROUTER_CLIENT_CONTAINER" pg-router 5406 \
    "UPDATE public.failover_probes SET phase = 'during-failover' WHERE id = '$PROBE_ID' RETURNING phase"
)" || die "Write through HAProxy failed after leader election."

[[ "$FAILOVER_VALUE" == "during-failover" ]] ||
  die "Unexpected failover write result: $FAILOVER_VALUE"

NEW_PRIMARY_VALUE="$(
  psql_query "$NEW_PRIMARY_CONTAINER" localhost 5432 \
    "SELECT phase FROM public.failover_probes WHERE id = '$PROBE_ID'"
)" || die "Could not verify the failover write on the new primary."

[[ "$NEW_PRIMARY_VALUE" == "during-failover" ]] ||
  die "The new primary does not contain the failover write."

echo "PASS: Write committed through HAProxy and exists on the new primary."

echo
echo "========== RESTORE THE ORIGINAL LEADER =========="

docker unpause "$PRIMARY_CONTAINER" >/dev/null ||
  die "Could not unpause the original leader."

PAUSED_CONTAINER=""
echo "Unpaused: $PRIMARY_SERVICE"

echo
echo "========== WAIT FOR ORIGINAL LEADER TO REJOIN AS A REPLICA =========="

ORIGINAL_STATE=""
ORIGINAL_VALUE=""

for ((second = 0; second <= RECOVERY_TIMEOUT_SECONDS; second++)); do
  ORIGINAL_STATE="$(
    node_role "$PRIMARY_CONTAINER" 2>/dev/null || true
  )"

  if [[ "$ORIGINAL_STATE" == "replica" ]]; then
    ORIGINAL_VALUE="$(
      psql_query "$PRIMARY_CONTAINER" localhost 5432 \
        "SELECT phase FROM public.failover_probes WHERE id = '$PROBE_ID'" \
        2>/dev/null || true
    )"

    if [[ "$ORIGINAL_VALUE" == "during-failover" ]]; then
      break
    fi
  fi

  if (( second % 10 == 0 )); then
    echo "  Original member role: ${ORIGINAL_STATE:-unknown}; replicated value: ${ORIGINAL_VALUE:-pending} (${second}s)"
  fi

  sleep 1
done

[[ "$ORIGINAL_STATE" == "replica" ]] ||
  die "Original leader did not rejoin as a replica."

[[ "$ORIGINAL_VALUE" == "during-failover" ]] ||
  die "Original leader did not receive the committed failover write."

echo "Original member role: $ORIGINAL_STATE"
echo "PASS: Original leader rejoined as a replica."
echo "PASS: Recovered replica contains the failover write."

echo
echo "========== VERIFY THREE-MEMBER CLUSTER AFTER RECOVERY =========="

ROLE1="$(node_role "$NODE1_CONTAINER" 2>/dev/null || true)"
ROLE2="$(node_role "$NODE2_CONTAINER" 2>/dev/null || true)"
ROLE3="$(node_role "$NODE3_CONTAINER" 2>/dev/null || true)"

PRIMARY_COUNT=0
REPLICA_COUNT=0

for role in "$ROLE1" "$ROLE2" "$ROLE3"; do
  [[ "$role" == "primary" ]] && PRIMARY_COUNT=$((PRIMARY_COUNT + 1))
  [[ "$role" == "replica" ]] && REPLICA_COUNT=$((REPLICA_COUNT + 1))
done

echo "Roles after recovery: db-1=$ROLE1 db-2=$ROLE2 db-3=$ROLE3"

[[ "$PRIMARY_COUNT" -eq 1 && "$REPLICA_COUNT" -eq 2 ]] ||
  die "Expected one primary and two replicas after recovery."

echo "PASS: All three members returned to the expected cluster roles."

echo
echo "========== REMOVE TEST PROBE THROUGH HAPROXY =========="

DELETE_VALUE="$(
  psql_query "$ROUTER_CLIENT_CONTAINER" pg-router 5406 \
    "DELETE FROM public.failover_probes WHERE id = '$PROBE_ID' RETURNING id"
)" || die "Could not delete the test probe."

[[ "$DELETE_VALUE" == "$PROBE_ID" ]] ||
  die "Unexpected test probe deletion result."

psql_query "$ROUTER_CLIENT_CONTAINER" pg-router 5406 \
  "DROP TABLE public.failover_probes" >/dev/null ||
  die "Could not drop the test probe table."

echo "PASS: Test probe and table removed."

echo
echo "========== RESULT =========="
echo "PASS: Three-member PostgreSQL 16 Patroni cluster."
echo "PASS: Initial leader and replica roles verified."
echo "PASS: HAProxy initially routed writes to the leader."
echo "PASS: Replacement leader elected after primary pause."
echo "PASS: HAProxy followed the replacement leader."
echo "PASS: Write committed through HAProxy during failover."
echo "PASS: Original leader rejoined as a replica."
echo "PASS: Failover write replicated to the recovered member."
echo "PASS: One primary and two replicas verified after recovery."
echo "PASS: Test probe removed."
echo
echo "The EXIT handler will remove only the isolated test project."
