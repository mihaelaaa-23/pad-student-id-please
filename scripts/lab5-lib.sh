#!/usr/bin/env bash
# Shared helpers for the Lab 5 demo scripts (scripts/lab5-*.sh). Sourced, not run.
#
# Every script runs from the CPR root against the running compose stack, prints each command
# before it runs it, and stops before every step until Enter is pressed. NONINTERACTIVE=1
# skips the pauses (lab5-e2e.sh sets it). Works with macOS's bash 3.2: no associative arrays.
#
# Needs: docker (compose v2), curl, python3 (JSON parsing, as in the other scripts).
# Settings: BASE_URL (http://localhost:3000), and .env for SERVICE_TOKEN and the DB users.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

BASE_URL="${BASE_URL:-http://localhost:3000}"
BASE_URL="${BASE_URL%/}"
NONINTERACTIVE="${NONINTERACTIVE:-0}"

TMP_DIR="$(mktemp -d)"
HTTP_CODE=""
BODY_FILE="$TMP_DIR/body"
HEADERS_FILE="$TMP_DIR/headers"
CLEANUP_CMDS=()

if [[ -t 1 ]]; then
  BOLD=$'\033[1m' DIM=$'\033[2m' GREEN=$'\033[32m' RED=$'\033[31m' CYAN=$'\033[36m' RESET=$'\033[0m'
else
  BOLD="" DIM="" GREEN="" RED="" CYAN="" RESET=""
fi

die() {
  echo "${RED}FAIL:${RESET} $*" >&2
  exit 1
}

ok() { echo "${GREEN}OK:${RESET} $*"; }
info() { echo "${DIM}$*${RESET}"; }

# Commands run on exit (also on failure or Ctrl-C), last registered first: they put the
# stack back as it was (start a stopped node, turn the test hooks off again).
on_exit() {
  CLEANUP_CMDS+=("$1")
}

