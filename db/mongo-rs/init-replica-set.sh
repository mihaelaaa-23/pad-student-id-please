#!/bin/sh
# One-shot initiation of a MongoDB replica set, run by <db>-rs-init in compose.
#
# mongod started with --replSet does not form a set on its own: exactly one
# rs.initiate() has to name the members. This job waits for every member to
# answer, initiates the set if it is not formed yet, and waits for a PRIMARY to
# be elected before it exits, so that the service depending on it
# (service_completed_successfully) only starts against a writable set.
#
# Idempotent: on a stack that is already initiated it finds rs.status().ok = 1
# and exits 0 without touching anything, so it runs safely on every
# `docker compose up`.
#
# Member -1 is given priority 2 and the others 1, so elections prefer the member
# that holds the init script and the root user. It is a preference, not a
# requirement: any member can be primary, which is the point of the set.
#
# Env: RS_NAME (e.g. rs-discord-dms), RS_MEMBERS (comma-separated host:port, the
# first one is member 0), MONGO_ROOT_USERNAME, MONGO_ROOT_PASSWORD (the root user
# created on member -1), SERVICE_NAME (for the log lines), WAIT_TIMEOUT_S
# (default 120).
set -eu

SERVICE="${SERVICE_NAME:-mongo-rs-init}"
INSTANCE="$(hostname)"
WAIT_TIMEOUT_S="${WAIT_TIMEOUT_S:-120}"

log() {
  printf '{"timestamp":"%s","level":"%s","service":"%s","instanceId":"%s","message":"%s","requestId":null,"replicaSet":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$SERVICE" "$INSTANCE" "$2" "$RS_NAME"
}

: "${RS_NAME:?RS_NAME is required}"
: "${RS_MEMBERS:?RS_MEMBERS is required, comma-separated host:port}"
: "${MONGO_ROOT_USERNAME:?MONGO_ROOT_USERNAME is required}"
: "${MONGO_ROOT_PASSWORD:?MONGO_ROOT_PASSWORD is required}"

MEMBER_LIST="$(echo "$RS_MEMBERS" | tr ',' ' ')"
FIRST="$(echo "$MEMBER_LIST" | awk '{print $1}')"

# Authenticated against the admin database of member -1, which is where the root
# user exists before the set replicates it to the others.
mongo_eval() {
  mongosh "mongodb://$1/admin" \
    --quiet \
    --username "$MONGO_ROOT_USERNAME" \
    --password "$MONGO_ROOT_PASSWORD" \
    --authenticationDatabase admin \
    --eval "$2"
}

# ping needs no authentication, so this works before the set exists and before
# the root user has replicated anywhere.
wait_for_member() {
  waited=0
  until mongosh "mongodb://$1/admin" --quiet --eval "db.adminCommand('ping').ok" >/dev/null 2>&1; do
    if [ "$waited" -ge "$WAIT_TIMEOUT_S" ]; then
      log ERROR "member $1 did not answer after ${WAIT_TIMEOUT_S}s"
      exit 1
    fi
    sleep 2
    waited=$((waited + 2))
  done
}

for member in $MEMBER_LIST; do
  log INFO "waiting for member $member"
  wait_for_member "$member"
done
log INFO "every member answers"

# An initiated set answers ok = 1. A set that has never been initiated fails with
# NotYetInitialized, which the catch turns into 0 rather than a non-zero exit.
already="$(mongo_eval "$FIRST" "try { rs.status().ok } catch (e) { 0 }" 2>/dev/null || echo 0)"
if [ "$already" = "1" ]; then
  log INFO "replica set already initiated, nothing to do"
  exit 0
fi

index=0
members=""
for member in $MEMBER_LIST; do
  priority=1
  [ "$index" -eq 0 ] && priority=2
  members="${members}{_id:${index},host:\"${member}\",priority:${priority}},"
  index=$((index + 1))
done
members="[${members%,}]"

log INFO "initiating the set with ${index} members"
mongo_eval "$FIRST" "rs.initiate({_id:\"$RS_NAME\",members:$members})" >/dev/null

log INFO "waiting for a primary to be elected"
waited=0
until [ "$(mongo_eval "$FIRST" "try { rs.status().members.filter(m => m.stateStr === 'PRIMARY').length } catch (e) { 0 }" 2>/dev/null || echo 0)" = "1" ]; do
  if [ "$waited" -ge "$WAIT_TIMEOUT_S" ]; then
    log ERROR "no primary after ${WAIT_TIMEOUT_S}s"
    exit 1
  fi
  sleep 2
  waited=$((waited + 2))
done

log INFO "replica set ready with a primary"
