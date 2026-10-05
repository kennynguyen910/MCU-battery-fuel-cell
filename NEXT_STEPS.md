# NEXT STEPS - MCU + APP INTEGRATION

**START HERE:** Implement the secure firmware credential flow. The Flutter client is ready; the firmware currently supports only Wi-Fi status and scanning.

**As of:** September 29, 2026 | **Baseline:** `0715fe4` | **Branch:** `codex/flutter-wifi-provisioning-2026-09-29`

[Download the three-page visual guide](docs/Capstone_Next_Steps_Guide.pdf) | [Detailed integration architecture](docs/integration.md) | [Authoritative protocol PDF](app/docs/Will%20and%20Kenny%20Startup.pdf)

## At a glance

**Measurement performance update (October 5):** Native and browser collectors
each preserved 360,000 complete frames at 2kSPS over three minutes, including
delayed uploads, outage recovery and accurate microsecond intervals. The 1kSPS
minimum and a shorter 3kSPS stress run also passed.
See the [capture next-steps guide](app/docs/1ksps-capture.md) for results, reproduction,
and the physical phone/ESP32 gate. The linked September PDF remains a dated
provisioning roadmap.

**Current measured software ceiling:** normal uploads passed 6kSPS for three
minutes in native and Chrome; the delayed-upload/outage profile passed 3kSPS.
Native 7kSPS / delayed 3.5kSPS exhausted the pending buffer. The
[upper-bound report](app/docs/capacity-limits.md) preserves all attempts and
conditions. Firmware acquisition remains configured at 1kHz.

| State | What it means |
| --- | --- |
| READY IN HOST TESTS | Measurement formats match; 15 shared Python/Node/Flutter tests pass. |
| CLIENT IMPLEMENTED | Flutter has scan, credential fragments, change/forget, error handling, and encrypted-link checks. |
| FIRMWARE PARTIAL | GET_STATUS and START_SCAN exist. Credential Data and BEGIN/COMMIT/CLEAR/CANCEL are missing. |
| FINAL ACCEPTANCE PENDING | Secure phone pairing, ESP-IDF builds, NVS behavior, and physical timing still need verification. |

## Do these in order

| Priority | Next action | Responsible role | Done when |
| --- | --- | --- | --- |
| **1 - START NOW** | Secure the BLE link and implement bounded credential transactions | Firmware | Firmware rejects unsecured sensitive writes; validated fragments stage safely without changing NVS. |
| **2 - AFTER 1** | Save, apply, and forget Wi-Fi without reboot | Firmware | COMMIT starts connection; CLEAR leaves an unprovisioned device that can scan and be configured again. |
| **3 - AFTER 2** | Publish live status, errors, and reconnect behavior | Firmware + app | The phone sees success/failure, can retry/edit, and stays usable when the router or BLE drops. |
| **4 - AFTER 3** | Run board and end-to-end acceptance | Joint bench testing | Every required case passes, including persistence, malformed/security cases, and uninterrupted acquisition. |
| **5 - AFTER 4** | Review evidence and prepare the later merge | Team | Checks/builds/evidence are recorded and reviewed; merge only when the user requests it. |

There are no assigned dates or individual owners yet. Use the roles above to allocate work without changing the order.

## 1. Secure link + bounded transactions

**Files to start with**

- `components/ble/ble_manager.cpp` - pairing/security setup and GAP events.
- `components/ble/include/provisioning_protocol.hpp` - opcodes, error codes, byte validation.
- `components/ble/include/wifi_provisioning.hpp` and `components/ble/wifi_provisioning.cpp` - staged transaction and worker handoff.

**Implement**

- Require an encrypted BLE connection for BEGIN, credential Data, COMMIT, and CLEAR. The firmware must enforce this even if a client skips the app checks. Configure LE Secure Connections and define the authenticated pairing UX; an OLED passkey is a future option, not a prerequisite invented by this guide.
- Handle BEGIN, credential Data, COMMIT, CLEAR, and CANCEL with matching transaction IDs (1-255; zero is unsolicited).
- Stage at most 97 bytes: two length bytes, SSID up to 32 bytes, password up to 63 bytes. Support an empty password for an open network; do not attempt Enterprise provisioning.
- Validate transaction/object identity, constant total length, offset/chunk bounds, and conflicting duplicates. Identical duplicates may be ignored. Use 13-byte chunks so each Data packet fits MTU 23.
- Expire incomplete staging after about 60 seconds. Clear sensitive buffers on cancel, expiry, and safe disconnect cleanup; invalidate queued work using the BLE connection session generation. Never log password bytes or raw credential fragments.
- Keep NVS unchanged until complete validated data is committed. A new BEGIN discards the previous incomplete staging.

**Gate:** Test unsecured writes, incomplete/malformed/conflicting fragments, transaction mismatch, CANCEL, timeout, and BLE disconnect. No crash, no partial NVS update, and no acquisition queue/timer changes.

## 2. Apply / clear without reboot

**Files:** `components/wifi/include/wifi_manager.hpp`, `components/wifi/wifi_manager.cpp`, `components/wifi/wifi_credentials.cpp`, and the provisioning communications worker.

**Implement**

- Use the existing `wifi_cfg` namespace and `ssid` / `password` keys. Preserve the WiFiManager as the only Wi-Fi state owner.
- Add a worker-owned save/apply/connect operation. `saveCredentials()` currently persists only; it does not apply a new network live.
- Perform flash writes and station lifecycle changes serially on the communications worker, never in GATT/Wi-Fi callbacks or acquisition. Do not overlap them with scanning.
- After CLEAR, erase stored credentials and disconnect, then restore an UNPROVISIONED station capable of scanning. `clearCredentials()` currently deinitializes it, so simply invoking it is insufficient.
- Keep development seeding disabled for final firmware; forgetting a network must not seed it back on restart. Clear temporary worker credential copies when no longer needed.

