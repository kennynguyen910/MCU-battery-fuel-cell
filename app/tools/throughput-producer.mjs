// Independent worker: API/SQL pauses cannot slow the generator and mask loss.
import { parentPort, workerData } from 'node:worker_threads';
import dgram from 'node:dgram';
import { performance } from 'node:perf_hooks';
import { encodeBatch } from '../apps/api/src/network-simulator.js';
const socket = dgram.createSocket('udp4');
let generated = 0, sent = 0, sendErrors = 0, timer, start;
socket.on('error', () => sendErrors++);
parentPort.on('message', message => {
  if (message === 'start' && !timer) {
    start = performance.now();
    timer = setInterval(() => {
      const due = Math.min(workerData.frames, Math.floor((performance.now() - start) * workerData.fps / 10000) * 10);
      while (generated < due) {
        const bytes = encodeBatch(generated, generated / 10, workerData.fps); generated += 10;
        socket.send(bytes, workerData.port, '127.0.0.1', error => {
          if (error) sendErrors++; else sent += 10;
          if (sent + sendErrors * 10 === workerData.frames) {
            parentPort.postMessage({ generated, sent, sendErrors, elapsedMs: performance.now() - start });
            socket.close();
          }
        });
      }
      if (generated === workerData.frames) clearInterval(timer);
    }, 5);
  }
});
