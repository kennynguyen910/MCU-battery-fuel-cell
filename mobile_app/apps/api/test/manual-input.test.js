// Fast end-to-end HTTP flow using the in-memory adapter. This proves route wiring
// and storage semantics independently of a PostgreSQL installation.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createApp } from '../src/app.js';
import { MemoryStore } from '../src/memory-store.js';

test('manual sample propagates through HTTP; invalid sample is not stored', async () => {
  // Small helpers keep each arrange/act/assert step readable.
  const server = createApp(new MemoryStore(false)).listen(0, '127.0.0.1');
  await new Promise(resolve => server.once('listening', resolve));
  const base = 'http://127.0.0.1:' + server.address().port + '/api';
  const post = (path, body) => fetch(base + path, {
    method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body),
  });
  try {
    assert.deepEqual(await (await fetch(base + '/sessions')).json(), []);
    const device = await (await post('/devices', { deviceName: 'Manual', serialNumber: 'MANUAL-001' })).json();
    const session = await (await post('/sessions', {
      deviceId: device.deviceId, sessionName: 'Test', startTime: '2026-09-13T00:00:00Z',
    })).json();
    const path = '/sessions/' + session.sessionId;
    // Give every channel a distinct value so ordering mistakes are visible.
    const channels = Array.from({ length: 16 }, (_, i) => i / 10 - 0.5);
    assert.equal((await post(path + '/measurements', { samples: [{
      recordedAt: '2026-09-13T00:00:01Z', channels,
    }] })).status, 201);
    const saved = await (await fetch(base + path)).json();
    assert.deepEqual(saved.measurements.map(r => r.voltage), channels);
    // Retrying the identical frame updates the same logical rows.
    assert.equal((await post(path + '/measurements', { samples: [{
      recordedAt: '2026-09-13T00:00:01Z', channels,
    }] })).status, 201);
    assert.equal((await (await fetch(base + path)).json()).measurements.length, 16);

    // Batch order must not determine the session's end time.
    assert.equal((await post(path + '/measurements', {samples: [
      {recordedAt: '2026-09-13T00:00:03Z', channels},
      {recordedAt: '2026-09-13T00:00:02Z', channels},
    ]})).status, 201);
    const afterBatch = await (await fetch(base + path)).json();
    assert.equal(afterBatch.endTime, '2026-09-13T00:00:03.000Z');
    assert.equal(afterBatch.measurements.length, 48);
    assert.equal((await post(path + '/measurements', { samples: [{
      recordedAt: '2026-09-13T00:00:02Z', channels: Array(16).fill(6),
    }] })).status, 400);
    assert.equal((await (await fetch(base + path)).json()).measurements.length, 48);
  } finally {
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
  }
});
