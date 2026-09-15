# Stage 2 acquisition test plan

## Scope and architecture

Current test target: classic ESP32 / ESP-32S. Final target: ESP32-S3.
Stage 2 uses FakeADC only. No measurement networking or physical ADC is required.
Existing WiFiManager runs independently; acquisition never waits for Wi-Fi.

GPTimer (1 MHz counter, auto-reloading 1000-count alarm)
-> ISR task notification -> AcquisitionTask -> ADCInterface::readFrame
-> SampleFrame copy -> bounded FreeRTOS queue -> ConsumerTask.
DiagnosticsTask snapshots counters and reports every approximately 5 seconds.

Application priorities: AcquisitionTask 5, ConsumerTask 3, DiagnosticsTask 1.
Tasks are unpinned; ESP-IDF chooses their cores. Higher system priorities remain
available to Wi-Fi and other ESP-IDF tasks. Static stack sizes are 4096, 3072,
and 4096 bytes respectively (ESP-IDF stack parameters are in bytes).
Queue storage is static: 128 * sizeof(SampleFrame), plus its queue control block.
At 1000 frames/s this holds approximately 128 ms of completed frames.
No frame or task-stack allocation occurs during acquisition. GPTimer may allocate
a bounded driver object during startup. Static allocation must remain enabled.

## Acquisition and timing semantics

The ISR only calls vTaskNotifyGiveFromISR and returns whether a context switch is
needed. ADC reads, queue operations and diagnostics all run in task context.
ulTaskNotifyTake(pdTRUE, portMAX_DELAY) clears accumulated notifications at each
wake. The task performs one fresh ADC read per batch, never historical catch-up
reads. The notification count is a bounded 32-bit value, not an event queue.

Successful reads receive consecutive uint32 sequence values starting at 0 and
an esp_timer_get_time timestamp taken immediately before the ADC read.
Sequence wraps naturally after 2^32 successes (about 49.7 days at 1000 Hz).
The consumer accepts this rollover. FakeADC continues to own channel values only.
An ADC failure publishes nothing and consumes no successful-frame sequence number.
Status remains zero; this stage does not define protocol or hardware status bits.

The expected first alarm deadline is captured just before gptimer_start, so wake
lateness includes the small timer-start overhead. Each batch uses the newest
notified deadline. A batch is late if notifications were coalesced, its wake is
more than LATE_THRESHOLD_US (default 250 us) late, or the ADC read takes >= 1000 us.
Whole elapsed schedule periods beyond the notified deadline are also counted as
inferred missed periods and skipped when calculating the next deadline.

missedTimingEvents includes both notifications minus one and these inferred
elapsed periods. It is a timing-health estimate, not an exact hardware alarm
audit; ISR-delivery latency and notification races can affect that estimate.
Maximum wake lateness and ADC read time provide additional evidence.
No strict hard-real-time guarantee is claimed before hardware measurements.

Queue sends use timeout 0. A full queue drops the NEW completed frame, increments
both framesDropped and bufferOverflows, and immediately continues sampling.
Old queued frames remain available to the consumer. Sequence numbers are assigned
before queue send, so dropping a frame becomes a sequence gap downstream.

## Diagnostics

All counters are task-context updates protected by short portMUX critical sections,
including coherent snapshots of the 64-bit acquired/consumed totals. Logging and
queue waits occur outside these critical sections.

| Field | Meaning |
| --- | --- |
| framesAcquired | Successful ADC reads, including frames dropped at publication |
| framesConsumed | Frames removed by ConsumerTask |
| framesDropped | Successful reads rejected by a full queue |
| bufferOverflows | Failed zero-timeout queue sends; one per dropped frame |
| acquisitionLateEvents | Acquisition attempts classified late by the criteria above |
| missedTimingEvents | Coalesced notifications plus inferred skipped schedule periods |
| adcReadErrors | ADCInterface::readFrame returned false |
| sequenceDiscontinuities | Unexpected sequence transitions after the first consumed frame; counts gaps, not missing frame quantities |
| maximumQueueDepthObserved | Highest queue occupancy observed by the producer; may underestimate a transient peak if the other core drains concurrently |
| maximumWakeLatenessUs | Largest observed delay relative to the newest scheduled deadline |
| maximumAdcReadTimeUs | Longest observed ADC call duration |

The report also shows current queue occupancy and measured acquisition rate.
Rate uses the difference in framesAcquired divided by actual elapsed monotonic
microseconds between snapshots, printed to one decimal place. It does not assume
that vTaskDelay wakes after exactly 5 seconds. Counters are cumulative since boot.
32-bit diagnostic counters eventually wrap; they are intended for development
runs of the durations below.

