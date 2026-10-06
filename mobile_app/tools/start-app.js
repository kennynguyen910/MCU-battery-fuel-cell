// Normal persistent app launcher. Capture and simulation always start stopped.
import { spawn, execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import dotenv from '../apps/api/node_modules/dotenv/lib/main.js';

const root = fileURLToPath(new URL('../', import.meta.url));
dotenv.config({path: path.join(root, '.env'), quiet: true});
// The one-click app is self-contained and persistent. Cloud settings stay in
// .env and are selected only with --configured-database.
const configuredDatabase = process.argv.includes('--configured-database');
if (!configuredDatabase) {
  process.env.DATABASE_URL = 'postgresql://capstone@127.0.0.1:55432/capstone';
  process.env.DATABASE_SSL_CA = '';
}
const port = Number(process.env.PORT || 3001);
const apiUrl = `http://127.0.0.1:${port}`;
const pageUrl = `http://localhost:5173/?api=${encodeURIComponent(apiUrl)}#/mobile`;
const children = [];
let stopping = false;
function stop(code = 0) {
  if (stopping) return;
  stopping = true;
  for (const child of children) child.kill();
  process.exitCode = code;
}
async function health(url) {
  try {
    const response = await fetch(url, {signal: AbortSignal.timeout(2000)});
    return response.ok ? await response.json() : null;
  } catch { return null; }
}
async function start(script, url, matches) {
  const current = await health(url);
  if (current) {
    if (!matches(current)) throw new Error(`A different service occupies ${url}. Close it before launching Capstone.`);
    return;
  }
  const child = spawn(process.execPath, [path.join(root, script)], {
    cwd: root, windowsHide: true, stdio: 'inherit',
  });
  children.push(child);
  let failure;
  child.on('error', error => { failure = error; });
  child.on('exit', code => {
    failure = new Error(`${script} stopped (${code}). Check the error above.`);
    if (!stopping) stop(1);
  });
  for (let attempt = 0; attempt < 30; attempt++) {
    if (failure) throw failure;
    const result = await health(url);
    if (result && matches(result)) return;
    await new Promise(resolve => setTimeout(resolve, 500));
  }
  throw new Error(`Cannot reach ${url}. Check the configured database connection and network.`);
}
try {
  if (!process.env.DATABASE_URL) throw new Error('Set DATABASE_URL in .env; the normal app requires persistent PostgreSQL storage.');
  if (!process.env.APP_USERNAME || !process.env.APP_PASSWORD) throw new Error('Set APP_USERNAME and APP_PASSWORD in .env before starting.');
  const database = new URL(process.env.DATABASE_URL);
  if (['localhost', '127.0.0.1'].includes(database.hostname) && database.port === '55432') {
    execFileSync(process.execPath, [path.join(root, 'tools/start-postgres.js')], {stdio: 'inherit', windowsHide: true});
  }
  const expectedLocation = ['localhost', '127.0.0.1'].includes(database.hostname) ? 'local' : 'remote';
  await start('apps/api/src/server.js', `${apiUrl}/health`, value => value.service === 'capstone' && value.storage === 'postgres' && value.storageLocation === expectedLocation && value.networkSimulation === (process.env.NETWORK_SIMULATION_ENABLED === '1') && value.deviceReceiver === (process.env.DEVICE_UDP_ENABLED === '1' || Boolean(process.env.DEVICE_IP)));
  // Do not silently reuse an old API that is still running without login.
  const auth = await health(`${apiUrl}/api/auth/status`);
  if (!auth?.enabled || auth.demo) throw new Error('Close the old API window and run Start_Capstone.cmd again to apply login settings.');
  if (!auth.sessionOwnership) throw new Error('An older API is running. Close its launcher/API and run Start_Capstone.cmd again to activate session ownership.');
  const response = await fetch(`${apiUrl}/api/auth/login`, {
    method: 'POST', headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({username: process.env.APP_USERNAME, password: process.env.APP_PASSWORD}),
    signal: AbortSignal.timeout(5000),
  });
  if (!response.ok) throw new Error('The running API has different login settings. Close its window and run Start_Capstone.cmd again.');
  const {token} = await response.json();
  await fetch(`${apiUrl}/api/auth/logout`, {method: 'POST', headers: {Authorization: `Bearer ${token}`}, signal: AbortSignal.timeout(5000)});
  await start('apps/api/src/preview.js', 'http://127.0.0.1:5173/preview-health', value => value.service === 'capstone-web');
  console.log(`\nCapstone ready. Username: ${process.env.APP_USERNAME}\nStorage: ${configuredDatabase ? 'configured PostgreSQL database' : 'persistent local PostgreSQL (separate from cloud data)'}\nCollector: ${pageUrl}\nKeep this window open. Ctrl+C stops services started by this launcher.\nCapture and network simulation are stopped until you choose to start them.`);
  if (!process.argv.includes('--no-open')) {
    const browser = spawn('rundll32.exe', ['url.dll,FileProtocolHandler', pageUrl], {windowsHide: true, stdio: 'ignore'});
    browser.on('error', error => console.error(`Open the Collector link above: ${error.message}`));
    browser.unref();
  }
} catch (error) { console.error(error.message); stop(1); }
process.on('SIGINT', () => stop());
process.on('SIGTERM', () => stop());
