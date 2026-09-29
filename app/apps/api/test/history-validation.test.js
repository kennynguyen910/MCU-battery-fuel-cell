// History and Express-parser edge cases. A tiny in-memory server verifies actual
// HTTP status/body behavior without relying on PostgreSQL.
import test from 'node:test';
import assert from 'node:assert/strict';
import { validateRange } from '../src/validation.js';
import { createApp } from '../src/app.js';
import { MemoryStore } from '../src/memory-store.js';

test('time filters reject overflow dates, missing UTC, repeated values, and reversed ranges', () => {
  // These values are parseable or common mistakes but are not valid API ranges.
  for (const from of ['2026-02-30T12:00:00Z', '2026-09-14T12:00:00',
    '2026-09-14T25:00:00Z', ['2026-09-14T12:00:00Z']]) {
    assert.throws(() => validateRange({from}), /valid UTC/);
  }
  assert.throws(() => validateRange({from: '2026-09-14T12:00:01Z', to: '2026-09-14T12:00:00Z'}));
  assert.deepEqual(validateRange({from: '2026-09-14T12:00:00Z'}), {from: '2026-09-14T12:00:00.000Z'});
});

test('malformed JSON returns a useful client error', async () => {
  // Listen on port 0 so Windows chooses a free test port automatically.
  const server = createApp(new MemoryStore()).listen(0, '127.0.0.1');
  await new Promise(resolve => server.once('listening', resolve));
  try {
    const response = await fetch('http://127.0.0.1:' + server.address().port + '/api/test-input', {
      method: 'POST', headers: {'content-type': 'application/json'}, body: '{broken',
    });
    assert.equal(response.status, 400);
    assert.deepEqual(await response.json(), {error: 'Request body must be valid JSON'});
  } finally {
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
  }
});

test('API responses cannot be cached as stale measurement data', async () => {
  // History is live operational data, so browsers must request the latest rows.
  const server = createApp(new MemoryStore()).listen(0, '127.0.0.1');
  await new Promise(resolve => server.once('listening', resolve));
  try {
    const response = await fetch('http://127.0.0.1:' + server.address().port + '/api/sessions');
    assert.equal(response.status, 200);
    assert.equal(response.headers.get('cache-control'), 'no-store');
  } finally {
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
  }
});
