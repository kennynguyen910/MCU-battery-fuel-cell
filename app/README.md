# Capstone battery / fuel cell monitor

**Current specification:** [BLE Wi-Fi provisioning v1](docs/ble-wifi-provisioning-v1.md)
is the project’s authoritative provisioning requirement. Connect to BatteryMonitor
and use **Settings · Wi-Fi** to scan, set up, change, or forget its network.
The linked MCU firmware currently implements status and scans; credential commands
require its remaining firmware integration. See the guide for acceptance limits.

**Add users:** run `START_PROJECT/13_Add_User.cmd` while the normal app is running.
See [user accounts](docs/users.md) for storage, login, and database selection.

**Android connections:** the collector's **Device connections** page supports
BLE, Wi-Fi/UDP, and USB serial. See [Android connection setup](docs/android-connections.md)
for ESP32 pairing and the optional USB measurement firmware addition.

A student bench and demonstration app. The application code uses Flutter/Dart,
Express, Node.js, and PostgreSQL. AWS and Vercel remain the intended hosting
platforms; this development version runs locally.

## Start the app

Double-click **`Start_Capstone.cmd`**. It updates changed screens, starts the
services, and opens the normal collector. Log in with **`capstone`** /
**`capstone_password`**. Data persists in local PostgreSQL; capture and network
simulation start stopped. No demo sequence runs automatically.
See [running the app](docs/running-app.md) for device use, optional network tests,
and the preserved cloud database option. The [presentation guide](docs/network-demo.md)
is available when you want to demonstrate the features.

## The actual data path

**Manual dashboard or ESP32 UDP receiver → Android/iOS collector → Express API → Postgres → web application**

The input dashboard remains available for testing without hardware. The ESP32
receiver accepts validated UDP frames on the API laptop. Only the mobile
collector uploads selected frames into a test session; the web application
reads that stored session. UDP capture fetches buffered pages and uploads up to
1,000 frames per request; the one-second screen refresh is not the capture rate.
Capture runs independently of display updates and uploads. The receiver retains
60,000 frames per source; the collector journals up to 60,000 pending frames.
Uploads use up to four concurrent batches; timestamps retain microseconds.
Native and browser software tests passed sustained 2kSPS, with a 1kSPS minimum
and shorter native 3kSPS stress evidence. Physical phone/board acceptance remains.
See the [capture performance and next-steps guide](docs/1ksps-capture.md)
for sustained-load results, repeatable tests and remaining physical validation.

## Open the working previews

- Web history: http://localhost:5173/
- Mobile collector preview: http://localhost:5173/?preview=mobile#/mobile
- Manual device dashboard: http://localhost:5173/?preview=input#/input

The browser collector runs the same Dart screen and API code as the native app.
It is a preview, not an iOS emulator. Use only one collector per test session.
The actual Android APK is in:
`apps/monitor/build/app/outputs/flutter-apk/app-debug.apk`.

## Installed on this machine

| Component | Location |
| --- | --- |
| Flutter 3.47.4 / Dart 3.13.3 | .tools/flutter |
| Android SDK and emulator | .tools/android-sdk |
| Java 17 | .tools/java |
| PostgreSQL 17 binaries | .tools/pgsql |
| Persistent database files | .local/pgdata |
| Dart/Gradle download caches | .tools/pub-cache and .tools/gradle |

These large local directories are ignored by source control. Android's generated
Capstone_Test emulator lives under the Windows user's .android/avd directory.
The launch script finds Flutter locally, so no PATH repair or pnpm is required.

## Start and stop

### Easiest Windows launch

Double-click [`Start_Capstone.cmd`](Start_Capstone.cmd) for automatic startup
with persistent local data. The numbered launchers can also start the database,
API, previews, and Android pieces individually. On a newly cloned computer, run
`00_First_Time_Setup.cmd` once first; Android has a separate optional 00B setup
because its SDK/emulator download is several gigabytes.

From PowerShell in this directory:

```powershell
.\dev.cmd
```

The older `dev.cmd` development workflow starts the local Postgres cluster if necessary, then the API on
port 3001 and the compiled Flutter previews on port 5173. Keep the terminal open.
Ctrl+C stops the two Node servers; the database remains running. That development
workflow uses the database configured in `.env`, which may be a cloud database.

If previews are already open and working, do not start duplicate servers.
After changing Dart source, stop the previews, run `.\dev.cmd build`, then
start them again and refresh the browser. `.\dev.cmd app` runs a hot-reload
collector preview on port 5174 for active Dart development.

Stop the local database when desired:

```powershell
.\.tools\pgsql\bin\pg_ctl.exe -D .local\pgdata stop
```

