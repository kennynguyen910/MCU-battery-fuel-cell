// Development process supervisor. It starts the API and static preview server
// together, then stops both children when the student presses Ctrl+C.
import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
// Importing this small helper starts PostgreSQL only when it is not already up.
import './start-postgres.js';

// Resolve from this file rather than the terminal's current folder.
const root = fileURLToPath(new URL('../', import.meta.url));
process.chdir(root);
// A source checkout does not commit build output, so explain the required step.
if (!existsSync('build/web-viewer/index.html')) {
  console.error('Run dev.cmd build first to compile the Flutter preview.');
  process.exit(1);
}
// Each long-running service inherits this terminal's output for easy debugging.
const children = [
  spawn(process.execPath, ['apps/api/src/server.js'], {stdio: 'inherit', windowsHide: true}),
  spawn(process.execPath, ['apps/api/src/preview.js'], {stdio: 'inherit', windowsHide: true}),
];
// `stopping` prevents one child's exit event from starting a second shutdown.
let stopping = false;
function stop(code = 0) {
  if (stopping) return;
  stopping = true;
  for (const child of children) child.kill();
  process.exitCode = code;
}
// An unexpected child exit is considered a failed combined development run.
for (const child of children) {
  child.on('error', error => { console.error(error); stop(1); });
  child.on('exit', code => { if (!stopping) stop(code || 1); });
}
// Windows Ctrl+C and ordinary termination both use the same cleanup path.
process.on('SIGINT', () => stop());
process.on('SIGTERM', () => stop());
console.log('\nCapstone MVP is running.');
console.log('Web history: http://localhost:5173/');
console.log('Mobile preview: http://localhost:5173/?preview=mobile#/mobile');
console.log('Manual input: http://localhost:5173/?preview=input#/input');
console.log('Ctrl+C stops the API/previews. PostgreSQL stays running for persistence.');
