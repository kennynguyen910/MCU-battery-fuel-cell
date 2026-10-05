# 1kSPS capture — development and acceptance guide

**Target:** 1,000 complete 16-channel frames/second = 16,000 stored channel readings/second.
**Route:** ESP32 UDP → API buffer → collector journal → upload batches → PostgreSQL.
**Status:** Software throughput verified; physical ESP32/phone acceptance remains required.

## At a glance

| Check | Recorded result, October 5, 2026 |
| --- | --- |
| Sustained 1kSPS, native Dart/file journal | 60,000 frames in 60.009 seconds; exactly 960,000 SQL readings |
| Extended native 1kSPS, through ring retirement | 120,000 frames in 120.014 seconds; exactly 1,920,000 SQL readings; every voltage verified; reader misses 0; peak pending 10,760 |
| Sustained 1kSPS, built Chrome/IndexedDB collector | 60,000 frames in 60.014 seconds; exactly 960,000 SQL readings; every voltage verified; reader misses 0; peak pending 10,750; reload/retry recovered |
| Capacity headroom, native Dart/file journal | 60,000 frames at 2,000 FPS in 30.010 seconds; exactly 960,000 SQL readings |
| Software data loss/corruption in those runs | 0 UDP sequence gaps, 0 invalid frames, 0 reader misses; every SQL voltage matched the wire generator |
| Upload outage and lost acknowledgement | 10-second upload outage; first committed batch returned a synthetic failure; retry introduced no duplicate readings |
| Backlog recovery | Journal reloaded during the outage; peak pending 10,740 at 1kSPS and 21,550 at 2kSPS; final pending 0 |
| Hardware and physical phone | NOT YET VERIFIED; no device was attached for this work |

These are synthetic loopback tests on the development Windows PC with real disk
flushes, UDP, HTTP, Dart collector code and the project's PostgreSQL database.
The 2kSPS run measures software capacity; reconstructed SQL timestamps retain
millisecond uniqueness and are not a claim of accurate 2kHz physical timing.

The extended run retired 60,000 old receiver-buffer frames after they had already
been consumed. The existing `bufferDroppedFrames` counter counts such retention
retirement; reader-specific `missedFrames` measures actual collector overrun and
remained zero. Normal retirement must not be mistaken for dropped measurements.

The full app checks passed: 30 API tests using real PostgreSQL and 39 Flutter
tests, plus the shared 9 Python / 3 Node / 3 Dart integration contract checks.
Flutter analysis reported no issues and the normal web build passed.
The Android debug APK also compiled successfully, and its native activity was
verified in the package. Compilation does not establish physical phone throughput.

Android build verification also repaired the existing USB dependency setup:
the app now selects the checked-in `usb_serial` 0.5.2 path package with current
Gradle repositories/namespace/lint settings, retaining identical upstream Dart
and Java sources and the same 6.1.0 native driver. The app compiles against API 37
as required by its existing BLE/permission plugins; setup now installs platform
37.0. Target/minimum SDK behavior is preserved. See
`apps/monitor/third_party/usb_serial/CAPSTONE_PATCH.md` for provenance.

## What changed

1. **Receiving no longer waits for uploading.** A separate 250 ms capture pump
   pages up to eight 1,000-frame batches per turn; upload retries run separately.
   Display/session refreshes remain at one second. Slow database requests cannot
   hold the acquisition/storage pump.
2. **The receiver uses a ring buffer.** Retention is constant-time per sample;
   arrival paging reads only the requested frames. Its 60,000-frame capacity is
   60 seconds at 1kSPS. Legacy sequence paging and packet formats are preserved.
   The UDP socket requests a 4 MiB receive buffer; actual OS capacity is reported
   by the acceptance test (4,194,304 bytes on this PC).
3. **Save new batches, rather than rewrite all history.** Native apps append
   flushed journal records; browsers use strict IndexedDB transactions. Both
   migrate the old log, replay pending data, retain 500 uploaded frames and
   periodically compact. Only local commits serialize. HTTP runs outside that
   lock. A failed local acknowledgement leaves the batch pending for retry.
4. **Keep existing database keys and batch contracts.** Uploads still contain
   up to 1,000 frames and use the original session/timestamp/channel key. An
   identical retry avoids rewriting unchanged voltages. A changed voltage at
   the same key still updates. ADC, measurement UUIDs, BM/BB packet bytes and
   provisioning contracts were preserved.

