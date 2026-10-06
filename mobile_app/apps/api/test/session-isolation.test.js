import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import pg from 'pg';
import { SingleUserAuth } from '../src/auth.js';
import { DatabaseAuth } from '../src/user-auth.js';
import { createApp } from '../src/app.js';
import { MemoryStore } from '../src/memory-store.js';
import { PostgresStore } from '../src/postgres-store.js';
import { migrateSessionOwnership } from '../src/session-ownership.js';

const names = ['WillAdcox', 'KennyNguyen', 'capstone_admin', 'Capstone_admin'];
const password = 'isolated-test-password';
const samples = [{ recordedAt: '2026-10-05T12:00:00.000001Z', channels: Array(16).fill(1.25) }];
class TestAuth extends SingleUserAuth {
  constructor() { super('capstone_admin', password); }
  login(username, candidate, ip) {
    return this.verify(username, candidate, ip, names.includes(username)
      ? { username, salt: this.salt, passwordHash: this.passwordHash } : undefined);
  }
}

async function verifyIsolation(store, auth) {
  const device = await store.createDevice({ deviceName: 'Shared bench', serialNumber: randomUUID() });
  const legacy = await store.createSession({ deviceId: device.deviceId, sessionName: 'Preserved legacy',
    startTime: '2026-10-05T11:00:00Z' });
  await store.addSamples(legacy.sessionId, samples);
  const server = createApp(store, { auth }).listen(0, '127.0.0.1');
  await new Promise(resolve => server.once('listening', resolve));
  const base = `http://127.0.0.1:${server.address().port}/api`;
  const tokens = {};
  const ids = [legacy.sessionId];
  const request = (user, path, method = 'GET', body) => fetch(base + path, { method,
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${tokens[user]}`,
      'X-Username': 'capstone_admin', 'X-Is-Admin': 'true' },
    ...(body ? { body: JSON.stringify(body) } : {}) });
  try {
    for (const name of names) {
      const response = await fetch(base + '/auth/login', { method: 'POST',
        headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ username: name, password }) });
      assert.equal(response.status, 200);
      const login = await response.json();
      assert.equal(login.username, name);
      assert.equal(login.isAdmin, name === 'capstone_admin');
      tokens[name] = login.token;
    }
    const create = async user => {
      const response = await request(user, '/sessions', 'POST', { deviceId: device.deviceId,
        sessionName: `${user} owned session`, startTime: '2026-10-05T11:00:00Z',
        ownerUsername: 'capstone_admin', username: 'capstone_admin', isAdmin: true });
      assert.equal(response.status, 201);
      const result = await response.json();
      ids.push(result.sessionId);
      assert.equal(result.ownerUsername, user, 'Ownership comes from the token, not the body');
      return result;
    };
    const will = await create('WillAdcox');
    const kenny = await create('KennyNguyen');
    const admin = await create('capstone_admin');
    const lookalike = await create('Capstone_admin');
    for (const [user, session] of [['WillAdcox', will], ['KennyNguyen', kenny]]) {
      assert.equal((await request(user, `/sessions/${session.sessionId}/measurements`, 'POST', { samples })).status, 201);
    }
    for (const [user, own] of [['WillAdcox', will], ['KennyNguyen', kenny], ['Capstone_admin', lookalike]]) {
      const list = await (await request(user, '/sessions?ownerUsername=capstone_admin&isAdmin=true&from=2026-10-05T00:00:00Z&to=2026-10-06T00:00:00Z')).json();
      assert.deepEqual(list.map(s => s.sessionId), [own.sessionId]);
      assert.equal((await request(user, `/sessions/${own.sessionId}?recent=1`)).status, 200);
      for (const other of [legacy, admin, user === 'WillAdcox' ? kenny : will]) {
        const path = `/sessions/${other.sessionId}`;
        for (const suffix of ['', '?recent=1', '?from=2026-10-05T12:00:00Z&to=2026-10-06T00:00:00Z']) {
          const response = await request(user, path + suffix);
          assert.equal(response.status, 404);
          assert.deepEqual(await response.json(), { error: 'Session not found' });
        }
        assert.equal((await request(user, path + '/measurements', 'POST',
          { samples, ownerUsername: user, isAdmin: true })).status, 404);
        assert.equal((await request(user, path + '?ownerUsername=' + user, 'DELETE')).status, 404);
      }
    }
    const all = await (await request('capstone_admin', '/sessions')).json();
    assert.equal(all.filter(s => ids.includes(s.sessionId)).length, 5);
    for (const id of ids) assert.equal((await request('capstone_admin', `/sessions/${id}`)).status, 200);
    assert.equal((await request('capstone_admin', `/sessions/${will.sessionId}/measurements`, 'POST', { samples })).status, 201);
    assert.equal((await store.getSession(will.sessionId)).measurements.length, 16);
    assert.equal((await store.getSession(legacy.sessionId)).measurements.length, 16);
    // The persistence boundary independently enforces write/delete scope.
    await assert.rejects(store.addSamples(will.sessionId, samples, { ownerUsername: 'KennyNguyen' }), { code: '23503' });
    assert.equal(await store.deleteSession(will.sessionId, { ownerUsername: 'KennyNguyen' }), false);
    assert.equal(await store.getSession(will.sessionId, { ownerUsername: 'KennyNguyen' }), null);
    assert.equal((await request('WillAdcox', `/sessions/${will.sessionId}`, 'DELETE')).status, 204);
    assert.equal((await request('capstone_admin', `/sessions/${kenny.sessionId}`, 'DELETE')).status, 204);
    assert.ok(await store.getSession(legacy.sessionId), 'Legacy data is never reassigned or deleted');
    await request('WillAdcox', '/auth/logout', 'POST');
    assert.equal((await request('WillAdcox', '/sessions')).status, 401);
    assert.equal((await request('KennyNguyen', '/sessions')).status, 200);
    assert.ok((await store.listDevices()).some(d => d.deviceId === device.deviceId));
  } finally {
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
    for (const id of ids) await store.deleteSession(id);
    if (store.pool) await store.pool.query('DELETE FROM monitor_device WHERE device_id=$1', [device.deviceId]);
  }
}

test('memory HTTP: each user accesses only owned sessions; exact admin sees legacy and all users', async () => {
  await verifyIsolation(new MemoryStore(), new TestAuth());
});

test('PostgreSQL HTTP: token identity isolates list/history/uploads/deletion with unchanged shared devices', {
  skip: !process.env.TEST_DATABASE_URL,
}, async () => {
  const store = new PostgresStore(process.env.TEST_DATABASE_URL);
  try {
    await migrateSessionOwnership(store.pool);
    const auth = new DatabaseAuth(store.pool);
    await auth.initialize();
    for (const name of names) await auth.addUser(name, password);
    await verifyIsolation(store, auth);
  } finally {
    await store.pool.query('DELETE FROM app_user WHERE username = ANY($1)', [names]);
    await store.pool.end();
  }
});

test('expired and revoked tokens cannot supply a principal or an admin role', () => {
  const auth = new TestAuth();
  const { token } = auth.login('WillAdcox', password, 'test');
  assert.deepEqual(auth.principal(token), { username: 'WillAdcox', isAdmin: false });
  auth.tokens.get(auth.digest(token)).expiresAt = Date.now() - 1;
  assert.equal(auth.principal(token), null);
  assert.equal(auth.valid(token), false);
  const admin = auth.login('capstone_admin', password, 'test').token;
  auth.logout(admin);
  assert.equal(auth.principal(admin), null);
  assert.equal(auth.principal('invented-admin-token'), null);
});

test('additive ownership migration preserves all legacy IDs, values and constraints and can be repeated', {
  skip: !process.env.TEST_DATABASE_URL,
}, async () => {
  const schemaName = 'ownership_' + randomUUID().replaceAll('-', '');
  const base = new pg.Pool({ connectionString: process.env.TEST_DATABASE_URL });
  await base.query(`CREATE SCHEMA ${schemaName}`);
  const pool = new pg.Pool({ connectionString: process.env.TEST_DATABASE_URL,
    options: `-c search_path=${schemaName},public` });
  try {
    // Remove only the ownership additions to reproduce the pre-upgrade schema.
    const schema = readFileSync(new URL('../../../database/schema.sql', import.meta.url), 'utf8')
      .replace(/^\s*owner_username TEXT,\r?\n/m, '')
      .replace(/ALTER TABLE test_session ADD COLUMN IF NOT EXISTS owner_username TEXT;\r?\n/, '')
      .replace(/CREATE INDEX IF NOT EXISTS test_session_owner_start_time_idx\s+ON test_session \(owner_username, start_time DESC\);/, '');
    await pool.query(schema);
    const device = (await pool.query("INSERT INTO monitor_device(device_name,serial_number) VALUES('Legacy','legacy') RETURNING device_id")).rows[0];
    const session = (await pool.query("INSERT INTO test_session(device_id,session_name,start_time,notes) VALUES($1,'Legacy','2026-10-05T00:00:00Z','Keep unchanged') RETURNING *", [device.device_id])).rows[0];
    await pool.query("INSERT INTO measurement(session_id,recorded_at,channel,voltage) VALUES($1,'2026-10-05T00:00:00.000001Z',0,1.25)", [session.session_id]);
    const rowsBefore = (await pool.query('SELECT * FROM measurement')).rows;
    const constraints = async () => (await pool.query(`SELECT conname,pg_get_constraintdef(c.oid) AS definition
      FROM pg_constraint c JOIN pg_namespace n ON n.oid=c.connamespace WHERE n.nspname=$1 ORDER BY conname`, [schemaName])).rows;
    const before = await constraints();
    const reader = await pool.connect();
    try {
      await reader.query('BEGIN');
      await reader.query('SELECT session_id FROM test_session');
      await assert.rejects(migrateSessionOwnership(pool), { code: '55P03' });
      assert.equal((await reader.query('SELECT * FROM measurement')).rows.length, 1,
        'An existing reader stays available during a failed migration');
    } finally {
      await reader.query('ROLLBACK');
      reader.release();
    }
    assert.equal((await pool.query(`SELECT count(*) FROM information_schema.columns
      WHERE table_schema=$1 AND table_name='test_session' AND column_name='owner_username'`, [schemaName])).rows[0].count, '0');
    await migrateSessionOwnership(pool);
    await migrateSessionOwnership(pool);
    const after = (await pool.query('SELECT * FROM test_session')).rows[0];
    assert.equal(after.owner_username, null);
    delete after.owner_username;
    assert.deepEqual(after, session);
    assert.deepEqual((await pool.query('SELECT * FROM measurement')).rows, rowsBefore);
    assert.deepEqual(await constraints(), before);
    assert.equal((await pool.query('SELECT * FROM monitor_device')).rows[0].device_id, device.device_id);
  } finally {
    await pool.end();
    await base.query(`DROP SCHEMA ${schemaName} CASCADE`);
    await base.end();
  }
});
