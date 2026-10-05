# Capture next steps: 2kSPS target, 1kSPS minimum

**SOFTWARE VERIFIED:** sustained 2,000 complete frames/s in native and browser collectors.

**MINIMUM VERIFIED:** 1,000 frames/s with delayed uploads and outage recovery.

**HARDWARE GATE OPEN:** ESP32 + physical phone acceptance remains required.

**NEXT ACTION:** run the target phone against the real board, router and database.

A frame contains **all 16 channels**. At 2kSPS the database stores 32,000 channel
readings each second. The firmware's existing 1kHz acquisition timer is preserved.
The application now has headroom above that rate; these tests do not raise the ADC rate.

## At a glance — recorded October 5, 2026

| Rate | Collector | Wire run | Frames / SQL readings | Final backlog drain |
| --- | --- | --- | --- | --- |
| **1,000/s minimum** | Native Dart + file journal | 120.013 s | 120,000 / 1,920,000 | 2.109 s |
| **2,000/s target** | Native Dart + file journal | 180.004 s | 360,000 / 5,760,000 | 4.104 s |
| **2,000/s target** | Built Chrome + IndexedDB | 180.013 s | 360,000 / 5,760,000 | 2.660 s |
| 3,000/s stress headroom | Native + live history viewer | 60.008 s | 180,000 / 2,880,000 | 7.774 s |

**All four runs passed:** zero send errors, UDP sequence gaps, invalid frames or
collector misses; every SQL voltage and every microsecond sample timestamp
matched the independent wire generator. Final pending count after reload: **0**.
Each included **750 ms extra delay on successful uploads**, a **10-second upload
outage**, **journal reload during that outage**, and **one committed batch whose
response was lost**. Retry produced no duplicate readings.

Peak pending counts were 13,490 at 1kSPS, 25,500 / 25,510 in native / Chrome at
2kSPS, and 41,240 in the 3kSPS stress run. The 3kSPS run also served 70 bounded
history reads, with a maximum observed response time of 1,580 ms. It is shorter
stress evidence, not the sustained target rating. Raw evidence is in
[1ksps-results.json](1ksps-results.json).

These are synthetic elapsed-time tests on the Windows development PC with real
UDP, HTTP, disk flushes or IndexedDB transactions, and PostgreSQL. They do not
establish performance on an attached board or physical phone. Receiver-buffer
retirement after consumption is normal; reader-specific `missedFrames` is the
loss check. All runs exceed the receiver's 60,000-frame retention capacity.

An earlier concurrent 3kSPS stress attempt exceeded the **unchanged 10-second
final-drain limit** while two acceptance verifiers repeatedly sorted millions
of database rows. The verifier now orders by the indexed raw timestamp rather
than its formatted text alias. The subsequent 3kSPS run with a normal live
viewer passed. Database overload can still exhaust finite buffers; it must not
be described as reliable operation.

Regression checks passed: **34 API tests with PostgreSQL**, **42 Flutter tests**,
**9 Python + 3 Node + 3 Dart shared-contract tests**, and **zero analyzer issues**.
Normal web and Android debug builds passed. The existing USB build repair keeps
upstream runtime sources and the native driver unchanged; see
`apps/monitor/third_party/usb_serial/CAPSTONE_PATCH.md`.

## What supports the higher rate

1. **Preserve sub-millisecond timing.** Device-clock intervals are anchored once
   to host UTC, retaining microseconds across packet delivery jitter and host
   clock adjustments. An estimated device restart starts a new anchor while
   keeping keys monotonic. API validation accepts up to six fractional digits;
   PostgreSQL history emits precise ISO text instead of a truncated JavaScript
   Date. Direct BLE/USB collection and history filters also preserve microseconds.
   A 2kHz frame retains its 500-microsecond spacing; it is no longer stretched
   to 1 ms. Absolute UTC remains an estimate, not clock synchronization.
2. **Up to four batches can upload concurrently.** Each still contains at most
   1,000 frames. Failures stop new dispatch; every in-flight request and durable
   acknowledgement settles before flush returns or ownership changes. Only
   acknowledged batches leave the pending journal. Retries preserve timestamps.
3. **Receiving remains independent.** The 250 ms pump fetches up to eight
   1,000-frame pages per turn and saves before advancing its arrival cursor.
   Uploading and one-second screen refreshes cannot hold the acquisition pump.
   The UI tests now cover both 1kSPS and 2kSPS while uploads/history are blocked.
4. **Bounded retention and append journals remain in use.** The receiver ring
   retains 60,000 frames with constant-time insertion. The UDP socket requests
   4 MiB (4,194,304 bytes observed here). Flushed native append records and strict
   IndexedDB transactions preserve pending data, compact periodically and keep
   500 acknowledged frames. A full pending journal holds the fetch cursor.

Measurement BLE UUIDs, BM/BB packet layouts, the ADC pipeline, queues, timer,
SQL uniqueness key and provisioning v1 contracts are preserved. No schema
migration is needed: the existing PostgreSQL timestamps retain microseconds.
Restart the API and rebuild/relaunch the collector to use these changes.

## Repeat the acceptance tests

Prepare the local test database and dependencies with the existing setup. From
`app/` in the integration checkout, or the standalone application root:

