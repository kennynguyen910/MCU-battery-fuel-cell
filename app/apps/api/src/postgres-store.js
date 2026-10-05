// PostgreSQL persistence adapter. Route code knows only these methods, which
// keeps SQL out of HTTP handlers and makes the architecture easy to test.
import pg from "pg";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { compareTimes } from './sample-time.js';

const { Pool } = pg;

// Configuration files use a project-relative certificate path so the repository
// can be moved to another Windows computer without editing an absolute path.
const projectRoot = fileURLToPath(new URL("../../../", import.meta.url));

// Shared projection keeps list/detail field names consistent for Flutter.
const sessionSelect = `
  SELECT s.session_id AS "sessionId", s.device_id AS "deviceId",
    s.session_name AS "sessionName", s.owner_username AS "ownerUsername",
    to_char(s.start_time AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS "startTime",
    to_char(s.end_time AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS "endTime", s.notes, d.device_name AS "deviceName",
    d.serial_number AS "serialNumber"
  FROM test_session s JOIN monitor_device d USING (device_id)`;

export class PostgresStore {
  constructor(connectionString) {
    // AWS RDS supplies a public certificate bundle. When DATABASE_SSL_CA is set,
    // Node verifies both the certificate authority and the RDS hostname instead
    // of merely encrypting traffic without authenticating the remote server.
    const certificatePath = process.env.DATABASE_SSL_CA;
    const ssl = certificatePath
      ? {
          ca: fs.readFileSync(path.resolve(projectRoot, certificatePath), "utf8"),
          rejectUnauthorized: true,
        }
      : undefined;

    // pg.Pool reuses database connections across one-second UI polling requests.
    // Local development omits ssl; the AWS setup launcher supplies it explicitly.
    this.pool = new Pool({ connectionString, ssl });
  }

  // Stable ordering makes dropdown behavior predictable.
  async listDevices() {
    const { rows } = await this.pool.query(`SELECT device_id AS "deviceId", device_name AS "deviceName", serial_number AS "serialNumber" FROM monitor_device ORDER BY device_name`);
    return rows;
  }

  // Parameters ($1, $2) keep user text separate from SQL instructions.
  async createDevice({ deviceName, serialNumber }) {
    if (!deviceName || !serialNumber) throw new Error("deviceName and serialNumber are required");
    const { rows } = await this.pool.query(`INSERT INTO monitor_device (device_name, serial_number) VALUES ($1, $2) RETURNING device_id AS "deviceId", device_name AS "deviceName", serial_number AS "serialNumber"`, [deviceName, serialNumber]);
    return rows[0];
  }

  // Build optional WHERE clauses while keeping every value parameterized.
  async listSessions({ from, to, ownerUsername } = {}) {
    const values = [];
    const clauses = [];
    if (from) { values.push(from); clauses.push(`s.start_time >= $${values.length}`); }
    if (to) { values.push(to); clauses.push(`s.start_time <= $${values.length}`); }
    if (ownerUsername !== undefined) { values.push(ownerUsername); clauses.push(`s.owner_username = $${values.length}`); }
    const where = clauses.length ? ` WHERE ${clauses.join(" AND ")}` : "";
    const { rows } = await this.pool.query(`${sessionSelect}${where} ORDER BY s.start_time DESC`, values);
    return rows;
  }

  // Return the complete session shape so callers do not need a second contract.
  async createSession({ deviceId, sessionName, startTime, notes = "", ownerUsername = null }) {
    if (!deviceId || !sessionName || Number.isNaN(new Date(startTime).valueOf())) throw new Error("deviceId, sessionName, and a valid startTime are required");
    const { rows } = await this.pool.query(`INSERT INTO test_session (device_id, session_name, start_time, notes, owner_username) VALUES ($1, $2, $3, $4, $5) RETURNING session_id AS "sessionId"`, [deviceId, sessionName, startTime, notes, ownerUsername]);
    return (await this.getSession(rows[0].sessionId));
  }

  // The existing measurement foreign key cascades within this one statement.
  // The device and its other sessions remain intact; late uploads cannot recreate it.
  async deleteSession(sessionId, { ownerUsername } = {}) {
    const result = await this.pool.query(
      `DELETE FROM test_session WHERE session_id = $1
        ${ownerUsername === undefined ? '' : 'AND owner_username = $2'} RETURNING session_id`,
      ownerUsername === undefined ? [sessionId] : [sessionId, ownerUsername]);
    return result.rowCount === 1;
  }