Sample/consumer counts can briefly differ because of queue occupancy and a frame
in transit. After draining, acquired should equal consumed + dropped.
Normal mode should show no drops, overflows, ADC errors, or sequence gaps.
Review late/missed events and measured rate under actual Wi-Fi load; do not infer
timing accuracy solely from successful compilation.

## Build and run

From an activated ESP-IDF terminal at this repository root:

```sh
idf.py set-target esp32
idf.py build
idf.py -p COM3 flash monitor
```

Choose the actual serial port. Exit monitor with Ctrl+].
set-target resets generated local configuration; no sibling project is needed.
Set temporary Wi-Fi credentials in components/wifi/include/wifi_config.hpp.
Record target, ESP-IDF version, build configuration, test mode, actual elapsed
time and diagnostic snapshots for each test. Hardware runs below are pending
until a board is connected; a successful build is not a passed runtime test.

## Tests A-D: sustained acquisition

Keep ENABLE_CONSUMER_STRESS_TEST = false.

| Test | Duration | Approximate successful frames |
| --- | --- | --- |
| A | 10 seconds | 10,000 |
| B | 1 minute | 60,000 |
| C | 10 minutes | 600,000 |
| D | 1 hour (may be deferred) | 3,600,000 |

Measure elapsed time from acquisition startup, or compare counter deltas between
two reports; Wi-Fi initialization before startup is outside the sampling interval.
Check no crash/reset, no drops/overflows, no ADC errors, no sequence gaps, queue
usually near empty, aYou are working inside my Battery/Fuel Cell Monitor MCU_Firmware repository.

STAGE 1 IS COMPLETE AND CURRENTLY BUILDS SUCCESSFULLY FOR A CLASSIC ESP32.

The final board will be an ESP32-S3, but I am currently testing the firmware
on a classic ESP32 / ESP-32S development board.

IMPORTANT WORKSPACE AND SAFETY RULES:

- Work ONLY inside the currently opened MCU_Firmware repository.
- Do not access or modify ../wifi_test or any sibling project.
- Preserve the working Stage 1 architecture.
- Preserve the existing working WiFiManager.
- Do not rewrite the Wi-Fi subsystem.
- Do not add UDP, TCP, Ethernet, BLE, CAN, OLED, packet serialization,
  or RealADC in this stage.
- Do not use Arduino APIs.
- Use ESP-IDF, FreeRTOS, and C++.
- Do not introduce unbounded dynamic allocation.
- Make Stage 2 portable between classic ESP32 and ESP32-S3.

This task is ONLY Stage 2:

1. 1 kHz acquisition timing
2. AcquisitionTask
3. Bounded SampleFrame buffering
4. Consumer/test task
5. Diagnostics
6. Timing and stress-test support

Before modifying anything:

1. Inspect the current repository.
2. Review the existing:
   - SampleFrame
   - ADCInterface
   - FakeADC
   - board configuration
   - WiFiManager
   - app_main()
3. Preserve existing working functionality.
4. Reuse existing files/components rather than duplicating them.

==================================================
STAGE 2 GOAL
==================================================

Implement this architecture:

Timer/Event
    ↓
Task notification
    ↓
AcquisitionTask
    ↓
ADCInterface::readFrame()
    ↓
SampleFrame
    ↓
bounded FreeRTOS queue
    ↓
ConsumerTask
    ↓
Diagnostics

WiFiManager must continue running independently.

The target acquisition rate is:

1000 complete SampleFrames per second

which corresponds to approximately:

1 frame every 1 millisecond

Each SampleFrame contains 16 channel measurements.

==================================================
1. ACQUISITION OWNERSHIP
==================================================

The acquisition subsystem must own:

- sampling cadence
- sequence number
- timestamp
- calling ADCInterface::readFrame()
- publishing completed SampleFrames

FakeADC must continue to be responsible ONLY for generating channel values.

FakeADC must NOT:
- determine timing
- increment sequence number
- assign timestamp
- communicate over a network

For every successfully acquired frame:

frame.sequence = monotonically increasing sequence number

frame.timestamp_us = timestamp in microseconds

Use an appropriate ESP-IDF monotonic microsecond timer such as
esp_timer_get_time() for timestamps.

Do not derive timestamps from network arrival time.

==================================================
2. ACQUISITION TASK
==================================================

Create a FreeRTOS AcquisitionTask.

The AcquisitionTask should:

