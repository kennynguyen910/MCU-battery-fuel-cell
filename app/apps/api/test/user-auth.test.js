import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { spawn } from 'node:child_process';
import { DatabaseAuth, validateCredentials } from '../src/user-auth.js';
import { PostgresStore } from '../src/postgres-store.js';
import { MemoryStore } from '../src/memory-store.js';
import { createApp } from '../src/app.js';

test('account validation enforces supported usernames and password length', () => {
  validateCredentials('student-1.test', 'a-long-password');
  for (const username of ['', 'name with spaces', "x';--", 'x'.repeat(101)])
    assert.throws(() => validateCredentials(username, 'a-long-password'));
  for (const password of ['', 'short', 'x'.repeat(1001)])
    assert.throws(() => validateCredentials('student', password));
});

test('database accounts persist, seed safely, and support independent HTTP login/logout and CLI creation', {
  skip: !process.env.TEST_DATABASE_URL,
}, async () => {
  const store = new PostgresStore(process.env.TEST_DATABASE_URL);
  const names = ['seed', 'second', 'cli'].map(prefix => `${prefix}-${randomUUID()}`);
  const password = 'test-account-password';
  let server;
  try {
    const auth = new DatabaseAuth(store.pool);
    await auth.initialize(names[0], password);
    await auth.addUser(names[1], password);
    await assert.rejects(auth.addUser(names[1], 'different-password'), /already exists/);
    const restarted = new DatabaseAuth(store.pool);
    await restarted.initialize(names[0], 'changed-environment-password');
    assert.ok((await restarted.login(names[0], password, 'seed')).token);
    assert.equal((await restarted.login(names[0], 'changed-environment-password', 'seed')).status, 401);
    assert.equal((await restarted.login('unknown', password, 'unknown')).status, 401);
    const { rows } = await store.pool.query('SELECT password_hash, password_salt FROM app_user WHERE username = ANY($1)', [names]);
    assert.equal(rows.length, 2);
    assert.equal(rows[0].password_hash.length, 32);
    assert.notDeepEqual(rows[0].password_hash, rows[1].password_hash);
    assert.notDeepEqual(rows[0].password_salt, rows[1].password_salt);
    server = createApp(new MemoryStore(), { auth: restarted }).listen(0);
    await new Promise(resolve => server.once('listening', resolve));
    const base = `http://127.0.0.1:${server.address().port}/api`;
    const login = async (username, candidate = password) => {
      const response = await fetch(`${base}/auth/login`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ username, password: candidate }),
      });
      return { status: response.status, ...await response.json() };
    };
    const first = await login(names[0]);
    const second = await login(names[1]);
    assert.equal(first.status, 200);
    assert.equal(second.username, names[1]);
    assert.notEqual(first.token, second.token);
    assert.equal((await login(names[1], 'wrong')).status, 401);
    const headers = token => ({ Authorization: `Bearer ${token}` });
    assert.equal((await fetch(`${base}/sessions`, { headers: headers(second.token) })).status, 200);
    await fetch(`${base}/auth/logout`, { method: 'POST', headers: headers(first.token) });
    assert.equal((await fetch(`${base}/sessions`, { headers: headers(first.token) })).status, 401);
    assert.equal((await fetch(`${base}/sessions`, { headers: headers(second.token) })).status, 200);
    const child = spawn(process.execPath, ['tools/add-user.js', '--configured-database'], {
      cwd: new URL('../../../', import.meta.url),
      env: { ...process.env, DATABASE_URL: process.env.TEST_DATABASE_URL, DATABASE_SSL_CA: '' },
      windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'],
    });
    let output = '';
    child.stdout.on('data', data => output += data);
    child.stderr.on('data', data => output += data);
    child.stdin.end(JSON.stringify({ username: names[2], password }));
    const code = await new Promise((resolve, reject) => {
      child.on('error', reject); child.on('close', resolve);
    });
    assert.equal(code, 0, output);
    assert.equal(output.includes(password), false);
    assert.equal((await login(names[2])).status, 200);
    for (let i = 0; i < 10; i++) await restarted.login(names[1], 'wrong', 'limited');
    assert.equal((await restarted.login(names[1], password, 'limited')).status, 429);
  } finally {
    if (server) await new Promise(resolve => server.close(resolve));
    await store.pool.query('DELETE FROM app_user WHERE username = ANY($1)', [names]);
    await store.pool.end();
  }
});
