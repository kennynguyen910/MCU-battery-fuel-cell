// Start the project-owned PostgreSQL cluster without installing a Windows
// service. The database stays running when the API or preview is restarted.
import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

// Absolute paths make the helper safe to call from any working directory.
const root = fileURLToPath(new URL('../', import.meta.url));
const pgCtl = path.join(root, '.tools/pgsql/bin/pg_ctl.exe');
const pgData = path.join(root, '.local/pgdata');

// Missing binaries/data usually mean first-time setup has not been run.
if (!existsSync(pgCtl) || !existsSync(pgData)) {
  throw new Error('Local PostgreSQL is not installed. See README.md for setup details.');
}

try {
  // A successful status command means another launcher already started it.
  execFileSync(path.join(root, '.tools/pgsql/bin/pg_isready.exe'),
    ['-h', '127.0.0.1', '-p', '55432', '-U', 'capstone', '-d', 'capstone'], { stdio: 'ignore', windowsHide: true });
  console.log('PostgreSQL: already running');
} catch {
  // Listen only on loopback and use a non-default port to avoid other installs.
  execFileSync(
    pgCtl,
    ['-D', pgData, '-l', path.join(root, '.local/postgres.log'), '-o', '-p 55432 -h 127.0.0.1', 'start'],
    { stdio: 'inherit' },
  );
  console.log('PostgreSQL: started on 127.0.0.1:55432');
}
