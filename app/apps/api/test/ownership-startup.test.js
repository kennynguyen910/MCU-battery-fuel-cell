import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createServer } from 'node:net';
import { randomUUID } from 'node:crypto';
import { PostgresStore } from '../src/postgres-store.js';

test('production entry point upgrades before listening and publishes the ownership capability', {
  skip: !process.env.TEST_DATABASE_URL,
}, async () => {
  const reservation = createServer().listen(0, '127.0.0.1');
  await new Promise(resolve => reservation.once('listening', resolve));
  const port = reservation.address().port;
  await new Promise(resolve => reservation.close(resolve));
  const username = 'startup-' + randomUUID();
  const password = 'startup-test-password';
  const child = spawn(process.execPath, ['src/server.js'], { windowsHide: true,
    env: { ...process.env, PORT: String(port), DATABASE_URL: process.env.TEST_DATABASE_URL,
      DATABASE_SSL_CA: '', APP_USERNAME: username, APP_PASSWORD: password,
      NETWORK_SIMULATION_ENABLED: '0', DEVICE_UDP_ENABLED: '0', DEVICE_IP: '' },
    stdio: ['ignore', 'pipe', 'pipe'] });
  const closed = new Promise(resolve => child.once('close', resolve));
  let output = '', failure;
  child.stdout.on('data', data => { output += data; });
  child.stderr.on('data', data => { output += data; });
  child.on('error', error => { failure = error; });
  const base = `http://127.0.0.1:${port}`;
  const store = new PostgresStore(process.env.TEST_DATABASE_URL);
  let device, session;
  try {
    let health;
    for (let i = 0; i < 100; i++) {
      if (failure || child.exitCode !== null) throw new Error(output || String(failure));
      try {
        const response = await fetch(base + '/health', { signal: AbortSignal.timeout(250) });
        if (response.ok) { health = await response.json(); break; }
      } catch { /* The process has not started listening yet. */ }
      await new Promise(resolve => setTimeout(resolve, 50));
    }
    assert.equal(health?.storage, 'postgres', output);
    const capability = await (await fetch(base + '/api/auth/status')).json();
    assert.equal(capability.enabled, true);
    assert.equal(capability.sessionOwnership, true);
    const login = await fetch(base + '/api/auth/login', { method: 'POST',
      headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ username, password }) });
    assert.equal(login.status, 200);
    const { token } = await login.json();
    const post = async (path, body) => {
      const response = await fetch(base + '/api' + path, { method: 'POST',
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
        body: JSON.stringify(body) });
      assert.equal(response.status, 201);
      return response.json();
    };
    device = await post('/devices', { deviceName: 'Startup check', serialNumber: randomUUID() });
    session = await post('/sessions', { deviceId: device.deviceId,
      sessionName: 'Owned after automatic upgrade', startTime: '2026-10-05T00:00:00Z' });
    assert.equal(session.ownerUsername, username);
  } finally {
    child.kill();
    await closed;
    if (session) await store.deleteSession(session.sessionId);
    if (device) await store.pool.query('DELETE FROM monitor_device WHERE device_id=$1', [device.deviceId]);
    await store.pool.query('DELETE FROM app_user WHERE username=$1', [username]);
    await store.pool.end();
  }
});