_cleanup() {
  local code=$?
  trap - EXIT
  local i
  for ((i = ${#CLEANUP_CMDS[@]} - 1; i >= 0; i--)); do
    echo "${DIM}cleanup: $(echo "${CLEANUP_CMDS[$i]}" | sed -E "s/Bearer [^' ]+/Bearer ***/g")${RESET}"
    eval "${CLEANUP_CMDS[$i]}" >/dev/null 2>&1 || true
  done
  rm -rf "$TMP_DIR"
  exit "$code"
}
trap _cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for command_name in docker curl python3; do
  command -v "$command_name" >/dev/null 2>&1 || die "$command_name is required."
done
docker compose version >/dev/null 2>&1 || die "docker compose (v2) is required."

# A value from .env (the last assignment wins), or the default. Quotes around it are removed.
env_value() {
  local key="$1" default="${2:-}" value=""
  if [[ -f .env ]]; then
    value="$(sed -n "s/^${key}=//p" .env | tail -n 1)"
    value="${value%\"}"; value="${value#\"}"; value="${value%\'}"; value="${value#\'}"
  fi
  printf '%s' "${value:-$default}"
}

SERVICE_TOKEN="${SERVICE_TOKEN:-$(env_value SERVICE_TOKEN)}"
[[ -n "$SERVICE_TOKEN" ]] || die "SERVICE_TOKEN is empty: set it in .env (see .env.example)."

# A titled step. Waits for Enter unless NONINTERACTIVE=1.
STEP_NO=0
step() {
  STEP_NO=$((STEP_NO + 1))
  echo
  echo "${BOLD}== $STEP_NO. $* ==${RESET}"
  if [[ "$NONINTERACTIVE" != "1" ]]; then
    read -r -p "${DIM}press Enter to run it${RESET} " _ </dev/tty || true
  fi
}

# Prints a command the way it is run.
show() { echo "${CYAN}\$ $*${RESET}"; }

# Prints the command, then runs it.
run() {
  show "$*"
  "$@"
}

compose() { docker compose "$@"; }

# api METHOD PATH TOKEN [JSON_BODY] [EXTRA_HEADER...]
# Calls the Gateway. Sets HTTP_CODE; the body is in $BODY_FILE, the headers in $HEADERS_FILE.
# TOKEN "-" sends no Authorization header. Prints the request (never the token).
api() {
  local method="$1" path="$2" token="$3" body="${4:-}"
  shift 3; [[ $# -gt 0 ]] && shift
  local args=(--silent --show-error --max-time 20 -X "$method" -o "$BODY_FILE" -D "$HEADERS_FILE" -w '%{http_code}')
  local shown="curl -X $method $BASE_URL$path"
  if [[ "$token" != "-" ]]; then
    args+=(-H "Authorization: Bearer $token")
    if [[ "$token" == "$SERVICE_TOKEN" ]]; then shown+=' -H "Authorization: Bearer $SERVICE_TOKEN"'; else shown+=' -H "Authorization: Bearer $TOKEN"'; fi
  fi
  if [[ -n "$body" ]]; then
    args+=(-H 'Content-Type: application/json' --data "$body")
    shown+=" -H 'Content-Type: application/json' -d '$body'"
  fi
  local header
  for header in "$@"; do
    args+=(-H "$header")
    shown+=" -H '$header'"
  done
  [[ "${API_QUIET:-0}" == "1" ]] || show "$shown"
  HTTP_CODE="$(curl "${args[@]}" "$BASE_URL$path" 2>"$TMP_DIR/curl.err")" || HTTP_CODE="000"
}

# The same, without printing the request (loops of many calls).
api_quiet() { API_QUIET=1 api "$@"; }

# Fails unless the last api call answered one of the given codes.
expect_code() {
  local code
  for code in "$@"; do
    [[ "$HTTP_CODE" == "$code" ]] && return 0
  done
  echo "--- response body:" >&2
  head -c 2000 "$BODY_FILE" >&2 2>/dev/null || true
  echo >&2
  die "expected HTTP $* from the last call, got $HTTP_CODE"
}

# A value from the last response header (case-insensitive name), empty when absent.
header() {
  tr -d '\r' <"$HEADERS_FILE" | awk -v name="$(echo "$1" | tr '[:upper:]' '[:lower:]')" -F': ' \
    'tolower($1) == name { value = $2 } END { print value }'
}

# jget PATH [FILE]: a field of a JSON document (default: the last response body).
# PATH is dotted, with numeric list indexes: "steps.1.attempts". Prints "" when missing;
# objects and lists are printed as JSON.
jget() {
  python3 - "$1" "${2:-$BODY_FILE}" <<'PY'
import json, sys
path, file = sys.argv[1], sys.argv[2]
try:
    value = json.load(open(file))
    for part in [p for p in path.split(".") if p]:
        value = value[int(part)] if isinstance(value, list) else value.get(part)
        if value is None:
            break
except Exception:
    value = None
if value is None:
    print("")
elif isinstance(value, (dict, list)):
    print(json.dumps(value))
elif isinstance(value, bool):
    print("true" if value else "false")
else:
    print(value)
PY
}

# Pretty-prints the last response body (or a file), cut to 60 lines.
pretty() {
  python3 -m json.tool "${1:-$BODY_FILE}" 2>/dev/null | head -n 60 || head -c 2000 "${1:-$BODY_FILE}"
}

# wait_until TIMEOUT_S DESCRIPTION COMMAND...: retries the command every 2 s.
wait_until() {
  local timeout="$1" description="$2"
  shift 2
  local started=$SECONDS
  info "waiting up to ${timeout}s: $description"
  until "$@" >/dev/null 2>&1; do
    (( SECONDS - started < timeout )) || die "timed out after ${timeout}s: $description"
    sleep 2
  done
  ok "$description ($((SECONDS - started))s)"
}

# A unique suffix for names created by a demo.
unique() { echo "$(date +%s)$RANDOM"; }

# Registers and logs in a throwaway player. Sets PLAYER_ID, PLAYER_NAME and PLAYER_TOKEN,
# and deletes the player on exit.
new_player() {
  PLAYER_NAME="lab5_$(unique)"
  api POST /player/players/register - "{\"username\":\"$PLAYER_NAME\",\"email\":\"$PLAYER_NAME@test.com\",\"password\":\"pw123\"}"
  expect_code 201
  PLAYER_ID="$(jget playerId)"
  api POST /player/players/login - "{\"username\":\"$PLAYER_NAME\",\"password\":\"pw123\"}"
  expect_code 200
  PLAYER_TOKEN="$(jget token)"
  [[ -n "$PLAYER_ID" && -n "$PLAYER_TOKEN" ]] || die "register/login did not return playerId and token"
  on_exit "curl -s -o /dev/null -X DELETE -H 'Authorization: Bearer $PLAYER_TOKEN' '$BASE_URL/player/players/$PLAYER_ID'"
  ok "player $PLAYER_NAME ($PLAYER_ID)"
}

# psql on a PostgreSQL cluster's current leader, through pg-router's read-write port, as the
# superuser. Runs inside a node of that cluster (Spilo has psql); NODE must be running.
# pg_leader_sql NODE PORT SQL
pg_leader_sql() {
  local node="$1" port="$2" sql="$3"
  show "docker compose exec -T $node sh -c 'PGPASSWORD=\"\$PGPASSWORD_SUPERUSER\" psql -h pg-router -p $port -U postgres -d postgres -Atc \"$sql\"'"
  compose exec -T "$node" sh -c "PGPASSWORD=\"\$PGPASSWORD_SUPERUSER\" psql -h pg-router -p $port -U postgres -d postgres -Atc \"$sql\""
}

# Members of a Patroni cluster as tab-separated "member<TAB>role<TAB>state" lines, asked on a
# running node. Roles: Leader, Replica, Sync Standby; states: running, streaming, ...
patroni_members() {
  compose exec -T "$1" patronictl list -f json 2>/dev/null | python3 -c '
import json, sys
for m in json.load(sys.stdin):
    print("%s\t%s\t%s" % (m.get("Member"), m.get("Role"), m.get("State")))'
}

patroni_leader() {
  patroni_members "$1" | awk -F'\t' '$2 == "Leader" { print $1 }'
}
