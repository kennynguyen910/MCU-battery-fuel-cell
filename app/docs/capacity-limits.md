# Current capture upper bound — measured October 5, 2026

**NORMAL OPERATION: about 6kSPS verified; native 7kSPS fails.**

**DELAYED UPLOADS + OUTAGE: about 3kSPS verified; native 3.5kSPS fails.**

**BOARD: configured at 1kSPS; physical maximum has not been measured.**

Here, SPS means **complete 16-channel frames each second**, so 6kSPS is
96,000 stored channel readings/s, and every channel is sampled at 6kSPS.
Both passing levels were confirmed for **three minutes in native and Chrome**.
These are measured software limits on this development PC. The native normal
boundary is bracketed between **6,000 and 7,000**, and the delayed/outage boundary
between **3,000 and 3,500**. Chrome was validated at those passing levels; its
individual ceiling above them was not searched. Rates inside the brackets remain
untested. These numbers are not universal hard limits or phone/board ratings.

## Confirmed runs

| SPS | Conditions | Collector | Frames / SQL readings | Peak observed pending | Final drain |
| --- | --- | --- | --- | --- | --- |
| 6,000 | Normal uploads | Dart VM / file journal | 1,080,000 / 17,280,000 | 20,790 | 2.785 s |
| 3,000 | 750 ms + 10 s outage | Dart VM / file journal | 540,000 / 8,640,000 | 42,000 | 6.186 s |
| 6,000 | Normal uploads | Chrome / IndexedDB | 1,080,000 / 17,280,000 | 20,830 | 3.293 s |
| 3,000 | 750 ms + 10 s outage | Chrome / IndexedDB | 540,000 / 8,640,000 | 40,540 | 6.468 s |

Every confirmed run had **zero send errors, receiver sequence gaps, invalid
frames and reader misses**. Every stored voltage and microsecond timestamp matched
the independent producer. All expected rows existed, and final pending was zero
after journal reload. Native normal: 180.012 s of wire generation; native delayed:
180.005 s. See [capacity-results.json](capacity-results.json) for every result,
actual wire rate, browser durations, pending-data traces and failed attempts.

The delayed profile adds **750 ms to every successful upload**, injects a
**10-second upload outage**, loses one already-committed response, and reloads
the journal during the outage. The normal profile explicitly disables those
injections. Both include live history **HTTP polling**, real SQL and durable
platform journals. They do not benchmark graph drawing or the physical phone UI.

## Where the boundary appears

The uploader cannot clear pending data fast enough above the passing rates. A
whole new page would exceed the **60,000-frame pending limit**, so capture refuses
the append and retains its fetch cursor. The sustained native **7kSPS attempt
failed after 131.109 s**, and **3.5kSPS with delayed uploads failed after 144.876 s**.
The receiver reported no sequence gaps or invalid frames before these aborts;
that does not make an aborted run successful or lossless.

A **one-minute 8kSPS run passed**, but a subsequent 8kSPS attempt overflowed after
32.626 s. Native 9k, 10k, 12k and 16k also overflowed. Short passes, warm caches
and available database/CPU capacity can conceal an unsustainable rate. The
three-minute passing results define the current verified ceiling; more hours of
capture, larger sessions, other query load and different devices can lower it.

| Candidate SPS | Profile | Runtime | Planned wire run | Result |
| --- | --- | --- | --- | --- |
| 4,000 | Delayed + outage | dart-vm | 60 s | FAIL — pending buffer full |
| 8,000 | Normal | dart-vm | 60 s | PASS |
| 16,000 | Normal | dart-vm | 60 s | FAIL — pending buffer full |
| 12,000 | Normal | dart-vm | 60 s | FAIL — pending buffer full |
| 10,000 | Normal | dart-vm | 60 s | FAIL — pending buffer full |
| 9,000 | Normal | dart-vm | 60 s | FAIL — pending buffer full |
| 8,000 | Normal | dart-vm | 180 s | FAIL — pending buffer full |
| 7,000 | Normal | dart-vm | 180 s | FAIL — pending buffer full |
| 6,000 | Normal | dart-vm | 180 s | PASS |
| 3,000 | Delayed + outage | dart-vm | 180 s | PASS |
| 3,500 | Delayed + outage | dart-vm | 180 s | FAIL — pending buffer full |
| 6,000 | Normal | chrome | 180 s | PASS |
| 3,000 | Delayed + outage | chrome | 180 s | PASS |

## Test environment and current constraints

The production implementation was commit `1af04da`; acquisition, packets,
provisioning, upload workers and storage logic were unchanged for this search.
The workstation has an Intel Core i9-13900H, 20 logical processors and about
32 GB RAM, with Node 24.14.1, PostgreSQL 17.11 and Flutter 3.47.4 / Dart 3.13.3.
Tests used UDP/HTTP loopback and the real local database. Performance tests ran
**sequentially**, including each preceding test's readback and cleanup.

There are four upload workers and at most 1,000 frames/request. Just 750 ms of
latency puts a theoretical pre-processing upload ceiling below 5,334 frames/s;
SQL, serialization, journal commits and scheduling reduce the observed ceiling.
A 60,000-frame backlog holds 10 seconds at 6kSPS or 20 seconds at 3kSPS, before
accounting for existing pending frames. Absolute delivery through radio/router
loss still needs an acknowledged replay transport; present UDP has none.

The board's `components/acquisition/include/acquisition_config.hpp` retains
`PERIOD_US = 1000`: **the current acquisition configuration produces at most
1,000 complete frames/s**. These host tests do not increase its timer, establish
real ADC headroom, or validate an attached ESP32/phone. Keep the existing **2kSPS
software target / 1kSPS minimum** until physical acceptance passes; the measured
ceilings are headroom evidence, not a new firmware setting.

## Reproduce

Prepare the existing local test database and Flutter dependencies. From `app/`
in the integration branch, or the standalone app root:

```powershell
$env:TEST_DATABASE_URL = 'postgresql://capstone@127.0.0.1:55432/capstone'
$env:THROUGHPUT_FPS = '6000'
$env:THROUGHPUT_FRAMES = '1080000' # Three minutes.
$env:THROUGHPUT_UPLOAD_DELAY_MS = '0'
$env:THROUGHPUT_FAULTS = '0'
$env:THROUGHPUT_VIEWER = '1'
$env:THROUGHPUT_BROWSER = '0'
node tools/throughput-test.mjs C:/path/to/flutter/bin/flutter.bat
```

For browser mode set `THROUGHPUT_BROWSER='1'` and `CHROME_EXECUTABLE` to your
installed Chrome path. For the outage profile set FPS `3000`, frames `540000`,
delay `750`, and faults `1`. Set `PUB_CACHE` if your SDK uses a custom cache.
To verify failure boundaries, use native 7000 / 1260000 frames without injections,
or 3500 / 630000 frames with delay/outage. Keep the ten-second final-drain limit
and every correctness assertion. Capture **both successes and failures** from
`CAPACITY_RESULT`; do not run performance tests concurrently.

## Next work if higher sustained rates are needed

1. Profile SQL upload/commit latency and collector acknowledgement costs under
   backlog; measure how live history count queries scale with session length.
2. Repeat at 6.5kSPS normal and 3.25kSPS delayed to narrow the remaining intervals;
   use multiple longer runs and deployment database/network conditions.
3. Validate the foreground phone and real ADC at the current 1kHz acquisition
   setting, then review any separately requested firmware rate increase.

See the [capture next-steps guide](1ksps-capture.md) for physical acceptance.