1. wait for a timing event or task notification
2. wake approximately once every 1 ms
3. create/fill a SampleFrame
4. assign sequence number
5. assign timestamp_us
6. call ADCInterface::readFrame(frame)
7. update diagnostics
8. attempt to publish the frame into a bounded queue
9. immediately return to waiting for the next acquisition event

The AcquisitionTask should have a relatively high application priority.

Do not make it the maximum possible system priority unless necessary.

Document the chosen priority.

Do not perform:
- logging every frame
- network transmission
- OLED updates
- BLE operations
- CAN operations

inside AcquisitionTask.

==================================================
3. TIMER / TIMING EVENT
==================================================

Use an ESP-IDF timing mechanism capable of producing a reliable 1 kHz event.

Prefer a portable ESP-IDF hardware/high-resolution timer mechanism supported
by BOTH classic ESP32 and ESP32-S3.

GPTimer may be used if it is supported cleanly by both configured targets.

If GPTimer introduces target-specific compatibility problems, use an
appropriate ESP-IDF high-resolution periodic timer mechanism instead.

Do NOT use vTaskDelay(1) as the primary acquisition clock.

The timer callback / ISR must remain extremely short.

The timer callback should ONLY do something similar to:

timer event
    ↓
notify AcquisitionTask

Do NOT:
- call FakeADC from the ISR
- enqueue full SampleFrames from the ISR
- send network packets from the ISR
- log from the ISR
- allocate memory from the ISR

Use a FreeRTOS task notification or similarly lightweight ISR-safe mechanism
to wake AcquisitionTask.

==================================================
4. MISSED / LATE TIMING EVENTS
==================================================

Design the timing logic so diagnostics can identify if acquisition is not
keeping up.

Track at minimum:

- acquisitionLateEvents
- missedTimingEvents if practical

If multiple timer notifications occur before AcquisitionTask processes them,
do not silently pretend timing was perfect.

Choose a reasonable implementation and document how missed/coalesced timing
events are detected.

Do not create an unlimited backlog of timer events.

==================================================
5. BOUNDED SAMPLEFRAME QUEUE
==================================================

Use a bounded FreeRTOS queue initially.

Do NOT write a custom ring buffer in Stage 2 unless there is a clear reason.

The queue stores complete SampleFrame objects.

Start with a queue depth of approximately:

128 frames

unless existing memory constraints justify another value.

Document the queue capacity.

At 1000 frames/sec, a 128-frame queue represents roughly:

128 ms

of buffering.

The queue must be created once during initialization.

No per-frame heap allocation should occur.

==================================================
6. QUEUE FULL BEHAVIOR
==================================================

Acquisition timing is more important than waiting for the consumer.

When AcquisitionTask attempts to publish a SampleFrame:

If the queue has room:
    enqueue the frame

If the queue is full:
    do NOT block indefinitely
    increment:
        framesDropped
        bufferOverflows
    continue acquisition

Use a zero or very short bounded queue-send timeout.

Document the chosen behavior.

The system must prefer:

continue sampling + record dropped buffered frame

over:

block acquisition waiting for communications/consumer

==================================================
7. TEST CONSUMER TASK
==================================================

Create a ConsumerTask for Stage 2 testing.

This task should:

1. wait for SampleFrames from the queue
2. receive them
3. increment framesConsumed
4. optionally validate sequence continuity
5. NOT print every SampleFrame

The ConsumerTask represents the future Packetizer/NetworkTask.

It should run at a lower priority than AcquisitionTask.

For normal operation, it should consume frames quickly enough that the queue
usually remains nearly empty.

Do NOT add networking yet.

==================================================
8. CONSUMER STRESS TEST MODE
==================================================

Add a simple development-only way to intentionally slow ConsumerTask.

For example:

constexpr bool ENABLE_CONSUMER_STRESS_TEST = false;

When enabled:

- periodically pause the consumer for a configurable amount of time
  such as 50 ms

The purpose is to verify:

AcquisitionTask continues running
    ↓
queue depth increases
    ↓
consumer resumes
    ↓
queue drains

Do not permanently slow normal operation.

Keep this test option clearly marked DEVELOPMENT / TEST ONLY.

==================================================
9. DIAGNOSTICS COMPONENT
==================================================

Create a diagnostics component if one does not already exist:

components/
└── diagnostics/
    ├── CMakeLists.txt
    ├── diagnostics.cpp
    └── include/
        └── diagnostics.hpp

Track at minimum:

std::uint64_t framesAcquired;
std::uint64_t framesConsumed;

std::uint32_t framesDropped;
std::uint32_t bufferOverflows;

std::uint32_t acquisitionLateEvents;

std::uint32_t adcReadErrors;

