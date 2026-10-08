CREATE TABLE IF NOT EXISTS university_records (
    id SERIAL PRIMARY KEY,
    applicant_id VARCHAR(100) NOT NULL UNIQUE,
    name VARCHAR(255) NOT NULL,
    student_id VARCHAR(100) NOT NULL,
    university VARCHAR(255) NOT NULL,
    faculty VARCHAR(255),
    program VARCHAR(255),
    study_year INTEGER,
    role VARCHAR(50) NOT NULL,
    enrollment_status VARCHAR(50) NOT NULL DEFAULT 'active',
    previously_banned BOOLEAN NOT NULL DEFAULT FALSE,
    is_enrolled BOOLEAN NOT NULL DEFAULT FALSE,
    average_grade NUMERIC(5,2),
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

ALTER TABLE university_records
    ADD COLUMN IF NOT EXISTS previously_banned BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS is_enrolled BOOLEAN NOT NULL DEFAULT FALSE;

CREATE INDEX IF NOT EXISTS idx_university_records_applicant_id
    ON university_records(applicant_id);

INSERT INTO university_records (
    applicant_id,
    name,
    student_id,
    university,
    faculty,
    program,
    study_year,
    role,
    enrollment_status,
    previously_banned,
    is_enrolled,
    average_grade
)
VALUES
(
    'applicant-001',
    'Ion Popescu',
    'FCIM-261847',
    'Technical University of Moldova',
    'FAF',
    'Software Engineering',
    4,
    'student_faf',
    'active',
    FALSE,
    TRUE,
    9.25
),
(
    'applicant-002',
    'Maria Rusu',
    'FCIM-251234',
    'Technical University of Moldova',
    'FCIM',
    'Telecommunications',
    3,
    'student_other',
    'active',
    FALSE,
    TRUE,
    8.70
)
ON CONFLICT (applicant_id) DO NOTHING;