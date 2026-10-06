import test from 'node:test';
import assert from 'node:assert/strict';
import { createApp } from '../src/app.js';
import { MemoryStore } from '../src/memory-store.js';
import { SingleUserAuth } from '../src/auth.js';
import { crc32, decodeDatagram } from '../src/device-udp.js';
import { startDeviceListener } from '../src/device-listener.js';
import dgram from 'node:dgram';

function fixture() {
  const bytes = Buffer.alloc(88);
  bytes.writeUInt16BE(0x424d, 0);
  bytes[2] = 1; bytes[3] = 1;
  bytes.writeUInt32BE(0x01020304, 4);
  bytes.writeBigUInt64BE(0x0102030405060708n, 8);
  const values = [1234567, -1234567, -2147483648, 2147483647,
    ...Array.from({length: 12}, (_, i) => (i - 4) * 10000)];
  values.forEach((v, i) => bytes.writeInt32BE(v, 16 + i * 4));
  bytes.writeUInt32BE(0xa1b2c3d4, 80);
  bytes.writeUInt32BE(crc32(bytes.subarray(0, 84)), 84);
  return bytes;
}

test('decodes documented frame and batch, rejects tampering', () => {
  const frame = fixture();
  assert.equal(frame.readUInt32BE(84), 0x35aaf680);
  assert.equal(decodeDatagram(frame)[0].channels[1], -1.234567);
  const batch = Buffer.alloc(10 + 2 * 88);
  batch.writeUInt16BE(0x4242, 0);
  batch[2] = 1; batch[3] = 2;
  batch.writeUInt16BE(2, 4);
  frame.copy(batch, 10); frame.copy(batch, 98);
  assert.equal(decodeDatagram(batch).length, 2);
  batch[20] ^= 1;
  assert.equal(decodeDatagram(batch).length, 1);
  assert.throws(() => decodeDatagram(batch.subarray(0, 100)), /length/);
});

test('UDP socket receives a firmware frame and makes it discoverable', async () => {
  const app = createApp(new MemoryStore());
  const listener = await startDeviceListener(app, {port: 0, sourceIp: '127.0.0.1'});
  const sender = dgram.createSocket('udp4');
  const server = app.listen(0);
  await new Promise(resolve => server.once('listening', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    await new Promise((resolve, reject) => sender.send(fixture(), listener.address().port,
      '127.0.0.1', error => error ? reject(error) : resolve()));
    let sources = [];
    for (let i = 0; i < 20; i += 1) {
      sources = await (await fetch(`${base}/api/device-sources`)).json();
      if (sources.length) break;
      await new Promise(resolve => setTimeout(resolve, 10));
    }
    assert.equal(sources[0]?.sourceIp, '127.0.0.1');
    assert.equal(sources[0]?.receivedFrames, 1);
  } finally {
    sender.close();
    listener.close();
    await new Promise(resolve => server.close(resolve));
  }
});

test('user login gates data routes and logout revokes the token', async () => {
  const auth = new SingleUserAuth('student', 'a-long-test-password');
  const app = createApp(new MemoryStore(), {auth});
  const server = app.listen(0);
  await new Promise(resolve => server.once('listening', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    assert.equal((await fetch(`${base}/api/sessions`)).status, 401);
    const bad = await fetch(`${base}/api/auth/login`, {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({username: 'student', password: 'wrong'})});
    assert.equal(bad.status, 401);
    const good = await fetch(`${base}/api/auth/login`, {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({username: 'student', password: 'a-long-test-password'})});
    assert.equal(good.status, 200);
    const {token} = await good.json();
    const headers = {Authorization: `Bearer ${token}`};
    assert.equal((await fetch(`${base}/api/sessions`, {headers})).status, 200);
    assert.equal((await fetch(`${base}/api/auth/logout`, {method: 'POST', headers})).status, 204);
    assert.equal((await fetch(`${base}/api/sessions`, {headers})).status, 401);
  } finally { await new Promise(resolve => server.close(resolve)); }
});

test('UDP ingestion exposes only validated latest device frame', async () => {
  const app = createApp(new MemoryStore());
  const server = app.listen(0);
  await new Promise(resolve => server.once('listening', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    app.locals.ingestDeviceDatagram(fixture(), '192.168.1.50');
    const first = await (await fetch(`${base}/api/device-input`)).json();
    assert.equal(first.receivedFrames, 1);
    assert.equal(first.frame.channels[0], 1.234567);
    assert.equal(first.sourceIp, '192.168.1.50');
    const corrupt = fixture(); corrupt[40] ^= 1;
    app.locals.ingestDeviceDatagram(corrupt, '192.168.1.50');
    const second = await (await fetch(`${base}/api/device-input`)).json();
    assert.equal(second.invalidDatagrams, 1);
    assert.equal(second.frame.frameId, first.frame.frameId);
    app.locals.ingestDeviceDatagram(fixture(), '192.168.1.51');
    const sources = await (await fetch(`${base}/api/device-sources`)).json();
    assert.equal(sources.length, 2);
    assert.ok(sources.every(source => source.deviceId === null));
    const pairedResponse = await fetch(`${base}/api/device-sources/pair`, {
      method: 'POST', headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({sourceIp: '192.168.1.50'}),
    });
    assert.equal(pairedResponse.status, 201);
    const paired = await pairedResponse.json();
    assert.equal(paired.serialNumber, 'ESP32-UDP-192.168.1.50');
    const selected = await (await fetch(`${base}/api/device-input?sourceIp=192.168.1.50`)).json();
    assert.equal(selected.frame.frameId, first.frame.frameId);
    const refreshed = await (await fetch(`${base}/api/device-sources`)).json();
    assert.equal(refreshed.find(source => source.sourceIp === '192.168.1.50').deviceId, paired.deviceId);
    assert.equal(refreshed.find(source => source.sourceIp === '192.168.1.51').deviceId, null);
    assert.equal((await fetch(`${base}/api/device-sources/pair`, {
      method: 'POST', headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({sourceIp: '192.168.1.99'}),
    })).status, 400);
  } finally { await new Promise(resolve => server.close(resolve)); }
});
