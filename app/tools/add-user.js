// Password arrives on stdin, never in command arguments or terminal output.
import dotenv from '../apps/api/node_modules/dotenv/lib/main.js';
import { fileURLToPath } from 'node:url';
import { PostgresStore } from '../apps/api/src/postgres-store.js';
import { DatabaseAuth } from '../apps/api/src/user-auth.js';

dotenv.config({ path: fileURLToPath(new URL('../.env', import.meta.url)), quiet: true });
if (!process.argv.includes('--configured-database')) {
  process.env.DATABASE_URL = 'postgresql://capstone@127.0.0.1:55432/capstone';
  process.env.DATABASE_SSL_CA = '';
}
let store;
try {
  if (!process.env.DATABASE_URL) throw new Error('DATABASE_URL is required.');
  let input = '';
  for await (const chunk of process.stdin) input += chunk;
  const { username, password } = JSON.parse(input.replace(/^\uFEFF/, ''));
  store = new PostgresStore(process.env.DATABASE_URL);
  const auth = new DatabaseAuth(store.pool);
  await auth.initialize();
  await auth.addUser(username, password);
  console.log(`Created user ${username}. You can log in now; no restart is needed.`);
} catch (error) {
  console.error(error.code ? 'Could not create user. Start Capstone and check the selected database connection.' : error.message);
  process.exitCode = 1;
} finally {
  if (store) await store.pool.end();
}
