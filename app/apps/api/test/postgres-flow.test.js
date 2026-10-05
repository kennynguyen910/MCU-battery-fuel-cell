// Real integration test for the required device → mobile → PostgreSQL → web
// boundary. It is deliberately additive and never erases a developer's data.
import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { createApp } from '../src/app.js';
import { PostgresStore } from '../src/postgres-store.js';

// Skip only when a caller intentionally omits a test-database connection string.
test('input -> collector upload -> persistent Postgres -> web read', {
  skip: !process.env.TEST_DATABASE_URL,
}, async () => {
  const store = new PostgresStore(process.env.TEST_DATABASE_URL);
  const server = createApp(store).listen(0, '127.0.0.1');
  await new Promise(resolve => server.once('listening', resolve));
  const base = 'http://127.0.0.1:' + server.address().port + '/api';
  const get = async path => {
    const response = await fetch(base + path);
    assert.equal(response.status, 200);
    return response.json();
  };
  const post = async (path, data) => {
    const response = await fetch(base + path, {
      method: 'POST', headers: {'content-type': 'application/json'},
      body: JSON.stringify(data),
    });
    assert.equal(response.status, 201, await response.clone().text());
    return response.json();
  };
  let reader;
  try {
    // A random serial avoids conflicts with earlier retained test evidence.
    const device = await post('/devices', {deviceName: 'Integration check', serialNumber: randomUUID()});
    const session = await post('/sessions', {
      deviceId: device.deviceId, sessionName: 'Verified database flow',
      startTime: new Date().toISOString(), notes: 'Automated integration check.',
    });
    const path = '/sessions/' + session.sessionId;
    const channels = Array.from({length: 16}, (_, i) => (i - 8) / 10);
    await post('/test-input', {channels});
    assert.equal((await get(path)).measurements.length, 0, 'Input dashboard must not bypass mobile');
    const frame = await get('/test-input'); // This read represents the mobile app.
    const upload = {samples: [{recordedAt: frame.recordedAt, channels: frame.channels}]};
    await post(path + '/measurements', upload);
    await post(path + '/measurements', upload); // Retry preserves original timestamp.
    const saved = await get(path); // Web reads this.
    assert.deepEqual(saved.measurements.map(row => row.voltage), channels);
    // A second pool proves persistence outside the original writer connection.
    reader = new PostgresStore(process.env.TEST_DATABASE_URL);
    assert.equal((await reader.getSession(session.sessionId)).measurements.length, 16);
    // Equal boundaries include the sample. A later start excludes it.
    const instant = encodeURIComponent(frame.recordedAt);
    assert.equal((await get(path + '?from=' + instant + '&to=' + instant)).measurements.length, 16);
    const later = encodeURIComponent(new Date(Date.parse(frame.recordedAt) + 1).toISOString());
    assert.equal((await get(path + '?from=' + later)).measurements.length, 0);
    assert.equal((await fetch(base + path + '?from=bad')).status, 400);
    assert.equal((await fetch(base + path + '?from=' + later + '&to=' + instant)).status, 400);
  } finally {
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
    await store.pool.end();
    if (reader) await reader.pool.end();
  }
});
