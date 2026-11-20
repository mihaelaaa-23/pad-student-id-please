"""ETL job (Lab 5, grade 4): copies every service database into the Data Warehouse.

Runs every ETL_INTERVAL_S seconds (or once with --once). For each source it extracts
the full current state, transforms it into the warehouse's star schema
(db/warehouse/init.sql) and upserts it on the natural key, in one transaction per
source, so a run can be repeated at any time without duplicates. Sources are read
read-only: PostgreSQL sessions are opened with default_transaction_read_only, and
MongoDB is read with readPreference=secondaryPreferred (a replica when there is one).
Because every pass is a full snapshot, rows that a source no longer has are deleted
from the warehouse in the same transaction (a compensated saga, a deleted decision).
A source that is not configured is skipped; a source that fails does not stop the
others (and deletes nothing), and the run is recorded as "partial".
A source that answers but is empty (for example a Mongo replica still in its initial
sync) empties its warehouse tables for that pass; the next pass refills them.
"""

import argparse
import json
import logging
import os
import signal
import socket
import sys
import threading
import time
import uuid
from datetime import UTC, date, datetime

import psycopg
from psycopg.rows import dict_row
from pymongo import MongoClient

SERVICE = "etl"
INSTANCE_ID = socket.gethostname()
DATE_KEY_MIN, DATE_KEY_MAX = 20260101, 20271231  # the range prefilled in dim_date


# ---------- logging (team Logging Convention: JSON lines on stdout) ----------

class JsonFormatter(logging.Formatter):
    def format(self, record):
        line = {
            "timestamp": datetime.now(UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z"),
            "level": {"WARNING": "WARN", "CRITICAL": "ERROR"}.get(record.levelname, record.levelname),
            "service": SERVICE,
            "instanceId": INSTANCE_ID,
            "message": record.getMessage(),
            "requestId": getattr(record, "requestId", None),
        }
        line.update(getattr(record, "fields", {}))
        return json.dumps(line, default=str)


def make_logger():
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())
    logger = logging.getLogger(SERVICE)
    logger.handlers = [handler]
    level = os.environ.get("LOG_LEVEL", "INFO").upper()
    logger.setLevel({"WARN": "WARNING"}.get(level, level))
    logger.propagate = False
    return logger


log = make_logger()


def emit(level, message, request_id, **fields):
    log.log(level, message, extra={"requestId": request_id, "fields": fields})


# ---------- helpers ----------

def to_ts(value):
    """A timestamp from Mongo (datetime or ISO string) or PostgreSQL, as an aware UTC datetime."""
    if value is None or value == "":
        return None
    if isinstance(value, datetime):
        return value if value.tzinfo else value.replace(tzinfo=UTC)
    if isinstance(value, date):
        return datetime(value.year, value.month, value.day, tzinfo=UTC)
    if isinstance(value, str):
        try:
            parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            return None
        return parsed if parsed.tzinfo else parsed.replace(tzinfo=UTC)
    return None


def to_text(value):
    if value is None or isinstance(value, str):
        return value
    return json.dumps(value, default=str, sort_keys=True)


def to_int(value):
    try:
        return int(value) if value is not None else None
    except (TypeError, ValueError):
        return None


def date_key(ts):
    if ts is None:
        return None
    key = int(ts.astimezone(UTC).strftime("%Y%m%d"))
    return key if DATE_KEY_MIN <= key <= DATE_KEY_MAX else None


def dedupe(rows, key):
    """Last row wins per key, so one upsert batch never touches the same row twice."""
    return list({tuple(row[k] for k in key): row for row in rows}.values())


# ---------- connections ----------

def env(prefix, name, default=None):
    return os.environ.get(f"{prefix}_{name}", default)


def pg_source(prefix):
    if not env(prefix, "DB_HOST"):
        return None
    return psycopg.connect(
        host=env(prefix, "DB_HOST"),
        port=int(env(prefix, "DB_PORT", "5432")),
        user=env(prefix, "DB_USER"),
        password=env(prefix, "DB_PASSWORD"),
        dbname=env(prefix, "DB_NAME"),
        connect_timeout=5,
        options="-c default_transaction_read_only=on",
        application_name="etl",
    )