```powershell
$env:TEST_DATABASE_URL = 'postgresql://capstone@127.0.0.1:55432/capstone'
$env:THROUGHPUT_FPS = '2000'
$env:THROUGHPUT_FRAMES = '360000' # Three minutes at 2kSPS.
$env:THROUGHPUT_UPLOAD_DELAY_MS = '750'
node tools/throughput-test.mjs C:/path/to/flutter/bin/flutter.bat
```

Set `PUB_CACHE` if your SDK uses a custom cache. For the same browser test, add:

```powershell
$env:THROUGHPUT_BROWSER = '1'
$env:CHROME_EXECUTABLE = 'C:/Program Files/Google/Chrome/Application/chrome.exe'
```

For the minimum baseline: remove `THROUGHPUT_BROWSER`, set FPS to `1000` and
frames to `120000`. For the shorter stress case: FPS `3000`, frames `180000`,
`THROUGHPUT_VIEWER='1'`, native mode. Rates 1000, 2000 and 3000 are supported;
frames must be divisible by ten and represent at least 30 seconds. Defaults
are native 1000 FPS, 60000 frames, and 750 ms extra upload delay. On macOS/Linux
pass the Flutter executable path. Do not run expensive post-capture database
verification jobs concurrently when establishing the normal operating rating.

The independent producer uses the correct device-clock period for each rate;
API/SQL pauses cannot slow generation to hide lost samples. The harness requires
exact generated/sent/received/saved/SQL counts, every voltage, every timestamp,
zero reader misses, outage/retry/reload recovery and final drain within 10 seconds.
Unique test records are cleaned up. Test-only failure routes are absent from
production. A nonzero exit or skipped test is **failed/unverified acceptance**.
Browser mode builds a separate test entry point with local engine assets and an
isolated temporary profile, using the same production collector and journal.

## Next bench steps — complete before claiming physical reliability

| Order | Action | Pass condition |
| --- | --- | --- |
| **1 — board** | Build with ESP-IDF; use the real ADC and intended router | Existing 1kHz acquisition builds; ADC read time stays below 1 ms; timing misses, read errors and queue overflow stay zero |
| **2 — phone** | Run the foreground collector on the intended phone, router and deployment database for at least ten minutes at 1kSPS | Every complete frame reaches SQL with 16 readings; no send errors, sequence gaps, CRC errors or reader misses |
| **3 — recovery** | Add 750 ms upload latency and interrupt uploads for ten seconds, keeping UDP/paging reachable | Capture continues; durable backlog drains; lost responses retry without duplicates; no missing readings |
| **4 — headroom** | Feed the target phone a verified 2kSPS UDP source for at least ten minutes, with live history open | Correct counts, microsecond intervals and voltage values; pending backlog remains bounded and final drain is under ten seconds |
| **5 — integration** | Repeat provisioning security, scan, reconnect and persistence cases from the authoritative specification | Provisioning causes no acquisition timing miss, queue overflow or telemetry loss; credentials remain protected |
| **6 — review** | Record board/API/collector/SQL counters and artifacts; review with the team | Physical gates pass; merging remains a later user decision |

Before and after each physical run, reconcile in-flight queue/batch frames and
record `framesDropped`, `bufferOverflows`, `missedTimingEvents`, `adcReadErrors`,
`networkFramesNotSent`, send failures, receiver gaps, reader misses and CRC errors.
Changing the board itself to acquire above 1kHz needs a separate ADC/timing budget
and firmware review; simply increasing its preserved timer is not this change.

## Operating limits

- **UDP has no acknowledgement/replay.** Current firmware discards failed sends.
  RF loss or router outages can lose data despite adequate software capacity.
  Absolute delivery through those failures needs a specified replay transport
  and physical validation.
- **Buffers are finite:** 60,000 frames means 60 seconds at 1kSPS, 30 at 2kSPS,
  or 20 at 3kSPS before accounting for existing backlog. Average database commit
  throughput must exceed input rate to recover outages. Heavy query load and
  slower deployment links can change that balance.
- **A whole API outage differs from an upload outage.** Paging cannot run while
  the API is unreachable; its in-memory ring is lost on restart. A stream-ID
  change stops capture. Already-journaled frames still survive for later upload.
- **Use one foreground collector.** Screen-off/background scheduling, phone
  thermal limits, browser quota/eviction and cross-tab ownership remain physical
  acceptance concerns. Current firmware BLE/USB telemetry sends slower snapshots;
  only UDP presently carries the full measurement stream.

## Files to use for future development

| Area | Start here |
| --- | --- |
| Capture ownership / UI | `apps/monitor/lib/buffered_capture.dart`, `direct_capture.dart`, `screens.dart` |
| Durable buffering / upload workers | `capture_log.dart`, `file_capture_journal.dart`, `browser_capture_journal.dart` |
| Timestamp fidelity / SQL / receiver | `apps/api/src/sample-time.js`, `validation.js`, `postgres-store.js`, `device-receiver.js` |
| Repeatable acceptance | `tools/throughput-test.mjs`, `throughput-producer.mjs`, `apps/monitor/test/support/throughput_check.dart` |
| Physical limits at repository root | `components/acquisition/`, `components/adc/`, `main/network_consumer.cpp`, `components/udp/`, `components/diagnostics/` |

The provisioning v1 specification remains authoritative for provisioning; this
guide covers measurement performance and future physical acceptance.
