#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RS_SCRIPT_DIR="$REPO_ROOT/db/mongo-rs"

INIT_TIMEOUT_SECONDS="${INIT_TIMEOUT_SECONDS:-180}"
ELECTION_TIMEOUT_SECONDS="${ELECTION_TIMEOUT_SECONDS:-90}"
RESTORE_TIMEOUT_SECONDS="${RESTORE_TIMEOUT_SECONDS:-120}"

die() {
  echo "FAIL: $*" >&2
  exit 1
}

for command_name in docker openssl; do
  command -v "$command_name" >/dev/null 2>&1 ||
    die "$command_name is required."
done

for script_file in mongod-rs.sh init-replica-set.sh; do
  [[ -r "$RS_SCRIPT_DIR/$script_file" ]] ||
    die "Missing replica-set script: $RS_SCRIPT_DIR/$script_file"
done

for value in \
  "$INIT_TIMEOUT_SECONDS" \
  "$ELECTION_TIMEOUT_SECONDS" \
  "$RESTORE_TIMEOUT_SECONDS"; do
  [[ "$value" =~ ^[0-9]+$ ]] && (( value > 0 )) ||
    die "Timeout settings must be positive integers."
done

docker version >/dev/null 2>&1 ||
  die "Docker Engine is unavailable."

TMP_BASE="${TMPDIR:-/tmp}"
TMP_DIR="$(mktemp -d "${TMP_BASE%/}/pad-mongo-rs-failover.XXXXXX")"

PROJECT_NAME="pad-mongo-rs-failover-$$-$RANDOM"
MONGO_ROOT_USERNAME="failover_root"
MONGO_ROOT_PASSWORD="$(openssl rand -hex 32)"
MONGO_REPLICA_KEY="$(openssl rand -base64 64 | tr -d '\n')"
PROBE_ID="probe-${PROJECT_NAME}"
DB_NAME="mongo_failover_test"

PAUSED_CONTAINER=""
STACK_CREATED=0

export MONGO_ROOT_USERNAME
export MONGO_ROOT_PASSWORD
export MONGO_REPLICA_KEY
export MONGO_RS_SCRIPT_DIR="$RS_SCRIPT_DIR"

# Preserve temporary Compose interpolation values for manual recovery if cleanup fails.
ENV_FILE="$TMP_DIR/.env"
{
  printf 'MONGO_ROOT_USERNAME=%s\n' "$MONGO_ROOT_USERNAME"
  printf 'MONGO_ROOT_PASSWORD=%s\n' "$MONGO_ROOT_PASSWORD"
  printf 'MONGO_REPLICA_KEY=%s\n' "$MONGO_REPLICA_KEY"
  printf 'MONGO_RS_SCRIPT_DIR=%s\n' "$MONGO_RS_SCRIPT_DIR"
} > "$ENV_FILE"
chmod 600 "$ENV_FILE"

