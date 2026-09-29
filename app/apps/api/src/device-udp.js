// Decoder for MCU-battery-fuel-cell protocol v1 (88-byte measurements and
// 10-byte UDP batch envelope). The firmware's monotonic time is not UTC.
const FRAME_SIZE = 88;

export function crc32(bytes) {
  let crc = 0xffffffff;
  for (const byte of bytes) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit += 1) {
      crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
    }
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function frameAt(datagram, offset) {
  const frame = datagram.subarray(offset, offset + FRAME_SIZE);
  if (frame.readUInt16BE(0) !== 0x424d || frame[2] !== 1 || frame[3] !== 1) {
    throw new Error('Invalid measurement header');
  }
  if (crc32(frame.subarray(0, 84)) !== frame.readUInt32BE(84)) {
    throw new Error('Invalid measurement CRC');
  }
  return {
    sequence: frame.readUInt32BE(4),
    timestampUs: frame.readBigUInt64BE(8).toString(),
    channels: Array.from({length: 16}, (_, i) => frame.readInt32BE(16 + i * 4) / 1_000_000),
    deviceStatus: frame.readUInt32BE(80),
  };
}

export function inspectDatagram(datagram) {
  if (!Buffer.isBuffer(datagram)) throw new Error('Expected UDP bytes');
  if (datagram.length === FRAME_SIZE) {
    try { return { frames: [frameAt(datagram, 0)], invalidFrames: 0, crcErrors: 0 }; }
    catch (error) { return { frames: [], invalidFrames: 1, crcErrors: Number(error.message.includes('CRC')) }; }
  }
  if (datagram.length < 10 || datagram.readUInt16BE(0) !== 0x4242 ||
      datagram[2] !== 1 || datagram[3] !== 2) {
    throw new Error('Invalid batch header');
  }
  const count = datagram.readUInt16BE(4);
  if (count < 1 || count > 10 || datagram.length !== 10 + count * FRAME_SIZE) {
    throw new Error('Invalid batch length');
  }
  const frames = [];
  let invalidFrames = 0, crcErrors = 0;
  for (let i = 0; i < count; i += 1) {
    // One damaged frame does not suppress valid neighbors in a sound envelope.
    try { frames.push(frameAt(datagram, 10 + i * FRAME_SIZE)); }
    catch (error) { invalidFrames++; crcErrors += Number(error.message.includes('CRC')); }
  }
  return { frames, invalidFrames, crcErrors };
}

export function decodeDatagram(datagram) {
  const result = inspectDatagram(datagram);
  if (!result.frames.length) throw new Error('No valid frames (header or CRC)');
  return result.frames;
}
