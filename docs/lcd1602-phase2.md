# LCD1602 Phase 2: cycling prototype

Branch: feature/lcd1602-i2c-diagnostic. The user confirmed that the previous
fixed-message startup test displayed both lines on physical classic ESP32.
The cycling firmware and the refactored row-update timing still require a
user-performed flash and physical regression test. The agent does not flash.

## Data and state

The existing acquisition task publishes a SampleFrame only after a successful
ADCInterface read. It contains 16 signed integer microvolt values, a monotonic
timestamp taken at the START of that ADC read, sequence and status.
SAMPLE_STATUS_SIMULATED (bit 31) identifies FakeADC. No per-channel fault mask
or real ADS8688 source is implemented in the current code.

The priority-1 display task calls LatestFrameStore::read(), whose short critical
section copies the entire frame. It releases that lock before formatting or
I2C work. It never consumes the network queue, calls an ADC or changes the 1 kHz
GPTimer, packetization, CRC, measurement structures, provisioning or UDP path.

After reading the frame, the task samples esp_timer_get_time(); this ordering
avoids classifying a newly published frame as coming from the future because
the display clock was read before the frame. A frame is unavailable until the
store has published one, invalid for a zero/future timestamp, and stale after
500 ms. This is 500 missing nominal 1 ms acquisition periods and two display
refresh intervals. It is a data-age policy, not a claim that every intermediate
ADC read succeeded. Channels outside the specified +/-5 V range show INVALID.
No unavailable value is formatted as 0.000 V.

Voltage rounding uses integer arithmetic (nearest millivolt; ties away from
zero), with no floating point or dynamic strings. Negative signs are preserved,
including a negative value that rounds to -0.000. A legitimate fresh zero is
+0.000 V. Every output row is padded to exactly 16 characters, plus a terminator.

WiFiManager::getState() supplies its actual atomic state. Display abbreviations:
UNPROV = UNPROVISIONED and FAILED = CONNECTION_FAILED; CONNECTING and CONNECTED
appear in full. BLEManager::isConnected() supplies connection state through an
atomically bound firmware-lifetime pointer. Before that binding, or if BLE is
disabled, the display says UNKNOWN. DISCONNECTED never means ADVERTISING.
No SSIDs, credentials, addresses or destinations are introduced or read for display.

## Page behavior

Startup shows BATTERY MONITOR / INITIALIZING... for about 2.5 seconds.
Then the repeating 10-page cycle begins with acquisition/data status:
1. ADC/data status (page 9).
2. CH01/CH02, then CH03/CH04 through CH15/CH16 (pages 0-7).
3. Wi-Fi/BLE connectivity (page 8), then back to ADC/data status.

Each page lasts about 2.5 seconds; values and visible statuses refresh every
250 ms. Scheduling uses monotonic elapsed time, so row-write duration does not
accumulate into page drift. A radio change is visible on the connectivity page
at its next refresh; it does not interrupt channel-page rotation.

Formatting examples only (negative formatting is tested on the host; the current
FakeADC generates positive values roughly from 1.0 to 1.25 V):
~~~text
CH01: +1.230 V S
CH02: -1.250 V S
~~~
The final S labels simulated data on EVERY channel page, including a stale
simulated frame. A dedicated ADC: SIMULATED / DATA: FRESH page reinforces the
provenance. That page can instead show DISABLED, NO DATA, INVALID or STALE.
A fresh frame without the simulated bit says ADC: UNKNOWN, not REAL.
DATA: FRESH describes data age; it does not claim that the entire system is healthy.

Example connection row uses all 16 columns:
~~~text
WIFI: CONNECTED
BLE:DISCONNECTED
~~~

## Preserved hardware path and error behavior

The native Lcd1602 class shares the previously working initialization sequence:
GPIO21/SDA and GPIO22/SCL on classic ESP32, 0x3E LCD commands, 0x60 backlight
registers and 100 kHz I2C. The function-set repetitions, display/clear/entry-mode
commands, power-up delays and backlight sequence are unchanged.

