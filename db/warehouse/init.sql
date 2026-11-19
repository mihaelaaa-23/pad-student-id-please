-- Data Warehouse (Lab 5, grade 4): a star schema loaded by the ETL job (etl/etl.py).
-- Facts are what happened in the game (sessions, decisions, chat); dimensions describe
-- who and what they are about (players, applicants, credentials, records, rules, dates).
-- Every table is filled by upsert on its natural key, so the ETL can run again at any time.

CREATE TABLE IF NOT EXISTS dim_date (
  date_key    integer PRIMARY KEY,           -- yyyymmdd
  full_date   date    NOT NULL UNIQUE,
  year        integer NOT NULL,
  month       integer NOT NULL,
  day         integer NOT NULL,
  iso_weekday integer NOT NULL               -- 1 = Monday
);

INSERT INTO dim_date (date_key, full_date, year, month, day, iso_weekday)
SELECT to_char(d, 'YYYYMMDD')::integer, d::date,
       extract(year FROM d)::integer, extract(month FROM d)::integer,
       extract(day FROM d)::integer, extract(isodow FROM d)::integer
FROM generate_series('2026-01-01'::date, '2027-12-31'::date, interval '1 day') AS d
ON CONFLICT (date_key) DO NOTHING;

-- Player Service (player-db.players)
CREATE TABLE IF NOT EXISTS dim_player (
  player_id     text PRIMARY KEY,
  username      text NOT NULL,
  level         integer NOT NULL,
  xp            integer NOT NULL,
  friends_count integer NOT NULL,
  loaded_at     timestamptz NOT NULL DEFAULT now()
);

-- Applicant Service (applicant_service_db.applicants)
CREATE TABLE IF NOT EXISTS dim_applicant (
  applicant_id text PRIMARY KEY,
  student_id   text,
  major        text,
  year         integer,
  role         text,
  status       text,
  scenario     text,                         -- ground truth: stays inside the warehouse
  origin       text,
  created_at   timestamptz,
  loaded_at    timestamptz NOT NULL DEFAULT now()
);

-- Credential Service (credential_service_db.credentials)
CREATE TABLE IF NOT EXISTS dim_credential (
  applicant_id   text PRIMARY KEY,
  student_id     text,
  issued_at      timestamptz,
  expires_at     timestamptz,
  document_count integer NOT NULL DEFAULT 0,
  scenario       text,
  created_at     timestamptz,
  loaded_at      timestamptz NOT NULL DEFAULT now()
);

-- University Record Service (university_records)
CREATE TABLE IF NOT EXISTS dim_university_record (
  applicant_id      text PRIMARY KEY,
  student_id        text,
  faculty           text,
  program           text,
  study_year        integer,
  role              text,
  enrollment_status text,
  previously_banned boolean,
  is_enrolled       boolean,
  average_grade     numeric(4, 2),
  created_at        timestamptz,
  updated_at        timestamptz,
  loaded_at         timestamptz NOT NULL DEFAULT now()
);

-- Server Rules Service (server_rules_service_db.rules)
CREATE TABLE IF NOT EXISTS dim_rule (
  rule_id     text PRIMARY KEY,
  description text,
  enabled     boolean,
  loaded_at   timestamptz NOT NULL DEFAULT now()
);

-- Server Moderation Session Service (sessions, session_participants)
CREATE TABLE IF NOT EXISTS fact_session (
  session_id      text PRIMARY KEY,
  moderator_id    text,
  status          text,
  result          text,
  processed_count integer NOT NULL DEFAULT 0,
  score           integer NOT NULL DEFAULT 0,
  participants    integer NOT NULL DEFAULT 0,
  loaded_at       timestamptz NOT NULL DEFAULT now()
);

-- Moderation Service (decisions, violated_rules)
CREATE TABLE IF NOT EXISTS fact_decision (
  decision_id       uuid PRIMARY KEY,
  session_id        text NOT NULL,
  applicant_id      text NOT NULL,
  decided_by        text,
  decision          text NOT NULL,
  expected_decision text,
  correct           boolean,
  penalty           integer NOT NULL DEFAULT 0,
  violated_rules    text[] NOT NULL DEFAULT '{}',
  decided_at        timestamptz NOT NULL,
  date_key          integer REFERENCES dim_date (date_key),
  loaded_at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS fact_decision_session_idx ON fact_decision (session_id);

-- Discord DMs Service (channels, messages): activity per session and channel
CREATE TABLE IF NOT EXISTS fact_chat_activity (
  session_id       text NOT NULL,
  channel          text NOT NULL,
  messages         integer NOT NULL,
  senders          integer NOT NULL,
  first_message_at timestamptz,
  last_message_at  timestamptz,
  loaded_at        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (session_id, channel)
);

-- One row per ETL run, with the per-source counts and errors.
CREATE TABLE IF NOT EXISTS etl_run (
  run_id      bigserial PRIMARY KEY,
  started_at  timestamptz NOT NULL,
  finished_at timestamptz,
  status      text NOT NULL,                 -- ok, partial, failed
  sources     jsonb NOT NULL DEFAULT '{}'
);

CREATE OR REPLACE VIEW v_accuracy_by_role AS
SELECT a.role,
       count(*)                                      AS decisions,
       count(*) FILTER (WHERE d.correct)             AS correct,
       round(avg(d.correct::int)::numeric, 3)        AS accuracy
FROM fact_decision d
JOIN dim_applicant a USING (applicant_id)
GROUP BY a.role;

CREATE OR REPLACE VIEW v_accuracy_by_scenario AS
SELECT a.scenario,
       count(*)                                      AS decisions,
       count(*) FILTER (WHERE d.correct)             AS correct,
       round(avg(d.correct::int)::numeric, 3)        AS accuracy
FROM fact_decision d
JOIN dim_applicant a USING (applicant_id)
GROUP BY a.scenario;

CREATE OR REPLACE VIEW v_moderator_leaderboard AS
SELECT d.decided_by                                  AS player_id,
       p.username,
       count(*)                                      AS decisions,
       round(avg(d.correct::int)::numeric, 3)        AS accuracy,
       sum(d.penalty)                                AS total_penalty
FROM fact_decision d
LEFT JOIN dim_player p ON p.player_id = d.decided_by
WHERE d.decided_by IS NOT NULL
GROUP BY d.decided_by, p.username;
