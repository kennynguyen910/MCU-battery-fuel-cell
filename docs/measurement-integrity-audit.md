# Measurement provenance and receiver integrity audit

Audited from executable source on 2026-10-08, branch `firmware/provisioning-v1`.
No hardware was flashed or exercised. The Git main branch was not modified.

## 1. Executive conclusion

**App source classification: MIXED. Current firmware ADC source: FAKE.**

The firmware's `app_main()` instantiates `FakeADC` through `ADCInterface`.
Its voltages are a deterministic triangular waveform: 1,000,000 + channel ×
10,000 + ramp × 1,000 microvolts. There is no peripheral read.
Those frames can reach Android directly over BLE, or reach Flutter through
the laptop UDP receiver and HTTP API. Flutter's default mobile collector is
manual/API mode until the operator selects the device receiver.
The separate web entry displays saved API/database rows.

Other available inputs are explicitly entered manual bench values and an
operator-enabled network simulator. The simulator generates sine values in
Node, not Flutter. Existing database history can contain any of these inputs.

**Real hardware ADC data is not yet available.**
The source trace does not prove any current physical ADC measurements.
The running firmware installed on any particular device was not inspected;
these conclusions describe this checkout and the locally built configuration.

## 2. Complete source trace

All paths below are relative to the repository root. Each row describes actual
code; documentation alone was not used to infer behavior.

