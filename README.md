# Battery/Fuel Cell Monitor firmware

This repository is the firmware for a 16-channel battery and fuel-cell monitor. It is built with C++, ESP-IDF, and FreeRTOS. The final board is planned around an ESP32-S3; development and end-to-end network testing currently use a classic ESP32. The firmware already exercises the full path from sampling to a laptop, while the physical ADC and final board wiring are still to come.

## What it does today

A timer drives acquisition at approximately 1,000 frames per second. Each frame contains a sequence number, timestamp, 16 signed channel readings in microvolts, and a status field. A bounded queue keeps sampling separate from communications, and the acquisition task does not wait for the network. For now, `FakeADC` supplies predictable changing voltages so the timing and data path can be tested without the analog hardware.

The Wi-Fi station connects and reconnects in the background. The network task serializes each frame into the documented 88-byte binary measurement format, groups up to ten frames in one UDP datagram, and sends the batch to a laptop on port 5005. A partial batch is flushed after about 20 ms. The Python receiver validates frame CRCs, displays the latest channel voltages once per second, and reports frame rate and sequence gaps. This Wi-Fi/UDP path has been exercised end to end on the classic ESP32.

An introductory BLE path is also present. It advertises as **BatteryMonitor** and offers a custom GATT service with voltage data, system status, a placeholder configuration value, and a no-op command. BLE reads a separate copy of the latest measurement at about 10 Hz, so it does not compete with the Wi-Fi queue or change the sampling rate. The BLE code builds for the classic ESP32; phone connection, notification, and Wi-Fi coexistence testing are the next hardware checks.

Five-second diagnostics report acquisition rate and timing, queue drops, UDP datagrams and frame losses, Wi-Fi state, and BLE connection/notification activity. The board abstraction keeps pin assignments in one place; hardware pin mappings are still marked TBD.

## Current progress

- **Working in development:** FakeADC acquisition, bounded buffering, binary packetization, ten-frame UDP batching, Wi-Fi reconnects, and laptop-side decoding.
- **Implemented, awaiting live validation:** BLE advertising and GATT monitoring alongside Wi-Fi; repeat the full timing and radio tests on the final ESP32-S3.
- **Still to build:** the real 16-channel ADC driver and calibration, final board pin mapping, and any later hardware interfaces. Synthetic values are not real battery or fuel-cell measurements.

The latest classic ESP32 build succeeds with ESP-IDF 5.5.5. The Bluetooth-enabled image is close to the current 1 MB app-partition limit, with about 4% free. A successful build does not by itself establish BLE phone behavior or sustained Wi-Fi/BLE coexistence.

## Build and try it

Open an ESP-IDF terminal in this repository. For the current classic ESP32 test board:

```powershell
idf.py set-target esp32
idf.py build
idf.py -p COM3 flash monitor
```

Replace `COM3` with the board's serial port. The first `set-target` selects the chip; subsequent builds can use `idf.py build`. Exit the serial monitor with **Ctrl+]**. To build for the planned ESP32-S3, select `esp32s3` and rebuild; hardware behavior still needs retesting there. `sdkconfig.defaults` names ESP32-S3 for a fresh configuration, while the generated local `sdkconfig` records the currently selected target.

Before flashing, set the temporary Wi-Fi credentials in [`components/wifi/include/wifi_config.hpp`](components/wifi/include/wifi_config.hpp) and the laptop's IPv4 address in [`components/udp/include/udp_config.hpp`](components/udp/include/udp_config.hpp). These are development settings; avoid committing personal credentials. On the laptop, run:

```powershell
python .\tools\udp_receiver.py
```

For BLE testing, scan for **BatteryMonitor** in nRF Connect, connect, and subscribe to Voltage Data. An 80-byte voltage notification needs an ATT MTU of at least 83; request MTU 128 in the app if necessary. See the [BLE guide](docs/ble.md) for the characteristic formats and phone test.

The firmware entry point is [`main/main.cpp`](main/main.cpp). The root-level `main.cpp` is an older desktop example and is not part of the ESP-IDF firmware build. More detail is in the [protocol](docs/protocol.md), [UDP transport](docs/udp-transport.md), [architecture](docs/architecture.md), and [test plan](docs/test-plan.md) documents.
