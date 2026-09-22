CREATE TABLE IF NOT EXISTS university_records (
    id SERIAL PRIMARY KEY,
    applicant_id VARCHAR(100) NOT NULL UNIQUE,
    student_id VARCHAR(100),
    university VARCHAR(255) NOT NULL,
    faculty VARCHAR(255),
    program VARCHAR(255),
    study_year INTEGER,
    enrollment_status VARCHAR(50) NOT NULL DEFAULT 'active',
    average_grade NUMERIC(5,2),
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_university_records_applicant_id
    ON university_records(applicant_id);

INSERT INTO university_records (
    applicant_id,
    student_id,
    university,
    faculty,
    program,
    study_year,
    enrollment_status,
    average_grade
)
VALUES
(
    'applicant-001',
    'UTM-2026-001',
    'Technical University of Moldova',
    'Faculty of Computers, Informatics and Microelectronics',
    'Software Engineering',
    4,
    'active',
    9.25
),
(
    'applicant-002',
    'UTM-2026-002',
    'Technical University of Moldova',
    'Faculty of Electronics and Telecommunications',
    'Telecommunications',
    3,
    'active',
    8.70
)
ON CONFLICT (applicant_id) DO NOTHING;
