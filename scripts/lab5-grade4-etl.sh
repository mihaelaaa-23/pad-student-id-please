#!/usr/bin/env bash
# Lab 5, grade 4: one ETL pass over every service database into the Data Warehouse, then the
# row counts per table and the three analytics views.
#
#   bash scripts/lab5-grade4-etl.sh            (NONINTERACTIVE=1 to skip the pauses)
source "$(dirname "$0")/lab5-lib.sh"

# psql in the warehouse container, as the warehouse's own user (its POSTGRES_* variables).
wh_sql() {
  show "docker compose exec -T warehouse-db sh -c 'psql -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\"' <<< \"$1\""
  compose exec -T warehouse-db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -P pager=off' <<<"$1"
}

step "The warehouse and the ETL job are running"
run docker compose ps warehouse-db etl
[[ -n "$(compose ps -q --status running etl)" ]] || die "the etl service is not running"

step "One ETL pass: extract from every database (replicas, read-only etl_reader), transform, upsert"
show "docker compose exec -T etl python etl.py --once"
set +e
cat >"$TMP_DIR/summarize.py" <<'PY'
import json, sys
FIELDS = ("source", "status", "table", "extracted", "loaded", "deleted", "durationMs", "error", "reason")
for line in sys.stdin:
    try:
        event = json.loads(line)
    except ValueError:
        print(line, end="")
        continue
    keep = {k: event[k] for k in FIELDS if k in event}
    print("%-5s %-26s %s" % (event.get("level", ""), event.get("message", ""), json.dumps(keep) if keep else ""))
PY
compose exec -T etl python etl.py --once | tee "$TMP_DIR/etl.log" | python3 "$TMP_DIR/summarize.py"
etl_exit=${PIPESTATUS[0]}
set -e
[[ "$etl_exit" == "0" ]] || die "the ETL pass failed (exit $etl_exit)"
grep -q '"etl source failed"' "$TMP_DIR/etl.log" && die "a source failed in this pass (see above)"
ok "every source extracted and loaded"

step "The run as the warehouse recorded it (etl_run)"
wh_sql "SELECT run_id, started_at, finished_at - started_at AS took, status, (SELECT string_agg(k || '=' || (v->>'status') || '/' || coalesce(v->>'loaded', '-'), ', ' ORDER BY k) FROM jsonb_each(sources) AS s(k, v)) AS sources FROM etl_run ORDER BY run_id DESC LIMIT 1;"
last_status="$(compose exec -T warehouse-db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At' <<<"SELECT status FROM etl_run ORDER BY run_id DESC LIMIT 1;")"
[[ "$last_status" == "ok" ]] || die "the last etl_run has status '$last_status', expected ok"
ok "last run: $last_status"

step "Rows in the star schema"
wh_sql "SELECT 'dim_player' AS \"table\", count(*) FROM dim_player UNION ALL SELECT 'dim_applicant', count(*) FROM dim_applicant UNION ALL SELECT 'dim_credential', count(*) FROM dim_credential UNION ALL SELECT 'dim_university_record', count(*) FROM dim_university_record UNION ALL SELECT 'dim_rule', count(*) FROM dim_rule UNION ALL SELECT 'dim_date', count(*) FROM dim_date UNION ALL SELECT 'fact_session', count(*) FROM fact_session UNION ALL SELECT 'fact_decision', count(*) FROM fact_decision UNION ALL SELECT 'fact_chat_activity', count(*) FROM fact_chat_activity;"

step "Analytics views: accuracy by applicant role"
wh_sql "SELECT * FROM v_accuracy_by_role ORDER BY decisions DESC;"

step "Analytics views: accuracy by scenario"
wh_sql "SELECT * FROM v_accuracy_by_scenario ORDER BY decisions DESC;"

step "Analytics views: moderator leaderboard"
wh_sql "SELECT * FROM v_moderator_leaderboard ORDER BY decisions DESC, accuracy DESC LIMIT 10;"

echo
ok "grade 4 demo done"
