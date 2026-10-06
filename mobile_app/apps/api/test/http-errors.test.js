// Public error-contract tests. Clients should receive stable, safe JSON even when
// request paths, identifiers, or internal dependencies fail.
import test from 'node:test';
import assert from 'node:assert/strict';
import {createApp} from '../src/app.js';
import {MemoryStore} from '../src/memory-store.js';

async function withServer(store, callback) {
  // Always close sockets so the Node test process can exit cleanly.
  const server = createApp(store).listen(0, '127.0.0.1');
  await new Promise(resolve => server.once('listening', resolve));
  try {
    await callback('http://127.0.0.1:' + server.address().port);
  } finally {
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
  }
}

test('returns stable JSON errors for bad routes, identifiers, and bodies', async () => {
  // Exercise routes through HTTP rather than calling validators directly.
  await withServer(new MemoryStore(), async base => {
    let response = await fetch(base + '/does-not-exist');
    assert.equal(response.status, 404);
    assert.deepEqual(await response.json(), {error: 'Route not found'});

    response = await fetch(base + '/api/sessions/not-a-uuid');
    assert.equal(response.status, 400);
    assert.match((await response.json()).error, /valid UUID/);

    response = await fetch(base + '/api/devices', {
      method: 'POST', headers: {'content-type': 'application/json'},
      body: JSON.stringify({deviceName: '   ', serialNumber: 'X'}),
    });
    assert.equal(response.status, 400);

    response = await fetch(base + '/api/sessions', {
      method: 'POST', headers: {'content-type': 'application/json'},
      body: JSON.stringify({
        deviceId: '10000000-0000-4000-8000-000000000000',
        sessionName: 'Test', startTime: '2026-09-14T12:00:00',
      }),
    });
    assert.equal(response.status, 400);
    assert.match((await response.json()).error, /timezone/);
  });
});

test('does not expose unexpected internal error details', async () => {
  // Replace one store method with a secret-bearing failure, then prove the body
  // contains only the generic public message.
  const store = new MemoryStore();
  store.listDevices = async () => { throw new Error('secret connection detail'); };
  const originalError = console.error;
  console.error = () => {};
  try {
    await withServer(store, async base => {
      const response = await fetch(base + '/api/devices');
      assert.equal(response.status, 500);
      assert.deepEqual(await response.json(), {error: 'Internal server error'});
    });
  } finally {
    console.error = originalError;
  }
});
