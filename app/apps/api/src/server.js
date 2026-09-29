// Production-process entry point. Route definitions stay in app.js so tests can
// start the same Express app on a temporary port without spawning this file.
import dotenv from "dotenv";
import { fileURLToPath } from "node:url";
// Resolve configuration relative to this file, regardless of terminal directory.
dotenv.config({ path: fileURLToPath(new URL("../../../.env", import.meta.url)) });
import { createApp } from "./app.js";
import { MemoryStore } from "./memory-store.js";
import { PostgresStore } from "./postgres-store.js";
import { startDeviceListener } from './device-listener.js';
import { SingleUserAuth } from './auth.js';
import { DatabaseAuth } from './user-auth.js';
import { NetworkSimulator } from './network-simulator.js';

const port = Number(process.env.PORT || 3001);
if (!Number.isInteger(port) || port < 1 || port > 65535) {
  throw new Error('PORT must be an integer between 1 and 65535');
}
// Memory mode is useful for isolated tests; normal development supplies Postgres.
const store = process.env.DATABASE_URL ? new PostgresStore(process.env.DATABASE_URL) : new MemoryStore();

// Keep the returned server so shutdown can stop accepting new requests cleanly.
const hasAuthSetting = Boolean(process.env.APP_USERNAME || process.env.APP_PASSWORD);
const auth = store.pool ? new DatabaseAuth(store.pool)
  : hasAuthSetting ? new SingleUserAuth(process.env.APP_USERNAME, process.env.APP_PASSWORD) : undefined;
if (auth instanceof DatabaseAuth)
  await auth.initialize(process.env.APP_USERNAME, process.env.APP_PASSWORD);
const deviceEnabled = process.env.DEVICE_UDP_ENABLED === '1' || Boolean(process.env.DEVICE_IP);
if (deviceEnabled && !auth) {
  throw new Error('Set APP_USERNAME and APP_PASSWORD before enabling the ESP32 receiver');
}
const simulationEnabled = process.env.NETWORK_SIMULATION_ENABLED === '1';
if (simulationEnabled && !auth) throw new Error('Configure login before enabling network simulation');
// A dedicated loopback socket keeps synthetic traffic separate from the board's
// optional source-IP filter. Nothing is generated until the operator starts it.
let simulator;
const simulation = simulationEnabled ? {
  snapshot: () => simulator.snapshot(),
  setScenario: name => simulator.setScenario(name),
} : undefined;
const app = createApp(store, { auth, simulation });
app.locals.runtime = {
  storageLocation: process.env.DATABASE_URL && ['localhost', '127.0.0.1'].includes(new URL(process.env.DATABASE_URL).hostname) ? 'local' : 'remote',
  networkSimulation: simulationEnabled,
  deviceReceiver: deviceEnabled,
};
let simulationSocket;
if (simulationEnabled) {
  simulationSocket = await startDeviceListener(app, { port: 0, host: '127.0.0.1', sourceIp: '127.0.0.1' });
  simulator = new NetworkSimulator({ port: simulationSocket.address().port });
}
const server = app.listen(port, () => {
  console.log(`API listening on http://localhost:${port} (${process.env.DATABASE_URL ? "PostgreSQL" : "demo memory"} mode)`);
});
// The ESP32 sends datagrams to the laptop, not to a phone. Enable this listener
// only for an explicitly configured bench network. DEVICE_IP can limit senders.
let deviceSocket;
if (deviceEnabled) {
  const devicePort = Number(process.env.DEVICE_UDP_PORT || 5005);
  if (!Number.isInteger(devicePort) || devicePort < 1 || devicePort > 65535) {
    throw new Error('DEVICE_UDP_PORT must be an integer between 1 and 65535');
  }
  deviceSocket = await startDeviceListener(app, { port: devicePort, sourceIp: process.env.DEVICE_IP });
  console.log(`Device UDP listener on port ${devicePort}; sender ${process.env.DEVICE_IP || 'LAN discovery'}`);
}

// Close the HTTP listener before its database pool. The five-second fallback
// prevents a stuck connection from leaving a terminal that never exits.
let shuttingDown = false;
async function shutdown(signal) {
  if (shuttingDown) return;
  shuttingDown = true;
  console.log(`${signal} received; closing API connections.`);
  deviceSocket?.close();
  simulator?.close();
  simulationSocket?.close();
  server.close(async () => {
    if (store.pool) await store.pool.end();
    process.exit(0);
  });
  setTimeout(() => process.exit(1), 5000).unref();
}
process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
