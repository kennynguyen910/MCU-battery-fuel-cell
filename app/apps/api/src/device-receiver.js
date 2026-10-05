import { randomUUID } from 'node:crypto';
import { isIP } from 'node:net';
import { inspectDatagram } from './device-udp.js';

// Sequence gaps are estimates: UDP has no acknowledgement or boot identifier.
// First/last unseen losses cannot be inferred; late packets do not undo a gap.

// Collectors poll over HTTP, far slower than the wire rate. A bounded per-source
// buffer lets a polling collector fetch every frame instead of only the latest.
export const MAX_BUFFERED_FRAMES = 60000;

// O(1) retention, O(page size) arrival paging even after hours of capture.
class FrameRing {
  constructor(capacity) { this.capacity = capacity; this.slots = new Array(capacity); this.length = 0; this.head = 0; }
  push(frame) {
    const full = this.length === this.capacity;
    this.slots[(this.head + this.length) % this.capacity] = frame;
    if (full) this.head = (this.head + 1) % this.capacity;
    else this.length++;
    return full;
  }
  at(index) { return this.slots[(this.head + index) % this.capacity]; }
  after(cursor, limit) {
    const start = Math.max(0, cursor + 1 - (this.at(0)?.cursor ?? 1));
    const frames = [];
    for (let i = start; i < this.length && frames.length < limit; i++) frames.push(this.at(i));
    return frames;
  }
  *[Symbol.iterator]() { for (let i = 0; i < this.length; i++) yield this.at(i); }
}

export class DeviceReceiver {
  constructor({ now = Date.now, capacity = MAX_BUFFERED_FRAMES } = {}) {
    if (!Number.isSafeInteger(capacity) || capacity < 1) throw new Error('Invalid receiver capacity');
    this.sources = new Map(); this.now = now; this.capacity = capacity;
  }
  ingest(bytes, sourceIp) {
    if (isIP(sourceIp) !== 4) return;
    if (!this.sources.has(sourceIp) && this.sources.size >= 32) {
      const oldest = [...this.sources.values()].sort((a, b) => a.lastSeen - b.lastSeen)[0];
      this.sources.delete(oldest.sourceIp);
    }
    const now = this.now();
    const source = this.sources.get(sourceIp) || {
      sourceIp, frame: null, receivedFrames: 0, uniqueFrames: 0, receivedDatagrams: 0,
      missingFrames: 0, duplicateFrames: 0, lateFrames: 0, restartEstimates: 0,
      invalidFrames: 0, invalidDatagrams: 0, crcErrors: 0, lastReceivedAt: null,
      lastSequence: null, lastTimestamp: null, rate: [], recent: new FrameRing(this.capacity),
      bufferDroppedFrames: 0, streamId: randomUUID(), lastRecordedMs: 0,
    };
    source.lastSeen = now;
    source.receivedDatagrams++;
    this.sources.set(sourceIp, source);
    let result;
    try { result = inspectDatagram(bytes); }
    catch { source.invalidDatagrams++; return; }
    source.invalidFrames += result.invalidFrames;
    source.crcErrors += result.crcErrors;
    // Preserve the existing all-invalid datagram counter while also counting
    // invalid frames inside partially usable batches.
    if (!result.frames.length) source.invalidDatagrams++;
    let accepted = 0;
    for (const frame of result.frames) {
      source.receivedFrames++;
      const timestamp = BigInt(frame.timestampUs);
      if (source.lastSequence !== null) {
        const delta = (frame.sequence - source.lastSequence) >>> 0;
        const restart = frame.sequence <= 10 && timestamp + 1_000_000n < source.lastTimestamp;
        if (restart) source.restartEstimates++;
        else if (delta === 0) { source.duplicateFrames++; continue; }
        else if (delta >= 0x80000000) { source.lateFrames++; continue; }
        else source.missingFrames += delta - 1;
      }
      source.lastSequence = frame.sequence;
      source.lastTimestamp = timestamp;
      source.uniqueFrames++;
      accepted++;
      source.lastReceivedAt = new Date(now).toISOString();
      // Recover intra-packet timing from the device clock. SQL keys have ms
      // precision, so make timestamps strictly increasing for a <=1 kHz stream.
      // receivedAt remains the actual arrival time; recordedAt is reconstructed.
      const tail = BigInt(result.frames.at(-1).timestampUs);
      const offset = tail >= timestamp ? Number((tail - timestamp) / 1000n) : 0;
      source.lastRecordedMs = Math.max(now - offset, source.lastRecordedMs + 1);
      source.frame = { ...frame, frameId: randomUUID(), cursor: source.uniqueFrames,
        recordedAt: new Date(source.lastRecordedMs).toISOString(), receivedAt: source.lastReceivedAt, sourceIp };
      if (source.recent.push(source.frame)) source.bufferDroppedFrames++;
    }
    source.rate = source.rate.filter(entry => now - entry.time < 1000);
    if (accepted) source.rate.push({ time: now, count: accepted });
  }
  // Frames newer than afterSequence, oldest first, for polling collectors.
  // A null afterSequence returns only the cursor so capture starts at the
  // next frame rather than replaying buffered history into a new session.
  framesAfter(ip, afterSequence, limit) {
    const source = ip ? this.sources.get(ip) : [...this.sources.values()].sort((a, b) => b.lastSeen - a.lastSeen)[0];
    if (!source) return { sourceIp: ip || null, frames: [], lastSequence: null, bufferDroppedFrames: 0 };
    const frames = afterSequence === null ? [] : [...source.recent]
      .filter(frame => {
        const delta = (frame.sequence - afterSequence) >>> 0;
        return delta > 0 && delta < 0x80000000;
      })
      .slice(0, limit);
    return { sourceIp: source.sourceIp, frames, lastSequence: frames.at(-1)?.sequence ?? source.lastSequence,
      bufferDroppedFrames: source.bufferDroppedFrames, stale: this.view(source).stale };
  }

