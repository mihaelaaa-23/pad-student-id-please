-- Moderation Service - database bootstrap.
--
-- PostgreSQL runs this once, when the data volume is created. The service
-- applies the very same schema itself on every boot, so this file is not what
-- makes the service work: it is here so that a freshly started stack already has
-- something to look at, and so the shared stack in the umbrella repository can
-- mount one script per service.
--
-- Everything below is written to be safe to run against an existing database:
-- the tables are created only if missing and the sample shift is inserted only
-- when the audit trail is still empty.

CREATE TABLE IF NOT EXISTS decisions (
    id                uuid        PRIMARY KEY,
    session_id        text        NOT NULL,
    applicant_id      text        NOT NULL,
    decision          text        NOT NULL CHECK (decision IN ('accept', 'reject', 'flag', 'ban')),
    expected_decision text        NOT NULL CHECK (expected_decision IN ('accept', 'reject', 'flag', 'ban')),
    correct           boolean     NOT NULL,
    penalty           integer     NOT NULL CHECK (penalty >= 0),
    decided_by        text,
    sources           jsonb       NOT NULL DEFAULT '{}'::jsonb,
    created_at        timestamptz NOT NULL,
    updated_at        timestamptz
);

CREATE UNIQUE INDEX IF NOT EXISTS decisions_session_applicant_unique
    ON decisions (session_id, applicant_id);

CREATE INDEX IF NOT EXISTS decisions_session_created_at
    ON decisions (session_id, created_at DESC);

CREATE TABLE IF NOT EXISTS violated_rules (
    id          bigserial PRIMARY KEY,
    decision_id uuid      NOT NULL REFERENCES decisions (id) ON DELETE CASCADE,
    position    integer   NOT NULL,
    rule        text      NOT NULL
);

CREATE INDEX IF NOT EXISTS violated_rules_decision
    ON violated_rules (decision_id, position);

-- ---------------------------------------------------------------------------
-- A sample shift, inserted only into an empty audit trail.
--
-- It is one shift of three applicants: a call that was right, a call that was
-- too lenient, and a call that was too harsh - enough to make
-- GET /sessions/shift-demo/summary show something the first time it is opened.
-- ---------------------------------------------------------------------------
INSERT INTO decisions
    (id, session_id, applicant_id, decision, expected_decision, correct, penalty, decided_by, sources, created_at)
SELECT *
  FROM (VALUES
        ('a1000000-0000-4000-8000-000000000001'::uuid, 'shift-demo', 'applicant-1006',
         'accept', 'accept', true,   0, 'player-moderator-1',
         '{"applicant-service": "simulated", "credential-service": "simulated", "server-rules-service": "simulated", "university-record-service": "simulated"}'::jsonb,
         now() - interval '20 minutes'),

        ('a1000000-0000-4000-8000-000000000002'::uuid, 'shift-demo', 'applicant-1000',
         'accept', 'reject', false, 40, 'player-moderator-1',
         '{"applicant-service": "simulated", "credential-service": "simulated", "server-rules-service": "simulated", "university-record-service": "simulated"}'::jsonb,
         now() - interval '12 minutes'),

        ('a1000000-0000-4000-8000-000000000003'::uuid, 'shift-demo', 'applicant-1003',
         'ban', 'flag', false, 20, 'player-moderator-1',
         '{"applicant-service": "simulated", "credential-service": "simulated", "server-rules-service": "simulated", "university-record-service": "simulated"}'::jsonb,
         now() - interval '4 minutes')
       ) AS sample
 WHERE NOT EXISTS (SELECT 1 FROM decisions);

INSERT INTO violated_rules (decision_id, position, rule)
SELECT *
  FROM (VALUES
        ('a1000000-0000-4000-8000-000000000002'::uuid, 0,
         'credential: the student ID number does not match any issued card'),
        ('a1000000-0000-4000-8000-000000000002'::uuid, 1,
         'record: the applicant is not on the enrollment list'),
        ('a1000000-0000-4000-8000-000000000003'::uuid, 0,
         'credential: the student ID card expired at the end of the previous semester')
       ) AS sample
 WHERE NOT EXISTS (SELECT 1 FROM violated_rules);
