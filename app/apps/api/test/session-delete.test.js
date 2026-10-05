import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { createApp } from '../src/app.js';
import { MemoryStore } from '../src/memory-store.js';
import { PostgresStore } from '../src/postgres-store.js';
import { SingleUserAuth } from '../src/auth.js';

const samples = [{ recordedAt: '2026-10-05T12:00:00.000001Z', channels: Array(16).fill(1.25) }];

async function fixture(store) {
  const device = await store.createDevice({ deviceName: 'Deletion check', serialNumber: randomUUID() });
  const create = name => store.createSession({ deviceId: device.deviceId,
    sessionName: name, startTime: '2026-10-05T11:00:00Z' });
  const removed = await create('Remove only this session');
  const kept = await create('Keep this session');
  await store.addSamples(removed.sessionId, samples);
  await store.addSamples(kept.sessionId, samples);
  return { device, removed, kept };
}

async function serve(store, options = {}) {
  const server = createApp(store, options).listen(0, '127.0.0.1');
  await new Promise(resolve => server.once('listening', resolve));
  return { base: `http://127.0.0.1:${server.address().port}/api`,
    close: async () => {
      server.closeAllConnections();
      await new Promise(resolve => server.close(resolve));
    } };
}

async function verifyDeletion(store) {
  const { device, removed, kept } = await fixture(store);
  const { base, close } = await serve(store);
  const path = `${base}/sessions/${removed.sessionId}`;
  try {
    assert.equal((await fetch(`${base}/sessions/not-a-uuid`, { method: 'DELETE' })).status, 400);
    assert.equal((await fetch(`${base}/sessions/${randomUUID()}`, { method: 'DELETE' })).status, 404);
    const response = await fetch(path, { method: 'DELETE' });
    assert.equal(response.status, 204);
    assert.equal(await response.text(), '');
    assert.equal((await fetch(path)).status, 404);
    assert.equal((await fetch(path, { method: 'DELETE' })).status, 404);
    assert.equal((await fetch(`${path}/measurements`, { method: 'POST',
      headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ samples }) })).status, 404);
    assert.ok(!(await store.listSessions()).some(s => s.sessionId === removed.sessionId));
    assert.equal((await store.getSession(kept.sessionId)).measurements.length, 16);
    assert.ok((await store.listDevices()).some(d => d.deviceId === device.deviceId));
    if (store.pool) {
      assert.equal(Number((await store.pool.query('SELECT count(*) FROM measurement WHERE session_id=$1',
        [removed.sessionId])).rows[0].count), 0, 'All measurement rows cascade');
    } else assert.ok(!store.measurements.has(removed.sessionId));
  } finally {
    await close();
    // Only remove this test's randomly identified records, never existing data.
    await store.deleteSession(kept.sessionId);
    if (store.pool) await store.pool.query('DELETE FROM monitor_device WHERE device_id=$1', [device.deviceId]);
  }
}

test('HTTP deletion removes only the chosen session and blocks later uploads', async () => {
  await verifyDeletion(new MemoryStore());
});

test('PostgreSQL deletion cascades measurements while keeping device and sibling session', {
  skip: !process.env.TEST_DATABASE_URL,
}, async () => {
  const store = new PostgresStore(process.env.TEST_DATABASE_URL);
  try { await verifyDeletion(store); } finally { await store.pool.end(); }
});

test('session deletion requires a valid login when authentication is enabled', async () => {
  const store = new MemoryStore();
  const { removed } = await fixture(store);
  const auth = new SingleUserAuth('student', 'long-test-password');
  const { base, close } = await serve(store, { auth });
  const path = `${base}/sessions/${removed.sessionId}`;
  try {
    assert.equal((await fetch(path, { method: 'DELETE' })).status, 401);
    assert.equal((await fetch(path, { method: 'DELETE', headers: { Authorization: 'Bearer invalid' } })).status, 401);
    assert.ok(await store.getSession(removed.sessionId));
    const { token } = auth.login('student', 'long-test-password', 'test');
    assert.equal((await fetch(path, { method: 'DELETE', headers: { Authorization: `Bearer ${token}` } })).status, 204);
  } finally { await close(); }
});

test('deletion between upload metadata lookup and PostgreSQL insert returns 404 without resurrection', {
  skip: !process.env.TEST_DATABASE_URL,
}, async () => {
  const store = new PostgresStore(process.env.TEST_DATABASE_URL);
  const { device, removed, kept } = await fixture(store);
  const insert = store.addSamples.bind(store);
  let start, resume;
  const started = new Promise(resolve => { start = resolve; });
  const gate = new Promise(resolve => { resume = resolve; });
  store.addSamples = async (...args) => { start(); await gate; return insert(...args); };
  const { base, close } = await serve(store);
  const path = `${base}/sessions/${removed.sessionId}`;
  let upload;
  try {
    upload = fetch(`${path}/measurements`, { method: 'POST',
      headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ samples }) });
    await started;
    assert.equal((await fetch(path, { method: 'DELETE' })).status, 204);
    resume();
    assert.equal((await upload).status, 404);
    assert.equal(await store.getSession(removed.sessionId), null);
    assert.equal(Number((await store.pool.query('SELECT count(*) FROM measurement WHERE session_id=$1',
      [removed.sessionId])).rows[0].count), 0);
  } finally {
    resume();
    if (upload) await upload;
    await close();
    await store.deleteSession(removed.sessionId);
    await store.deleteSession(kept.sessionId);
    await store.pool.query('DELETE FROM monitor_device WHERE device_id=$1', [device.deviceId]);
    await store.pool.end();
  }
});