def mongo_source(prefix):
    hosts = env(prefix, "DB_HOSTS")
    if not hosts:
        return None
    kwargs = {
        "username": env(prefix, "DB_USER"),
        "password": env(prefix, "DB_PASSWORD"),
        "authSource": env(prefix, "DB_AUTH_SOURCE", "admin"),
        "readPreference": "secondaryPreferred",
        "serverSelectionTimeoutMS": 5000,
        "appname": "etl",
    }
    if env(prefix, "DB_REPLICA_SET"):
        kwargs["replicaSet"] = env(prefix, "DB_REPLICA_SET")
    client = MongoClient([h.strip() for h in hosts.split(",") if h.strip()], **kwargs)
    return client, client[env(prefix, "DB_NAME")]


def warehouse():
    return psycopg.connect(
        host=os.environ["WAREHOUSE_DB_HOST"],
        port=int(os.environ.get("WAREHOUSE_DB_PORT", "5432")),
        user=os.environ["WAREHOUSE_DB_USER"],
        password=os.environ["WAREHOUSE_DB_PASSWORD"],
        dbname=os.environ["WAREHOUSE_DB_NAME"],
        connect_timeout=5,
        application_name="etl",
    )


# ---------- extract + transform, one function per source database ----------
# Each returns (warehouse table, natural key, rows as dicts).

PLAYER_SQL = """
SELECT player_id, username, level, xp, coalesce(cardinality(friends), 0) AS friends_count
FROM players
"""

SESSION_SQL = """
SELECT s.session_id, s.moderator_id, s.status, s.result,
       coalesce(s.processed_count, 0) AS processed_count, coalesce(s.score, 0) AS score,
       (SELECT count(*) FROM session_participants p WHERE p.session_id = s.session_id)::int AS participants
FROM sessions s
"""

UNIVERSITY_RECORD_SQL = """
SELECT applicant_id, student_id, faculty, program, study_year, role, enrollment_status,
       previously_banned, is_enrolled, average_grade, created_at, updated_at
FROM university_records
WHERE applicant_id IS NOT NULL
ORDER BY coalesce(updated_at, created_at) NULLS FIRST
"""

MODERATION_SQL = """
SELECT d.id AS decision_id, d.session_id, d.applicant_id, d.decided_by, d.decision,
       d.expected_decision, d.correct, coalesce(d.penalty, 0) AS penalty,
       coalesce((SELECT array_agg(v.rule ORDER BY v.position) FROM violated_rules v
                 WHERE v.decision_id = d.id), '{}') AS violated_rules,
       d.created_at AS decided_at
FROM decisions d
"""


def pg_rows(conn, sql):
    with conn.cursor(row_factory=dict_row) as cur:
        cur.execute(sql)
        return cur.fetchall()


def extract_player(conn):
    return "dim_player", ("player_id",), pg_rows(conn, PLAYER_SQL)


def extract_session(conn):
    return "fact_session", ("session_id",), pg_rows(conn, SESSION_SQL)


def extract_university_record(conn):
    rows = []
    for r in pg_rows(conn, UNIVERSITY_RECORD_SQL):
        r["created_at"], r["updated_at"] = to_ts(r["created_at"]), to_ts(r["updated_at"])
        rows.append(r)
    return "dim_university_record", ("applicant_id",), rows


def decision_row(r):
    decided_at = to_ts(r["decided_at"])
    return {**r, "decision_id": str(r["decision_id"]), "decided_at": decided_at, "date_key": date_key(decided_at)}


def extract_moderation(conn):
    return "fact_decision", ("decision_id",), [decision_row(r) for r in pg_rows(conn, MODERATION_SQL)]


