import dgram from 'node:dgram';
import { performance } from 'node:perf_hooks';
import { crc32 } from './device-udp.js';

export const scenarios = Object.freeze({
  baseline: { label: 'Baseline', fps: 100, dropEvery: 0, corruptEvery: 0 },
  load: { label: 'High load', fps: 1000, dropEvery: 0, corruptEvery: 0 },
  loss: { label: '20% packet loss', fps: 1000, dropEvery: 5, corruptEvery: 0 },
  corrupt: { label: 'CRC corruption', fps: 1000, dropEvery: 0, corruptEvery: 10 },
  outage: { label: 'Network disconnected', fps: 1000, dropEvery: 1, corruptEvery: 0 },
  stopped: { label: 'Stopped', fps: 0, dropEvery: 0, corruptEvery: 0 },
});

// Same wire format as firmware: 10-byte BB envelope plus 10 BM frames.
export function encodeBatch(sequence, batchSequence, fps = 1000) {
  const bytes = Buffer.alloc(890);
  bytes.writeUInt16BE(0x4242, 0); bytes[2] = 1; bytes[3] = 2;
  bytes.writeUInt16BE(10, 4); bytes.writeUInt32BE(batchSequence >>> 0, 6);
  for (let i = 0; i < 10; i++) {
    const frame = bytes.subarray(10 + i * 88, 10 + (i + 1) * 88);
    const seq = (sequence + i) >>> 0;
    frame.writeUInt16BE(0x424d, 0); frame[2] = 1; frame[3] = 1;
    frame.writeUInt32BE(seq, 4);
    frame.writeBigUInt64BE(BigInt(seq) * 1_000_000n / BigInt(fps), 8);
    for (let channel = 0; channel < 16; channel++) {
      frame.writeInt32BE(Math.round(1_000_000 * (Math.sin(seq / 500 + channel / 4) + channel / 20)), 16 + channel * 4);
    }
    frame.writeUInt32BE(crc32(frame.subarray(0, 84)), 84);
  }
  return bytes;
}

export class NetworkSimulator {
  constructor({ port }) {
    this.port = port;
    this.socket = dgram.createSocket('udp4');
    this.socket.on('error', () => this.stats.sendErrors++);
    this.scenario = 'stopped'; this.sequence = 0; this.batch = 0; this.phaseBatch = 0;
    this.stats = { generatedFrames: 0, sentDatagrams: 0, injectedDroppedFrames: 0,
      injectedCorruptFrames: 0, schedulerDroppedFrames: 0, sendErrors: 0 };
    this.credit = 0; this.lastTick = performance.now(); this.closed = false;
    this.timer = setInterval(() => this.tick(), 10);
  }
  setScenario(name) {
    if (!Object.hasOwn(scenarios, name)) throw new Error('Choose baseline, load, loss, corrupt, outage, or stopped');
    this.scenario = name; this.phaseBatch = 0; this.credit = 0; this.lastTick = performance.now();
    return this.snapshot();
  }
  tick() {
    const now = performance.now();
    const profile = scenarios[this.scenario];
    this.credit += (now - this.lastTick) * profile.fps / 1000;
    this.lastTick = now;
    // Bound catch-up after laptop sleep or a long event-loop pause. Record it
    // separately from deliberate network loss, so overload is not hidden.
    const due = Math.floor(this.credit / 10);
    if (due > 50) {
      const skipped = (due - 50) * 10;
      this.stats.schedulerDroppedFrames += skipped;
      this.stats.generatedFrames += skipped;
      this.sequence = (this.sequence + skipped) >>> 0;
      this.credit -= skipped;
    }
    while (this.credit >= 10 && profile.fps > 0) {
      this.credit -= 10;
      this.emitBatch(profile);
    }
  }
  emitBatch(profile) {
    const bytes = encodeBatch(this.sequence, this.batch++);
    this.sequence = (this.sequence + 10) >>> 0; this.phaseBatch++;
    this.stats.generatedFrames += 10;
    if (profile.dropEvery && this.phaseBatch % profile.dropEvery === 0) {
      this.stats.injectedDroppedFrames += 10; return;
    }
    if (profile.corruptEvery && this.phaseBatch % profile.corruptEvery === 0) {
      bytes[26] ^= 1; // Damage one voltage without replacing its CRC.
      this.stats.injectedCorruptFrames++;
    }
    this.socket.send(bytes, this.port, '127.0.0.1', error => {
      if (error) this.stats.sendErrors++; else this.stats.sentDatagrams++;
    });
  }
  snapshot() { return { scenario: this.scenario, ...scenarios[this.scenario], ...this.stats, synthetic: true }; }
  close() {
    if (this.closed) return;
    this.closed = true; clearInterval(this.timer);
    try { this.socket.close(); } catch { /* never sent */ }
  }
}
