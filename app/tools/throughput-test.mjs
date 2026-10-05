// Real UDP -> HTTP -> production Dart collector/journal -> HTTP -> PostgreSQL.
// Requires TEST_DATABASE_URL and Flutter. Temporary test records are cleaned up.
import { Worker } from 'node:worker_threads';
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { existsSync } from 'node:fs';
import { mkdtemp, rm } from 'node:fs/promises';
import os from 'node:os';
import express from '../apps/api/node_modules/express/index.js';
import cors from '../apps/api/node_modules/cors/lib/index.js';
import { createApp } from '../apps/api/src/app.js';
import { PostgresStore } from '../apps/api/src/postgres-store.js';
import { startDeviceListener } from '../apps/api/src/device-listener.js';
import { timestampMicros } from '../apps/api/src/sample-time.js';
if (!process.env.TEST_DATABASE_URL) throw new Error('TEST_DATABASE_URL is required (local test database).');
const frames = Number(process.env.THROUGHPUT_FRAMES || 60000);
const fps = Number(process.env.THROUGHPUT_FPS || 1000);
const uploadDelayMs = Number(process.env.THROUGHPUT_UPLOAD_DELAY_MS ?? 750);
const faults = process.env.THROUGHPUT_FAULTS !== '0';
if (!Number.isSafeInteger(fps) || fps < 100 || fps > 32000 || !Number.isSafeInteger(frames) || frames < fps * 30 || frames % 10) throw new Error('Use integer fps 100–32000 and >=30 seconds of frames in batches of 10');
if (!Number.isSafeInteger(uploadDelayMs) || uploadDelayMs < 0 || uploadDelayMs > 5000) throw new Error('Use upload delay 0–5000 ms');
const store = new PostgresStore(process.env.TEST_DATABASE_URL);
let server, listener, worker, device, browser, browserProfile, viewerTimer, viewerTask, viewerError, api;
let viewerRequests = 0, maxViewerMs = 0;
let observation = null;
const browserMode = process.env.THROUGHPUT_BROWSER === '1';
let stats = null, startedAt = 0, uploadRequests = 0, outageRequests = 0, retryRequests = 0;
try {
  device = await store.createDevice({deviceName:'1kSPS acceptance test', serialNumber:randomUUID()});
  const session = await store.createSession({deviceId:device.deviceId,sessionName:'Synthetic throughput acceptance',startTime:new Date().toISOString()});
  api = createApp(store);
  listener = await startDeviceListener(api, {port:0,host:'127.0.0.1'});
  worker = new Worker(new URL('./throughput-producer.mjs', import.meta.url), {workerData:{port:listener.address().port,frames,fps}});
  worker.on('message', value => { stats = value; });
  worker.on('error', error => { stats = {error:error.message}; });
  const host = express();
  host.use(cors());
  let finishBrowser;
  const browserResult = new Promise(resolve => { finishBrowser = resolve; });
  host.post('/test/result', express.json(), (req,res) => { finishBrowser(req.body); res.json({ok:true}); });
  const benchmarkBuild = fileURLToPath(new URL('../apps/monitor/build/throughput-web/',import.meta.url));
  host.use('/bench', express.static(benchmarkBuild));
  host.get('/test/config', (_req,res) => res.json({sessionId:session.sessionId, frames, fps, faults}));
  host.post('/test/observation', express.json(), (req,res) => { observation = req.body; res.json({ok:true}); });
  host.post('/test/start', (_req,res) => {
    if (startedAt) return res.status(409).json({error:'Already started'});
    startedAt = Date.now(); worker.postMessage('start'); res.json({ok:true});
  });
  host.get('/test/status', (_req,res) => res.json({producer:stats, source:api.locals.deviceSources()[0] ?? null}));
  host.use(async (req,res,next) => {
    if (req.method === 'POST' && req.path.endsWith('/measurements')) {
      uploadRequests++;
      // Database upload outage only: acquisition/paging remains reachable.
      const elapsed = Date.now() - startedAt;
      if (faults && elapsed >= 5000 && elapsed < 15000) {
        outageRequests++;
        await new Promise(resolve => setTimeout(resolve, 1500));
        return res.status(503).json({error:'Synthetic upload outage'});
      }
      // Commit one batch then lose its response. Retrying must not duplicate SQL rows.
      if (faults && uploadRequests === 1) {
        const original = res.json.bind(res);
        res.json = body => {
          if (res.statusCode === 201) { retryRequests++; res.status(503); return original({error:'Synthetic lost commit response'}); }
          return original(body);
        };
      }
      // Successful writes also remain slow: backlog must drain while acquisition
      // continues, rather than letting a fast local database conceal latency.
      await new Promise(resolve => setTimeout(resolve, uploadDelayMs));
    }
    next();
  });
  host.use(api);
  server = host.listen(0, '127.0.0.1');
  await new Promise(resolve => server.once('listening',resolve));
  const url = `http://127.0.0.1:${server.address().port}`;
  if (process.env.THROUGHPUT_VIEWER === '1') {
    viewerTimer = setInterval(() => {
      if (viewerTask) return;
      viewerTask = (async () => {
        const start = Date.now();
        try {
          const response = await fetch(`${url}/api/sessions/${session.sessionId}?recent=1`, {signal:AbortSignal.timeout(5000)});
          if (!response.ok) throw new Error(`Viewer HTTP ${response.status}`);
          const history = await response.json();
          if (history.measurements.length > 16000 || history.measurements.length % 16) throw new Error('Invalid bounded viewer history');
          viewerRequests++; maxViewerMs = Math.max(maxViewerMs,Date.now()-start);
        } catch (error) { viewerError ??= error; }
      })().finally(() => { viewerTask = null; });
    },1000);
  }
  const flutter = process.argv[2] || 'flutter';
  const args = browserMode ? ['build','web','--no-pub','--no-web-resources-cdn','--no-wasm-dry-run',
      '--target=test/throughput_browser_main.dart','--output=build/throughput-web','--base-href=/bench/',`--dart-define=THROUGHPUT_URL=${url}`]
    : ['test','--no-pub','--reporter','expanded','test/throughput_acceptance_test.dart',`--dart-define=THROUGHPUT_URL=${url}`];
  // Windows .bat files need a shell. Invoke the SDK's cached tool directly
  // instead, so paths/arguments remain separate even when they contain spaces.
  let executable = flutter;
  const env = {...process.env};
  if (process.platform === 'win32') {
    if (!path.isAbsolute(flutter)) throw new Error('Pass an absolute Flutter SDK bin/flutter.bat path on Windows');
    const sdk = path.dirname(path.dirname(flutter));
    executable = path.join(sdk,'bin/cache/dart-sdk/bin/dart.exe');
    const snapshot = path.join(sdk,'bin/cache/flutter_tools.snapshot');
    if (!existsSync(executable) || !existsSync(snapshot)) throw new Error('Initialize the Flutter SDK before running acceptance');
    args.unshift(`--packages=${path.join(sdk,'packages/flutter_tools/.dart_tool/package_config.json')}`,snapshot);
    env.FLUTTER_ROOT = sdk;
  }
  const child = spawn(executable, args,
      {cwd:fileURLToPath(new URL('../apps/monitor/',import.meta.url)),env,stdio:'inherit',windowsHide:true});
  const code = await new Promise((resolve,reject) => {child.on('exit',resolve);child.on('error',reject);});
  if (code !== 0) throw new Error(`Dart acceptance test exited ${code}`);
  if (browserMode) {
    const chrome = process.env.CHROME_EXECUTABLE;
    if (!chrome || !existsSync(chrome)) throw new Error('Set CHROME_EXECUTABLE to an installed Chrome executable');
    browserProfile = await mkdtemp(path.join(os.tmpdir(),'capstone-throughput-chrome-'));
    browser = spawn(chrome, ['--headless','--no-sandbox','--no-first-run','--no-default-browser-check',
        '--disable-background-timer-throttling',`--user-data-dir=${browserProfile}`,`${url}/bench/`],{windowsHide:true,stdio:'ignore'});
    let timeout;
    try {
      const result = await Promise.race([browserResult,
        new Promise((_,reject) => { timeout=setTimeout(() => reject(new Error('Browser acceptance timed out')), frames/fps*1000+180000); }),
        new Promise((_,reject) => browser.once('error',reject))]);
      if (!result.ok) throw new Error(`Browser acceptance failed: ${result.error}\n${result.stack}`);
      console.log('BROWSER_THROUGHPUT_RESULT '+JSON.stringify(result.result));
    } finally { clearTimeout(timeout); }
  }
  clearInterval(viewerTimer); await viewerTask;
  if (viewerError) throw viewerError;
  if (!stats || stats.generated !== frames || stats.sent !== frames || stats.sendErrors) throw new Error(`Generator failure: ${JSON.stringify(stats)}`);
  const source = api.locals.deviceSources()[0];
  if (source.uniqueFrames !== frames || source.missingFrames || source.invalidFrames) throw new Error('UDP reception lost frames');
  const count = (await store.pool.query('SELECT count(*)::int AS rows, count(DISTINCT recorded_at)::int AS frames FROM measurement WHERE session_id=$1',[session.sessionId])).rows[0];
  if (count.rows !== frames * 16 || count.frames !== frames) throw new Error(`SQL frame loss: ${JSON.stringify(count)}`);
  // Verify every stored channel, using bounded keyset reads (no million-row JSON).
  let after = null, sequence = 0, firstUs = null, lastUs = null;
  while (sequence < frames) {
    const {rows} = await store.pool.query(`SELECT to_char(recorded_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS recorded_at,channel,voltage FROM measurement WHERE session_id=$1 AND ($2::timestamptz IS NULL OR recorded_at>$2) ORDER BY measurement.recorded_at,channel LIMIT 16000`,[session.sessionId,after]);
    if (!rows.length || rows.length % 16) throw new Error('Incomplete SQL frame');
    for (let i=0;i<rows.length;i++) {
      const channel=i%16, seq=sequence+Math.floor(i/16);
      const expected=Math.round(1e6*(Math.sin(seq/500+channel/4)+channel/20))/1e6;
      if (rows[i].channel!==channel || Math.abs(rows[i].voltage-expected)>1e-12) throw new Error(`Corrupt SQL voltage at ${seq}/${channel}`);
      const us = timestampMicros(rows[i].recorded_at);
      firstUs ??= us;
      if (us - firstUs !== BigInt(seq) * 1_000_000n / BigInt(fps)) throw new Error(`Distorted SQL sample timing at ${seq}/${channel}`);
      lastUs = us;
    }
    sequence += rows.length/16; after=rows.at(-1).recorded_at;
  }
  if (faults && (!outageRequests || retryRequests!==1)) throw new Error('Outage/retry scenarios did not run');
  console.log('THROUGHPUT_RESULT '+JSON.stringify({fps, uploadDelayMs, viewerRequests, maxViewerMs, recordedSpanUs:Number(lastUs-firstUs), everyTimestampVerified:true, runtime:process.env.THROUGHPUT_BROWSER === '1' ? 'chrome' : 'dart-vm', ...stats, ...count, outageRequests, retryRequests,
      missingFrames:source.missingFrames, invalidFrames:source.invalidFrames, actualReceiveBufferBytes:listener.getRecvBufferSize(), allVoltagesVerified:true}));
  console.log('CAPACITY_RESULT '+JSON.stringify({passed:true,runtime:browserMode?'chrome':'dart-vm',fps,frames,faults,uploadDelayMs,viewerRequests,maxViewerMs,producer:stats,collector:observation,
    rows:count.rows,missingFrames:source.missingFrames,invalidFrames:source.invalidFrames,everyTimestampVerified:true,allVoltagesVerified:true}));
} catch (error) {
  const source = api?.locals.deviceSources()[0];
  console.log('CAPACITY_RESULT '+JSON.stringify({passed:false,runtime:browserMode?'chrome':'dart-vm',fps,frames,faults,uploadDelayMs,viewerRequests,maxViewerMs,producer:stats,collector:observation,
    received:source?.uniqueFrames,missingFrames:source?.missingFrames,invalidFrames:source?.invalidFrames,error:error.message}));
  throw error;
} finally {
  clearInterval(viewerTimer); await viewerTask;
  if (browser) {
    const closed = new Promise(resolve => browser.once('exit',resolve));
    browser.kill(); await Promise.race([closed, new Promise(resolve => setTimeout(resolve,3000))]);
  }
  if (browserProfile) {
    // Delete only our explicitly created temporary browser profile.
    const root=path.resolve(os.tmpdir())+path.sep;
    const target=path.resolve(browserProfile);
    if (target.startsWith(root) && path.basename(target).startsWith('capstone-throughput-chrome-')) {
      await rm(target,{recursive:true,force:true,maxRetries:5,retryDelay:200});
    }
  }
  await worker?.terminate();
  listener?.close();
  if (server) await new Promise(resolve => server.close(resolve));
  if (device) {
    await store.pool.query('DELETE FROM test_session WHERE device_id=$1',[device.deviceId]);
    await store.pool.query('DELETE FROM monitor_device WHERE device_id=$1',[device.deviceId]);
  }
  await store.pool.end();
}