compose() {
  docker compose \
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
  echo "========== CLEANUP: isolated MongoDB test project =========="

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
  fi

  if (( cleanup_failed == 0 )); then
    rm -rf "$TMP_DIR"
    echo "PASS: Temporary project, network, containers, and volumes removed."
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
  applicant-db-1:
    image: mongo:7
    hostname: applicant-db-1
    restart: "no"
    entrypoint: ["sh", "/mongod-rs.sh"]
    environment:
      SERVICE_NAME: applicant-db-1
      RS_NAME: rs-applicant
      MONGO_REPLICA_KEY: "${MONGO_REPLICA_KEY}"
      MONGO_INITDB_ROOT_USERNAME: "${MONGO_ROOT_USERNAME}"
      MONGO_INITDB_ROOT_PASSWORD: "${MONGO_ROOT_PASSWORD}"
    volumes:
      - mongo1_data:/data/db
      - "${MONGO_RS_SCRIPT_DIR}/mongod-rs.sh:/mongod-rs.sh:ro"
    healthcheck:
      test: ["CMD", "mongosh", "--quiet", "--eval", "db.adminCommand('ping').ok"]
      interval: 5s
      timeout: 5s
      retries: 30
      start_period: 20s

  applicant-db-2:
    image: mongo:7
    hostname: applicant-db-2
    restart: "no"
    entrypoint: ["sh", "/mongod-rs.sh"]
    environment:
      SERVICE_NAME: applicant-db-2
      RS_NAME: rs-applicant
      MONGO_REPLICA_KEY: "${MONGO_REPLICA_KEY}"
    volumes:
      - mongo2_data:/data/db
      - "${MONGO_RS_SCRIPT_DIR}/mongod-rs.sh:/mongod-rs.sh:ro"
    healthcheck:
      test: ["CMD", "mongosh", "--quiet", "--eval", "db.adminCommand('ping').ok"]
      interval: 5s
      timeout: 5s
      retries: 30
      start_period: 20s

  applicant-db-3:
    image: mongo:7
    hostname: applicant-db-3
    restart: "no"
    entrypoint: ["sh", "/mongod-rs.sh"]
    environment:
      SERVICE_NAME: applicant-db-3
      RS_NAME: rs-applicant
      MONGO_REPLICA_KEY: "${MONGO_REPLICA_KEY}"
    volumes:
      - mongo3_data:/data/db
      - "${MONGO_RS_SCRIPT_DIR}/mongod-rs.sh:/mongod-rs.sh:ro"
    healthcheck:
      test: ["CMD", "mongosh", "--quiet", "--eval", "db.adminCommand('ping').ok"]
      interval: 5s
      timeout: 5s
      retries: 30
      start_period: 20s

  applicant-db-rs-init:
    image: mongo:7
    restart: "no"
    command: ["sh", "/init-replica-set.sh"]
    environment:
      SERVICE_NAME: applicant-db-rs-init
      RS_NAME: rs-applicant
      RS_MEMBERS: applicant-db-1:27017,applicant-db-2:27017,applicant-db-3:27017
      MONGO_ROOT_USERNAME: "${MONGO_ROOT_USERNAME}"
      MONGO_ROOT_PASSWORD: "${MONGO_ROOT_PASSWORD}"
      WAIT_TIMEOUT_S: "120"
    volumes:
      - "${MONGO_RS_SCRIPT_DIR}/init-replica-set.sh:/init-replica-set.sh:ro"
    depends_on:
      applicant-db-1:
        condition: service_healthy
      applicant-db-2:
        condition: service_healthy
      applicant-db-3:
        condition: service_healthy

volumes:
  mongo1_data:
  mongo2_data:
  mongo3_data:
COMPOSE

chmod 600 "$TMP_DIR/compose.yml"

MONGO_DIRECT_URI="mongodb://127.0.0.1:27017/admin?directConnection=true&serverSelectionTimeoutMS=5000"
MONGO_DIRECT_READ_URI="${MONGO_DIRECT_URI}&readPreference=secondaryPreferred"

MONGO_CLUSTER_URI="mongodb://${MONGO_ROOT_USERNAME}:${MONGO_ROOT_PASSWORD}@applicant-db-1:27017,applicant-db-2:27017,applicant-db-3:27017/admin?replicaSet=rs-applicant&authSource=admin&retryWrites=true&w=majority&serverSelectionTimeoutMS=20000&connectTimeoutMS=5000"

mongo_direct_eval() {
  local container="$1"
  local javascript="$2"

  docker exec "$container" mongosh "$MONGO_DIRECT_URI" \
    --quiet \
    --username "$MONGO_ROOT_USERNAME" \
    --password "$MONGO_ROOT_PASSWORD" \
    --authenticationDatabase admin \
    --eval "$javascript"
}

mongo_direct_read_eval() {
  local container="$1"
  local javascript="$2"

  docker exec "$container" mongosh "$MONGO_DIRECT_READ_URI" \
    --quiet \
    --username "$MONGO_ROOT_USERNAME" \
    --password "$MONGO_ROOT_PASSWORD" \
    --authenticationDatabase admin \
    --eval "$javascript"
}

mongo_cluster_eval() {
  local container="$1"
  local javascript="$2"

  docker exec "$container" mongosh "$MONGO_CLUSTER_URI" \
    --quiet \
    --eval "$javascript"
}

echo "========== ISOLATED MONGODB REPLICA-SET FAILOVER TEST =========="
echo "Compose project: $PROJECT_NAME"
echo "Replica set:     rs-applicant"
echo "Database:        $DB_NAME"
echo "Members:         3"
echo
echo "The existing Compose projects will not be modified."

echo
echo "========== START THREE ISOLATED MONGODB MEMBERS =========="

STACK_CREATED=1
compose up -d

INIT_CONTAINER="$(container_id_for applicant-db-rs-init)"
[[ -n "$INIT_CONTAINER" ]] ||
  die "Could not find the replica-set initialization container."

echo
echo "========== WAIT FOR REPLICA-SET INITIALIZATION =========="

INIT_COMPLETED=0

for ((second = 0; second <= INIT_TIMEOUT_SECONDS; second++)); do
  INIT_STATE="$(
    docker inspect --format '{{.State.Status}}' \
      "$INIT_CONTAINER" 2>/dev/null || true
  )"

  if [[ "$INIT_STATE" == "exited" ]]; then
    INIT_EXIT_CODE="$(
      docker inspect --format '{{.State.ExitCode}}' "$INIT_CONTAINER"
    )"

    if [[ "$INIT_EXIT_CODE" == "0" ]]; then
      INIT_COMPLETED=1
      break
    fi

    compose logs applicant-db-rs-init
    die "Replica-set initialization exited with code $INIT_EXIT_CODE."
  fi

  [[ "$INIT_STATE" != "dead" ]] ||
    die "Replica-set initialization container entered the dead state."

  if (( second % 10 == 0 )); then
    echo "  Initialization state: ${INIT_STATE:-unknown} (${second}s)"
  fi

  sleep 1
