import test from 'node:test';
import assert from 'node:assert/strict';
import { DeviceReceiver } from '../src/device-receiver.js';
import { encodeBatch, scenarios } from '../src/network-simulator.js';
import { startDemo } from '../../../tools/demo.js';

test('receiver counts gaps, duplicates, late frames and partial corruption without replacing fresh data', () => {
  let now = 100000;
  const receiver = new DeviceReceiver({now: () => now});
  const ip = '127.0.0.1';
  receiver.ingest(encodeBatch(0, 0), ip);
  receiver.ingest(encodeBatch(20, 2), ip);
  assert.equal(receiver.get(ip).missingFrames, 10);
  receiver.ingest(encodeBatch(10, 1), ip);
  assert.equal(receiver.get(ip).lateFrames, 10);
  receiver.ingest(encodeBatch(29, 3).subarray(10, 98), ip);
  assert.equal(receiver.get(ip).duplicateFrames, 1);
  assert.equal(receiver.get(ip).frame.sequence, 29);
  const damaged = encodeBatch(30, 3); damaged[26] ^= 1;
  receiver.ingest(damaged, ip);
  assert.equal(receiver.get(ip).crcErrors, 1);
  assert.equal(receiver.get(ip).invalidFrames, 1);
  assert.equal(receiver.get(ip).missingFrames, 11);
  assert.equal(receiver.get(ip).frame.sequence, 39);
  now += 5001;
  assert.equal(receiver.get(ip).stale, true);
  assert.equal(receiver.get(ip).framesPerSecond, 0);
  receiver.ingest(encodeBatch(40, 4), ip);
  assert.equal(receiver.get(ip).stale, false);
});

test('receiver handles uint32 wrap without an enormous loss estimate', () => {
  const receiver = new DeviceReceiver();
  receiver.ingest(encodeBatch(0xfffffff6, 1), '127.0.0.1');
  receiver.ingest(encodeBatch(0, 2), '127.0.0.1');
  assert.equal(receiver.get('127.0.0.1').missingFrames, 0);
  assert.equal(receiver.get('127.0.0.1').uniqueFrames, 20);
});

test('demo exercises login, real UDP loss/corruption, pairing, capture upload and logout', async () => {
  const demo = await startDemo({port: 0, udpPort: 0, serveWeb: false});
  let token;
  const request = async (path, body) => fetch(`${demo.url}/api${path}`, {
    method: body ? 'POST' : 'GET',
    headers: {'Content-Type': 'application/json', ...(token ? {Authorization: `Bearer ${token}`} : {})},
    ...(body ? {body: JSON.stringify(body)} : {}),
  });
  try {
    assert.equal((await request('/simulation')).status, 401);
    assert.equal((await request('/auth/login', {username: demo.username, password: 'wrong'})).status, 401);
    token = (await (await request('/auth/login', {username: demo.username, password: demo.password})).json()).token;
    const idle = await (await request('/simulation')).json();
    assert.equal(idle.scenario, 'stopped');
    assert.equal(idle.generatedFrames, 0);
    assert.deepEqual(idle.sources, []);
    assert.equal((await request('/simulation', {scenario: 'unknown'})).status, 400);
    demo.simulator.emitBatch(scenarios.baseline);
    demo.simulator.phaseBatch = 0;
    for (let i = 0; i < 100; i++) {
      demo.simulator.emitBatch(scenarios.loss);
      await new Promise(resolve => setTimeout(resolve, 3));
    }
    demo.simulator.phaseBatch = 0;
    for (let i = 0; i < 10; i++) {
      demo.simulator.emitBatch(scenarios.corrupt);
      await new Promise(resolve => setTimeout(resolve, 3));
    }
    for (let i = 0; i < 100; i++) {
      const status = await (await request('/simulation')).json();
      if (status.sources[0]?.lastSequence === 1109) break;
      await new Promise(resolve => setTimeout(resolve, 10));
    }
    const result = await (await request('/simulation')).json();
    assert.equal(result.injectedDroppedFrames, 200);
    assert.equal(result.sources[0].missingFrames, 201);
    assert.equal(result.sources[0].crcErrors, 1);
    assert.equal(result.sources[0].receivedFrames, 909);
    const paired = await (await request('/device-sources/pair', {sourceIp: '127.0.0.1'})).json();
    const session = await (await request('/sessions', {deviceId: paired.deviceId, sessionName: 'Demo test', startTime: '2020-01-01T00:00:00Z'})).json();
    const {frame} = await (await request('/device-input?sourceIp=127.0.0.1')).json();
    const uploaded = await request(`/sessions/${session.sessionId}/measurements`, {samples: [{recordedAt: frame.recordedAt, channels: frame.channels}]});
    assert.equal(uploaded.status, 201);
    assert.equal((await (await request(`/sessions/${session.sessionId}`)).json()).measurements.length, 16);
    await request('/auth/logout', {});
    assert.equal((await request('/simulation')).status, 401);
  } finally { await demo.close(); }
});
