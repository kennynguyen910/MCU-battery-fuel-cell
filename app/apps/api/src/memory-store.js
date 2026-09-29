// Small nonpersistent adapter used by fast HTTP tests. It mirrors PostgreSQL's
// public behavior—including idempotent measurement retries—as closely as useful.
import { randomUUID } from "node:crypto";


export class MemoryStore {
  constructor() {
    // Empty by design: only explicit uploads produce values in the MVP.
    const data = { devices: [], sessions: [], measurements: new Map() };
    Object.assign(this, data);
  }

  // Async methods preserve the same calling convention as the PostgreSQL store.
  async listDevices() {
    return this.devices;
  }

  // Error codes imitate PostgreSQL so Express maps them to the same statuses.
  async createDevice({ deviceName, serialNumber }) {
    if (!deviceName || !serialNumber) throw new Error("deviceName and serialNumber are required");
    if (this.devices.some((device) => device.serialNumber === serialNumber)) {
      const error = new Error("serialNumber already exists");
      error.code = '23505';
      throw error;
    }
    const device = { deviceId: randomUUID(), deviceName, serialNumber };
    this.devices.push(device);
    return device;
  }

  // Filtering compares instants, while sorting keeps newest sessions first.
  async listSessions({ from, to } = {}) {
    return this.sessions.filter((session) => {
      const time = new Date(session.startTime).valueOf();
      return (!from || time >= new Date(from).valueOf()) && (!to || time <= new Date(to).valueOf());
    }).sort((a, b) => b.startTime.localeCompare(a.startTime));
  }

  // Copy the device display fields into the response just like the SQL join.
  async createSession({ deviceId, sessionName, startTime, notes = "" }) {
    const device = this.devices.find((item) => item.deviceId === deviceId);
    if (!device) {
      const error = new Error("deviceId was not found");
      error.code = '23503';
      throw error;
    }
    if (!sessionName || Number.isNaN(new Date(startTime).valueOf())) {
      throw new Error("sessionName and a valid startTime are required");
    }
    const session = {
      sessionId: randomUUID(), deviceId, deviceName: device.deviceName,
      serialNumber: device.serialNumber, sessionName, startTime: new Date(startTime).toISOString(),
      endTime: null, notes,
    };
    this.sessions.push(session);
    this.measurements.set(session.sessionId, []);
    return session;
  }

  // Update an existing time/channel pair rather than adding duplicate rows.
  async addSamples(sessionId, samples) {
    const session = this.sessions.find((item) => item.sessionId === sessionId);
    if (!session) throw new Error("sessionId was not found");
    const rows = this.measurements.get(sessionId);
    const index = new Map(rows.map(row => [`${row.recordedAt}/${row.channel}`, row]));
    for (const sample of samples) {
      sample.channels.forEach((voltage, channel) => {
        const key = `${sample.recordedAt}/${channel}`;
        const existing = index.get(key);
        if (existing) existing.voltage = voltage;
        else {
          const row = { recordedAt: sample.recordedAt, channel, voltage };
          rows.push(row); index.set(key, row);
        }
      });
    }
    // Session end time is the maximum sample ever received, not batch order.
    const latestRecordedAt = samples.reduce((latest, sample) =>
      sample.recordedAt > latest ? sample.recordedAt : latest, samples[0].recordedAt);
    session.endTime = !session.endTime || latestRecordedAt > session.endTime
      ? latestRecordedAt : session.endTime;
    return { insertedMeasurements: samples.length * 16 };
  }

  // Return a new object so callers cannot accidentally replace stored metadata.
  async getSession(sessionId, { from, to, metadataOnly = false, recent = false } = {}) {
    const session = this.sessions.find((item) => item.sessionId === sessionId);
    if (!session) return null;
    if (metadataOnly) return {...session};
    const measurements = (this.measurements.get(sessionId) || []).filter((row) => {
      const time = new Date(row.recordedAt).valueOf();
      return (!from || time >= new Date(from).valueOf()) && (!to || time <= new Date(to).valueOf());
    });
    measurements.sort((a,b) => a.recordedAt.localeCompare(b.recordedAt) || a.channel-b.channel);
    return { ...session, measurements: recent ? measurements.slice(-16000) : measurements,
      measurementCount: measurements.length, truncated: recent && measurements.length > 16000 };
  }
}
