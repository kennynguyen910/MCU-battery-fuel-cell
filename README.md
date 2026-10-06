# Battery/Fuel Cell Monitor firmware

## Repository layout and build safety

- **firmware/**: ESP32 ESP-IDF project. Run idf.py commands ONLY here.
- **mobile_app/**: Flutter project, with supporting API in apps/api/ and database files in database/. Completely outside the ESP-IDF source tree.
- **docs/**: shared protocol, integration, and system documentation.
- **contracts/** and **tools/**: shared fixtures and compatibility checks. Firmware-only tests and the UDP receiver are in firmware/tools/.

**DO NOT run ESP-IDF flash commands from mobile_app/. DO NOT add mobile_app/ as an ESP-IDF component. Flutter code is never flashed onto the ESP32 through this configuration.**

Build from a repository-root terminal:

~~~powershell
cd firmware
idf.py build
~~~

Flash example, from a new repository-root terminal (not run by this reorganization):

~~~powershell
cd firmware
idf.py -p COM5 flash monitor
~~~

Flutter setup, from a new repository-root terminal:

~~~powershell
cd mobile_app
flutter pub get
flutter analyze
~~~

The repository root has no ESP-IDF CMakeLists.txt. Open firmware/ as the IDE project for firmware work. The previous generated build is preserved in ignored firmware/build-before-reorganization/; build a fresh cache in firmware/build/.


## NEXT STEPS - START HERE

**[Open the development roadmap](NEXT_STEPS.md)** | **[Download the three-page visual guide](docs/Capstone_Next_Steps_Guide.pdf)**

**Next action:** secure the BLE link and implement firmware credential transactions.
The guide shows priorities, file locations, completion criteria and the hardware checklist.


## Firmware and app integration branch

This branch contains the ESP-IDF firmware under firmware/ and the complete
Flutter/API/PostgreSQL application under [`mobile_app/`](mobile_app/README.md).
Start with the [combined architecture and integration steps](docs/integration.md).

- Windows app setup: `Setup_App.cmd`; normal startup: `Start_Project.cmd`.
- Firmware build/flash: ESP-IDF commands from firmware/ only.
- Shared compatibility checks: `python tools/check_integration.py`.
- Current provisioning specification: [Will and Kenny Startup.pdf](mobile_app/docs/Will%20and%20Kenny%20Startup.pdf).

Measurement wire formats already match. Full app-driven Wi-Fi setup still needs
firmware credential transactions, secure pairing, live apply/clear, and state
notifications. Status/scans are available now. This branch is for later review
and merge; see the integration guide for exact implementation and acceptance gates.


This repository is the firmware for a 16-channel battery and fuel-cell monitor. It is built with C++, ESP-IDF, and FreeRTOS. The final board is planned around an ESP32-S3; development and end-to-end network testing currently use a classic ESP32. The firmware already exercises the full path from sampling to a laptop, while the physical ADC and final board wiring are still to come.

## What it does today

A timer drives acquisition at approximately 1,000 frames per second. Each frame contains a sequence number, timestamp, 16 signed channel readings in microvolts, and a status field. A bounded queue keeps sampling separate from communications, and the acquisition task does not wait for the network. For now, `FakeADC` supplies predictable changing voltages so the timing and data path can be tested without the analog hardware.

The Wi-Fi station connects and reconnects in the background. The network task serializes each frame into the documented 88-byte binary measurement format, groups up to ten frames in one UDP datagram, and sends the batch to a laptop on port 5005. A partial batch is flushed after about 20 ms. The Python receiver validates frame CRCs, displays the latest channel voltages once per second, and reports frame rate and sequence gaps. This Wi-Fi/UDP path has been exercised end to end on the classic ESP32.

An introductory BLE path is also present. It advertises as **BatteryMonitor** and offers a custom GATT service with voltage data, system status, a placeholder configuration value, and a no-op command. BLE reads a separate copy of the latest measurement at about 10 Hz, so it does not compete with the Wi-Fi queue or change the sampling rate. The BLE code builds for the classic ESP32; measurement notifications, Wi-Fi scanning, and UDP coexistence have been hardware-tested on classic ESP32. BLE credential save/apply/clear is implemented and awaits hardware validation.

Five-second diagnostics report acquisition rate and timing, queue drops, UDP datagrams and frame losses, Wi-Fi state, and BLE connection/notification activity. The board abstraction keeps pin assignments in one place; hardware pin mappings are still marked TBD.

## Current progress

- **Working in development:** FakeADC acquisition, bounded buffering, binary packetization, ten-frame UDP batching, Wi-Fi reconnects, and laptop-side decoding.
- **Implemented, awaiting live validation:** BLE credential reception, save/apply/clear, timeout cleanup, and encryption gate; repeat the full timing and radio tests on the final ESP32-S3.
- **Still to build:** the real 16-channel ADC driver and calibration, final board pin mapping, and any later hardware interfaces. Synthetic values are not real battery or fuel-cell measurements.

The latest classic ESP32 build succeeds with ESP-IDF 5.5.5. The Bluetooth-enabled image is close to the current 1 MB app-partition limit, with about 2% free. A successful build does not by itself establish BLE phone behavior or sustained Wi-Fi/BLE coexistence.

## Build and try it

Open an ESP-IDF terminal and enter firmware/. For the current classic ESP32 test board:

```powershell
cd firmware
idf.py set-target esp32
idf.py build
idf.py -p COM3 flash monitor
```

Replace `COM3` with the board's serial port. The first `set-target` selects the chip; subsequent builds can use `idf.py build`. Exit the serial monitor with **Ctrl+]**. To build for the planned ESP32-S3, select `esp32s3` and rebuild; hardware behavior still needs retesting there. `sdkconfig.defaults` names ESP32-S3 for a fresh configuration, while the generated local `sdkconfig` records the currently selected target.

Wi-Fi credentials now persist across reboot in NVS namespace `wifi_cfg`, keys `ssid` and `password`. With no saved credentials, startup succeeds in `UNPROVISIONED`: no station connection attempts occur, while acquisition, BLE, and diagnostics continue. The station radio runs to support explicit BLE-requested scans. Saved credentials are loaded at boot; connection attempts are asynchronous and existing disconnect/reconnect behavior is retained. `getState()` reports `UNPROVISIONED`, `CONNECTING`, `CONNECTED` (has IP), or `CONNECTION_FAILED`. Disconnects enter failure state, then `CONNECTING` when a retry starts.

For temporary development seeding, use your existing local values in [`wifi_config.hpp`](firmware/components/wifi/include/wifi_config.hpp) and set `WIFI_ENABLE_DEVELOPMENT_SEED` to `1` in [`wifi_provisioning_config.hpp`](firmware/components/wifi/include/wifi_provisioning_config.hpp). It defaults to `0`; credentials are written only when NVS keys are missing, never over valid saved credentials or on a read error. After one successful boot, set it back to `0` and rebuild/flash without erasing NVS. With seeding disabled the credential header is excluded from compilation. Do not commit personal credentials.

`WiFiManager` exposes `loadCredentials(WiFiCredentials&)`, `saveCredentials(const WiFiCredentials&)`, `hasStoredCredentials()`, and `clearCredentials()`. The separate [BLE Wi-Fi provisioning service](docs/ble_wifi_provisioning.md) now supports credential staging, COMMIT, CLEAR, CANCEL, and timeout/disconnect cleanup alongside GET_STATUS and START_SCAN. Credential operations require encryption by default; the documented development bypass is disabled. Saved credentials can be applied without reboot using `applyStoredCredentials()`. Call `init()` first, then invoke storage/lifecycle operations serially from one control task, never an ISR, acquisition task, or Wi-Fi callback. Queries of connection state are atomic. Saving persists only; `applyStoredCredentials()` reloads and starts an asynchronous connection, or credentials take effect on next boot; clearing stops Wi-Fi, erases only the two keys, and sets `UNPROVISIONED`. Disable seeding before clearing or credentials will be seeded on the next boot. NVS read/write errors are logged without credentials. An interrupted save can leave credentials absent; it does not intentionally reuse a partially updated pair. Full NVS erase is retained only for ESP-IDF's existing initialization recovery cases.

For hardware validation, use the exact nRF Connect credential and regression tests in the [provisioning guide](docs/ble_wifi_provisioning.md). Monitor acquisition timing, queue counters, and BLE/UDP coexistence during NVS writes and Wi-Fi replacement. Keep development seeding disabled before CLEAR and reboot tests.

Set the laptop's IPv4 address in [`firmware/components/udp/include/udp_config.hpp`](firmware/components/udp/include/udp_config.hpp). On the laptop, run:

```powershell
python .\firmware\tools\udp_receiver.py
```

For BLE testing, scan for **BatteryMonitor** in nRF Connect, connect, and subscribe to Voltage Data. An 80-byte voltage notification needs an ATT MTU of at least 83; request MTU 128 in the app if necessary. See the [BLE guide](docs/ble.md) for the characteristic formats and phone test.

The firmware entry point is [`firmware/main/main.cpp`](firmware/main/main.cpp). The `firmware/examples/desktop/main.cpp` is an older desktop example and is not part of the ESP-IDF firmware build. More detail is in the [protocol](docs/protocol.md), [UDP transport](docs/udp-transport.md), [architecture](docs/architecture.md), and [test plan](docs/test-plan.md) documents.