done

(( INIT_COMPLETED == 1 )) ||
  die "Replica-set initialization did not finish within ${INIT_TIMEOUT_SECONDS}s."

NODE1_CONTAINER="$(container_id_for applicant-db-1)"
NODE2_CONTAINER="$(container_id_for applicant-db-2)"
NODE3_CONTAINER="$(container_id_for applicant-db-3)"

[[ -n "$NODE1_CONTAINER" && -n "$NODE2_CONTAINER" && -n "$NODE3_CONTAINER" ]] ||
  die "Could not find all three MongoDB containers."

echo "PASS: Initialization completed successfully."

echo
echo "========== VERIFY INITIAL REPLICA-SET MEMBERS =========="

MEMBER_COUNT="$(
  mongo_direct_eval "$NODE1_CONTAINER" \
    'print(rs.status().members.length)'
)" || die "Could not read the initial replica-set status."

HEALTHY_COUNT="$(
  mongo_direct_eval "$NODE1_CONTAINER" \
    'print(rs.status().members.filter(m => m.health === 1 && ["PRIMARY", "SECONDARY"].includes(m.stateStr)).length)'
)" || die "Could not count healthy replica-set members."

[[ "$MEMBER_COUNT" == "3" ]] ||
  die "Expected exactly three replica-set members; found $MEMBER_COUNT."

[[ "$HEALTHY_COUNT" == "3" ]] ||
  die "Expected three healthy PRIMARY/SECONDARY members; found $HEALTHY_COUNT."

PRIMARY_ADDRESS="$(
  mongo_direct_eval "$NODE1_CONTAINER" \
    'const p = rs.status().members.find(m => m.stateStr === "PRIMARY"); print(p ? p.name : "")'
)" || die "Could not identify the initial primary."

[[ -n "$PRIMARY_ADDRESS" ]] ||
  die "No initial primary was elected."

PRIMARY_HOST="${PRIMARY_ADDRESS%%:*}"

case "$PRIMARY_HOST" in
  applicant-db-1)
    PRIMARY_SERVICE="applicant-db-1"
    PRIMARY_CONTAINER="$NODE1_CONTAINER"
    SURVIVOR_SERVICE="applicant-db-2"
    SURVIVOR_CONTAINER="$NODE2_CONTAINER"
    ;;
  applicant-db-2)
    PRIMARY_SERVICE="applicant-db-2"
    PRIMARY_CONTAINER="$NODE2_CONTAINER"
    SURVIVOR_SERVICE="applicant-db-1"
    SURVIVOR_CONTAINER="$NODE1_CONTAINER"
    ;;
  applicant-db-3)
    PRIMARY_SERVICE="applicant-db-3"
    PRIMARY_CONTAINER="$NODE3_CONTAINER"
    SURVIVOR_SERVICE="applicant-db-1"
    SURVIVOR_CONTAINER="$NODE1_CONTAINER"
    ;;
  *)
    die "Unexpected primary hostname: $PRIMARY_HOST"
    ;;
