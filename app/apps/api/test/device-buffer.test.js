import test from 'node:test';
import assert from 'node:assert/strict';
import { createApp } from '../src/app.js';
import { MemoryStore } from '../src/memory-store.js';
import { DeviceReceiver, MAX_BUFFERED_FRAMES } from '../src/device-receiver.js';
import { encodeBatch } from '../src/network-simulator.js';
import { timestampMicros } from '../src/sample-time.js';

test('ring paging preserves chronology through repeated non-batch-aligned wraps', () => {
  const receiver = new DeviceReceiver({capacity:37, now:() => 100000});
  for (let i=0;i<1000;i++) receiver.ingest(encodeBatch(i*10,i),'127.0.0.1');
  const first = receiver.page('127.0.0.1',0,undefined,13);
  assert.equal(first.missedFrames,9963);
  let cursor=first.nextCursor;
  const frames=[...first.frames];
  while (cursor<10000) {
    const page=receiver.page('127.0.0.1',cursor,first.streamId,13);
    assert.equal(page.missedFrames,0); frames.push(...page.frames); cursor=page.nextCursor;
  }
  assert.deepEqual(frames.map(f=>f.sequence),Array.from({length:37},(_,i)=>9963+i));
  assert.equal(receiver.get('127.0.0.1').bufferedFrames,37);
  assert.equal(receiver.get('127.0.0.1').bufferCapacity,37);
});

test('arrival paging never skips a full page and gives every batched frame a unique timestamp', () => {
  const receiver = new DeviceReceiver({now: () => 100000});
  for(let i=0;i<250;i++) receiver.ingest(encodeBatch(i*10,i),'127.0.0.1');
  const collected=[];
  let cursor=0;
  do {
    const page=receiver.page('127.0.0.1',cursor,undefined,1000);
    collected.push(...page.frames); cursor=page.nextCursor;
    if(!page.hasMore) break;
  } while(true);
  assert.equal(collected.length,2500);
  assert.equal(new Set(collected.map(f=>f.recordedAt)).size,2500);
  assert.deepEqual(collected.map(f=>f.sequence),Array.from({length:2500},(_,i)=>i));
});

test('arrival cursors report reader-specific overflow and receiver replacement', () => {
  const receiver=new DeviceReceiver();
  for(let i=0;i<MAX_BUFFERED_FRAMES/10+2;i++) receiver.ingest(encodeBatch(i*10,i),'127.0.0.1');
  const page=receiver.page('127.0.0.1',0,undefined,1000);
  assert.equal(page.missedFrames,20);
  assert.equal(receiver.page('127.0.0.1',page.nextCursor,page.streamId,1000).missedFrames,0);
  const reset=receiver.page('127.0.0.1',999,'old-server',1000);
  assert.equal(reset.streamReset,true);
  assert.deepEqual(reset.frames,[]);
});

test('arrival cursor continues through a device sequence restart', () => {
  const receiver=new DeviceReceiver();
  receiver.ingest(encodeBatch(2000,1),'127.0.0.1');
  const baseline=receiver.page('127.0.0.1',null,undefined,1000);
  receiver.ingest(encodeBatch(0,0),'127.0.0.1');
  const page=receiver.page('127.0.0.1',baseline.nextCursor,baseline.streamId,1000);
  assert.equal(page.streamReset,false);
  assert.deepEqual(page.frames.map(f=>f.sequence),[0,1,2,3,4,5,6,7,8,9]);
  assert.equal(page.nextCursor,20);
  const times = page.frames.map(f=>timestampMicros(f.recordedAt));
  for (let i=1;i<times.length;i++) assert.equal(times[i]-times[i-1],1000n);
});

// Start the real Express app on a temporary port, then feed it wire-format
// batches exactly as the UDP listener would.
async function startApp() {
  const app = createApp(new MemoryStore());
  const server = app.listen(0);
  await new Promise(resolve => server.once('listening', resolve));
  return { app, server, base: `http://127.0.0.1:${server.address().port}` };
}

