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
    average_grade NUMERIC(5,2),
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

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
    8.70
)
ON CONFLICT (applicant_id) DO NOTHING;