The refactor separates initialize(), writeRows() and object lifetime. The fixed
showLcdStartup() diagnostic remains selectable and still writes BATTERY MONITOR /
ESP32 ONLINE. The cycling task retains device/bus handles while running.
A row cache suppresses unchanged rows; recurring refreshes never issue CLEAR.
Only initialization clears the LCD.

The old per-character RTOS-tick wait would exceed the refresh budget for two
rows. Character writes retain the same two-byte packets but use a 100 us ROM
delay after each transfer, outside all critical sections. Higher-priority
acquisition remains preemptible; initialization/cursor waits still yield.
This timing change needs physical regression testing.

All probes/transfers use finite timeouts. Missing hardware or transfer failure
logs an error, releases the handles/bus, waits 5 seconds and retries initialization.
The reconnected display starts with the startup/status sequence. A bus-cleanup
failure stops only the display task instead of leaking further buses.
If I2C fails while the LCD remains powered, its old contents may remain visible
until communication is restored; consult the serial log. No display error uses
ESP_ERROR_CHECK or intentionally resets the MCU.

There are no recurring application heap allocations for formatting, snapshots
or rows. Task creation occurs once; bus/device allocation repeats only during
error recovery. External pull-ups and safe GPIO signaling remain required.
Keep the display on the MCU/digital side of the isolation barrier.

## Modes and build commands (PowerShell, repository root)

The normal defaults disable the display. The new cycling switch
CONFIG_BATTERY_LCD_CYCLING is mutually exclusive with the existing probe task.
The fixed test remains CONFIG_BATTERY_DISPLAY_PROBE plus
CONFIG_BATTERY_LCD_STARTUP_TEST. Use separate build/configuration paths to retain
all modes without overwriting firmware/sdkconfig.

Open the installed ESP-IDF 5.5.5 environment:
~~~powershell
. 'C:\Espressif\tools\Microsoft.v5.5.5.PowerShell_profile.ps1'
cd firmware
~~~

Classic ESP32 cycling build:
~~~powershell
idf.py -B build/lcd-cycling-esp32 '-DIDF_TARGET=esp32' '-DSDKCONFIG=build/lcd-cycling-esp32/sdkconfig' '-DSDKCONFIG_DEFAULTS=sdkconfig.defaults;sdkconfig.lcd-cycling.defaults' build
~~~

Display disabled:
~~~powershell
idf.py -B build/lcd-off-esp32 '-DIDF_TARGET=esp32' '-DSDKCONFIG=build/lcd-off-esp32/sdkconfig' '-DSDKCONFIG_DEFAULTS=sdkconfig.defaults' build
~~~

Full S3 cycling build, with pins unassigned:
~~~powershell
idf.py -B build/lcd-cycling-esp32s3 '-DIDF_TARGET=esp32s3' '-DSDKCONFIG=build/lcd-cycling-esp32s3/sdkconfig' '-DSDKCONFIG_DEFAULTS=sdkconfig.defaults;sdkconfig.lcd-cycling.defaults' build
~~~
S3 uses separate CONFIG_BATTERY_DISPLAY_S3_SDA/SCL values, both default -1.
With those defaults the task logs unassigned pins and exits without I2C access.
Do not carry GPIO22 to S3 or infer that a successful build validates PCB routing.

Preserved fixed-message diagnostic:
~~~powershell
idf.py -B build/lcd-startup-esp32 '-DIDF_TARGET=esp32' '-DSDKCONFIG=build/lcd-startup-esp32/sdkconfig' '-DSDKCONFIG_DEFAULTS=sdkconfig.defaults;sdkconfig.lcd-startup.defaults' build
~~~

After checking the selected board, flash capacity and electrical levels,
replace COM3 with the actual port to flash/monitor the cycling firmware:
~~~powershell
idf.py -B build/lcd-cycling-esp32 -p COM3 flash
idf.py -B build/lcd-cycling-esp32 -p COM3 monitor
~~~
Exit monitor with Ctrl+]. No NVS erase is needed or performed. Cycling defaults
retain the previously selected 1500 KiB single-app layout within configured
2 MiB flash; NVS/PHY offsets are unchanged. Check the actual image-size result
and physical flash capacity before flashing.

## Formatter tests