function ingestBatches(app, firstSequence, batches) {
  for (let i = 0; i < batches; i += 1) {
    app.locals.ingestDeviceDatagram(encodeBatch(firstSequence + i * 10, i), '127.0.0.1');
  }
}

test('device-frames pages the buffer from a sequence cursor', async () => {
  const { app, server, base } = await startApp();
  try {
    ingestBatches(app, 0, 3); // sequences 0..29
    // No cursor: only the baseline, so a new capture never replays history.
    const baseline = await (await fetch(`${base}/api/device-frames?sourceIp=127.0.0.1`)).json();
    assert.deepEqual(baseline.frames, []);
    assert.equal(baseline.lastSequence, 29);
    // Cursor mid-stream: every newer frame, oldest first, nothing skipped.
    const page = await (await fetch(`${base}/api/device-frames?sourceIp=127.0.0.1&afterSequence=5`)).json();
    assert.equal(page.frames.length, 24);
    assert.equal(page.frames[0].sequence, 6);
    assert.equal(page.frames.at(-1).sequence, 29);
    assert.ok(page.frames.every(f => f.frameId && f.recordedAt && f.channels.length === 16));
    assert.equal(page.lastSequence, 29);
    // Limit pages large backlogs; unknown sources return an empty baseline.
    const limited = await (await fetch(`${base}/api/device-frames?sourceIp=127.0.0.1&afterSequence=5&limit=3`)).json();
    assert.deepEqual(limited.frames.map(f => f.sequence), [6, 7, 8]);
    const unknown = await (await fetch(`${base}/api/device-frames?sourceIp=192.0.2.1`)).json();
    assert.deepEqual(unknown.frames, []);
    assert.equal(unknown.lastSequence, null);
  } finally {
    await new Promise(resolve => server.close(resolve));
  }
});

test('device-frames rejects malformed parameters', async () => {
  const { server, base } = await startApp();
  try {
    for (const query of [
      'sourceIp=not-an-ip',
      'afterSequence=-1', 'afterSequence=abc', 'afterSequence=4294967296',
      'limit=0', 'limit=1001', 'limit=1.5',
    ]) {
      assert.equal((await fetch(`${base}/api/device-frames?${query}`)).status, 400, query);
    }
  } finally {
    await new Promise(resolve => server.close(resolve));
  }
});

test('device-frames keeps collecting across uint32 sequence wraparound', async () => {
  const { app, server, base } = await startApp();
  try {
    app.locals.ingestDeviceDatagram(encodeBatch(0xfffffff0, 0), '127.0.0.1');
    app.locals.ingestDeviceDatagram(encodeBatch(0xfffffffa, 1), '127.0.0.1');
    const page = await (await fetch(
        `${base}/api/device-frames?sourceIp=127.0.0.1&afterSequence=4294967288`)).json();
    assert.deepEqual(page.frames.map(f => f.sequence),
        [0xfffffff9, 0xfffffffa, 0xfffffffb, 0xfffffffc, 0xfffffffd,
          0xfffffffe, 0xffffffff, 0, 1, 2, 3]);
  } finally {
    await new Promise(resolve => server.close(resolve));
  }
});

test('buffer stays bounded and reports overflow', () => {
  const receiver = new DeviceReceiver();
  const batches = MAX_BUFFERED_FRAMES / 10 + 2; // 20 frames beyond the cap
  for (let i = 0; i < batches; i += 1) {
    receiver.ingest(encodeBatch(i * 10, i), '10.0.0.9');
  }
  const page = receiver.framesAfter('10.0.0.9', 0, MAX_BUFFERED_FRAMES + 100);
  assert.equal(page.frames.length, MAX_BUFFERED_FRAMES);
  assert.equal(page.frames[0].sequence, 20); // the oldest 20 were evicted
  assert.equal(page.bufferDroppedFrames, 20);
  // Public source views must not serialize the whole buffer into list responses.
  assert.equal(receiver.get('10.0.0.9').recent, undefined);
  assert.equal(receiver.get('10.0.0.9').bufferDroppedFrames, 20);
});
