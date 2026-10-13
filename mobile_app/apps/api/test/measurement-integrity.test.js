import test from 'node:test';
import assert from 'node:assert/strict';
import { crc32, inspectDatagram, SAMPLE_STATUS_SIMULATED } from '../src/device-udp.js';
import { DeviceReceiver } from '../src/device-receiver.js';
import { encodeBatch } from '../src/network-simulator.js';

function frame(sequence, time, status = SAMPLE_STATUS_SIMULATED) {
  const f = Buffer.alloc(88);
  f.writeUInt16BE(0x424d); f[2] = 1; f[3] = 1;
  f.writeUInt32BE(sequence, 4); f.writeBigUInt64BE(BigInt(time), 8);
  for (let i = 0; i < 16; i++) f.writeInt32BE((i - 8) * 123456, 16 + i * 4);
  f.writeUInt32BE(status, 80); f.writeUInt32BE(crc32(f.subarray(0, 84)), 84);
  return f;
}
test('UDP decodes all signed channels, exact time and source; simulator always marks frames', () => {
  const f = inspectDatagram(frame(42, 9007199254740993n)).frames[0];
  assert.deepEqual(f.channels, Array.from({length:16}, (_,i)=>(i-8)*123456/1e6));
  assert.equal(f.timestampUs, '9007199254740993');
  assert.equal(f.adcSource, 'SIMULATED');
  assert.equal(f.deviceStatus, SAMPLE_STATUS_SIMULATED);
  assert.equal(inspectDatagram(frame(42, 1000, 0)).frames[0].adcSource, 'UNKNOWN');
  assert.ok(inspectDatagram(encodeBatch(0, 0)).frames.every(f => f.adcSource === 'SIMULATED'));
});
test('batch decodes every frame and rejects only the corrupt neighbor', () => {
  const batch = encodeBatch(100, 2);
  assert.equal(inspectDatagram(batch).frames.length, 10);
  batch[10 + 3 * 88 + 20] ^= 1;
  const result = inspectDatagram(batch);
  assert.equal(result.frames.length, 9);
  assert.equal(result.invalidFrames, 1);
  assert.equal(result.crcErrors, 1);
  assert.deepEqual(result.frames.map(f=>f.sequence), [100,101,102,104,105,106,107,108,109]);
  assert.throws(()=>inspectDatagram(batch.subarray(0,889)));
  batch.writeUInt16BE(11,4);
  assert.throws(()=>inspectDatagram(batch));
});
test('UDP metrics track gap, duplicate, late, wrap and reboot separately', () => {
  const r = new DeviceReceiver({now:()=>10000});
  const ip = '192.168.1.5';
  for (const [seq, ts] of [[100,10000000],[103,10003000],[103,10003000],[102,10002000],[104,10004000],[0,0],[1,1000]]) r.ingest(frame(seq, ts),ip);
  const s = r.get(ip);
  assert.equal(s.missingFrames,2);
  assert.equal(s.duplicateFrames,1);
  assert.equal(s.lateFrames,1);
  assert.equal(s.restartEstimates,1);
  assert.equal(s.adcSource,'SIMULATED');
  assert.equal(s.transport,'UDP');
  assert.equal(s.frame.timestampUs,'1000');
  const wrap = new DeviceReceiver();
  for (const [seq,ts] of [[0xfffffffe,1000],[0xffffffff,2000],[0,3000],[1,4000]]) wrap.ingest(frame(seq,ts),ip);
  assert.equal(wrap.get(ip).missingFrames,0);
  assert.equal(wrap.get(ip).restartEstimates,0);
});
test('forward sequence with regressed device timestamp cannot replace latest', () => {
  const r = new DeviceReceiver(); const ip = '192.168.1.5';
  r.ingest(frame(40,50000),ip); r.ingest(frame(41,49000),ip);
  assert.equal(r.get(ip).invalidTimestamps,1);
  assert.equal(r.get(ip).frame.sequence,40);
});
test('no data, malformed and duplicate traffic cannot keep old data live', () => {
  let now = 10000;
  const r = new DeviceReceiver({now:()=>now});
  const ip = '192.168.1.5';
  assert.equal(r.get(ip).frame,null);
  r.ingest(frame(100,1000000),ip);
  now += 5001;
  r.ingest(frame(100,1000000),ip);
  r.ingest(Buffer.alloc(87),ip);
  const bad = frame(101,1001000); bad[20] ^= 1; r.ingest(bad,ip);
  assert.equal(r.get(ip).stale,true);
  assert.equal(r.get(ip).frameAgeMs,5001);
  assert.equal(r.get(ip).crcErrors,1);
  assert.equal(r.get(ip).invalidDatagrams,2);
  assert.equal(r.get(ip).frame.sequence,100);
  r.ingest(frame(101,1001000,0),ip);
  assert.equal(r.get(ip).stale,false);
  assert.equal(r.get(ip).adcSource,'UNKNOWN');
});
