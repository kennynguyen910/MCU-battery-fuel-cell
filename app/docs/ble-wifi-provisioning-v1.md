# BLE Wi-Fi provisioning v1

For both codebases and their remaining integration steps, see the
[combined repository guide](../../docs/integration.md).

The authoritative protocol is [Will and Kenny Startup.pdf](Will%20and%20Kenny%20Startup.pdf).
It supersedes conflicting provisioning assumptions in earlier documentation.

The Flutter client implements a separate service with control, data, and status
characteristics (5ecf1000 through 5ecf1003 with the specified UUID suffix).
After connecting to BatteryMonitor, it opens Settings / Wi-Fi, discovers the
service, subscribes to all three notification characteristics, and reads status.
Existing voltage subscriptions continue independently.

The settings flow displays device state and IP, offers Wi-Fi setup, scans networks,
reassembles results, sorts by signal strength, and marks unsupported authentication
modes. Credentials use UTF-8 byte limits and 13-byte fragments, fitting default
MTU 23. BEGIN and COMMIT share a transaction ID. Commands await matching ACK/error
responses; scans time out after 60 seconds. Failed transfers attempt CANCEL.
Passwords are obscured, never logged, and cleared after each submission; mutable
credential buffers are overwritten. Dart strings cannot guarantee secure erasure.
Sensitive operations reread the firmware status encrypted-link flag immediately
before sending; the settings page also offers a status refresh after OS pairing; the firmware
must independently enforce BLE encryption and authenticated pairing.

Change network replaces credentials without first clearing them. Forget network
sends CLEAR_CREDENTIALS. Connection failures show a retry message. Missing service
produces an explicit firmware compatibility message.

## Firmware boundary and remaining acceptance

This application checkout contains only a USB measurement extension. The linked
MCU repository at `731a40ce670f5ea4187f8e1f27f0071fb0b42dbd` already implements
GET_STATUS and START_SCAN, with NVS credential APIs, but explicitly rejects
credential Data writes and does not implement BEGIN/COMMIT/CLEAR/CANCEL commands.
The supplied PDF specifies the remaining firmware integration: separate GATT service, RAM staging, 60-second
expiry, existing wifi_cfg NVS APIs, asynchronous scan/connect, status notifications,
security enforcement, and credential-memory cleanup. App code does not implement
or prove those firmware behaviors.

On physical hardware, run every acceptance case in section 27 of the PDF,
including wrong password, router recovery, power-cycle persistence, interrupted
BLE staging, malformed fragments, and acquisition throughput/queue checks.
Verify subscription ordering and Android/iOS encrypted pairing with actual firmware.
Do not claim 1 kHz acquisition or NVS/security acceptance from app unit tests.

## Publishing layout

The integration branch retains the MCU repository history and places the complete
application under `app/`. The root firmware remains available for later integration.
The branch is for later review and merge; main is unchanged. SDKs, generated
binaries, local databases, capture logs, and secrets are recreated locally and
excluded from Git. All app source, platform hosts, schemas, tests, launchers,
lockfiles, documentation, and this specification are included.
