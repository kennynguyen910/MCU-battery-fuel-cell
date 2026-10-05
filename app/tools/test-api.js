// Keep regression tests, migrations and test accounts out of the app database.
import { randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { spawn } from 'node:child_process';
const { Pool } = createRequire(new URL('../apps/api/package.json', import.meta.url))('pg');
const name = 'capstone_test_' + randomUUID().replaceAll('-', '');
const admin = new Pool({ connectionString: 'postgresql://capstone@127.0.0.1:55432/postgres' });
const testUrl = `postgresql://capstone@127.0.0.1:55432/${name}`;
let created = false;
try {
  await admin.query(`CREATE DATABASE ${name}`);
  created = true;
  const isolated = new Pool({ connectionString: testUrl });
  try {
    await isolated.query(readFileSync(new URL('../database/schema.sql', import.meta.url), 'utf8'));
  } finally { await isolated.end(); }
  console.log('API tests use a temporary isolated database. App records stay unchanged.');
  const code = await new Promise((resolve, reject) => {
    const child = spawn(process.execPath, ['--test'], {
      cwd: new URL('../apps/api/', import.meta.url), windowsHide: true, stdio: 'inherit',
      env: { ...process.env, TEST_DATABASE_URL: testUrl, DATABASE_SSL_CA: '' },
    });
    child.on('error', reject);
    child.on('close', code => resolve(code ?? 1));
  });
  process.exitCode = code;
} finally {
  try {
    // Only this run's generated database is eligible for cleanup; no FORCE.
    if (created && /^capstone_test_[a-f0-9]{32}$/.test(name)) {
      await admin.query(`DROP DATABASE ${name}`);
    }
  } finally { await admin.end(); }
}
