#!/usr/bin/env bash
# Lab 5, grade 9: applicant intake runs as a long-running saga coordinated by the Message
# Broker: applicant.create (Applicant's database), then credential.issue (Credential's).
#   1. completed: both steps done.
#   2. compensated: Credential refuses (test hook), so the applicant from step 1 is deleted.
#   3. long-running: Credential is stopped; the saga waits in `running` with attempts
#      growing, survives a Broker restart, and completes once Credential is back.
#
#   bash scripts/lab5-grade9-saga.sh           (NONINTERACTIVE=1 to skip the pauses)
#
# Part 2 recreates credential-service with ENABLE_TEST_HOOKS=true and puts it back without
# the hooks at the end (also on failure or Ctrl-C).
source "$(dirname "$0")/lab5-lib.sh"

# The value .env gives the hooks, restored after part 2.
HOOKS_DEFAULT="$(env_value ENABLE_TEST_HOOKS false)"

start_intake() {
  api POST /applicant/applicants/intake "$SERVICE_TOKEN" "$1"
  expect_code 200 202
  SAGA_ID="$(jget sagaId)"
  [[ -n "$SAGA_ID" ]] || die "the intake answer has no sagaId"
  ok "saga $SAGA_ID started, state $(jget state)"
}

saga_state() {
  api_quiet GET "/applicant/applicants/intake/$SAGA_ID" "$SERVICE_TOKEN" "" "Cache-Control: no-cache"
  [[ "$HTTP_CODE" == "200" ]] || return 1
  jget state
}

show_saga() {
  api GET "/applicant/applicants/intake/$SAGA_ID" "$SERVICE_TOKEN" "" "Cache-Control: no-cache"
  expect_code 200
  python3 - "$BODY_FILE" <<'PY'
import json, sys
saga = json.load(open(sys.argv[1]))
print("saga %s: %s" % (saga.get("sagaId"), saga.get("state")))
for i, s in enumerate(saga.get("steps", []), 1):
    print("  step %d %-20s %-18s %-12s attempts=%s %s" % (i, s.get("service", ""), s.get("action", ""), s.get("state", ""),
          s.get("attempts", "-"), ("last error: " + (s.get("lastError") or s.get("last_error"))) if (s.get("lastError") or s.get("last_error")) else ""))
PY
}

saga_ended() { local s; s="$(saga_state)" && [[ "$s" == "completed" || "$s" == "compensated" || "$s" == "failed" ]]; }

saga_applicant() {
  api_quiet GET "/applicant/applicants/intake/$SAGA_ID" "$SERVICE_TOKEN" "" "Cache-Control: no-cache"
  local id
  id="$(jget applicantId)"
  [[ -n "$id" ]] || id="$(jget context.applicantId)"
  echo "$id"
}

credential_up() {
  api_quiet GET /credential/status "$SERVICE_TOKEN"
  [[ "$HTTP_CODE" == "200" ]]
}

# ---------------------------------------------------------------- 1. completed

step "Completed: start an intake"
start_intake "{\"seed\":$RANDOM}"
wait_until 30 "the saga ended" saga_ended
show_saga
[[ "$(saga_state)" == "completed" ]] || die "the saga should be completed"
APPLICANT_ID="$(saga_applicant)"

step "Both databases hold the result: the applicant and its credential"
api GET "/applicant/applicants/$APPLICANT_ID" "$SERVICE_TOKEN" "" "Cache-Control: no-cache"
expect_code 200
api GET "/credential/credentials/$APPLICANT_ID" "$SERVICE_TOKEN" "" "Cache-Control: no-cache"
expect_code 200
ok "applicant $APPLICANT_ID and its credential exist"

# ---------------------------------------------------------------- 2. compensated

step "Compensated: run Credential with the test hook on (ENABLE_TEST_HOOKS=true)"
show "ENABLE_TEST_HOOKS=true docker compose up -d --no-deps credential-service"
HOOKS_ON=1
on_exit "[[ \$HOOKS_ON == 1 ]] && ENABLE_TEST_HOOKS=$HOOKS_DEFAULT docker compose up -d --no-deps credential-service"
ENABLE_TEST_HOOKS=true compose up -d --no-deps credential-service
wait_until 60 "credential-service answers" credential_up

step "Start an intake that fails at Credential (simulateFailAt)"
start_intake "{\"seed\":$RANDOM,\"simulateFailAt\":\"credential-service\"}"
wait_until 60 "the saga ended" saga_ended
show_saga
[[ "$(saga_state)" == "compensated" ]] || die "the saga should be compensated"
APPLICANT_ID="$(saga_applicant)"

step "Compensation deleted the applicant that step 1 created"
api GET "/applicant/applicants/$APPLICANT_ID" "$SERVICE_TOKEN" "" "Cache-Control: no-cache"
expect_code 404
ok "applicant $APPLICANT_ID is gone"

step "Credential back with the hook as .env sets it (ENABLE_TEST_HOOKS=$HOOKS_DEFAULT)"
show "docker compose up -d --no-deps credential-service"
ENABLE_TEST_HOOKS="$HOOKS_DEFAULT" compose up -d --no-deps credential-service
HOOKS_ON=0
wait_until 60 "credential-service answers" credential_up

# ---------------------------------------------------------------- 3. long-running

step "Long-running: stop Credential (every instance)"
run docker compose stop credential-service
on_exit "docker compose start credential-service"

step "Start an intake: step 1 is done, step 2 can't reach Credential, so the saga waits"
start_intake "{\"seed\":$RANDOM}"
sleep 6
show_saga
[[ "$(saga_state)" == "running" ]] || die "the saga should still be running"
attempts_before="$(jget steps.1.attempts)"
sleep 10
show_saga
[[ "$(saga_state)" == "running" ]] || die "the saga should still be running"
attempts_after="$(jget steps.1.attempts)"
(( attempts_after > attempts_before )) || die "step 2's attempts should grow while Credential is down ($attempts_before -> $attempts_after)"
ok "still running, step 2 attempts $attempts_before -> $attempts_after, none counted toward the limit"

step "Restart the Broker: the saga is in its SQLite log and resumes"
run docker compose restart message-broker
broker_answers() { saga_state >/dev/null; }
wait_until 60 "the Broker answers again" broker_answers
show_saga
[[ "$(saga_state)" == "running" ]] || die "the saga should still be running after the restart"
show "docker compose logs --since 2m message-broker | grep '$SAGA_ID' | grep 'saga resumed'"
compose logs --no-color --since 2m message-broker 2>/dev/null | grep -F "$SAGA_ID" | grep -F "saga resumed" | tail -n 1 ||
  info "(no 'saga resumed' line found for this saga)"

step "Start Credential again: the next retry reaches it and the saga completes"
run docker compose start credential-service
# The retry backoff is capped at 30 s, so the next attempt can be up to 30 s away.
wait_until 120 "the saga ended" saga_ended
show_saga
[[ "$(saga_state)" == "completed" ]] || die "the saga should be completed"
APPLICANT_ID="$(saga_applicant)"
api GET "/credential/credentials/$APPLICANT_ID" "$SERVICE_TOKEN" "" "Cache-Control: no-cache"
expect_code 200
ok "the credential was issued once Credential came back"

echo
ok "grade 9 demo done"