If practical also track:

std::uint32_t sequenceDiscontinuities;
std::uint32_t maximumQueueDepthObserved;

Use synchronization appropriate for counters that may be touched by multiple
FreeRTOS tasks.

Do not add unnecessarily heavy locking.

If std::atomic is suitable and supported cleanly, it may be used.

Otherwise use an appropriate FreeRTOS/ESP-IDF synchronization mechanism.

==================================================
10. PERIODIC DIAGNOSTIC LOGGING
==================================================

Create a low-priority DiagnosticsTask or equivalent periodic diagnostic
reporting mechanism.

Print a concise report approximately every 5 seconds.

Example:

=== Battery Monitor Diagnostics ===
Frames acquired:        5000
Frames consumed:        5000
Frames dropped:         0
Buffer overflows:       0
ADC read errors:        0
Late acquisition events:0
Queue depth:            0 / 128
Max queue depth:        4

Do NOT print diagnostics at 1 kHz.

Do NOT print every channel every frame.

Logging must not significantly disturb acquisition timing.

==================================================
11. FRAME SEQUENCE VALIDATION
==================================================

ConsumerTask should optionally validate sequence numbers.

Normal sequence:

100
101
102
103

If it sees:

100
101
103

increment:

sequenceDiscontinuities

Do not crash or stop acquisition.

This will later help detect dropped frames in networking.

==================================================
12. TIMING VALIDATION
==================================================

Add enough diagnostics to determine whether the acquisition system is close
to the required 1000 frames/sec.

Do not calculate rate using assumptions only.

Use elapsed monotonic time.

For example every diagnostic interval calculate approximately:

frames acquired during interval
--------------------------------
elapsed seconds

and log:

Acquisition rate: 999.8 frames/sec

or similar.

Avoid floating point if it significantly complicates embedded code; an
integer or fixed-point representation is acceptable.

Do not require exactly 1000.000 every interval due to scheduling/log timing,
but the design should target 1000 Hz.

==================================================
13. APP_MAIN INTEGRATION
==================================================

Keep app_main() primarily responsible for initialization.

Conceptually:

app_main()
    ↓
log target
    ↓
initialize WiFiManager
    ↓
initialize FakeADC through ADCInterface
    ↓
initialize Diagnostics
    ↓
initialize acquisition queue
    ↓
start AcquisitionTask
    ↓
start ConsumerTask
    ↓
start DiagnosticsTask
    ↓
start 1 kHz timing source

Do not put the acquisition loop directly inside app_main().

Preserve WiFiManager's static/object lifetime requirements.

If Stage 1 currently reads and logs one FakeADC frame at startup, remove or
replace that one-time test only if the continuous acquisition subsystem now
supersedes it cleanly.

Do not remove useful startup checks unnecessarily.

==================================================
14. WIFI MUST REMAIN INDEPENDENT
==================================================

WiFiManager should continue connecting in the background.

Stage 2 should NOT send SampleFrames over Wi-Fi.

This is intentional.

The test should demonstrate:

Wi-Fi activity
      │
      └──────── independent
                 from
                   │
                   ▼
             1 kHz acquisition

Wi-Fi disconnection must not stop AcquisitionTask.

Do not modify WiFiManager unless a minimal compile/integration fix is
absolutely necessary.

==================================================
15. TARGET PORTABILITY
==================================================

CURRENT TEST TARGET:

classic ESP32 / ESP-32S

Use:

idf.py set-target esp32

The design must also remain compatible with the future ESP32-S3.

Avoid classic-ESP32-only APIs when a portable ESP-IDF equivalent exists.

Do not hardcode board GPIOs in acquisition code.

Stage 2 currently uses FakeADC, so no ADC GPIO should be required.

Document any API that may behave differently on ESP32-S3.

==================================================
16. TEST PLAN DOCUMENTATION
==================================================

Update docs/test-plan.md with Stage 2 tests.

Add:

TEST A — 10 seconds

Target:
1000 frames/sec

Expected approximately:
10,000 frames acquired

Check:
- no crash
- no queue overflow
- no ADC error
- acquisition rate close to 1000 Hz


TEST B — 1 minute

Expected approximately:
60,000 frames acquired

Check diagnostics.


TEST C — 10 minutes

Expected approximately:
600,000 frames acquired


TEST D — 1 hour

Expected approximately:
3,600,000 frames acquired

This can be performed later.


TEST E — Consumer stress test

Artificially pause ConsumerTask.

Expected:
- AcquisitionTask continues
- queue fills temporarily
- queue drains afterward if capacity is sufficient


TEST F — Queue overflow test

