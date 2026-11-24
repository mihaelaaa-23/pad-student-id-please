#!/bin/sh
# One-shot initialisation of a Spilo (Patroni) cluster, run by <db>-init in compose.
#
# Spilo bootstraps PostgreSQL itself, so /docker-entrypoint-initdb.d never runs and
# its post_init hook is Spilo's own /scripts/post_init.sh. This script does the same
# job from outside, through pg-router's read-write port (always the current leader):
#   1. creates the application role and database, if missing;
#   2. runs the service's init SQL, only when it has just created the database;
#   3. creates the read-only etl_reader and grants it SELECT, now and on future tables.
# Every step is idempotent, so it runs safely on every `docker compose up`.
#
# Env: PGHOST, PGPORT (the leader port on pg-router), PGUSER and PGPASSWORD (the
# superuser), APP_DB_USER, APP_DB_PASSWORD, APP_DB_NAME, ETL_READER_PASSWORD,
# INIT_SQL_DIR (default /init-sql), WAIT_TIMEOUT_S (default 180).
set -eu

SERVICE="${SERVICE_NAME:-postgres-ha-init}"
INSTANCE="$(hostname)"
INIT_SQL_DIR="${INIT_SQL_DIR:-/init-sql}"
WAIT_TIMEOUT_S="${WAIT_TIMEOUT_S:-180}"

log() {
  printf '{"timestamp":"%s","level":"%s","service":"%s","instanceId":"%s","message":"%s","requestId":null,"cluster":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$SERVICE" "$INSTANCE" "$2" "$APP_DB_NAME"
}

: "${APP_DB_USER:?APP_DB_USER is required}"
: "${APP_DB_PASSWORD:?APP_DB_PASSWORD is required}"
: "${APP_DB_NAME:?APP_DB_NAME is required}"
: "${ETL_READER_PASSWORD:?ETL_READER_PASSWORD is required}"

psql_admin() {
  psql -X -q -v ON_ERROR_STOP=1 -d postgres "$@"
}

log INFO "waiting for the leader on ${PGHOST}:${PGPORT}"
waited=0
until [ "$(psql -X -At -d postgres -c 'SELECT pg_is_in_recovery()' 2>/dev/null)" = "f" ]; do
  if [ "$waited" -ge "$WAIT_TIMEOUT_S" ]; then
    log ERROR "no writable leader after ${WAIT_TIMEOUT_S}s"
    exit 1
  fi
  sleep 2
  waited=$((waited + 2))
done
log INFO "leader reachable"

psql_admin -v app_user="$APP_DB_USER" -v app_password="$APP_DB_PASSWORD" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'app_user', :'app_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'app_user') \gexec
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', :'app_user', :'app_password') \gexec
SQL
log INFO "application role ready"

db_exists="$(psql -X -At -d postgres -v ON_ERROR_STOP=1 -v app_db="$APP_DB_NAME" <<'SQL'
SELECT count(*) FROM pg_database WHERE datname = :'app_db';
SQL
)"

if [ "$db_exists" = "0" ]; then
  psql_admin -v app_db="$APP_DB_NAME" -v app_user="$APP_DB_USER" <<'SQL'
SELECT format('CREATE DATABASE %I OWNER %I', :'app_db', :'app_user') \gexec
SQL
  log INFO "database created"
  for f in "$INIT_SQL_DIR"/*.sql; do
    [ -e "$f" ] || continue
    PGPASSWORD="$APP_DB_PASSWORD" psql -X -q -v ON_ERROR_STOP=1 -U "$APP_DB_USER" -d "$APP_DB_NAME" -f "$f"
    log INFO "ran $(basename "$f")"
  done
else
  log INFO "database exists, init SQL skipped"
fi

psql_admin -v reader_password="$ETL_READER_PASSWORD" <<'SQL'
SELECT format('CREATE ROLE etl_reader LOGIN PASSWORD %L', :'reader_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'etl_reader') \gexec
SELECT format('ALTER ROLE etl_reader LOGIN PASSWORD %L', :'reader_password') \gexec
SQL

psql -X -q -v ON_ERROR_STOP=1 -d "$APP_DB_NAME" -v app_db="$APP_DB_NAME" -v app_user="$APP_DB_USER" <<'SQL'
SELECT format('GRANT CONNECT ON DATABASE %I TO etl_reader', :'app_db') \gexec
GRANT USAGE ON SCHEMA public TO etl_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO etl_reader;
SELECT format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA public GRANT SELECT ON TABLES TO etl_reader', :'app_user') \gexec
SQL
log INFO "etl_reader ready"
log INFO "init complete"