esac

echo "Initial primary: $PRIMARY_HOST"
echo "Surviving probe: $SURVIVOR_SERVICE"
echo "PASS: Three members are healthy and one primary is elected."

echo
echo "========== WRITE BASELINE PROBE DOCUMENT =========="

mongo_cluster_eval "$SURVIVOR_CONTAINER" "
const collection = db.getSiblingDB('$DB_NAME').failover_probes;
const result = collection.insertOne(
  { _id: '$PROBE_ID', phase: 'before-failover' },
  { writeConcern: { w: 'majority', wtimeout: 20000 } }
);
if (!result.acknowledged) {
  throw new Error('Baseline write was not acknowledged');
}
print('Baseline majority write acknowledged');
" || die "Could not write the baseline probe document."

echo
echo "========== PAUSE THE CURRENT PRIMARY =========="

# Set this before pausing so the EXIT trap always attempts to restore it.
PAUSED_CONTAINER="$PRIMARY_CONTAINER"

docker pause "$PRIMARY_CONTAINER" >/dev/null ||
  die "Could not pause the initial primary container."

echo "Paused: $PRIMARY_HOST"

echo
echo "========== WAIT FOR A NEW PRIMARY ELECTION =========="

NEW_PRIMARY_ADDRESS=""

for ((second = 0; second <= ELECTION_TIMEOUT_SECONDS; second++)); do
  NEW_PRIMARY_ADDRESS="$(
    mongo_direct_eval "$SURVIVOR_CONTAINER" \
      'const p = rs.status().members.find(m => m.stateStr === "PRIMARY"); print(p ? p.name : "")' \
      2>/dev/null || true
  )"

  if [[ -n "$NEW_PRIMARY_ADDRESS" &&
        "$NEW_PRIMARY_ADDRESS" != "$PRIMARY_ADDRESS" ]]; then
    break
  fi

  if (( second % 5 == 0 )); then
    echo "  Waiting for election (${second}s) ..."
  fi

  sleep 1
done

[[ -n "$NEW_PRIMARY_ADDRESS" ]] ||
  die "No new primary was elected within ${ELECTION_TIMEOUT_SECONDS}s."

[[ "$NEW_PRIMARY_ADDRESS" != "$PRIMARY_ADDRESS" ]] ||
  die "The paused member is still reported as primary."

NEW_PRIMARY_HOST="${NEW_PRIMARY_ADDRESS%%:*}"

case "$NEW_PRIMARY_HOST" in
  applicant-db-1) NEW_PRIMARY_CONTAINER="$NODE1_CONTAINER" ;;
  applicant-db-2) NEW_PRIMARY_CONTAINER="$NODE2_CONTAINER" ;;
  applicant-db-3) NEW_PRIMARY_CONTAINER="$NODE3_CONTAINER" ;;
  *) die "Unexpected elected primary: $NEW_PRIMARY_HOST" ;;
esac

echo "New primary: $NEW_PRIMARY_HOST"
echo "PASS: A different replica was elected."

echo
echo "========== VERIFY MAJORITY WRITE DURING FAILOVER =========="

mongo_cluster_eval "$SURVIVOR_CONTAINER" "
const collection = db.getSiblingDB('$DB_NAME').failover_probes;
const result = collection.updateOne(
  { _id: '$PROBE_ID' },
  { \$set: { phase: 'during-failover' } },
  { writeConcern: { w: 'majority', wtimeout: 20000 } }
);
if (!result.acknowledged || result.matchedCount !== 1) {
  throw new Error('Failover majority write was not acknowledged');
}
print('Failover majority write acknowledged');
" || die "A majority-acknowledged write failed while the original primary was paused."

FAILOVER_VALUE="$(
  mongo_direct_read_eval "$NEW_PRIMARY_CONTAINER" \
    "const p = db.getSiblingDB('$DB_NAME').failover_probes.findOne({ _id: '$PROBE_ID' }); print(p ? p.phase : '')"
)" || die "Could not verify the probe on the newly elected primary."

