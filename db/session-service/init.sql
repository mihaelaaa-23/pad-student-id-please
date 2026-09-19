CREATE TABLE IF NOT EXISTS sessions (
  session_id TEXT PRIMARY KEY,
  moderator_id TEXT NOT NULL,
  current_applicant_id TEXT,
  processed_count INT NOT NULL DEFAULT 0,
  score INT NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'active',
  result TEXT
);

CREATE TABLE IF NOT EXISTS session_participants (
  session_id TEXT NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,
  player_id TEXT NOT NULL,
  role TEXT NOT NULL,
  PRIMARY KEY (session_id, player_id)
);