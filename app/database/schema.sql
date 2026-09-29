-- PostgreSQL schema for the MVP. Re-running this file is safe: CREATE statements
-- and retrofit blocks are idempotent, so setup can repair an existing database.
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- One row identifies each physical or temporary manual monitor.
CREATE TABLE IF NOT EXISTS monitor_device (
  device_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  device_name TEXT NOT NULL,
  serial_number TEXT NOT NULL UNIQUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT monitor_device_name_length_check
    CHECK (char_length(btrim(device_name)) BETWEEN 1 AND 100),
  CONSTRAINT monitor_device_serial_length_check
    CHECK (char_length(btrim(serial_number)) BETWEEN 1 AND 100)
);

-- A session groups measurements from one device and records the test context.
CREATE TABLE IF NOT EXISTS test_session (
  session_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  device_id UUID NOT NULL REFERENCES monitor_device(device_id),
  session_name TEXT NOT NULL,
  start_time TIMESTAMPTZ NOT NULL,
  end_time TIMESTAMPTZ,
  notes TEXT NOT NULL DEFAULT '',
  CHECK (end_time IS NULL OR end_time >= start_time),
  CONSTRAINT test_session_name_length_check
    CHECK (char_length(btrim(session_name)) BETWEEN 1 AND 120),
  CONSTRAINT test_session_notes_length_check
    CHECK (char_length(notes) <= 2000)
);

-- Storing one channel per row makes channel/time filtering straightforward.
CREATE TABLE IF NOT EXISTS measurement (
  measurement_id BIGSERIAL PRIMARY KEY,
  session_id UUID NOT NULL REFERENCES test_session(session_id) ON DELETE CASCADE,
  recorded_at TIMESTAMPTZ NOT NULL,
  channel SMALLINT NOT NULL CHECK (channel BETWEEN 0 AND 15),
  voltage DOUBLE PRECISION NOT NULL CHECK (voltage BETWEEN -5 AND 5),
  -- Retrying the same frame updates its logical rows instead of duplicating them.
  UNIQUE (session_id, recorded_at, channel)
);

-- This index supports session history reads ordered or filtered by sample time.
CREATE INDEX IF NOT EXISTS measurement_session_time_idx
  ON measurement (session_id, recorded_at);

-- This index supports the newest-first session dropdown.
CREATE INDEX IF NOT EXISTS test_session_start_time_idx
  ON test_session (start_time DESC);

-- CREATE TABLE IF NOT EXISTS does not retrofit checks into an existing local
-- cluster. These idempotent blocks keep an upgraded development database aligned.
DO $$ BEGIN
  ALTER TABLE monitor_device ADD CONSTRAINT monitor_device_name_length_check
    CHECK (char_length(btrim(device_name)) BETWEEN 1 AND 100);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  ALTER TABLE monitor_device ADD CONSTRAINT monitor_device_serial_length_check
    CHECK (char_length(btrim(serial_number)) BETWEEN 1 AND 100);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  ALTER TABLE test_session ADD CONSTRAINT test_session_name_length_check
    CHECK (char_length(btrim(session_name)) BETWEEN 1 AND 120);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  ALTER TABLE test_session ADD CONSTRAINT test_session_notes_length_check
    CHECK (char_length(notes) <= 2000);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