## Five-minute manual test

1. Open the collector and click **Create session**. The default name is fine.
2. Click **Start capture**. Existing old device input is ignored.
3. In the device dashboard, enter CH 1 = 1.234 and CH 2 = -0.500. Leave the other
   14 values at zero. Click **Publish device frame**.
4. The collector should show the values, a local-log entry, and one upload.
5. In the web application select the same session. It should show 16 database
   rows, CH 1 = 1.234 V, and CH 2 = -0.500 V.
6. Change CH 1 and publish again. The web row count should increase by 16.
7. Stop capture, then publish. Device values may still display in the collector,
   but no additional rows should be uploaded.
8. An empty field, non-number, or voltage outside [-5,+5] must be rejected.

Allow about one second for collector polling plus one second for web polling.
A browser can throttle hidden tabs, so allow more time when they are inactive.

## Mobile build and install

For the ESP32 Wi-Fi/UDP receiver, router setup, API login, and collector steps,
see [device connection](docs/device-connection.md).

`.\dev.cmd android` builds the debug APK for the Android emulator. It defaults
to API address http://10.0.2.2:3001, which maps to this PC from Android's emulator.
A physical phone must use a reachable PC address instead. The collector has an
API-address field so you can change it without rebuilding.

Native Android/iOS projects are checked into apps/monitor/android and
apps/monitor/ios. See [mobile instructions](docs/mobile.md) for emulator,
physical-device, and iOS build commands.

## Persistence and local logging

The main launcher selects project Postgres at 127.0.0.1:55432. The original
root `.env` database is selected by the separate configured-database launcher.
Database rows survive API and app restarts. The local database is loopback-only,
with trust authentication for this development cluster; it is not a production
configuration.

Every captured frame is written locally before upload. Android/iOS use an
append journal in the app documents directory; the browser uses IndexedDB.
Older JSON logs are migrated automatically. **View local log** shows the JSON. Entries include destination API,
session, original timestamp, and upload status. Failed uploads retry automatically
for the currently connected API. Do not clear app/browser storage before pending
uploads finish.

Saved sessions are private to their creator. `capstone_admin` can access all
sessions; preserved older sessions are admin-only. The collector filters its
local log and pending uploads by signed-in account as well. See
[user accounts and activation steps](docs/users.md) for the additive upgrade.

To organize saved sessions, select one in the collector or web history and
choose **Delete session**. Confirming permanently removes the session and its
saved readings. Stop any collectors using it first. Deletion is disabled during
capture on this collector; its local frames for the deleted session are also
removed after the server confirms deletion. Other sessions and devices remain.

## Verification commands

```powershell
.\dev.cmd test
.\dev.cmd build
.\dev.cmd android
```

The test command starts the local database if necessary, then runs Node
validation/HTTP tests, a real Postgres flow test, Flutter capture Start/Stop
tests, a durable-upload retry test, and Dart analysis.

## Scope and limitations

Implemented: native mobile host projects, manual device input, capture Start/Stop,
16-channel display, session selection, local JSON logging, upload retry,
Postgres persistence, and a separate read-only web viewer with UTC time filters
and a single-channel voltage history graph.

Implemented for bench use: validated ESP32 UDP ingestion, discovered sender
pairing/selection, buffered batch storage, and optional single-user login.
Physical hardware throughput and cryptographic device authentication remain unverified;
randomized sensor sim-mode, production signing, or cloud deployment. A deterministic
UDP network lab now covers load, packet loss, corruption, and outage recovery.
The test input holds only the latest frame; publishing multiple frames inside a
poll interval can replace an unread frame. This is intentionally a manual-test
interface, not a streaming protocol.

iOS source is ready for a Mac build. An iOS binary/simulator cannot be built or
run on this Windows host. See docs/mobile.md for the exact remaining steps.

## Code and documentation map

- [Demo runbook](docs/demo.md): five-minute walkthrough and fast recovery.
- [Requirements traceability](docs/requirements.md): requirement, code, and acceptance mapping.
- [Verification record](docs/verification.md): tests, builds, runtime smoke evidence, and exclusions.
- [Deployment handoff](docs/deployment.md): AWS/Vercel boundary and production gate.
- [Risk register](docs/risks.md): known MVP risks, mitigations, and next decisions.
- [GitHub/PC transfer](docs/github-transfer.md): safe repository contents and second-PC setup.
- [Architecture](docs/architecture.md): ownership, data flow, and design choices.
- [API contract](docs/api.md): routes, payloads, storage, and errors.
- [Mobile setup](docs/mobile.md): Android, iOS, and network configuration.
- [Developer guide](docs/development.md): file map, tests, and troubleshooting.
