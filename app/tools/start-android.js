// Reuse the project's emulator instead of launching a conflicting second copy.
import {execFileSync, spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
const adb = path.join(root, '.tools/android-sdk/platform-tools/adb.exe');
const emulator = path.join(root, '.tools/android-sdk/emulator/emulator.exe');
function query(file, args) {
  try {
    return execFileSync(file, args, {encoding: 'utf8', windowsHide: true,
      timeout: 10000, stdio: ['ignore', 'pipe', 'pipe']}).trim();
  } catch { return ''; }
}
const devices = query(adb, ['devices']).split(/\r?\n/);
for (const line of devices) {
  const match = line.match(/^(emulator-\d+)\s+(device|offline)/);
  if (!match) continue;
  const name = query(adb, ['-s', match[1], 'emu', 'avd', 'name']);
  if (name.split(/\r?\n/).includes('Capstone_Test')) {
    console.log('Capstone_Test is already running. Use its existing window.');
    console.log('Next: 03_Install_And_Open_Android_App.cmd after Android boots.');
    process.exit(0);
  }
  if (match[2] === 'offline') {
    console.log('An Android emulator is still starting or shutting down.');
    console.log('Wait for it to finish, then retry. A second copy was not started.');
    process.exit(0);
  }
}
// A booting emulator may not have registered with adb yet.
const processes = query('tasklist.exe', ['/FO', 'CSV', '/NH']);
if (/"(?:qemu-system-[^"]+|emulator)\.exe"/i.test(processes)) {
  console.log('An emulator process is already active, possibly without a visible window.');
  console.log('Wait for startup/shutdown to finish and retry; check Task Manager if it stays stuck.');
  process.exit(0);
}
console.log('Starting Capstone_Test. Keep this window open while Android runs.');
// A saved quick-boot state hung on this laptop; cold boot preserves app data.
const child = spawn(emulator, ['-avd', 'Capstone_Test', '-no-snapshot-load'], {stdio: 'inherit', windowsHide: true});
child.on('error', error => { console.error(error.message); process.exitCode = 1; });
child.on('exit', code => {
  process.exitCode = code ?? 1;
  if (code) console.error('Android exited with an error. The actual cause is shown above; this does not necessarily mean the AVD is missing.');
});
