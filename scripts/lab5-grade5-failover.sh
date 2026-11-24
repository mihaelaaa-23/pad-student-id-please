#!/usr/bin/env bash
# Lab 5, grade 5: replication with failover.
#   PostgreSQL (player-db): Patroni elects a new leader through etcd, pg-router follows it,
#   and Player Service keeps answering with no code change.
#   MongoDB (rs-applicant): the replica set elects a new primary and the driver follows it.
# Each stopped node is started again and rejoins as a replica (a secondary).
#
#   bash scripts/lab5-grade5-failover.sh       (NONINTERACTIVE=1 to skip the pauses)
source "$(dirname "$0")/lab5-lib.sh"

PG_NODES="player-db-1 player-db-2 player-db-3"
RS_NODES="applicant-db-1 applicant-db-2 applicant-db-3"
APPLICANT_DB_USER="$(env_value APPLICANT_DB_USER)"
APPLICANT_DB_PASSWORD="$(env_value APPLICANT_DB_PASSWORD)"
[[ -n "$APPLICANT_DB_USER" && -n "$APPLICANT_DB_PASSWORD" ]] || die "APPLICANT_DB_USER and APPLICANT_DB_PASSWORD must be set in .env"

# A node of the list that is running (to ask it about the cluster), other than $2.
running_node() {
  local node
  for node in $1; do
    [[ "$node" == "${2:-}" ]] && continue
    [[ -n "$(compose ps -q --status running "$node")" ]] && { echo "$node"; return 0; }
  done
  return 1
}

show_patroni() {
  local node
  node="$(running_node "$PG_NODES")" || die "no player-db node is running"
  run docker compose exec -T "$node" patronictl list
}

# "member state" lines of rs-applicant, asked on a running member (the root user is in admin).
rs_members() {
  local node
  node="$(running_node "$RS_NODES" "${1:-}")" || return 1
  compose exec -T -e MONGO_USER="$APPLICANT_DB_USER" -e MONGO_PASS="$APPLICANT_DB_PASSWORD" "$node" \
    sh -c 'mongosh --quiet -u "$MONGO_USER" -p "$MONGO_PASS" --authenticationDatabase admin --eval "rs.status().members.forEach(function (m) { print(m.name.split(\":\")[0] + \" \" + m.stateStr) })"' 2>/dev/null
}

show_rs() {
  local node
  node="$(running_node "$RS_NODES")" || die "no applicant-db node is running"
  show "docker compose exec -T $node mongosh -u \"\$APPLICANT_DB_USER\" -p \"\$APPLICANT_DB_PASSWORD\" --authenticationDatabase admin --quiet --eval 'rs.status().members.forEach(m => print(m.name, m.stateStr))'"
  rs_members
}

rs_primary() { rs_members "${1:-}" | awk '$2 == "PRIMARY" { print $1 }'; }

# ---------------------------------------------------------------- PostgreSQL: player-db

step "player-db: one leader and two streaming replicas (Patroni + etcd)"
show_patroni
PG_LEADER="$(patroni_leader "$(running_node "$PG_NODES")")"
[[ -n "$PG_LEADER" ]] || die "player-db has no leader"
ok "leader: $PG_LEADER"

step "Write a row through pg-router (a new player) and read it back"
new_player
api GET "/player/players/$PLAYER_ID" "$PLAYER_TOKEN" "" "Cache-Control: no-cache"
expect_code 200
pretty

step "Stop the leader ($PG_LEADER)"
run docker compose stop "$PG_LEADER"
on_exit "docker compose start $PG_LEADER"
OTHER_PG="$(running_node "$PG_NODES" "$PG_LEADER")"

new_pg_leader() {
  local leader
  leader="$(patroni_leader "$OTHER_PG")"
  [[ -n "$leader" && "$leader" != "$PG_LEADER" ]]
}
started=$SECONDS
wait_until 90 "Patroni promoted a replica" new_pg_leader
NEW_PG_LEADER="$(patroni_leader "$OTHER_PG")"
show_patroni
ok "new leader: $NEW_PG_LEADER"