| File | Class/function | Input → output; transformation / generation |
| --- | --- | --- |
| firmware/main/main.cpp | app_main | Kconfig choice → explicit FakeADC instance, bound as ADCInterface. REAL fails compilation; NONE leaves Wi-Fi/BLE provisioning available but disables measurement acquisition. |
| firmware/components/adc/fake_adc.cpp | FakeADC::init / readFrame | init resets phase; readFrame generates all 16 signed integer microvolt values and ORs the simulated status bit. This is the active generator. |
| firmware/components/adc/include/adc_interface.hpp | ADCInterface | Abstract init/readFrame interface; no driver, source substitution, conversion or fallback logic. |
| firmware/components/acquisition/acquisition.cpp | Acquisition::start / onAlarm | GPTimer alarm each 1,000 µs → task notification. ISR does not read ADC, serialize or send. |
| firmware/components/acquisition/include/acquisition_task.hpp | Acquisition constructor adapter / read_frame_ | ADCInterface reference → callback invoking readFrame on that same source; no automatic substitute. |
| firmware/components/acquisition/acquisition.cpp | Acquisition::acquisitionTask | Successful read → sequence++, timestamp_us = monotonic ADC-read start. Source channels and status preserved. Failed reads are not published; diagnostics count failures. |
| firmware/components/acquisition/include/latest_frame_store.hpp | LatestFrameStore::publish / read | Complete SampleFrame copied under a critical section; no conversion, replacement or generation. |
| firmware/components/acquisition/acquisition.cpp | xQueueSend / Acquisition::networkTask / xQueueReceive | Complete SampleFrame copied through static bounded queue (128 frames); nonblocking producer, separate network task. Queue loss is counted. |
| firmware/main/network_consumer.cpp | NetworkConsumer::consumeFrame / consume | Queued frame → Packetizer::serializeMeasurement → existing batch buffer. Copies up to 10 packets. No measurement generation. |
| firmware/components/protocol/packetizer.cpp | Packetizer::serializeMeasurement / crc32 | SampleFrame → 88-byte BM v1 packet; signed values preserved as two's-complement bits, all fields big-endian, CRC32 over bytes 0–83. Status unchanged at offset 80. |
| firmware/main/network_consumer.cpp | NetworkConsumer::flush / flushExpired | Up to 10 complete packets + 10-byte BB envelope → one UDP send; partial batch flush after 20 ms. Network failure drops batch with diagnostics; never substitutes values. |
| firmware/components/udp/udp_transport.cpp | UdpTransport::init / send | Nonblocking IPv4 socket sends bytes to compiled destination; no transformation or retry generator. |
| firmware/components/ble/ble_manager.cpp | BLEManager::updateTask / update / encodeVoltage | LatestFrameStore → latest 80-byte value about every 100 ms, conditional on subscription and MTU ≥83. Channels/status unchanged, big-endian. Intentional acquisition downsampling. |
| mobile_app/lib/device_connections.dart | _connectBle notification callback | Requests MTU 128; subscribes to measurement characteristic only if negotiated MTU ≥83; callback → decodeBleVoltage → DirectCapture.add. No sample substitute on disconnect/error. |
| mobile_app/lib/device_packets.dart | decodeBleVoltage | Exactly 80 bytes → sequence, raw ESP timestamp, 16 signed int32 channels divided once by 1,000,000, status at offset 76. No application CRC exists in this BLE format. |
| mobile_app/lib/direct_capture.dart | DirectCapture.add | Valid sample → ReceiverIntegrity.accept → latest/receivedAt, then bounded capture queue if capturing. Invalid/duplicate/late/timestamp-regressed samples cannot replace live data. No generation. |
| mobile_app/lib/device_connections.dart | build / _tick | Latest valid frame → VoltageTiles, source badge and diagnostics; values hidden after 2 s. UI refreshed by 500 ms timer, independently of notification acceptance. |
| mobile_app/apps/api/src/device-listener.js | startDeviceListener | Laptop UDP socket bound to 0.0.0.0:5005 by default; optional sender-IP filter; all datagrams → app.locals.ingestDeviceDatagram. Socket closes on shutdown. |
| mobile_app/apps/api/src/device-udp.js | inspectDatagram / frameAt | 88-byte frame OR BB batch containing 1–10 frames → per-frame header/CRC validation and signed microvolt conversion. Valid neighbors survive a damaged frame in an otherwise valid batch. |
| mobile_app/apps/api/src/app.js | app.locals.ingestDeviceDatagram | Calls DeviceReceiver.ingest; no substitution, no direct database write. |
| mobile_app/apps/api/src/device-receiver.js | DeviceReceiver.ingest | Valid decoded frames → per-IP sequence metrics, exact device time string, receipt time, reconstructed UTC, 60,000-frame bounded ring and latest frame. Duplicate/late packets do not refresh freshness. |
| mobile_app/apps/api/src/app.js | /device-input, /device-sources, /device-frames | Receiver → authenticated JSON latest/diagnostics or arrival-cursor pages (≤1,000 frames). No sample generation. |
| mobile_app/lib/screens.dart | Dashboard.refresh | HTTP /device-input in device mode; /test-input in manual mode → live list and VoltageTiles. Network errors/null/invalid frames clear visible live readings. Screen poll is once per second. |
| mobile_app/lib/buffered_capture.dart | BufferedCapture.start / pump / _pump | Arrival cursor → independent 250 ms capture pump, up to eight 1,000-frame pages per turn → CaptureLog.appendAll. Cursor advances only after durable local save. All returned frames retained; UI refresh does not sample the capture stream. |
| mobile_app/lib/capture_log.dart; capture_journal_codec.dart; file_capture_journal.dart; browser_capture_journal.dart | CaptureLog.appendAll / flush and journal replay | Full local frame metadata saved before upload. Retries reuse frame IDs/timestamps. Pending storage is bounded; overflow reported. Acknowledged logs retain only recent uploaded entries (500), not a permanent provenance archive. |
| mobile_app/lib/api.dart | Api.uploadFrames | Local frames → HTTP samples containing recordedAt + channels only. Drops frame provenance and raw ESP timestamp from upload contract. |
| mobile_app/apps/api/src/validation.js; memory-store.js; postgres-store.js | validateSamples / addSamples | Valid 16-channel voltage sample → 16 per-channel rows; transaction and timestamp/channel conflict keys prevent duplicate retries. No generated substitute. |
| mobile_app/lib/screens.dart; history.dart | Dashboard.refresh / HistoryPanel / VoltageHistoryChart | Stored API rows → latest channel tiles and paired time/voltage points. Graph joins recorded samples; does not create stored measurements. History is visibly SOURCE UNVERIFIED because database rows lack frame provenance. |

