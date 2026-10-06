import dgram from 'node:dgram';
import { isIP } from 'node:net';

export async function startDeviceListener(app, { port = 5005, sourceIp, host = '0.0.0.0', receiveBufferBytes = 4 * 1024 * 1024 } = {}) {
  if (sourceIp && isIP(sourceIp) !== 4) {
    throw new Error('DEVICE_IP must be the ESP32 IPv4 address');
  }
  if (!Number.isInteger(port) || port < 0 || port > 65535) {
    throw new Error('DEVICE_UDP_PORT must be an integer between 1 and 65535');
  }
  const socket = dgram.createSocket('udp4');
  socket.on('message', (bytes, remote) => {
    if (!sourceIp || remote.address === sourceIp) {
      app.locals.ingestDeviceDatagram(bytes, remote.address);
    }
  });
  try {
    await new Promise((resolve, reject) => {
      socket.once('error', reject);
      socket.bind(port, host, resolve);
    });
    // Absorb scheduling/GC pauses before the receiver's application ring.
    socket.setRecvBufferSize(receiveBufferBytes);
  } catch (error) {
    socket.close();
    throw error;
  }
  socket.on('error', error => console.error('Device UDP listener:', error));
  return socket;
}