IndexedDB writes request `durability: "strict"` and wait for transaction
completion before advancing a cursor. See the [browser transaction API](https://developer.mozilla.org/en-US/docs/Web/API/IDBDatabase/transaction).

## Repeat the throughput test

Install the app dependencies, initialize Flutter and prepare the local test
database using the existing setup. From `app/` in the integration checkout (or
the root of the standalone app):

```powershell
$env:TEST_DATABASE_URL = 'postgresql://capstone@127.0.0.1:55432/capstone'
$env:PUB_CACHE = 'C:/path/to/pub-cache' # Only if your SDK uses a custom cache.
node tools/throughput-test.mjs C:/path/to/flutter/bin/flutter.bat
```

For browser acceptance, add these before the same command:

```powershell
$env:THROUGHPUT_BROWSER = '1'
$env:CHROME_EXECUTABLE = 'C:/Program Files/Google/Chrome/Application/chrome.exe'
```

For software capacity headroom, set `THROUGHPUT_FPS=2000`. `THROUGHPUT_FRAMES`
defaults to 60000 and must be a multiple of ten. Use at least 60,000 for acceptance
so the complete outage/recovery scenario runs. Remove these variables for the
default native 1kSPS run. On macOS/Linux, pass the Flutter executable path.

The generator runs in an independent worker so API/SQL stalls do not slow it
and conceal loss. It waits for every UDP send callback before closing. The
collector runs the production pump and platform journal on real elapsed time.
The test verifies generated/sent/received/saved counts, every stored channel and
voltage, unique timestamps, zero reader misses, outage retry and journal reload.
Test devices/sessions are uniquely named and deleted afterward; existing user
records are preserved. Test-only outage endpoints are never added to production.
The last `THROUGHPUT_RESULT` must report zero errors and exact counts. A nonzero
exit, an untested runtime, or a skipped test is not acceptance evidence.

Browser mode builds a separate test entry point and serves its local engine
assets to headless Chrome with an isolated temporary profile. It runs the same
acceptance assertions as the VM test using the production IndexedDB journal.
This avoids a Windows path bug in the installed Flutter browser test server;
no SDK patch is required. The normal web application build is separate.

## Next bench steps — do these before declaring the full system lossless

| Order | Action | Pass condition |
| --- | --- | --- |
| 1 | Build the unchanged measurement firmware with ESP-IDF on the firmware machine; use the actual ADC and intended router | Build passes; acquisition clock/ADC are configured for 1,000 complete frames/s |
| 2 | Run one collector in the foreground on the target physical phone, with the production API/database | Ten-minute run maintains 1kSPS and records every accepted frame with 16 readings |
| 3 | Record synchronized before/after board and receiver counters plus SQL counts | `framesDropped`, `bufferOverflows`, `missedTimingEvents`, `adcReadErrors`, `networkFramesNotSent`, send failures, receiver sequence gaps, reader misses and CRC errors remain zero; reconcile in-flight queue/batch frames at boundaries |
| 4 | Interrupt database uploads for ten seconds while UDP/paging remain reachable; restore uploads | Pending grows, acquisition continues, backlog drains, exact stored counts/voltages remain intact |
| 5 | Repeat during the required BLE provisioning/security/scan/reconnect cases | Provisioning does not introduce timing misses, queue overflow or telemetry loss; credential safety remains intact |
| 6 | Review evidence with the team | Merge remains a later user decision; never merge main automatically |

## Operating limits that still matter

- **UDP is unacknowledged.** The current firmware drops a batch on failed send
  and has no retransmission contract. Software capacity cannot guarantee delivery
  across RF loss or router disconnection. An absolute delivery guarantee would
  require a separately specified acknowledged/replay transport and board testing.
- **Buffers are finite.** Each API source retains 60,000 frames; the local
  journal permits 60,000 pending frames (about 60 seconds at 1kSPS). A full
  journal refuses to advance the fetch cursor. A longer outage can still overrun
  retention; reader misses and UDP gaps must be treated as failed acceptance.
  Average upload and database commit throughput must keep pace with acquisition.
- **A whole API outage differs from an upload outage.** Pages cannot be fetched
  while that API is unreachable. The API buffer is in memory and is lost on
  receiver restart; the collector stops on a stream-ID change. Successfully
  journaled frames still survive and can upload afterward.
- **Keep one collector active and the phone app in the foreground.** There is no
  new background service or screen-off guarantee. Browser storage quota/eviction
  and CPU scheduling still require testing on the intended device/browser.
- **BLE/USB are snapshots in current firmware.** They do not deliver the full
  1kSPS stream. Their direct collector now saves independently of upload waits,
  but changing their wire rate is separate hardware work.

## Files future work should start with

| Area | Files |
| --- | --- |
| Collector/UI ownership | `apps/monitor/lib/buffered_capture.dart`, `screens.dart`, `direct_capture.dart`, `device_connections.dart` |
| Durable buffering/recovery | `capture_log.dart`, `file_capture_journal.dart`, `browser_capture_journal.dart`, `capture_journal_codec.dart` |
| API retention/socket/SQL | `apps/api/src/device-receiver.js`, `device-listener.js`, `postgres-store.js` |
| Repeatable acceptance | `tools/throughput-test.mjs`, `throughput-producer.mjs`, `apps/monitor/test/throughput_acceptance_test.dart` |
| Hardware limits (repository root) | `main/network_consumer.cpp`, `components/udp/udp_transport.cpp`, `components/acquisition/`, `components/diagnostics/` |

The provisioning v1 specification remains authoritative for provisioning; this
guide concerns measurement performance and does not alter that protocol.