USB is an additional direct path: `_connectUsb` opens Android serial at 115,200;
`UsbMeasurementLines.add` reassembles `BMHEX:` text containing the same
CRC-protected 88-byte packet, calls `decodeUsbMeasurement`, then
`DirectCapture.add`. The main firmware does not emit these measurement lines;
`firmware/examples/usb-console/usb_measurement_console.hpp` is an optional
extension. Ordinary diagnostic console text is never treated as a measurement.

### Additional input traces

* Manual: `Dashboard.publish` posts the 16 values entered by the operator to
  `/test-input`; `validateSamples` validates them and sets a receipt timestamp
  and frame ID. The collector explicitly labels them MANUAL TEST INPUT / NOT
  HARDWARE. Publishing alone does not write database rows.
* Network simulator: `server.js` enables `NetworkSimulator` only with
  `NETWORK_SIMULATION_ENABLED=1`, requires login configuration, binds a
  separate loopback listener and starts in the stopped scenario. The demo
  launcher also starts this explicit simulator. `encodeBatch` generates sine
  values and now sets the simulated bit before CRC. Every collector shows the
  per-frame badge, even without a demo query parameter.
* Web: `main.dart` selects history on web and the collector on native platforms; `main_mobile.dart` explicitly selects the collector;
  `main_input.dart` the manual publisher. Stored rows are authoritative for
  history values, not proof of physical origin.

## 3. FakeADC audit

| Question | Before hardening | After hardening |
| --- | --- | --- |
| Compiled? | Yes, adc CMake SRCS unconditionally includes fake_adc.cpp. | Yes in current FAKE build; compiled only for the FAKE choice. |
| Instantiated / active? | Yes, static FakeADC in app_main. | Yes, current sdkconfig and checked-in development defaults explicitly select FAKE. |
| Selection? | Hardcoded class; neither clean Kconfig nor runtime selection. | Mutually exclusive compile-time NONE / FAKE / REAL choice. Kconfig default NONE; development sdkconfig.defaults explicitly enables FAKE. |
| Real-failure fallback? | None; RealADC does not exist. | None; selecting REAL fails compilation. |
| Could run without an obvious warning? | Yes; ordinary startup did not prominently warn. | Supported app_main path prints the prominent warning once; every generated frame is marked. Tests instantiate FakeADC without runtime logs but verify its flag. |
| Reach UDP? | Yes, NetworkConsumer → packetizer → UDP. | Yes, visibly simulated; still available for development. |
| Reach BLE? | Yes, LatestFrameStore → encodeVoltage. | Yes, same 80-byte packet with simulated status. |
| Reach Flutter? | Yes, direct BLE or UDP/API. | Yes, explicit simulated banner. |
| Flutter distinguish it? | Could parse status but no provenance flag/label existed. | New flagged frames yes; old status=0 firmware remains UNKNOWN, never asserted real. |

**CURRENT ACTIVE MEASUREMENT SOURCE: FAKE (compile-time CONFIGURABLE after hardening).**

## 4. RealADC audit

No RealADC class or project hardware ADC implementation exists. No project ADC
SPI transfers, channel-to-physical-pin mapping, ADC code conversion, calibration
or real-source instantiation was found. ESP-IDF's generic SDK ADC/SPI components
are not a project measurement driver. Board GPIO mappings remain TBD.
Hardware testing is unproven. Selecting REAL deliberately fails compilation with
“Real hardware ADC data is not yet available.” No hardware behavior was invented.

## 5. Flutter mock/generated-data audit

