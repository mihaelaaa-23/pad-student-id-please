#!/bin/sh
# Entrypoint for a MongoDB replica-set member (Lab 5, grade 5).
#
# A replica set with authentication needs a shared keyfile: the members use it to
# authenticate to each other. The key cannot be a bind mount from the repository,
# because mongod refuses a keyfile that is group- or world-readable and a mounted
# file keeps the permissions it has on the host. So the key arrives as an
# environment variable and this script writes it inside the container, with the
# permissions mongod insists on, before handing over to the image's own entrypoint.
#
# Only member -1 of a cluster is given MONGO_INITDB_ROOT_USERNAME and the init
# script; it is the one the -rs-init job initiates the set on. Members -2 and -3
# start with an empty data directory and receive the users, the databases and the
# indexes through replication.
#
# Env: MONGO_REPLICA_KEY (the shared key, 6-1024 base64 characters), RS_NAME (the
# replica-set name, e.g. rs-discord-dms), SERVICE_NAME (for the log lines).
set -eu

SERVICE="${SERVICE_NAME:-mongo-rs}"
INSTANCE="$(hostname)"
KEYFILE=/tmp/mongo-keyfile

log() {
  printf '{"timestamp":"%s","level":"%s","service":"%s","instanceId":"%s","message":"%s","requestId":null,"replicaSet":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$SERVICE" "$INSTANCE" "$2" "${RS_NAME:-unset}"
}

: "${MONGO_REPLICA_KEY:?MONGO_REPLICA_KEY is required, see .env.example}"
: "${RS_NAME:?RS_NAME is required}"

# printf, not echo: the key must be byte-identical on every member, and mongod
# only ignores surrounding whitespace, so a shell that appends anything else
# would make the members fail to authenticate to each other.
printf '%s' "$MONGO_REPLICA_KEY" > "$KEYFILE"
chmod 400 "$KEYFILE"
# The image starts as root and drops to mongodb (999:999) through gosu, so the
# keyfile has to belong to mongodb to still be readable after the drop. When the
# container is already running as mongodb the chown is refused and not needed.
chown 999:999 "$KEYFILE" 2>/dev/null || true

log INFO "keyfile written, starting mongod as a member of ${RS_NAME}"

# Hand over to the image's entrypoint so that MONGO_INITDB_* and
# /docker-entrypoint-initdb.d keep working exactly as they do without a replica set.
exec docker-entrypoint.sh mongod \
  --replSet "$RS_NAME" \
  --keyFile "$KEYFILE" \
  --bind_ip_all