From the repository root:
~~~powershell
.\firmware\tools\test_lcd_display.ps1
~~~
The runner uses a native g++ if present, otherwise the existing Ubuntu WSL g++.
It installs nothing. The installed ESP-IDF Clang has embedded targets only
and cannot execute host tests. The tests compile the production formatter
with warnings treated as errors and run it as a normal host program.

Direct Linux/WSL equivalent (create the output directory first):
~~~sh
g++ -std=c++17 -Wall -Wextra -Werror -Ifirmware/main firmware/main/lcd_display_format.cpp firmware/tools/test_lcd_display.cpp -o firmware/build/lcd-format-tests/test_lcd_display
./firmware/build/lcd-format-tests/test_lcd_display
~~~

## Physical acceptance still required

- Confirm startup, provenance page, all eight channel pairs, connectivity and wrap.
- Confirm S labels correspond to FakeADC, not real battery/fuel-cell measurements.
- On the connectivity page, exercise Wi-Fi provisioning/connection failure and
  BLE connect/disconnect, with existing credentials handled by existing APIs only.
- Build with ADC source NONE in a separate configuration to check DISABLED/NO DATA.
  A stalled successful-frame publisher changes readings to STALE on the first
  visible refresh after age exceeds 500 ms (up to another 250 ms later).
  Formatter tests exercise missing, invalid and stale paths; source failure/stall
  has not been physically injected by the agent.
- Check row changes do not flicker or retain old characters. Recheck fixed-message
  mode after the shorter inter-character delay.
- Disconnect/reconnect safely and inspect bounded-error/retry logs.
- Compare acquisition rate/lateness/queue-drop diagnostics and UDP/BLE behavior
  before and during display activity. Builds do not prove physical coexistence.

## Unfinished milestones

Real ADS8688 acquisition/calibration remains unimplemented; REAL selection still
fails compilation. CAN and Ethernet status/driver work is outside this milestone.
S3-WROOM PCB pins, connector routing, supply/pull-up levels, isolation placement
and final hardware timing remain to be verified. DFR0650 SSD1306 OLED support
still needs a separate graphical driver/layout; this change implements LCD only.

## Verification results (2026-11-03)

| Check | Result |
| --- | --- |
| Classic ESP32 cycling full build | PASS: image 0x103de0, slot 0x177000 bytes, 31% free |
| Classic ESP32 display disabled | PASS: image 0xfbc20, original 0x100000 slot, 2% free |
| ESP32-S3 cycling full build, pins -1/-1 | PASS: image 0x102720, slot 0x177000 bytes, 31% free |
| Production formatter host tests | PASS with existing Ubuntu WSL g++ 13.3, -Wall -Wextra -Werror |
| New cycling firmware physical test | NOT RUN; awaiting user flash |
| Refactored fixed-message mode physical regression | NOT RUN; previous implementation confirmed by user |
| NVS erase / agent flashing | NOT RUN |

Working firmware/sdkconfig SHA-256 is unchanged:
C978C45885745D7888F323B6019FAEEF5E3D4B217081D0C8849952583C4F17B1.
The existing acquisition, ADC, BLE, Wi-Fi, protocol and UDP component sources
were not modified. No changes were merged into main.

Created for Phase 2:

- firmware/main/lcd1602.hpp
- firmware/main/lcd_display.hpp
- firmware/main/lcd_display.cpp
- firmware/main/lcd_display_format.hpp
- firmware/main/lcd_display_format.cpp
- firmware/sdkconfig.lcd-cycling.defaults
- firmware/tools/test_lcd_display.cpp
- firmware/tools/test_lcd_display.ps1
- docs/lcd1602-phase2.md

Modified for Phase 2:

- firmware/main/lcd1602_startup.cpp (shared initialization and cached row API)
- firmware/main/main.cpp (start observer task, bind BLE pointer)
- firmware/main/CMakeLists.txt
- firmware/main/Kconfig.projbuild
- firmware/components/board/board_config.cpp (S3 configuration guard)
- docs/lcd1602-startup-test.md (record user confirmation/link Phase 2)

Earlier diagnostic branch changes remain in the working tree.
Only stock ESP-IDF drivers/ROM/timer APIs are used; no external firmware
libraries or new software packages were installed.