[[ "$FAILOVER_VALUE" == "during-failover" ]] ||
  die "The new primary did not return the expected failover write."

echo "PASS: The newly elected primary contains the failover write."

echo
echo "========== RESTORE THE ORIGINAL PRIMARY =========="

docker unpause "$PRIMARY_CONTAINER" >/dev/null ||
  die "Could not unpause the original primary."

PAUSED_CONTAINER=""

echo "Unpaused: $PRIMARY_HOST"

echo
echo "========== WAIT FOR THE ORIGINAL MEMBER TO REJOIN =========="

ORIGINAL_MEMBER_STATE=""

for ((second = 0; second <= RESTORE_TIMEOUT_SECONDS; second++)); do
  ORIGINAL_MEMBER_STATE="$(
    mongo_direct_eval "$SURVIVOR_CONTAINER" "
      const m = rs.status().members.find(m => m.name === '$PRIMARY_ADDRESS');
      print(m ? m.stateStr + ':' + m.health : 'missing');
    " 2>/dev/null || true
  )"

  HEALTHY_COUNT="$(
    mongo_direct_eval "$SURVIVOR_CONTAINER" \
      'print(rs.status().members.filter(m => m.health === 1 && ["PRIMARY", "SECONDARY"].includes(m.stateStr)).length)' \
      2>/dev/null || true
  )"

  if [[ "$ORIGINAL_MEMBER_STATE" =~ ^(PRIMARY|SECONDARY):1$ &&
        "$HEALTHY_COUNT" == "3" ]]; then
    break
  fi

  if (( second % 10 == 0 )); then
    echo "  Original member: ${ORIGINAL_MEMBER_STATE:-unknown}; healthy members: ${HEALTHY_COUNT:-unknown} (${second}s)"
  fi

  sleep 1
done

[[ "$ORIGINAL_MEMBER_STATE" =~ ^(PRIMARY|SECONDARY):1$ ]] ||
  die "Original member did not return to PRIMARY/SECONDARY with health 1."

[[ "$HEALTHY_COUNT" == "3" ]] ||
  die "Expected all three members to be healthy after recovery; found $HEALTHY_COUNT."

echo "Original member state: $ORIGINAL_MEMBER_STATE"
echo "PASS: All three members are healthy again."

echo
echo "========== VERIFY REPLICATION ON THE RESTORED MEMBER =========="

REPLICATED_VALUE=""

for ((second = 0; second <= RESTORE_TIMEOUT_SECONDS; second++)); do
  REPLICATED_VALUE="$(
    mongo_direct_read_eval "$PRIMARY_CONTAINER" \
      "const p = db.getSiblingDB('$DB_NAME').failover_probes.findOne({ _id: '$PROBE_ID' }); print(p ? p.phase : '')" \
      2>/dev/null || true
  )"

  [[ "$REPLICATED_VALUE" == "during-failover" ]] && break

  if (( second % 10 == 0 )); then
    echo "  Waiting for replicated document (${second}s) ..."
  fi

  sleep 1
done

[[ "$REPLICATED_VALUE" == "during-failover" ]] ||
  die "The original member did not replicate the majority-acknowledged failover write."

echo "PASS: Restored member contains the failover write."

echo
echo "========== REMOVE TEST PROBE =========="

mongo_cluster_eval "$SURVIVOR_CONTAINER" "
const result = db.getSiblingDB('$DB_NAME').failover_probes.deleteOne(
  { _id: '$PROBE_ID' },
  { writeConcern: { w: 'majority', wtimeout: 20000 } }
);
if (!result.acknowledged || result.deletedCount !== 1) {
  throw new Error('Probe cleanup was not acknowledged');
}
print('Probe removed');
" || die "Could not remove the test probe."

echo
echo "========== RESULT =========="
echo "PASS: Initial three-member replica set."
echo "PASS: Primary failure and election of a replacement."
echo "PASS: Majority-acknowledged write during failover."
echo "PASS: Original member recovery."
echo "PASS: Replication of the failover write to the restored member."
echo "PASS: Test probe removed."
echo
echo "The EXIT handler will now remove only the isolated test project."