**Gate:** Change networks and forget/reconfigure within one boot. Power-cycle to confirm persistence and absence of cleared credentials.

## 3. Live status + app handoff

**Firmware files:** `components/ble/wifi_provisioning.cpp`, `components/wifi/wifi_manager.cpp`. **App files:** `app/apps/monitor/lib/wifi_protocol.dart`, `wifi_transport.dart`, and `wifi_settings.dart`.

- Publish WiFiManager state, IPv4, error, and encryption changes through the NimBLE host event queue. The current firmware only notifies on explicit requests/scan events.
- Preserve an observable connection failure/timeout while retaining router reconnect behavior. Do not replace FAILURE so quickly that the phone misses it.
- Keep the fixed eight-byte status format and the separate `5ecf1000` provisioning service. Do not create a second Wi-Fi state machine in BLE.
- Verify the existing app's CONNECTING/CONNECTED/FAILURE display, retry/edit, change/forget, stale transaction rejection, and fresh encryption check.
- Leave UDP destination setup separate: configure the laptop LAN address in `components/udp/include/udp_config.hpp`. Provisioning v1 does not discover that address or create cloud/API accounts.

**Gate:** Wrong password and router loss/recovery produce actionable phone updates. The device keeps acquiring and BLE remains available for replacement credentials.

## 4. Board + end-to-end acceptance checklist

Capture pass/fail, board/firmware version, phone/app version, and evidence for every row.

| Required case | Expected result | Evidence to keep |
| --- | --- | --- |
| Fresh device + scan at MTU 23 | UNPROVISIONED offers setup; nearby supported networks reassemble correctly | App view, scan/status trace |
| Correct / wrong password | CONNECTING then CONNECTED or actionable failure; retry works; no reboot | State/error timeline; no password logs |
| Power cycle | Saved network reconnects from NVS without recompilation | Boot/status trace |
| Change / forget / reconfigure | New credentials replace old; forget becomes UNPROVISIONED; setup works again in one boot | App actions and NVS/state result |
| BLE disconnect / CANCEL / 60 s expiry | Incomplete staging clears safely and stored credentials remain unchanged | Reconnect/timeout test result |
| Malformed fragments / unsecured writes | Device rejects input without crash or partial save | Error codes and rejection result |
| Router unavailable / restored | Existing reconnect resumes; acquisition and BLE continue | Serial rate/queue diagnostics and phone status |
| Acquisition during all operations | Approximately 1,000 SampleFrames/s; no queue overflow caused by provisioning | Rate, timing and queue counters before/during/after |
| Collector to history | UDP reception alone stores zero measurements; collector logs/uploads; retry does not duplicate; 16 channels appear in web history | Session counts and app/API/history evidence |

These cases summarize section 27 of the authoritative PDF. Run every case in that section, including on the planned ESP32-S3 when available. Host tests do not prove RF, NVS flash behavior, security pairing, or sustained 1 kHz performance.

## 5. Verification and later merge

Run from repository root after app setup and Flutter package resolution:

```powershell
python tools/check_integration.py
# If Flutter is elsewhere:
python tools/check_integration.py --flutter C:\path\to\flutter\bin\flutter.bat
```

Run full app tests, including local PostgreSQL:

```powershell
cd app
.\dev.cmd test
```

In the firmware machine's ESP-IDF terminal at repository root:

```powershell
idf.py build
idf.py -p COM3 flash monitor
```

Use the actual board target and serial port; `COM3` is a placeholder. Build and retest separately for classic ESP32 and ESP32-S3. Check firmware image/partition headroom and task stack use as part of the firmware build/bench review. The last firmware README reports a classic image near its 1 MB partition limit; remeasure after provisioning is added.

Record results in `app/docs/verification.md` with a linked firmware/bench evidence record in `docs/`. Include commit, board, phone, build target, pass/fail, and unresolved issues. Keep credentials out of logs and evidence. `--skip-flutter` is partial verification, not a complete pass. Review protocol changes before deliberately regenerating fixtures.

**Merge gate:** Host checks, applicable app tests, firmware builds, and all required board cases have evidence. Keep the integration branch separate until the user authorizes the later merge.

## Preserve these boundaries

- Keep firmware at the root and Flutter/API/PostgreSQL under `app/`, with separate builds.
- Keep 16 channels, existing measurement UUIDs, 88-byte UDP frames, 80-byte BLE values, CRC32, and existing UDP batching.
- Do not touch ADC acquisition, SampleFrame, queues, timer configuration, or the 1 kHz rate from provisioning.
- Keep the mobile local-log/upload ownership path; UDP reception is a transient buffer, not a direct SQL writer.
- MCU time since boot is not UTC. Preserve device intervals at microsecond precision, anchor estimated UTC once per boot, and retain timestamp identity on retry.

## Separate later work

**iOS native BLE:** Android is the current direct connection UI. iOS needs its own platform adapter, Bluetooth usage descriptions, a Mac build, and phone acceptance.

**Optional USB telemetry:** `app/firmware/usb_measurement_console.hpp` is not yet wired into root firmware. If adopted, use low-rate LatestFrameStore snapshots without draining the UDP queue.

**Other future work:** Real ADC/calibration, OTA, cloud/account setup, Enterprise credentials, and UDP destination discovery are independent workstreams, not additions to provisioning v1.