  page(ip, afterCursor, streamId, limit) {
    const source = this.sources.get(ip);
    if (!source) return {frames: [], nextCursor: 0, streamId: null, missedFrames: 0, hasMore: false};
    const reset = Boolean(streamId && streamId !== source.streamId);
    const baseline = afterCursor === null || reset;
    const frames = baseline ? [] : source.recent.after(afterCursor, limit);
    return {sourceIp: ip, streamId: source.streamId, streamReset: reset, frames,
      nextCursor: baseline ? source.uniqueFrames : frames.at(-1)?.cursor ?? afterCursor,
      missedFrames: baseline ? 0 : Math.max(0, (source.recent.at(0)?.cursor ?? 1) - afterCursor - 1),
      hasMore: frames.length > 0 && frames.at(-1).cursor < source.uniqueFrames};
  }

  view(source) {
    const { rate, lastTimestamp, lastRecordedMs, lastSeen, recent, ...publicState } = source;
    return { ...publicState,
      bufferedFrames: recent.length, bufferCapacity: this.capacity,
      framesPerSecond: rate.filter(entry => this.now() - entry.time < 1000).reduce((sum, e) => sum + e.count, 0),
      stale: !source.lastReceivedAt || this.now() - Date.parse(source.lastReceivedAt) > 5000,
      lossPercent: source.uniqueFrames + source.missingFrames === 0 ? 0 :
        100 * source.missingFrames / (source.uniqueFrames + source.missingFrames),
    };
  }
  list() { return [...this.sources.values()].map(source => this.view(source)); }
  get(ip) {
    const source = ip ? this.sources.get(ip) : [...this.sources.values()].sort((a,b) => b.lastSeen-a.lastSeen)[0];
    return source ? this.view(source) : { sourceIp: ip || null, frame: null, receivedFrames: 0,
      invalidDatagrams: 0, lastReceivedAt: null, stale: true, framesPerSecond: 0 };
  }
}
