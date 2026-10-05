// Express application factory. Dependency-injecting `store` lets the exact same
// routes use PostgreSQL in the app and a lightweight in-memory store in tests.
import cors from "cors";
import express from "express";
import { isIP } from 'node:net';
import { DeviceReceiver } from './device-receiver.js';
import {
  ValidationError, validateDevice, validateRange, validateSamples,
  validateSession, validateUuid,
} from "./validation.js";

export function createApp(store, { auth, simulation, demo = false } = {}) {
  const app = express();
  // Avoid advertising framework details and accept Flutter's JSON requests.
  app.disable('x-powered-by');
  app.use(cors());
  app.use(express.json({ limit: "2mb" }));
  app.use('/api', (_request, response, next) => { response.set('Cache-Control', 'no-store'); next(); });
  app.get('/api/auth/status', (_request, response) => response.json({
    enabled: Boolean(auth), demo, sessionOwnership: Boolean(auth) }));
  app.post('/api/auth/login', async (request, response) => {
    if (!auth) return response.status(503).json({ error: 'Login is not configured' });
    const { username, password } = request.body || {};
    if (typeof username !== 'string' || typeof password !== 'string' ||
        username.length > 100 || password.length > 1000) {
      return response.status(400).json({ error: 'Username and password are required' });
    }
    const result = await auth.login(username, password, request.ip);
    if (result.error) return response.status(result.status).json({ error: result.error });
    response.json(result);
  });
  app.use('/api', (request, response, next) => {
    if (!auth) return next();
    const token = request.get('Authorization')?.match(/^Bearer (\S+)$/)?.[1];
    const principal = auth.principal(token);
    if (!principal) return response.status(401).json({ error: 'Login required' });
    request.authToken = token;
    request.principal = principal;
    // Only the server-resolved identity can set scope; client fields are ignored.
    request.sessionScope = principal.isAdmin ? {} : { ownerUsername: principal.username };
    next();
  });
  app.post('/api/auth/logout', (request, response) => {
    auth?.logout(request.authToken);
    response.status(204).end();
  });

  // Device substitute only: publishing here NEVER writes measurement rows. The
  // mobile collector must receive a frame and upload it into a chosen session.
  let inputFrame = null;
  const receiver = new DeviceReceiver();
  app.locals.ingestDeviceDatagram = (bytes, ip) => receiver.ingest(bytes, ip);
  app.locals.deviceSources = () => receiver.list();
  if (simulation) {
    const report = () => ({ ...simulation.snapshot(), sources: receiver.list().map(({ frame, ...s }) => s),
      storage: store.pool ? 'postgres' : 'temporary memory', generatedAt: new Date().toISOString() });
    app.get('/api/simulation', (_request, response) => response.json(report()));
    app.post('/api/simulation', (request, response) => {
      try { simulation.setScenario(request.body?.scenario); response.json(report()); }
      catch (error) { response.status(400).json({error: error.message}); }
    });
  }
  app.get("/api/test-input", (_request, response) => response.json(inputFrame));
  app.post("/api/test-input", (request, response, next) => {
    try {
      const [sample] = validateSamples([{
        recordedAt: new Date().toISOString(),
        channels: request.body?.channels,
      }]);
      inputFrame = { ...sample, frameId: crypto.randomUUID() };
      response.status(201).json(inputFrame);
    } catch (error) { next(error); }
  });

  // Buffered frame paging for collectors. Unlike /device-input (latest only),
  // this returns every buffered frame after a sequence cursor so a slow HTTP
  // poll can still store the full wire-rate stream.
  app.get('/api/device-frames', (request, response) => {
    const sourceIp = request.query.sourceIp;
    if (sourceIp !== undefined && (typeof sourceIp !== 'string' || isIP(sourceIp) !== 4)) {
      return response.status(400).json({ error: 'sourceIp must be an IPv4 address' });
    }
    const rawAfter = request.query.afterSequence;
    let afterSequence = null;
    if (rawAfter !== undefined) {
      if (typeof rawAfter !== 'string' || !/^\d{1,10}$/.test(rawAfter) || Number(rawAfter) > 0xffffffff) {
        return response.status(400).json({ error: 'afterSequence must be an unsigned 32-bit integer' });
      }
      afterSequence = Number(rawAfter);
    }
    const rawLimit = request.query.limit;
    let limit = 1000;
    if (rawLimit !== undefined) {
      if (typeof rawLimit !== 'string' || !/^\d{1,4}$/.test(rawLimit) ||
          Number(rawLimit) < 1 || Number(rawLimit) > 1000) {
        return response.status(400).json({ error: 'limit must be an integer between 1 and 1000' });
      }
      limit = Number(rawLimit);
    }
    if (request.query.cursorMode === 'arrival') {
      if (!sourceIp) return response.status(400).json({error: 'sourceIp is required'});
      const cursor = request.query.afterCursor;
      const streamId = request.query.streamId;
      if ((cursor !== undefined && (typeof cursor !== 'string' || !/^\d+$/.test(cursor) || !Number.isSafeInteger(Number(cursor)))) ||
          (streamId !== undefined && (typeof streamId !== 'string' || streamId.length > 100))) {
        return response.status(400).json({error: 'Invalid arrival cursor or streamId'});
      }
      return response.json(receiver.page(sourceIp, cursor === undefined ? null : Number(cursor), streamId, limit));
    }
    response.json(receiver.framesAfter(sourceIp, afterSequence, limit));
  });
  app.get('/api/device-input', (request, response) => {
    const sourceIp = request.query.sourceIp;
    if (sourceIp !== undefined && (typeof sourceIp !== 'string' || isIP(sourceIp) !== 4)) {
      return response.status(400).json({ error: 'sourceIp must be an IPv4 address' });
    }
    response.json(receiver.get(sourceIp));
  });
  app.get('/api/device-sources', async (_request, response, next) => {
    try {
      const devices = await store.listDevices();
      response.json(receiver.list().map(source => ({
        ...source, frame: undefined,
        deviceId: devices.find(d => d.serialNumber === `ESP32-UDP-${source.sourceIp}`)?.deviceId || null,
      })));
    } catch (error) { next(error); }
  });
  app.post('/api/device-sources/pair', async (request, response, next) => {
    try {
      const sourceIp = request.body?.sourceIp;
      if (typeof sourceIp !== 'string' || isIP(sourceIp) !== 4 ||
          receiver.get(sourceIp).stale) {
        return response.status(400).json({ error: 'Choose a currently connected device source' });
      }
      const serialNumber = `ESP32-UDP-${sourceIp}`;
      const existing = (await store.listDevices()).find(d => d.serialNumber === serialNumber);
      const device = existing || await store.createDevice({
        deviceName: `ESP32 UDP sender ${sourceIp}`, serialNumber,
      });
      response.status(existing ? 200 : 201).json(device);
    } catch (error) { next(error); }
  });

  // Health checks prove both the HTTP process and its database dependency work.
  app.get("/health", async (_request, response) => {
    try {
      if (store.pool) await store.pool.query('SELECT 1');
      response.json({ service: 'capstone', status: 'ok', storage: store.pool ? 'postgres' : 'memory', ...app.locals.runtime });
    } catch {
      response.status(503).json({service: 'capstone', status: 'database unavailable'});
    }
  });
  // Device routes identify the monitor that owns each test session.
  app.get("/api/devices", async (_request, response, next) => {
    try { response.json(await store.listDevices()); } catch (error) { next(error); }
  });
  app.post("/api/devices", async (request, response, next) => {
    try { response.status(201).json(await store.createDevice(validateDevice(request.body))); } catch (error) { next(error); }
  });
  // Session-list filters apply to session start time, not individual samples.
  app.get("/api/sessions", async (request, response, next) => {
    try { response.json(await store.listSessions({...validateRange(request.query), ...request.sessionScope})); } catch (error) { next(error); }
  });
  app.post("/api/sessions", async (request, response, next) => {
    try { response.status(201).json(await store.createSession({ ...validateSession(request.body),
      ownerUsername: request.principal?.username ?? null })); } catch (error) { next(error); }
  });
  // Detail filters apply to measurement timestamps and are inclusive.
  app.get("/api/sessions/:sessionId", async (request, response, next) => {
    try {
      const sessionId = validateUuid(request.params.sessionId, 'sessionId');
      const session = await store.getSession(sessionId, {...validateRange(request.query),
        recent: request.query.recent === '1', ...request.sessionScope});
      if (!session) return response.status(404).json({ error: "Session not found" });
      response.json(session);
    } catch (error) { next(error); }
  });
  // Authentication above applies to deletion just as it does to other data routes.
  app.delete("/api/sessions/:sessionId", async (request, response, next) => {
    try {
      const sessionId = validateUuid(request.params.sessionId, 'sessionId');
      if (!await store.deleteSession(sessionId, request.sessionScope)) {
        return response.status(404).json({ error: "Session not found" });
      }
      response.status(204).end();
    } catch (error) { next(error); }
  });
  // Each validated sample becomes 16 rows inside one database transaction.
  app.post("/api/sessions/:sessionId/measurements", async (request, response, next) => {
    try {
      const sessionId = validateUuid(request.params.sessionId, 'sessionId');
      const samples = validateSamples(request.body?.samples);
      if (!await store.getSession(sessionId, {metadataOnly: true, ...request.sessionScope})) {
        return response.status(404).json({ error: "Session not found" });
      }
      response.status(201).json(await store.addSamples(sessionId, samples, request.sessionScope));
    } catch (error) {
      // Deletion can win after the metadata read but before the upload commits.
      if (error.code === '23503') return response.status(404).json({ error: "Session not found" });
      next(error);
    }
  });

  // Unknown endpoints return JSON so Flutter never receives an HTML error page.
  app.use((_request, response) => response.status(404).json({error: 'Route not found'}));

  // Translate expected client mistakes into stable statuses. Unexpected errors
  // are logged locally but deliberately hidden from clients.
  app.use((error, _request, response, _next) => {
    if (error.type === 'entity.parse.failed') {
      return response.status(400).json({ error: 'Request body must be valid JSON' });
    }
    if (error.type === 'entity.too.large') {
      return response.status(413).json({ error: 'Request body exceeds the 2 MB limit' });
    }
    if (error instanceof ValidationError) {
      return response.status(400).json({error: error.message});
    }
    if (error.code === '23505') {
      return response.status(409).json({error: 'Resource already exists'});
    }
    if (error.code === '23503') {
      return response.status(400).json({error: 'Referenced resource does not exist'});
    }
    console.error('Unexpected request failure:', error);
    response.status(500).json({error: 'Internal server error'});
  });
  return app;
}