Intentionally slow ConsumerTask enough to fill the bounded queue.

Expected:
- firmware does not crash
- AcquisitionTask continues
- framesDropped increases
- bufferOverflows increases


TEST G — Wi-Fi interference test

Leave Wi-Fi connected while acquisition runs.

Expected:
- 1 kHz acquisition remains stable


TEST H — Wi-Fi disconnect test

Turn off hotspot/router while acquisition is running.

Expected:
- WiFiManager reconnect logic activates
- acquisition continues
- acquisition counters continue increasing

==================================================
17. BUILD REQUIREMENTS
==================================================

Build for the CURRENT classic ESP32 first.

Run:

idf.py set-target esp32
idf.py build

Fix only compilation/CMake problems introduced by Stage 2.

Do not move on to Stage 3.

Do not add:
- UDP
- packet serialization
- Ethernet
- BLE
- CAN
- OLED
- real ADC SPI
- database/cloud code

==================================================
18. FINAL REPORT
==================================================

After implementation:

1. Show the relevant resulting repository tree.
2. List every file created or modified.
3. Explain the timer → notification → AcquisitionTask flow.
4. Explain why the timer callback is kept short.
5. Explain how SampleFrame enters the queue.
6. Explain what happens if the queue is full.
7. State the queue capacity and approximate milliseconds of buffering.
8. Explain ConsumerTask.
9. Explain all diagnostic counters.
10. Explain the consumer stress-test option.
11. Tell me how to enable/disable the stress test.
12. Confirm WiFiManager remains independent.
13. Run `idf.py build`.
14. Clearly state whether the classic ESP32 build succeeded.
15. Identify anything that may need retesting on ESP32-S3.
16. STOP AFTER STAGE 2.nd rate close to 1000 frames/s.
Suggested initial investigation threshold: sustained rate outside 990-1010
frames/s or repeatedly increasing late/missed counters. This is a development
criterion, not a final acceptance specification. Capture timing outliers rather
than requiring every report to equal 1000.000 frames/s.

## Test E: consumer stress / recovery

Edit components/acquisition/include/acquisition_config.hpp:

```cpp
ENABLE_CONSUMER_STRESS_TEST = true;
STRESS_PAUSE_MS = 50;
STRESS_EVERY_FRAMES = 1000;
```

These names are constexpr settings; keep their declarations when editing values.
Rebuild and flash. ConsumerTask pauses after each 1000 consumed frames.
Expected: acquired/rate continue, observed queue depth rises roughly 50 frames,
then drains, with no overflow if scheduling and capacity are sufficient.
Five-second snapshots may miss the brief fill/drain; inspect maximum queue depth.
vTaskDelay pause length is tick-quantized and may be extended by scheduling.
Restore ENABLE_CONSUMER_STRESS_TEST = false and rebuild for normal operation.

## Test F: deliberate overflow

Enable the same stress option and set STRESS_PAUSE_MS = 250 (greater than 128 ms).
Expected: maximum observed queue reaches 128, framesDropped and bufferOverflows
increase together, acquisition continues without crash, consumer later drains,
and sequenceDiscontinuities increases after consumption resumes.
The rate should remain near 1000 successful ADC reads/s even when publishing drops.
Restore the stress flag to false and pause to 50 ms afterward.

## Test G: Wi-Fi interference

With stress disabled, run connected to the configured router/hotspot for at least
one minute. Inspect rate, lateness, missed events, drops and ADC errors.
Wi-Fi logs may appear alongside diagnostics; no SampleFrame is sent over Wi-Fi.

## Test H: Wi-Fi disconnect / reconnect

While acquisition runs, turn off the router/hotspot, observe WiFiManager reconnect
logs, then restore it. Acquisition and consumption counters must keep increasing;
acquisition must not wait for Wi-Fi. Compare rates before, during and after loss.

## ESP32-S3 retest and later ADC integration

GPTimer, esp_timer_get_time and FreeRTOS notifications are supported on both
targets. Timer clock sources, interrupt latency, available memory and Wi-Fi/core
scheduling can differ; repeat A-H on ESP32-S3 after selecting that target.
The callback's IRAM_ATTR alone does not enable the driver's cache-safe ISR option;
flash/cache-disabled intervals can delay alarms under default configuration.
Review cache safety and timing requirements before background flash writes.

All board pins remain TBD, and Stage 2 touches no GPIO. Before RealADC integration,
ensure its read is bounded, confirm physical sampling/timestamp semantics and
validate full acquisition-cycle timing. Current timestamps indicate software
ADC read start, not a synchronized hardware conversion instant.