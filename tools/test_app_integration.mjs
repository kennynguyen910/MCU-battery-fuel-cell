import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {decodeDatagram, inspectDatagram} from '../mobile_app/apps/api/src/device-udp.js';
import {createApp} from '../mobile_app/apps/api/src/app.js';
import {MemoryStore} from '../mobile_app/apps/api/src/memory-store.js';

const fixture = JSON.parse(readFileSync(new URL('../contracts/protocol-v1.json', import.meta.url)));
function verify(frame, sample) {
  assert.equal(frame.sequence, sample.sequence);
  assert.equal(frame.timestampUs, sample.timestampUs);
  assert.equal(frame.deviceStatus, sample.status);
  assert.deepEqual(frame.channels, sample.channelsUv.map(value => value / 1_000_000));
}
test('API decodes the firmware C++ golden packet without byte-order or scaling drift', () => {
  verify(decodeDatagram(Buffer.from(fixture.firmwareGolden.udpHex, 'hex'))[0], fixture.firmwareGolden);
  const frames = decodeDatagram(Buffer.from(fixture.batchHex, 'hex'));
  frames.forEach((frame, index) => verify(frame, fixture.benchSamples[index]));
});
test('a corrupt frame is rejected without dropping its valid batch neighbor', () => {
  const bytes = Buffer.from(fixture.batchHex, 'hex'); bytes[30] ^= 1;
  const result = inspectDatagram(bytes);
  assert.equal(result.crcErrors, 1); assert.equal(result.invalidFrames, 1);
  assert.equal(result.frames.length, 1); verify(result.frames[0], fixture.benchSamples[1]);
});
test('firmware batch enters the API but only collector uploads write a session', async () => {
  const store = new MemoryStore();
  const app = createApp(store);
  const server = app.listen(0, '127.0.0.1');
  await new Promise(resolve => server.once('listening', resolve));
  const root = `http://127.0.0.1:${server.address().port}/api`;
  async function request(path, body) {
    const response = await fetch(root + path, {method: body ? 'POST' : 'GET',
      headers: {'Content-Type': 'application/json'}, ...(body ? {body: JSON.stringify(body)} : {})});
    assert.ok(response.ok, `${path}: ${response.status}`); return response.json();
  }
  try {
    app.locals.ingestDeviceDatagram(Buffer.from(fixture.batchHex, 'hex'), '192.168.1.42');
    const paired = await request('/device-sources/pair', {sourceIp: '192.168.1.42'});
    const session = await request('/sessions', {deviceId: paired.deviceId, sessionName: 'Shared wire contract', startTime: '2020-01-01T00:00:00Z'});
    assert.equal((await request(`/sessions/${session.sessionId}`)).measurementCount, 0);
    const page = await request('/device-frames?sourceIp=192.168.1.42&cursorMode=arrival&afterCursor=0&limit=1000');
    assert.equal(page.frames.length, 2);
    await request(`/sessions/${session.sessionId}/measurements`, {samples: page.frames});
    const history = await request(`/sessions/${session.sessionId}`);
    assert.equal(history.measurementCount, 32);
    assert.deepEqual(history.measurements.slice(0, 16).map(row => row.voltage), fixture.benchSamples[0].channelsUv.map(value => value / 1_000_000));
    // Lost HTTP acknowledgments can be retried without duplicating measurements.
    await request(`/sessions/${session.sessionId}/measurements`, {samples: page.frames});
    assert.equal((await request(`/sessions/${session.sessionId}`)).measurementCount, 32);
  } finally { await new Promise(resolve => server.close(resolve)); }
});
