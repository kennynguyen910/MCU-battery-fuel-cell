import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {DeviceReceiver} from '../src/device-receiver.js';
import {encodeBatch} from '../src/network-simulator.js';
import {PostgresStore} from '../src/postgres-store.js';

test('2500 buffered frames survive bulk PostgreSQL writes, retries, and bounded history', {
  skip: !process.env.TEST_DATABASE_URL,
}, async () => {
  const store = new PostgresStore(process.env.TEST_DATABASE_URL);
  try {
    const device = await store.createDevice({deviceName:'Buffered stream test',serialNumber:randomUUID()});
    const session = await store.createSession({deviceId:device.deviceId,sessionName:'Buffered 2500 frame verification',startTime:new Date().toISOString()});
    const receiver = new DeviceReceiver();
    for(let i=0;i<250;i++) receiver.ingest(encodeBatch(i*10,i),'127.0.0.1');
    let cursor=0;
    do {
      const page=receiver.page('127.0.0.1',cursor,undefined,1000);
      await store.addSamples(session.sessionId,page.frames);
      await store.addSamples(session.sessionId,page.frames); // Lost-response retry.
      cursor=page.nextCursor;
      if(!page.hasMore) break;
    } while(true);
    const history=await store.getSession(session.sessionId);
    assert.equal(history.measurements.length,40000);
    assert.equal(new Set(history.measurements.map(r=>r.recordedAt)).size,2500);
    const recent=await store.getSession(session.sessionId,{recent:true});
    assert.equal(recent.measurements.length,16000);
    assert.equal(recent.measurementCount,40000);
    assert.equal(recent.truncated,true);
  } finally { await store.pool.end(); }
});
