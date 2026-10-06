// Standalone, loopback-only demo. No .env loading, cloud access, or shared ports.
import { randomUUID } from 'node:crypto';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { existsSync } from 'node:fs';
import { spawn } from 'node:child_process';
import express from '../apps/api/node_modules/express/index.js';
import { createApp } from '../apps/api/src/app.js';
import { SingleUserAuth } from '../apps/api/src/auth.js';
import { MemoryStore } from '../apps/api/src/memory-store.js';
import { NetworkSimulator } from '../apps/api/src/network-simulator.js';
import { startDeviceListener } from '../apps/api/src/device-listener.js';

export async function startDemo({ port = 3301, udpPort = 15005, serveWeb = true } = {}) {
  const build = fileURLToPath(new URL('../build/web-viewer/', import.meta.url));
  if (serveWeb && !existsSync(`${build}/index.html`)) {
    throw new Error('Build the current web app first: dev.cmd build');
  }
  const password = 'capstone_password';
  const auth = new SingleUserAuth('capstone', password);
  let simulator;
  const simulation = {
    snapshot: () => simulator.snapshot(),
    setScenario: name => simulator.setScenario(name),
  };
  const app = createApp(new MemoryStore(), { auth, simulation, demo: true });
  const listener = await startDeviceListener(app, { port: udpPort, host: '127.0.0.1', sourceIp: '127.0.0.1' });
  simulator = new NetworkSimulator({ port: listener.address().port });
  // createApp has a JSON 404 handler; prepend a separate static host after the API mount.
  const host = express();
  host.use((req, res, next) => req.path.startsWith('/api/') ? app(req, res, next) : next());
  host.get('/health', (_req, res) => res.json({status: 'ok', service: 'capstone-demo', storage: 'temporary memory'}));
  if (serveWeb) host.use(express.static(build));
  const server = host.listen(port, '127.0.0.1');
  try { await new Promise((resolve, reject) => { server.once('listening', resolve); server.once('error', reject); }); }
  catch (error) { simulator.close(); listener.close(); throw error; }
  return { app, server, simulator, password, username: 'capstone',
    url: `http://127.0.0.1:${server.address().port}`,
    close: async () => { simulator.close(); listener.close(); await new Promise(resolve => server.close(resolve)); },
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const demo = await startDemo();
    const query = `?api=${encodeURIComponent(demo.url)}&demo=1&run=${randomUUID()}`;
    console.log(`\nOPTIONAL NETWORK SANDBOX — synthetic data, temporary storage\nUsername: capstone\nPassword: ${demo.password}\n`);
    console.log(`Network lab: ${demo.url}/${query}#/network`);
    console.log(`Collector:   ${demo.url}/${query}#/mobile`);
    console.log(`History:     ${demo.url}/${query}#/`);
    console.log('Keep this window open. Ctrl+C stops the demo. Data resets on restart.');
    if (process.argv.includes('--open')) {
      spawn('rundll32.exe', ['url.dll,FileProtocolHandler', `${demo.url}/${query}#/network`], { windowsHide: true });
    }
    let closing = false;
    for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, async () => {
      if (closing) return; closing = true; await demo.close(); process.exit(0);
    });
  } catch (error) { console.error(`Demo could not start: ${error.message}`); process.exitCode = 1; }
}
