"""Verify shared MCU/app contracts; this does not flash hardware or start services."""
import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--flutter', help='Flutter executable, if not on PATH or under app/.tools')
    parser.add_argument('--skip-flutter', action='store_true', help='Run only Python/Node checks; report partial verification')
    args = parser.parse_args()
    node = shutil.which('node')
    local_flutter = ROOT / 'app/.tools/flutter/bin' / ('flutter.bat' if os.name == 'nt' else 'flutter')
    flutter = args.flutter or shutil.which('flutter') or (str(local_flutter) if local_flutter.is_file() else None)
    if not node:
        parser.error('Install Node.js or run app/executables/00_First_Time_Setup.cmd first')
    if not flutter and not args.skip_flutter:
        parser.error('Provide --flutter PATH or run the app setup; use --skip-flutter only for a partial check')
    stages = [
        ('Fixture consistency', [sys.executable, 'tools/generate_protocol_fixtures.py'], ROOT),
        ('Firmware Python receiver and shared UUID checks', [sys.executable, '-m', 'unittest', 'discover', '-s', 'tools', '-p', 'test_*.py'], ROOT),
        ('API wire decoding and collector-to-history contract', [node, '--test', 'tools/test_app_integration.mjs'], ROOT),
    ]
    if not args.skip_flutter:
        stages.append(('Mobile BLE, USB and provisioning contracts', [flutter, 'test', '--no-pub', 'test/shared_protocol_test.dart'], ROOT / 'app/apps/monitor'))
    for label, command, directory in stages:
        print(f'\n{label}', flush=True)
        result = subprocess.run(command, cwd=directory, check=False)
        if result.returncode:
            raise SystemExit(result.returncode)
    print('\n' + ('Partial contract checks passed; Flutter omitted.' if args.skip_flutter else 'All shared contract checks passed.'))
    print('ESP-IDF build, physical BLE/Wi-Fi, pairing, NVS, and 1 kHz acceptance still require the board.')
if __name__ == '__main__': main()
