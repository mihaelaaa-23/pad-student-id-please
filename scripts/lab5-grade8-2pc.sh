#!/usr/bin/env bash
# Lab 5, grade 8: a moderation decision changes two databases, Moderation's (the decision)
# and Session's (the shift's score), in one two-phase commit coordinated by the Message
# Broker. First a commit, then an abort (Session votes NO on an ended shift), then no
# prepared transaction is left on either database.
#
#   bash scripts/lab5-grade8-2pc.sh            (NONINTERACTIVE=1 to skip the pauses)
#
# Needs the Broker (5.0.0-rc.1+), Session (5.0.0-rc.1+) and Moderation images with the
# tx.v1 coordinator and participants.
source "$(dirname "$0")/lab5-lib.sh"

session_field() {
  api_quiet GET "/session/sessions/$SESSION_ID" "$PLAYER_TOKEN" "" "Cache-Control: no-cache"
  [[ "$HTTP_CODE" == "200" ]] || die "GET /session/sessions/$SESSION_ID answered $HTTP_CODE"
  jget "$1"
}

tx_logs() {
  show "docker compose logs --since 10m message-broker moderation-service session-service | grep $1"
  compose logs --no-color --since 10m message-broker moderation-service session-service 2>/dev/null | grep -F "$1" |
    python3 -c '
import json, sys
for line in sys.stdin:
    prefix, _, rest = line.partition("| ")
    try:
        e = json.loads(rest)
    except ValueError:
        continue
    extra = {k: e[k] for k in ("branch", "vote", "yes", "reason", "outcome", "state", "gid") if k in e}
    print("  %-30s %-5s %s %s" % (prefix.strip(), e.get("level", ""), e.get("message", ""), json.dumps(extra) if extra else ""))' | head -n 30
}

prepared_count() {
  # $1 = a node of the cluster, $2 = its pg-router read-write port
  pg_leader_sql "$1" "$2" "SELECT count(*) FROM pg_prepared_xacts"
}

step "A moderator: a new player who opens a shift"
new_player
api POST /session/sessions "$PLAYER_TOKEN" "{\"moderatorId\":\"$PLAYER_ID\"}"
expect_code 201
SESSION_ID="$(jget sessionId)"
ok "shift $SESSION_ID, status $(jget status)"
api GET "/session/sessions/$SESSION_ID" "$PLAYER_TOKEN" "" "Cache-Control: no-cache"
expect_code 200
SCORE_BEFORE="$(jget score)"
echo "score=$SCORE_BEFORE decisionsApplied=$(jget decisionsApplied)"

# ---------------------------------------------------------------- commit

step "Process an applicant and decide: both databases commit"
api POST "/session/sessions/$SESSION_ID/process-applicant" "$PLAYER_TOKEN"
expect_code 200
APPLICANT_A="$(jget currentApplicantId)"
api POST /moderation/moderation/decide "$PLAYER_TOKEN" "{\"sessionId\":\"$SESSION_ID\",\"applicantId\":\"$APPLICANT_A\",\"decision\":\"reject\",\"decidedBy\":\"$PLAYER_ID\"}"
expect_code 201
pretty
TX_ID="$(jget transactionId)"
[[ "$TX_ID" =~ ^[0-9a-f-]{36}$ ]] || die "the decision has no transactionId: is Moderation running the 2PC image?"
if [[ "$(jget correct)" == "true" ]]; then DELTA=10; else DELTA=$((0 - $(jget penalty))); fi
ok "decision $(jget decisionId) recorded in transaction $TX_ID (scoreDelta $DELTA)"

step "Session applied the same transaction: score moved by $DELTA, decisionsApplied = 1"
applied_once() { [[ "$(session_field decisionsApplied)" == "1" ]]; }
wait_until 15 "Session committed its branch" applied_once
api GET "/session/sessions/$SESSION_ID" "$PLAYER_TOKEN" "" "Cache-Control: no-cache"
SCORE_AFTER="$(jget score)"
echo "score: $SCORE_BEFORE -> $SCORE_AFTER, decisionsApplied=$(jget decisionsApplied)"
[[ "$SCORE_AFTER" == "$((SCORE_BEFORE + DELTA))" ]] || die "the score should be $((SCORE_BEFORE + DELTA))"
ok "both databases changed"

step "The same txId in the Broker, Moderation and Session logs"
tx_logs "$TX_ID"

# ---------------------------------------------------------------- abort

step "End the shift, then decide on another applicant: Session votes NO, nothing changes"
api POST "/session/sessions/$SESSION_ID/process-applicant" "$PLAYER_TOKEN"
expect_code 200
APPLICANT_B="$(jget currentApplicantId)"
api POST "/session/sessions/$SESSION_ID/end" "$PLAYER_TOKEN"
expect_code 200
api POST /moderation/moderation/decide "$PLAYER_TOKEN" "{\"sessionId\":\"$SESSION_ID\",\"applicantId\":\"$APPLICANT_B\",\"decision\":\"accept\",\"decidedBy\":\"$PLAYER_ID\"}"
expect_code 409
pretty
[[ "$(jget error.code)" == "TX_ABORTED" ]] || die "expected error code TX_ABORTED"
ok "409 TX_ABORTED, with every vote in details"

step "Neither database changed: still one decision, the same score"
api GET "/moderation/sessions/$SESSION_ID/decisions" "$PLAYER_TOKEN" "" "Cache-Control: no-cache"
expect_code 200
[[ "$(jget count)" == "1" ]] || die "Moderation should still hold one decision for the shift, has $(jget count)"
ok "Moderation: 1 decision ($APPLICANT_A)"
[[ "$(session_field decisionsApplied)" == "1" && "$(session_field score)" == "$SCORE_AFTER" ]] ||
  die "Session's score or decisionsApplied changed"
ok "Session: score $SCORE_AFTER, decisionsApplied 1"

# ---------------------------------------------------------------- no prepared transaction left

step "No prepared transaction is left on either database (pg_prepared_xacts, on each leader)"
empty_after_commit() {
  [[ "$(prepared_count session-db-1 5402 | tail -n 1)" == "0" && "$(prepared_count moderation-db-1 5407 | tail -n 1)" == "0" ]]
}
wait_until 20 "pg_prepared_xacts is empty on session-db and moderation-db" empty_after_commit
echo "session-db:    $(prepared_count session-db-1 5402 | tail -n 1)"
echo "moderation-db: $(prepared_count moderation-db-1 5407 | tail -n 1)"

echo
ok "grade 8 demo done"