def applicant_row(doc):
    return {
        "applicant_id": doc.get("applicantId"),
        "student_id": doc.get("studentId"),
        "major": doc.get("major"),
        "year": to_int(doc.get("year")),
        "role": doc.get("role"),
        "status": doc.get("status"),
        "scenario": to_text(doc.get("scenario")),
        "origin": to_text(doc.get("origin")),
        "created_at": to_ts(doc.get("createdAt")),
    }


def extract_applicant(db):
    rows = [applicant_row(d) for d in db["applicants"].find({"applicantId": {"$exists": True}})]
    return "dim_applicant", ("applicant_id",), rows


def credential_row(doc):
    documents = doc.get("documents")
    return {
        "applicant_id": doc.get("applicantId"),
        "student_id": doc.get("studentId"),
        "issued_at": to_ts(doc.get("issuedAt")),
        "expires_at": to_ts(doc.get("expiresAt")),
        "document_count": len(documents) if isinstance(documents, list | dict) else 0,
        "scenario": to_text(doc.get("scenario")),
        "created_at": to_ts(doc.get("createdAt")),
    }


def extract_credential(db):
    rows = [credential_row(d) for d in db["credentials"].find({"applicantId": {"$exists": True}})]
    return "dim_credential", ("applicant_id",), rows


def extract_rules(db):
    rows = [
        {"rule_id": str(d.get("id")), "description": d.get("description"), "enabled": bool(d.get("enabled"))}
        for d in db["rules"].find({"id": {"$exists": True}})
    ]
    return "dim_rule", ("rule_id",), rows


def chat_activity_rows(channels, messages):
    """Messages per (session, channel): count, distinct senders, first and last time."""
    by_channel = {str(c["_id"]): (c.get("sessionId"), c.get("name")) for c in channels}
    stats = {}
    for m in messages:
        target = by_channel.get(str(m.get("channelId")))
        if target is None or target[0] is None or target[1] is None:
            continue
        s = stats.setdefault(target, {"messages": 0, "senders": set(), "first": None, "last": None})
        s["messages"] += 1
        s["senders"].add(m.get("senderId"))
        ts = to_ts(m.get("createdAt"))
        if ts is not None:
            s["first"] = ts if s["first"] is None else min(s["first"], ts)
            s["last"] = ts if s["last"] is None else max(s["last"], ts)
    return [
        {"session_id": sid, "channel": name, "messages": s["messages"], "senders": len(s["senders"]),
         "first_message_at": s["first"], "last_message_at": s["last"]}
        for (sid, name), s in stats.items()
    ]


def extract_discord_dms(db):
    channels = list(db["channels"].find({}, {"_id": 1, "sessionId": 1, "name": 1}))
    messages = db["messages"].find({}, {"channelId": 1, "senderId": 1, "createdAt": 1})
    return "fact_chat_activity", ("session_id", "channel"), chat_activity_rows(channels, messages)


# name, kind, env prefix, extract function
SOURCES = [
    ("player", "postgres", "PLAYER", extract_player),
    ("session", "postgres", "SESSION", extract_session),
    ("university-record", "postgres", "UNIVERSITY_RECORD", extract_university_record),
    ("moderation", "postgres", "MODERATION", extract_moderation),
    ("applicant", "mongo", "APPLICANT", extract_applicant),
    ("credential", "mongo", "CREDENTIAL", extract_credential),
    ("server-rules", "mongo", "RULES", extract_rules),
    ("discord-dms", "mongo", "DISCORD_DMS", extract_discord_dms),
]


# ---------- load ----------

def upsert_sql(table, key, columns):
    cols = ", ".join(columns)
    params = ", ".join(f"%({c})s" for c in columns)
    updates = ", ".join(f"{c} = EXCLUDED.{c}" for c in columns if c not in key)
    return (f"INSERT INTO {table} ({cols}, loaded_at) VALUES ({params}, now()) "
            f"ON CONFLICT ({', '.join(key)}) DO UPDATE SET {updates}, loaded_at = now()")


