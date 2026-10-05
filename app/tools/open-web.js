// Start missing services, wait for readiness, then open the compiled website.
import {spawn} from 'node:child_process';
import {mkdirSync, openSync, closeSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import path from 'node:path';
const root = fileURLToPath(new URL('../', import.meta.url));
// Only known local pages are accepted, never arbitrary shell command text.
const pageUrl = process.argv.includes('--input')
  ? 'http://localhost:5173/?preview=input#/input'
  : 'http://localhost:5173/';
async function ready(url) {
  try { return (await fetch(url, {signal: AbortSignal.timeout(2000)})).ok; }
  catch { return false; }
}
async function ensure(script, url, logName) {
  if (await ready(url)) return;
  mkdirSync(path.join(root, '.local'), {recursive: true});
  const log = openSync(path.join(root, '.local', logName), 'a');
  const child = spawn(process.execPath, [path.join(root, script)], {
    cwd: root, detached: true, windowsHide: true, stdio: ['ignore', log, log],
  });
  closeSync(log);
  let failed = false;
  child.on('error', () => { failed = true; });
  child.unref();
  for (let attempt = 0; attempt < 30; attempt++) {
    if (await ready(url)) return;
    if (failed) break;
    await new Promise(resolve => setTimeout(resolve, 500));
  }
  throw new Error(`Service unavailable: ${url}. See .local/${logName}.`);
}
try {
  await ensure('apps/api/src/server.js', 'http://127.0.0.1:3001/health', 'api-launch.log');
  await ensure('apps/api/src/preview.js', 'http://127.0.0.1:5173/', 'web-launch.log');
  const browser = spawn('cmd.exe', ['/d', '/c', 'start', '', pageUrl],
    {windowsHide: true, stdio: 'ignore'});
  browser.on('error', error => { console.error(error.message); process.exitCode = 1; });
  console.log(`Web app ready: ${pageUrl}`);
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