step "Player Service still answers (it connects to pg-router:5401, which follows the leader)"
player_answers() {
  api_quiet GET "/player/players/$PLAYER_ID" "$PLAYER_TOKEN" "" "Cache-Control: no-cache"
  [[ "$HTTP_CODE" == "200" ]]
}
wait_until 60 "GET /player/players/$PLAYER_ID answers 200 from the new leader" player_answers
api GET "/player/players/$PLAYER_ID" "$PLAYER_TOKEN" "" "Cache-Control: no-cache"
expect_code 200
ok "the row written before the failover is there; writes and reads work $((SECONDS - started))s after the stop"

step "Start the old leader again: it rejoins as a replica"
run docker compose start "$PG_LEADER"
old_leader_streams() {
  patroni_members "$OTHER_PG" | awk -F'\t' -v n="$PG_LEADER" '$1 == n && $2 != "Leader" && $3 == "streaming" { found = 1 } END { exit !found }'
}
wait_until 120 "$PG_LEADER is a streaming replica" old_leader_streams
show_patroni

# ---------------------------------------------------------------- MongoDB: rs-applicant

step "rs-applicant: one PRIMARY and two SECONDARY members"
show_rs
RS_PRIMARY="$(rs_primary)"
[[ -n "$RS_PRIMARY" ]] || die "rs-applicant has no primary"
ok "primary: $RS_PRIMARY"

step "Write an applicant (to the primary) and read it back"
suffix="$(unique)"
api POST /applicant/applicants "$SERVICE_TOKEN" "{\"name\":\"Failover Demo $suffix\",\"studentId\":\"FCIM-$((RANDOM % 900000 + 100000))\",\"major\":\"Software Engineering\",\"year\":3,\"role\":\"student_faf\",\"status\":\"active\"}"
expect_code 201
APPLICANT_ID="$(jget applicantId)"
on_exit "curl -s -o /dev/null -X DELETE -H 'Authorization: Bearer $SERVICE_TOKEN' '$BASE_URL/applicant/applicants/$APPLICANT_ID'"
api GET "/applicant/applicants/$APPLICANT_ID" "$SERVICE_TOKEN" "" "Cache-Control: no-cache"
expect_code 200
ok "applicant $APPLICANT_ID"

step "Stop the primary ($RS_PRIMARY)"
run docker compose stop "$RS_PRIMARY"
on_exit "docker compose start $RS_PRIMARY"

new_rs_primary() {
  local primary
  primary="$(rs_primary "$RS_PRIMARY")"
  [[ -n "$primary" && "$primary" != "$RS_PRIMARY" ]]
}
started=$SECONDS
wait_until 60 "the set elected a new primary" new_rs_primary
show_rs

step "Applicant Service still answers (the driver follows the new primary)"
applicant_answers() {
  api_quiet GET "/applicant/applicants/$APPLICANT_ID" "$SERVICE_TOKEN" "" "Cache-Control: no-cache"
  [[ "$HTTP_CODE" == "200" ]]
}
wait_until 60 "GET /applicant/applicants/$APPLICANT_ID answers 200" applicant_answers
api PATCH "/applicant/applicants/$APPLICANT_ID" "$SERVICE_TOKEN" '{"major":"Written after the failover"}'
expect_code 200
ok "reads and writes work $((SECONDS - started))s after the stop"

step "Start the old primary again: it rejoins (priority 2, so it then takes the primary back)"
run docker compose start "$RS_PRIMARY"
old_primary_back() {
  rs_members | awk -v n="$RS_PRIMARY" '$1 == n && ($2 == "SECONDARY" || $2 == "PRIMARY") { found = 1 } END { exit !found }'
}
wait_until 90 "$RS_PRIMARY is a member again" old_primary_back
show_rs

echo
ok "grade 5 demo done"