def prune_sql(table, key):
    """Deletes the rows whose key this pass did not see: the source no longer has them."""
    if len(key) == 1:
        return f"DELETE FROM {table} WHERE NOT ({key[0]}::text = ANY(%s::text[]))"
    cols = ", ".join(f"{k}::text" for k in key)
    arrays = ", ".join("%s::text[]" for _ in key)
    return f"DELETE FROM {table} WHERE ({cols}) NOT IN (SELECT * FROM unnest({arrays}))"


def load(wh, table, key, rows):
    """Upserts the snapshot and removes what the source no longer has, in one transaction."""
    rows = dedupe([r for r in rows if all(r.get(k) is not None for k in key)], key)
    with wh.transaction(), wh.cursor() as cur:
        if rows:
            cur.executemany(upsert_sql(table, key, list(rows[0].keys())), rows)
        cur.execute(prune_sql(table, key), [[str(r[k]) for r in rows] for k in key])
        deleted = cur.rowcount
    return len(rows), deleted


# ---------- one run ----------

def run_source(wh, name, kind, prefix, extract, request_id):
    started = time.monotonic()
    if kind == "postgres":
        conn = pg_source(prefix)
        if conn is None:
            emit(logging.WARNING, "etl source skipped", request_id, source=name, reason=f"{prefix}_DB_HOST not set")
            return {"status": "skipped"}
        with conn:
            table, key, rows = extract(conn)
    else:
        source = mongo_source(prefix)
        if source is None:
            emit(logging.WARNING, "etl source skipped", request_id, source=name, reason=f"{prefix}_DB_HOSTS not set")
            return {"status": "skipped"}
        client, db = source
        try:
            table, key, rows = extract(db)
        finally:
            client.close()
    loaded, deleted = load(wh, table, key, rows)
    result = {"status": "ok", "table": table, "extracted": len(rows), "loaded": loaded, "deleted": deleted,
              "durationMs": round((time.monotonic() - started) * 1000)}
    emit(logging.INFO, "etl source loaded", request_id, source=name, **result)
    return result


def run_once():
    request_id = f"etl-{uuid.uuid4()}"
    started_at = datetime.now(UTC)
    emit(logging.INFO, "etl run started", request_id)
    try:
        wh = warehouse()
    except psycopg.Error as exc:
        emit(logging.ERROR, "etl run failed: warehouse unreachable", request_id, error=str(exc))
        return False
    results = {}
    with wh:
        wh.autocommit = True
        for name, kind, prefix, extract in SOURCES:
            try:
                results[name] = run_source(wh, name, kind, prefix, extract, request_id)
            except Exception as exc:  # one source failing must not stop the others
                results[name] = {"status": "failed", "error": str(exc)}
                emit(logging.ERROR, "etl source failed", request_id, source=name, error=str(exc))
        statuses = {r["status"] for r in results.values()}
        if statuses == {"skipped"}:
            status = "skipped"
            emit(logging.WARNING, "etl run loaded nothing: no source is configured", request_id)
        elif "failed" in statuses:
            status = "failed" if statuses == {"failed"} else "partial"
        else:
            status = "ok"
        with wh.cursor() as cur:
            cur.execute(
                "INSERT INTO etl_run (started_at, finished_at, status, sources) VALUES (%s, now(), %s, %s)",
                (started_at, status, json.dumps(results)),
            )
    emit(logging.INFO, "etl run finished", request_id, status=status,
         loaded=sum(r.get("loaded", 0) for r in results.values()),
         deleted=sum(r.get("deleted", 0) for r in results.values()))
    return status != "failed"


def main():
    parser = argparse.ArgumentParser(description="Load every service database into the Data Warehouse.")
    parser.add_argument("--once", action="store_true", help="run one pass and exit")
    args = parser.parse_args()
    if args.once:
        sys.exit(0 if run_once() else 1)
    interval = int(os.environ.get("ETL_INTERVAL_S", "60"))
    stop = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    signal.signal(signal.SIGINT, lambda *_: stop.set())
    emit(logging.INFO, "etl scheduler started", None, intervalS=interval)
    while not stop.is_set():
        run_once()
        stop.wait(interval)
    emit(logging.INFO, "etl scheduler stopped", None)


if __name__ == "__main__":
    main()
