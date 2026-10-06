# Verification record

## 2026-09-29 BLE Wi-Fi provisioning integration

- All 29 API tests passed with real local PostgreSQL; none skipped.
- The final full Flutter suite passed: 31 tests, including 12 provisioning tests.
- Final Dart analysis reported no issues. The Flutter web build succeeded.
- Tests cover status/version validation, UTF-8 byte limits, MTU-23 fragments,
  reassembly, mismatched/conflicting packets, 60-second partial expiry,
  unsupported Enterprise networks, matching BEGIN/COMMIT transaction IDs,
  error ACK/CANCEL, insecure-link rejection, pairing status refresh, route close
  during transfer, scan failures, forget, and missing firmware service.
- Firmware at MCU commit `731a40c` supports status and scan only. Its credential
  commands and physical acceptance in section 27 of the PDF remain pending.
  No physical hardware throughput, authenticated pairing, or NVS write acceptance
  is claimed by these app tests.


## 2026-09-28 database user accounts

- All 29 API tests passed against local PostgreSQL, including salted password
  storage, persisted accounts, seed idempotency, duplicate rejection, unknown and
  wrong-password rejection, rate limiting, independent token logout, and creating
  an account through the stdin-based command while the HTTP server remains live.
- The add-user PowerShell launcher passed syntax validation. The existing login
  request/response contract is unchanged, so no mobile or web rebuild is required.
- Accounts share all data. No registration screen, password reset, or ownership
  restrictions were added. See [user accounts](users.md).

## Fixed login and normal application startup

The default entry point is now `Start_Capstone.cmd`, with username `capstone`
and the requested password `capstone_password`. It builds changed web screens,
starts persistent local PostgreSQL, verifies API/login readiness, and opens the
normal collector. Capture and simulation start stopped. Manual network scenarios
are available in the normal app, alongside the real device receiver. The temporary
sandbox is optional and uses the same credentials.

The configured cloud database was unreachable during this update. Its `.env`
settings were preserved; `12_Start_Configured_Database.cmd` selects them explicitly.
The default app uses separate local data, without automatic cloud synchronization.
The 19 API tests passed again, including a new assertion that the generator starts
stopped with no synthetic frames or sources.
All 10 Flutter tests also passed. The normal launcher was exercised through its
PowerShell entry point with browser opening disabled: it rebuilt the web app,
started the services, and reported ready. HTTP checks confirmed the requested
password, PostgreSQL/local storage, 21 readable saved sessions, and zero generated
simulation frames. Browser login with `capstone_password` succeeded on the normal
collector. Web and Android artifacts were rebuilt for this update.

## 2026-09-27 network demo and screen update

- **19 Node tests passed**, including the real local PostgreSQL integration test.
  Added receiver sequence-gap, duplicate, late-frame, partial-corruption, uint32
  wrap, and authenticated real-UDP demo coverage.
- **10 Flutter tests passed**. Added phone-width scenario controls and login
  expiration during capture. Updated existing capture/pairing tests for the new
  scrollable screen layout. Dart analysis reported no issues.
- The automated rehearsal (`node tools/demo-check.js`) passed baseline, high
  load, 20% packet loss, CRC corruption, outage, recovery, pairing, 16-channel
  upload/readback, and logout revocation. Report: `.local/network-demo-report.json`.
  The recorded high-load phase received 3,040 frames with zero gaps; loss received
  2,400 with 590 observed gaps; corruption received 1,980 with 20 CRC errors.
  Trailing drops are inferred only when the next valid sequence arrives.
- The browser walkthrough verified wrong-password rejection, successful login,
  login retained across role navigation, discovery/pairing, session creation,
  capture, cleared voltages during outage, and recovery at 1,000 frames/s.
  After stopping capture, History displayed **29 samples / 464 channel rows**
  and the channel graph. Desktop and 390-pixel phone layouts were inspected.
- Flutter web output was built into the directory actually served by the preview
  and demo: `build/web-viewer`. The Android debug APK was rebuilt
  with the collector entry point and emulator API address. Android tooling emits
  an SDK metadata-version warning, but the APK build succeeds.
- The demo launcher passed PowerShell syntax checking. It uses isolated
  loopback ports and temporary data; the normal `.env` and database are unchanged.

Physical ESP32/router/phone connectivity and an iOS build remain unverified.
Loopback throughput is not a Wi-Fi benchmark, and the collector stores at most
one latest frame per second. The walkthrough's demo data is temporary, while
the separate PostgreSQL integration test verifies persistence.

## 2026-09-26 device connection and login update

- 16 Node tests passed with the local PostgreSQL integration test enabled.
  These include protocol CRC/batch decoding, an actual UDP socket receive,
  discovered-source pairing/selection, login/logout, and database persistence.
- 8 Flutter tests passed, including the login and device-pairing widget flows.
- Dart analysis found no issues. The Flutter web build and Android debug APK
  build completed. The APK is at
  `build/app/outputs/flutter-apk/app-debug.apk`.
- The physical ESP32, router, and phone were unavailable for a live radio test.
  The socket test proves local UDP routing and packet decoding, while the
  connection guide specifies the remaining on-bench steps.

The Android build used the repository's Gradle, SDK, JDK, and Flutter caches.
Its debug keystore was copied into a project-local Android settings directory
because this sandbox could not write the default Android user directory.

Earlier MVP verification: 2026-09-14 on Windows, Flutter 3.47.4 / Dart 3.13.3,
Node.js 22, PostgreSQL 17, and an Android emulator.

## Automated verification

Run from the repository root:

```powershell
.\dev.cmd test
```

The command starts local PostgreSQL when necessary, then runs:

- 11 Node tests covering payloads, time ranges, HTTP errors, retry
  idempotency, unordered batches, and a real PostgreSQL end-to-end flow;
- 6 Flutter tests covering capture Start/Stop, stale/duplicate frames, local-log
  recovery/retry, history parsing/filtering/ordering, and graph edge cases;
- `flutter analyze` for static checks.

Result on the date above: all 17 tests passed and analysis reported no issues.
Tests do not truncate tables. Real-database tests leave clearly labeled records
so their results remain inspectable.

## Build verification

```powershell
.\dev.cmd build
.\dev.cmd android
```

Both commands completed successfully. The Android artifact is
`build/app/outputs/flutter-apk/app-debug.apk`. It was installed and
its main activity was confirmed visible in the `Capstone_Test` emulator.

## Runtime smoke verification

With `.\dev.cmd` running:

1. `GET /health` returned `status=ok` and `storage=postgres`.
2. A session named `5pm MVP smoke test` was created.
3. A transient frame containing CH 1 = 1.234, CH 2 = −0.500, and
   CH 3 = 0.250 was published.
4. Publication alone did not represent persistence; the collector-style upload
   inserted 16 rows into that session.
5. Reading the session returned 16 rows and CH 1 = 1.234.
6. History, collector, and input preview URLs each returned HTTP 200 and were
   visually checked for the expected controls/data.

## Not verified on this host

The iOS host project exists, but Apple requires macOS and Xcode to compile,
sign, and run it. Cloud deployment, physical hardware transport, and full-rate
acquisition have not been represented as verified work. Bench authentication
and loopback UDP transport are covered by the later verification records above.
