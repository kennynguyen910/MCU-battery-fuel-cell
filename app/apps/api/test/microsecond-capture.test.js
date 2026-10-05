import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {DeviceReceiver} from '../src/device-receiver.js';
import {encodeBatch} from '../src/network-simulator.js';
import {validateSamples, validateRange} from '../src/validation.js';
import {formatMicros, timestampMicros} from '../src/sample-time.js';
import {MemoryStore} from '../src/memory-store.js';
import {PostgresStore} from '../src/postgres-store.js';

test('microsecond validation preserves offsets, boundaries and pre-epoch instants', () => {
  const normalize = recordedAt => validateSamples([{recordedAt,channels:Array(16).fill(1)}])[0].recordedAt;
  assert.equal(normalize('2026-10-05T07:00:00.000500-05:00'), '2026-10-05T12:00:00.000500Z');
  assert.equal(normalize('2026-10-05T12:00:00.000100Z'), '2026-10-05T12:00:00.000100Z');
  assert.equal(normalize('1969-12-31T23:59:59.999500Z'), '1969-12-31T23:59:59.999500Z');
  assert.equal(formatMicros(-500n), '1969-12-31T23:59:59.999500Z');
  assert.throws(() => normalize('2026-10-05T12:00:00.0000001Z'), /valid timestamp/);
  assert.throws(() => normalize('2026-02-30T12:00:00.000500Z'), /valid timestamp/);
  const from = '2026-10-05T12:00:00.000Z', to = '2026-10-05T12:00:00.000500Z';
  assert.deepEqual(validateRange({from,to}), {from,to});
  assert.throws(() => validateRange({from:to,to:from}), /before/);
});

test('2kHz device timing survives delayed packets and host clock adjustments', () => {
  let now = 1_000_000;
  const receiver = new DeviceReceiver({now:() => now});
  receiver.ingest(encodeBatch(0,0,2000),'127.0.0.1');
  now += 800; // Delivery latency must not stretch acquisition time.
  receiver.ingest(encodeBatch(10,1,2000),'127.0.0.1');
  now -= 1500;
  receiver.ingest(encodeBatch(20,2,2000),'127.0.0.1');
  const frames = receiver.page('127.0.0.1',0,undefined,1000).frames;
  const first = timestampMicros(frames[0].recordedAt);
  for (let i=0;i<30;i++) assert.equal(timestampMicros(frames[i].recordedAt)-first,BigInt(i)*500n);
  assert.doesNotThrow(() => JSON.stringify(receiver.list()));
});

for (const adapter of ['memory','postgres']) test(`${adapter}: >1kHz timestamps, concurrent uploads, retries and microsecond history ranges`, {
  skip: adapter === 'postgres' && !process.env.TEST_DATABASE_URL,
}, async () => {
  const store = adapter === 'memory' ? new MemoryStore() : new PostgresStore(process.env.TEST_DATABASE_URL);
  let device;
  try {
    device = await store.createDevice({deviceName:'Microsecond acceptance',serialNumber:randomUUID()});
    const session = await store.createSession({deviceId:device.deviceId,sessionName:'Timing',startTime:'2026-10-05T12:00:00.000Z'});
    const times = ['2026-10-05T12:00:00.000Z','2026-10-05T12:00:00.000500Z','2026-10-05T12:00:00.001Z'];
    const samples = validateSamples(times.map((recordedAt,i) => ({recordedAt,channels:Array(16).fill(i)})));
    await Promise.all([store.addSamples(session.sessionId,[samples[2]]),store.addSamples(session.sessionId,samples.slice(0,2))]);
    await store.addSamples(session.sessionId,samples);
    const history = await store.getSession(session.sessionId);
    assert.equal(history.measurements.length,48);
    assert.equal(new Set(history.measurements.map(r=>timestampMicros(r.recordedAt))).size,3);
    assert.equal(timestampMicros(history.endTime),timestampMicros(times[2]));
    const range = await store.getSession(session.sessionId,validateRange({from:times[1],to:times[1]}));
    assert.equal(range.measurements.length,16);
    assert.ok(range.measurements.every(r=>r.voltage===1 && timestampMicros(r.recordedAt)===timestampMicros(times[1])));
  } finally {
    if (store.pool) {
      if (device) {
        await store.pool.query('DELETE FROM test_session WHERE device_id=$1',[device.deviceId]);
        await store.pool.query('DELETE FROM monitor_device WHERE device_id=$1',[device.deviceId]);
      }
      await store.pool.end();
    }
  }
});