No production Dart generator creates measurement values automatically. Matches
were checked by executable use, including production libraries, tests and Node
inputs, with `mock|fake|demo|sample|random|Random|Timer.periodic|sin|sine|
generate|simulation|placeholder|dummy` and measurement/voltage searches.

| Match group / files | Classification and actual role |
| --- | --- |
| lib/device_packets.dart List.generate / DeviceSample | Production decoder: all values come from transport bytes. |
| lib/device_connections.dart List.generate / timers | Production UI channel indexing, 500 ms drain/display and scan timeout; no generated values. |
| lib/direct_capture.dart Random.secure / DateTime | Production random capture-epoch identity and host clock anchor; does not generate voltages. |
| lib/screens.dart inputs initialized to '0' | Production manual-entry fields; sent only by explicit operator Publish action and clearly labeled manual. No receive-failure fallback. |
| lib/screens.dart demoMode / simulation / setScenario | Explicit demo UI and operator controls for the development Node generator. Per-frame provenance is independent of demoMode. |
| lib/screens.dart List.generate / Timer.periodic | Production channel controllers/tiles and receive/upload/display scheduling. Reads APIs; never synthesizes fallback readings. |
| lib/demo_widgets.dart | Production shared presentation widgets and explicit Network Lab diagnostics; class/file names do not imply a generator. |
| lib/history.dart plotting / math | Production stored-row plotting, scaling, channel choices and connecting samples; no fabricated saved samples. |
| lib/capture_log.dart List.generate | Production parallel upload workers; no measurement generation. |
| lib/wifi_provisioning.dart Timer.periodic | Unrelated provisioning status polling. |
| lib/log_storage_web.dart demo query / run | Development log namespace isolation; does not create samples. |
| lib/main.dart, main_input.dart comments | Entry-role comments; no generator. |
| test/*_test.dart, test/support/provisioning_fake.dart | Test-only deterministic measurements, HTTP/storage fakes and simulated provisioning events. The active IDE provisioning fake is not imported by lib/. |
| test/support/throughput_check.dart and throughput entry | Test-only generated throughput fixtures; not production entry points. |
| apps/api/src/network-simulator.js encodeBatch | Development-only operator-enabled sine generator. Previously status=0; now explicitly SIMULATED in every frame. |
| apps/api/src/app.js /test-input | Production-accessible manual bench input, explicitly labeled; values supplied by operator, not generated automatically. |
| apps/api/src/user-auth.js random fallback hash | Unrelated authentication; no measurements. |
| apps/api/test/*, tools protocol fixture generation | Test-only deterministic protocol/data fixtures. |
| firmware BLE config_value_ placeholder | Unrelated no-op configuration byte; never substitutes voltage values. |

No BLE disconnect, UDP outage, CRC failure, parser error or empty database
causes a local measurement generator to run.

## 6. Transport, rate and duplication boundaries

* BLE measurement service `5ecf0000-41c2-4cc4-9c96-640f406021d0`,
  Voltage Data `5ecf0001-41c2-4cc4-9c96-640f406021d0`; low-rate latest-frame
  display, approximately 10 Hz, not lossless 1 kHz acquisition.
* Provisioning uses independent `5ecf1000`–`5ecf1003` service/characteristics.
  Its protocol, encrypted credential handling and measurement UUIDs are unchanged.
* UDP carries the queued acquisition stream; normally 10 ×88 +10 =890 bytes.
  Flutter contains no direct UDP socket. Node receives on the laptop; Flutter
  pages buffered data through HTTP and uploads recordings to the API.
* Direct BLE/USB routes stop parent collector capture before owning the local
  journal; returning can select the API/UDP collector. BLE and USB disconnect
  before switching. They are not combined into one capture count. Sequence
  diagnostics are transport-specific; API deduplicates accepted per-source
  frames and database retries are timestamp/channel-idempotent.
* No hardware throughput claim follows from these software tests. Existing
  1 kHz timer, priorities, queue capacity and acquisition task are unchanged.
* Android has INTERNET and ACCESS_NETWORK_STATE for HTTP, BLE permissions and
  USB host support. No Android UDP bind path requires auditing or adding here.

## 7. Provenance hardening

`SAMPLE_STATUS_SIMULATED = 0x80000000` (bit 31). No existing named
SampleFrame measurement status bit occupied it. Provisioning flags are a
separate schema and not collisions. The golden packet's arbitrary status word
is a serialization fixture, not a hardware-source declaration.

FakeADC ORs this bit so other status bits survive. Acquisition does not overwrite
status; latest store and queue copy the entire frame. UDP serializes status at
80; BLE at 76. Dart and Node decode the original field. Node simulator marks it
before calculating CRC. No SampleFrame member, UDP size, BLE size or UUID changed.

Direct and API live views visibly show SIMULATED DATA. Unmarked values show
UNKNOWN/unverified hardware; absence of the bit cannot prove real hardware
because older firmware used status=0 for FakeADC. Manual data is explicitly
labeled. History always warns that its origin is unverified and may include
simulated/manual data. New session notes repeat this limitation.

Raw device time, status, source and receipt time survive the direct local
journal; buffered API frames already retain these. The existing upload/schema
stores only voltage plus reconstructed UTC. A future per-frame database
provenance extension would be necessary to classify historical rows definitively.

## 8. Receiver integrity

| Item | Result / limitation |
| --- | --- |
| Frame size/header | UDP/USB exactly 88 bytes, BM magic 0x424d, version=1, type=1; BLE exactly 80 bytes. |
| Batch validation | Node validates BB magic/version/type, count 1–10 and exact length 10 + count×88. No datagram=frame assumption. Sound batch neighbors are independently decoded. |
| CRC | UDP/USB CRC32, polynomial 0xedb88320, init/final XOR 0xffffffff, first 84 bytes. Corrupt frames never reach live/capture. BLE has no application CRC; link-layer error handling does not add one to this payload. |
| Counters | API received/unique/missing/duplicate/late/invalid-frame/invalid-datagram/CRC/restart/timestamp counters. Direct received/missing/duplicate/out-of-order/restart/timestamp/invalid-value/overflow counters; USB parser invalid count. |
| Sequence arithmetic | Unsigned uint32 modular delta; duplicates and backward arrivals rejected without moving baseline or renewing receipt time. Inferred gaps accumulate; late arrivals do not undo an earlier gap estimate. |
| Reboot | Direct estimates low seq ≤10 + backward sequence + regressed timestamp (excluding sequence rollover region). API existing estimate: low seq ≤10 + device time regression >1 s. No boot ID means delayed old packets can look like reboot, early/late missed reboots remain ambiguous. API timestamp guard rejects forward-sequence regression; no millions-of-missing arithmetic for recognized reboots. |
| BLE loss meaning | Missing acquisition sequence slots include intentional 1 kHz→10 Hz latest-frame selection. This is not a direct count of dropped BLE notifications. Full-rate UDP gaps are the useful acquisition-stream estimate. |
| Stale detection | Direct BLE/USB 2 s since last accepted frame (20 expected BLE periods); values hidden and STALE / NO LIVE DATA shown. Duplicate/invalid/late traffic cannot keep data live. API uses existing 5 s timeout, accommodating laptop/API scheduling; 1 s screen polling means another poll delay before UI observes receiver staleness. HTTP timeout=5 s and errors clear live values. |
| Timestamps | ESP measurement time is monotonic ADC-read-start time. Raw timestamp stays distinct from receipt time; UTC recordedAt is anchored once per estimated boot and kept monotonic for SQL keys, not a synchronized ESP clock. Raw time preserved locally/API receiver, not existing database rows. |
| MTU | Firmware and Flutter require MTU ≥83 for 80-byte notifications; Android requests 128. Below threshold, provisioning remains available, notification capture disabled with visible message; no truncation. Firmware reads have stable read-blob snapshot at small MTU; Flutter currently uses notifications. |
| UI performance | Direct callbacks process every delivered frame, display tick=500 ms. API processes every valid UDP frame, bounded ring=60,000; collector capture tick=250 ms/pages; UI tick=1 s. No 1,000-rebuild/s UI loop. |
| Invalid channel values | Direct capture rejects before latest update; buffered capture validates all 16 finite values within existing app ±5 V acceptance range before durability/cursor advance; dashboard hides invalid decoded values. |

### Channel order and units

Packet offsets below are zero-based within each frame. In UDP batch frame n,
absolute channel offset is 10 + 88×n + the UDP offset. All channels are signed
int32 big-endian microvolts divided **once** by 1,000,000.
1,234,567 µV →1.234567 V. No raw ADC code is asserted to be a voltage.
There is no physical pin mapping yet.

| Firmware index | UDP/USB byte offset | BLE byte offset | Flutter index | Display |
| --- | --- | --- | --- | --- |
| 0 | 16 | 12 | 0 | CH 1 |
| 1 | 20 | 16 | 1 | CH 2 |
| 2 | 24 | 20 | 2 | CH 3 |
| 3 | 28 | 24 | 3 | CH 4 |
| 4 | 32 | 28 | 4 | CH 5 |
| 5 | 36 | 32 | 5 | CH 6 |
| 6 | 40 | 36 | 6 | CH 7 |
| 7 | 44 | 40 | 7 | CH 8 |
| 8 | 48 | 44 | 8 | CH 9 |
| 9 | 52 | 48 | 9 | CH 10 |
| 10 | 56 | 52 | 10 | CH 11 |
| 11 | 60 | 56 | 11 | CH 12 |
| 12 | 64 | 60 | 12 | CH 13 |
| 13 | 68 | 64 | 13 | CH 14 |
| 14 | 72 | 68 | 14 | CH 15 |
| 15 | 76 | 72 | 15 | CH 16 |

## 9. UDP destination

Compiled destination remains **10.245.67.225:5005** in
`firmware/components/udp/include/udp_config.hpp`.
`UdpTransport::init` uses it directly. Wi-Fi provisioning knows the ESP's
own network/IP state; it does not register a phone/laptop receiver address.

For the implemented laptop-receiver architecture, the compiled IP must match
the laptop's Wi-Fi IPv4 address, its listener must be enabled, and UDP 5005 must
be reachable on the same network. The phone only needs the API's reachable URL.

**BLOCKER FOR PHONE UDP RECEIVING:** no native Flutter UDP socket and no
runtime destination registration. Direct phone UDP is not the current path.
Smallest future routing change would be an independently specified, validated
SET_UDP_DESTINATION command with IPv4+port, initially volatile, plus a phone
receiver. That would require a deliberate protocol extension; none was added
to provisioning v1 during this work.

## 10. Files changed

Firmware:
* components/acquisition/include/acquisition.hpp
* components/adc/include/adc_interface.hpp
* components/adc/fake_adc.cpp
* components/adc/CMakeLists.txt
* main/Kconfig.projbuild
* main/main.cpp
* sdkconfig.defaults
* tools/test_measurement_source.cpp

Flutter:
* lib/device_packets.dart
* lib/receiver_integrity.dart
* lib/direct_capture.dart
* lib/device_connections.dart
* lib/demo_widgets.dart
* lib/screens.dart
* lib/api.dart
* test/measurement_integrity_test.dart

API:
* apps/api/src/device-udp.js
* apps/api/src/network-simulator.js
* apps/api/src/device-receiver.js
* apps/api/src/app.js
* apps/api/test/measurement-integrity.test.js

Report: docs/measurement-integrity-audit.md (this file).

## 11. Tests

* Flutter: **99 passed**. New deterministic tests cover all 16 signed channels,
  endian/units/status, corrupt/truncated packets, source badge, uint32 wrap,
  gaps/duplicates/reordering/reboot, timestamp regression, stale renewal,
  invalid values/no-data behavior and durable raw timestamp/status metadata.
* Node API/UDP: **39 passed, 9 skipped**, 48 total. New tests cover simulation
  source, signed channels, exact 64-bit timestamp string, all ten batch frames,
  damaged neighbors, batch truncation/count, wrap/reboot/gap/duplicate/late,
  timestamp regression, stale and no-data behavior. PostgreSQL-dependent cases
  were skipped because no test database URL was provided.
* Existing Python firmware UDP tests: **6 passed**.
* Existing Python shared protocol tests: **3 passed**.
* New C++ `firmware/tools/test_measurement_source.cpp` tests 401 FakeADC frames,
  all channel values, preservation of other status bits, 88-byte serialization,
  simulated status bytes, CRC and existing fixed packetizer golden self-test.
  A runnable native host compiler is unavailable in this environment. Attempted
  esp-clang compilation reached linking, but that compiler targets embedded
  RISC-V and failed with unresolved unwind symbols; this test was **not run**.
  Run on a host with a native C++17 compiler (from repository root):

```sh
g++ -std=c++17 -Ifirmware/components/adc/include -Ifirmware/components/acquisition/include -Ifirmware/components/protocol/include firmware/tools/test_measurement_source.cpp firmware/components/adc/fake_adc.cpp firmware/components/protocol/packetizer.cpp firmware/components/protocol/packetizer_self_test.cpp -o test_measurement_source
./test_measurement_source
```

BLE serialization's status preservation and whole-frame acquisition/latest-store/
queue behavior are source-verified; these host tests do not execute FreeRTOS,
NimBLE or the physical link. RealADC tests are not applicable without a driver.

## 12. Build and checks

Current `idf.py build` succeeded for **ESP32**, using ESP-IDF 5.5.5 and the
existing local target config (not changed to S3). Application binary:
**0xfbbd0 = 1,031,120 bytes**. App partition: **0x100000 = 1,048,576 bytes**.
Remaining: **0x4430 = 17,456 bytes (about 2%)**.
Build warns that the app partition is nearly full. Partition table was not changed.
No flashing command was executed. S3 hardware acceptance was not performed.

Flutter `analyze --no-pub`: no issues found.
Final incremental ESP32 build succeeded with the same binary size/headroom.
Final Flutter analysis again reported no issues. Dart formatting was applied to
modified files; git diff --check reported no whitespace errors. Git printed
CRLF-to-LF normalization notices for modified app files. The unchanged
acquisition task, timer, queue, measurement serializers and UUID definitions
were checked in the diff; only the source status constant and source wiring
changed on that path.

## 13. Remaining blockers before claiming physical measurements

1. Specify actual ADC part, wiring, pin/channel order, input range, reference,
   sample timing, SPI transaction and data format.
2. Implement RealADC/ADCInterface hardware reads and calibrated signed microvolt
   conversion; reject failed/incomplete reads instead of substituting FakeADC.
3. Wire explicit REAL selection only after that driver exists; include source
   identity/version evidence that lets new clients confirm real hardware without
   treating every legacy zero-status frame as real.
4. Prove physical end-to-end data with calibrated input/DMM and frame capture.
5. Verify sustained full-rate acquisition/queue/UDP performance on final S3;
   BLE alone intentionally cannot prove all 1,000 acquisition frames/s.
6. Verify laptop destination/listener/API routing or separately scope phone UDP.
7. Decide how to persist frame provenance/raw ESP time before making historical
   database-origin claims; current history is explicitly unverified.
8. Resolve limited app-partition headroom before adding a substantive hardware
   driver, without changing the partition table in this task.

## 14. Hardware test procedure (future acceptance, not executed)

1. Obtain and record ADC part/datasheet, schematic, reference voltage, safe input
   range, channel wiring, conversion/calibration equations and expected error
   tolerance. Implement and review real SPI reads first. Do not select an
   invented driver or apply voltages to unspecified pins.
2. Build an explicitly REAL configuration after implementation; retain sdkconfig,
   commit, map file and binary hash. Confirm FakeADC is absent from the linked
   image and startup announces REAL hardware. If driver initialization fails,
   require no published measurements and a clear fault; never fall back.
3. Disable Node simulator and manual publishing. Choose one receiver path:
   full-rate UDP to the correctly configured laptop IP/5005 with authenticated
   API/collector, or direct BLE at negotiated MTU ≥83 for 10 Hz latest frames.
   Start with no data, confirm empty/stale UI, then start a clearly named test
   session and save receiver diagnostics.
4. For each physical channel 0–15 independently, connect a calibrated source
   through the confirmed safe analog interface. Apply zero and two distinct safe
   reference levels chosen from the specified input range; record exact DMM
   readings and tolerance. If the verified front end supports 1.234567 V, include
   that level to check 1,234,567 µV→1.234567 V. Use negative voltage only if the
   verified hardware supports it.
5. Capture raw ADC codes/conversion results, SampleFrame sequence/time/channels/
   status, transport bytes and app local records for each stimulus. Confirm only
   the intended channel changes, in the mapping above; all 16 values, signs,
   units and physical pin order agree. SIMULATED must be absent, and driver/source
   build evidence must independently identify REAL; a zero bit alone is not proof.
6. Change and remove the physical stimulus. Verify displayed values respond to
   the measured input rather than FakeADC's repeatable triangular pattern or
   Node's sine generator. Compare the saved raw ESP times to packet bytes and
   reconstructed UTC separately.
7. Test ADC read/init faults safely using the hardware specification: no synthetic
   values, no successful-frame publication on failed reads, diagnostic read-fault
   count increases and UI expires as stale. Restore and verify recovery.
8. Stop transport, send duplicate/late packets via a separate labeled test fixture,
   and damage UDP payload CRC. Verify accepted value and receive age do not
   renew on rejected packets, counters increase, and stale UI clears on the next
   new valid hardware frame. Reboot ESP and verify timestamp/session reset
   handling without an enormous missing count.
9. Run full-rate UDP capture long enough to assess 1 kHz, all 16 channels, queue/
   scheduling/network drops, CRC failures and bounded-buffer losses. Compare
   firmware generated/transmitted diagnostics with accepted sequence range and
   durable collector frames. Run BLE separately; its intentional sequence skips
   are not full-rate packet loss.
10. Review database uploads and all history screens. Retain raw packet/log/build/
    stimulus evidence outside the pruned upload journal; database rows alone
    cannot establish source or raw ESP time with the current schema. Claim
    physical ADC measurements only after the entire evidence chain agrees.

## Required YES / NO / PARTIAL answers

| Question | Answer |
| --- | --- |
| FakeADC currently active? | YES for this checkout's current build. |
| FakeADC data can reach Flutter? | YES, direct BLE or UDP/API. |
| Flutter identifies simulated data? | YES for new flagged frames; legacy frames remain UNKNOWN. |
| Flutter generates production mock measurements? | NO automatic Dart generator; operator-entered manual test values remain explicit. |
| All 16 channels decoded from transport? | YES. Physical pin mapping remains unknown. |
| Sequence loss detected? | YES as inferred gaps; BLE gaps include intentional downsampling. |
| Stale data detected? | YES; direct 2 s, API receiver 5 s. |
| Packet corruption detected? | PARTIAL: UDP/USB CRC yes; BLE has no application CRC. |
| ESP timestamp preserved? | PARTIAL: transport/receiver/local journal yes; existing database stores reconstructed UTC only. |
| App distinguishes real vs simulated? | PARTIAL: SIMULATED vs UNKNOWN; legacy bit-clear status cannot prove REAL. |
| RealADC implementation exists? | NO. |
| RealADC currently active? | NO. |
| Truthfully claim physical ADC measurements today? | NO. |
