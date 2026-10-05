// Repeatable, hardware-free preflight using actual loopback UDP + authenticated HTTP.
import assert from 'node:assert/strict';
import { mkdir, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { startDemo } from './demo.js';

const demo = await startDemo({ port: 0, udpPort: 0, serveWeb: false });
let token;
const phases = [];
const request = async (path, body) => {
  const response = await fetch(`${demo.url}/api${path}`, {method: body ? 'POST' : 'GET',
    headers: {'Content-Type': 'application/json', ...(token ? {Authorization: `Bearer ${token}`} : {})},
    ...(body ? {body: JSON.stringify(body)} : {})});
  const result = response.status === 204 ? null : await response.json();
  assert.ok(response.ok, `${path}: ${JSON.stringify(result)}`);
  return result;
};
try {
  assert.equal((await fetch(`${demo.url}/api/device-sources`)).status, 401);
  token = (await request('/auth/login', {username: demo.username, password: demo.password})).token;
  for (const [scenario, duration] of [['baseline',2000], ['load',3000], ['loss',3000], ['corrupt',2000], ['outage',5500], ['load',2000]]) {
    const before = await request('/simulation', {scenario});
    const started = Date.now();
    await new Promise(resolve => setTimeout(resolve, duration));
    const after = await request('/simulation');
    const previous = before.sources[0] || {};
    const source = after.sources[0];
    assert.ok(source, 'No UDP sender discovered');
    const phase = { scenario, elapsedMs: Date.now()-started,
      generated: after.generatedFrames-before.generatedFrames,
      received: source.receivedFrames-(previous.receivedFrames || 0),
      injectedDrops: after.injectedDroppedFrames-before.injectedDroppedFrames,
      observedGaps: source.missingFrames-(previous.missingFrames || 0),
      crcErrors: source.crcErrors-(previous.crcErrors || 0),
      framesPerSecond: source.framesPerSecond, offline: source.stale };
    phases.push(phase);
    if (scenario === 'outage') assert.equal(source.stale, true);
    else assert.equal(source.stale, false);
    if (scenario === 'loss') assert.ok(phase.injectedDrops > 0 && phase.observedGaps > 0);
    if (scenario === 'corrupt') assert.ok(phase.crcErrors > 0);
    if (scenario === 'load') assert.ok(phase.received > 0);
    console.log(`${scenario}: ${phase.received} valid frames; ${phase.observedGaps} sequence gaps; ${phase.crcErrors} CRC errors; ${source.stale ? 'OFFLINE' : 'LIVE'}`);
  }
  const paired = await request('/device-sources/pair', {sourceIp: '127.0.0.1'});
  const session = await request('/sessions', {deviceId: paired.deviceId, sessionName: 'Network preflight', startTime: '2020-01-01T00:00:00Z'});
  const {frame} = await request('/device-input?sourceIp=127.0.0.1');
  await request(`/sessions/${session.sessionId}/measurements`, {samples: [{recordedAt: frame.recordedAt, channels: frame.channels}]});
  const history = await request(`/sessions/${session.sessionId}`);
  assert.equal(history.measurements.length, 16);
  const final = await request('/simulation', {scenario: 'stopped'});
  await request('/auth/logout', {});
  assert.equal((await fetch(`${demo.url}/api/sessions`, {headers: {Authorization: `Bearer ${token}`}})).status, 401);
  const dir = fileURLToPath(new URL('../.local/', import.meta.url));
  await mkdir(dir, {recursive: true});
  await writeFile(`${dir}/network-demo-report.json`, JSON.stringify({passed: true, recordedAt: new Date().toISOString(),
    transport: 'real loopback UDP; synthetic firmware-v1 frames', storage: 'isolated temporary memory',
    phases, final, checks: ['login gate', 'load', 'injected loss', 'CRC rejection', 'offline detection', 'reconnection', 'pairing', '16-channel upload/readback', 'logout revocation']}, null, 2));
  console.log('PASS. Report: .local/network-demo-report.json');
} finally { await demo.close(); }
