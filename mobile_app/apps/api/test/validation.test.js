// Unit tests for the API's pure validation functions. These run without opening
// a port or database, so failures point directly to the payload contract.
import test from "node:test";
import assert from "node:assert/strict";
import {
  MAX_SAMPLES_PER_REQUEST, validateDevice, validateSamples, validateSession,
  validateUuid,
} from "../src/validation.js";

test("accepts a timestamp and exactly 16 voltage values", () => {
  // Millisecond inputs retain their established UTC representation; sub-ms
  // inputs additionally retain microseconds (covered by microsecond-capture).
  const [sample] = validateSamples([{ recordedAt: "2026-09-12T12:00:00Z", channels: Array(16).fill(1.2) }]);
  assert.equal(sample.channels.length, 16);
  assert.equal(sample.recordedAt, "2026-09-12T12:00:00.000Z");
});

test("rejects a sample with the wrong channel count", () => {
  assert.throws(() => validateSamples([{ recordedAt: "2026-09-12T12:00:00Z", channels: [1.2] }]), /exactly 16/);
});

test("rejects voltages outside the hardware range", () => {
  assert.throws(() => validateSamples([{ recordedAt: "2026-09-12T12:00:00Z", channels: [...Array(15).fill(1.2), 5.1] }]), /between -5 and 5/);
});

test('requires explicit timezones and limits batch size', () => {
  // Ambiguous local time and unbounded work are both rejected at the boundary.
  assert.throws(() => validateSamples([{
    recordedAt: '2026-09-12T12:00:00', channels: Array(16).fill(0),
  }]), /timezone/);
  assert.throws(() => validateSamples([{
    recordedAt: '2026-02-30T12:00:00Z', channels: Array(16).fill(0),
  }]), /valid timestamp/);
  const sample = {recordedAt: '2026-09-12T12:00:00Z', channels: Array(16).fill(0)};
  assert.throws(() => validateSamples(Array(MAX_SAMPLES_PER_REQUEST + 1).fill(sample)), /1000/);
});

test('normalizes device/session text and validates identifiers', () => {
  // Normalized output is what stores receive; they never trim fields themselves.
  assert.deepEqual(validateDevice({deviceName: ' Bench ', serialNumber: ' ABC-1 '}), {
    deviceName: 'Bench', serialNumber: 'ABC-1',
  });
  assert.throws(() => validateDevice({deviceName: ' ', serialNumber: 'ABC-1'}), /deviceName/);
  assert.throws(() => validateUuid('not-a-uuid', 'sessionId'), /sessionId/);
  const session = validateSession({
    deviceId: '10000000-0000-4000-8000-000000000000',
    sessionName: ' Test ', startTime: '2026-09-12T07:00:00-05:00', notes: ' note ',
  });
  assert.equal(session.sessionName, 'Test');
  assert.equal(session.startTime, '2026-09-12T12:00:00.000Z');
  assert.equal(session.notes, 'note');
  assert.throws(() => validateSession({
    deviceId: '10000000-0000-4000-8000-000000000000',
    sessionName: 'Test', startTime: '2026-02-30T12:00:00Z',
  }), /valid timestamp/);
});
