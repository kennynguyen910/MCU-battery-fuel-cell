# Battery/Fuel Cell Monitor Firmware

Minimal ESP-IDF C++ starter for a 16-channel Battery/Fuel Cell Monitor.
The CMake project name is `battery_monitor`; the target is **ESP32-S3**.
The firmware uses native ESP-IDF and its FreeRTOS runtime, without Arduino.

Original repository hardware/toolchain notes:
- ESP-IDF Version: 6.1 (original project note; not the locally installed version)
- Target: ESP32-S3
- Board: ESP32-S3-DevKitC-1-N8R8

## Current architecture

- `main/main.cpp`: ESP-IDF `app_main`, startup logging, fake ADC initialization,
  and one demonstration frame read. It returns afterward; no acquisition loop yet.
- `components/acquisition`: public `SampleFrame` with sequence, timestamp,
  16 signed channel values, and status. Task and buffer implementation are deferred.
- `components/adc`: `FakeADC`, with a public dependency on `acquisition` and a
  private dependency on `esp_timer` for microseconds since boot.
- `docs`: planned architecture, system requirements, and protocol outline.

`FakeADC::init()` resets the sequence to zero. Each read increments the sequence
(unsigned wraparound), records the current boot-relative timestamp, sets status
to zero, and fills channels 0 through 15 with `(channel - 8) * 1000`:
-8000, -7000, ..., 7000. Values are fixed dummy counts, not calibrated voltages.
The fake is intended for one caller, with `init()` called before reading.

The root-level `main.cpp` is the preserved original desktop hello-world example.
It is not registered in the ESP-IDF build; firmware starts in `main/main.cpp`.
This repository itself is the project root; no extra nested project is needed.

## Build and run

Verified with ESP-IDF 5.5.5: `idf.py build` completed successfully for ESP32-S3
using `sdkconfig.defaults` and generated `build/battery_monitor.bin`.
Flashing and hardware operation have not been tested.

Install ESP-IDF with ESP32-S3 tools and open an activated ESP-IDF terminal.
From this repository root, run:

```sh
idf.py set-target esp32s3
idf.py build
idf.py flash
idf.py monitor
```

If needed, select a serial port with `idf.py -p COM3 flash` or
`idf.py -p COM3 monitor`. Exit the monitor with Ctrl+].
`sdkconfig.defaults` selects ESP32-S3 for a fresh build and stays versioned;
`sdkconfig` and `build/` are generated locally. `set-target` can reset existing
local build configuration, so it is normally only needed when selecting a target.

Component registration and target defaults follow the
[ESP-IDF build system](https://docs.espressif.com/projects/esp-idf/en/latest/esp32s3/api-guides/build-system.html).

No real ADC, networking, CAN, OLED, packetizer, or acquisition task is implemented.
The requirements in `docs/requirements.md` describe future system goals, not
capabilities demonstrated by this starter.