  // A frame is atomic: either all 16 rows commit, or none of them do.
  async addSamples(sessionId, samples, { ownerUsername } = {}) {
    const client = await this.pool.connect();
    try {
      await client.query("BEGIN");
      // Authorize inside the write transaction. The row lock also ensures
      // deletion cannot race this batch. KEY SHARE permits parallel bulk inserts;
      // the scoped metadata update below rechecks ownership before commit.
      const allowed = await client.query(`SELECT session_id FROM test_session WHERE session_id = $1
        ${ownerUsername === undefined ? '' : 'AND owner_username = $2'} FOR KEY SHARE`,
        ownerUsername === undefined ? [sessionId] : [sessionId, ownerUsername]);
      if (!allowed.rowCount) {
        const error = new Error('Session not found');
        error.code = '23503';
        throw error;
      }
      // Collapse repeated timestamps as the old ordered upserts did, then send
      // the whole batch in one parameterized statement (16,000 rows at 1 kHz).
      const unique = new Map(samples.map(sample => [sample.recordedAt, sample]));
      const times = [], channels = [], voltages = [];
      for (const sample of unique.values()) sample.channels.forEach((voltage, channel) => {
        times.push(sample.recordedAt); channels.push(channel); voltages.push(voltage);
      });
      await client.query(`INSERT INTO measurement (session_id, recorded_at, channel, voltage)
        SELECT $1::uuid, x.t, x.c, x.v FROM unnest($2::timestamptz[], $3::int[], $4::double precision[]) AS x(t,c,v)
        ON CONFLICT (session_id, recorded_at, channel) DO UPDATE SET voltage = EXCLUDED.voltage
        WHERE measurement.voltage IS DISTINCT FROM EXCLUDED.voltage`,
        [sessionId, times, channels, voltages]);
      // Reduce across the batch because clients are not required to sort samples.
      const latestRecordedAt = samples.reduce((latest, sample) =>
        compareTimes(sample.recordedAt, latest) > 0 ? sample.recordedAt : latest, samples[0].recordedAt);
      const updated = await client.query(`UPDATE test_session SET end_time = GREATEST(COALESCE(end_time, $2), $2)
        WHERE session_id = $1 ${ownerUsername === undefined ? '' : 'AND owner_username = $3'}`,
        ownerUsername === undefined ? [sessionId, latestRecordedAt] : [sessionId, latestRecordedAt, ownerUsername]);
      if (!updated.rowCount) {
        const error = new Error('Session not found');
        error.code = '23503';
        throw error;
      }
      await client.query("COMMIT");
      return { insertedMeasurements: samples.length * 16 };
    } catch (error) {
      await client.query("ROLLBACK");
      throw error;
    } finally {
      client.release();
    }
  }

  // Session metadata and measurements are returned together for the MVP viewer.
  async getSession(sessionId, { from, to, metadataOnly = false, recent = false, ownerUsername } = {}) {
    const sessionResult = await this.pool.query(`${sessionSelect} WHERE s.session_id = $1
      ${ownerUsername === undefined ? '' : 'AND s.owner_username = $2'}`,
      ownerUsername === undefined ? [sessionId] : [sessionId, ownerUsername]);
    if (!sessionResult.rows[0]) return null;
    if (metadataOnly) return sessionResult.rows[0];
    const values = [sessionId];
    const clauses = ["session_id = $1"];
    if (from) { values.push(from); clauses.push(`recorded_at >= $${values.length}`); }
    if (to) { values.push(to); clauses.push(`recorded_at <= $${values.length}`); }
    // pg's Date decoder truncates microseconds. Project ISO text for measurements
    // so separate >1 kHz frames remain separate when the viewer reads them back.
    const { rows } = await this.pool.query(`SELECT to_char(recorded_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS "recordedAt", channel, voltage FROM measurement WHERE ${clauses.join(" AND ")} ORDER BY recorded_at ${recent ? 'DESC' : 'ASC'}, channel ${recent ? 'LIMIT 16000' : ''}`, values);
    const measurementCount = recent ? Number((await this.pool.query(`SELECT count(*) AS count FROM measurement WHERE ${clauses.join(' AND ')}`, values)).rows[0].count) : rows.length;
    return { ...sessionResult.rows[0], measurements: rows, measurementCount, truncated: measurementCount > rows.length };
  }
}
