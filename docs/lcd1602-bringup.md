# LCD1602 bring-up: address diagnostic only

The user subsequently confirmed physical ACKs at 0x3E, 0x60 and 0x70.
This document records the original scanner milestone. For the optional native
two-line startup implementation and current hardware checks, see
[lcd1602-startup-test.md](lcd1602-startup-test.md).
The scanner-only defaults below still send no LCD commands.

## Implemented scope

The controller behind the user's four-wire DFRobot LCD1602 marked BLWABA is
unconfirmed. BLWABA is not treated as a controller identifier. This change
therefore implements only the requested fallback: an optional, one-shot I2C
address scan. It does not initialize an LCD or display text. An address ACK
does not identify a controller or even prove that the responding device is an LCD.

The existing firmware uses ESP-IDF 5.5.5, C++, FreeRTOS and NimBLE. app_main()
runs its packet self-test, starts enabled acquisition before Wi-Fi, then starts
BLE. The diagnostic starts in its own priority-1 task before these steps and
does not depend on measurements, network state or credentials. It probes only
0x08..0x77, bounds each probe at 20 ms, yields between probes, stops on bus errors,
logs results, releases the bus and deletes its task. No LCD data commands are sent.
The switch defaults off. The optional diagnostic defaults select ESP-IDF's
1500 KiB single-app partition (within the configured 2 MiB flash); the original
1 MiB slot overflowed by 9,872 bytes on ESP32 and 4,128 bytes on S3. NVS offsets are unchanged. Verify actual
flash capacity before flashing. Normal firmware defaults are unchanged. ADC timing, queues, packets, storage and provisioning
are unchanged. No application I2C bus existed before this change.

## Hardware identification and electrical checks required

DFRobot documents multiple distinct LCD1602 products:

- DFR0555/DFR0556/DFR0557 Gravity modules: specified 3.3-5 V supply.
  https://wiki.dfrobot.com/dfr0555
- DFR0063 I2C 16x2 module: specified 5 V supply.
  https://wiki.dfrobot.com/dfr0063

These are identification candidates, not identification of this LCD. Obtain
the SKU, PCB revision, front/back markings and controller/backpack part number;
match the schematic and protocol documentation to the physical board. A scanner
address alone is insufficient. Do not guess PCF8574, RGB control or an address.

Before powering or connecting SDA/SCL, establish the module's supply requirement
and pull-up rail from its schematic or measurements. Verify the idle SDA/SCL
voltage is safe for 3.3 V ESP32 GPIOs. A 5 V supply rating does not establish
GPIO-safe signaling. If pull-ups go to 5 V, use suitable bidirectional I2C level
translation or a manufacturer-approved modification. External pull-ups are
required; firmware deliberately does not enable internal pull-ups.

Confirmed classic ESP32 wiring (user-provided P21/P22 labels):

| LCD signal | MCU side |
| --- | --- |
| SDA | GPIO21 / P21, through level translation if required |
| SCL | GPIO22 / P22, through level translation if required |
| GND | MCU digital ground |
| VCC | Verified module supply; unresolved |

Keep the display and its ground on the MCU/digital side of the isolation barrier.
No existing application pin use conflicts with GPIO21/22 were found. Other board
signals remain TBD; firmware inspection cannot establish final PCB routing.

BoardConfig has separate DISPLAY_SDA/SCL fields. Classic ESP32 uses 21/22.
ESP32-S3 defaults to -1/-1; configure only after checking the exact module and
schematic. GPIO22 must not be carried over to S3. Runtime validation rejects
unassigned, identical or non-output-capable pins. It cannot detect a valid pin
that conflicts with flash/PSRAM, USB, boot straps or other PCB signals.

## Commands (repository root, PowerShell)

Open the installed ESP-IDF environment:
~~~powershell
. 'C:\Espressif\tools\Microsoft.v5.5.5.PowerShell_profile.ps1'
cd firmware
~~~

Use isolated configurations so the working classic sdkconfig remains untouched:
~~~powershell
idf.py -B build/lcd-probe-esp32 -DIDF_TARGET=esp32 -DSDKCONFIG=build/lcd-probe-esp32/sdkconfig '-DSDKCONFIG_DEFAULTS=sdkconfig.defaults;sdkconfig.display-probe.defaults' build
~~~

After verifying the electrical checks, flash explicitly, replacing COM3 with
the actual port. Flashing is a user action; it was not performed by this task:
~~~powershell
idf.py -B build/lcd-probe-esp32 -p COM3 flash
idf.py -B build/lcd-probe-esp32 -p COM3 monitor
~~~
Exit the monitor with Ctrl+].

To verify normal firmware without the diagnostic:
~~~powershell
idf.py -B build/lcd-off-esp32 -DIDF_TARGET=esp32 -DSDKCONFIG=build/lcd-off-esp32/sdkconfig '-DSDKCONFIG_DEFAULTS=sdkconfig.defaults' build
~~~

Isolated S3 build (diagnostic disabled, pins unresolved):
~~~powershell
idf.py -B build/lcd-off-esp32s3 -DIDF_TARGET=esp32s3 -DSDKCONFIG=build/lcd-off-esp32s3/sdkconfig '-DSDKCONFIG_DEFAULTS=sdkconfig.defaults' build
~~~

To compile the shared diagnostic for S3 while leaving its pins unset:
~~~powershell
idf.py -B build/lcd-probe-esp32s3 '-DIDF_TARGET=esp32s3' '-DSDKCONFIG=build/lcd-probe-esp32s3/sdkconfig' '-DSDKCONFIG_DEFAULTS=sdkconfig.defaults;sdkconfig.display-probe.defaults' build
~~~
This configuration must log invalid/unassigned pins and skip the scan at runtime.

For an S3 scan, use a separate configuration, enable Battery display diagnostic
in menuconfig, and supply verified S3 SDA/SCL pins. Do not blindly enable it on
the final PCB. The scanner source is shared between both targets.

Expected serial messages (addresses depend on physical hardware):

- display_probe: I2C diagnostic SDA=21 SCL=22; probing 7-bit addresses 0x08..0x77
- display_probe: ACK at 7-bit address 0xNN (controller NOT identified), if present
- display_probe: Scan complete: N responding address(es)
- display_probe: LCD protocol unverified: no LCD initialization or text commands sent

No ACK: check verified power, shared digital ground, pin labels, pull-ups and
wiring. Timeout/bus error: check stuck-low lines, pull-ups, translation and shorts.
Initialization failure: inspect the named ESP-IDF error and bus availability.
Do not repeatedly scan an unidentified shared bus; this diagnostic is intended
for the isolated display bring-up connection.

A blank LCD is expected with this diagnostic. Once the physical controller and
address are confirmed, add its native ESP-IDF initialization and bounded writes
for the requested static message:
~~~text
BATTERY MONITOR
ESP32 ONLINE
~~~
This output has not been implemented or physically verified.

## Remaining milestones

- Identify LCD SKU/controller/revision and protocol; establish its 7-bit address.
- Verify supply, pull-up voltage and level translation on the physical module.
- Implement the two-line message with the confirmed controller.
- Assign S3-WROOM pins and route the custom PCB connector on the digital side.
- Repeat build, probe, electrical and display tests on the final S3 PCB.
- Later add a separate DFR0650 SSD1306 backend; confirm its board configuration.
  Manufacturer reference: https://wiki.dfrobot.com/dfr0650/
- Later implement real ADC readings and validity/staleness handling, 16-channel
  page cycling, and authoritative Wi-Fi/BLE/CAN/Ethernet status reporting.
  These are outside this diagnostic milestone.

## Verification results (2026-11-03)

| Check | Result |
| --- | --- |
| ESP32 diagnostic enabled | PASS: image 0x102690 bytes, 1500 KiB app slot |
| ESP32 diagnostic disabled | PASS: image 0xfbc20 bytes, original 1 MiB app slot |
| ESP32-S3 diagnostic enabled, pins -1/-1 | PASS: image 0x101020 bytes, 1500 KiB app slot |
| Physical LCD / fixed two-line message | NOT RUN; controller-specific output is unimplemented |
| Physical I2C detection | NOT RUN |
| Flashing | NOT RUN |

All builds used ESP-IDF 5.5.5 and isolated sdkconfig/build paths. The working
firmware/sdkconfig remains classic ESP32 with its original single-app layout.
The diagnostic source is absent from the disabled build's compile database.
Initial diagnostic builds compiled and linked but failed the 1 MiB size check;
the diagnostic-only large partition selection resolved both size failures.
The larger layout retains the NVS and PHY partitions at their existing offsets.
No hardware timing, electrical compatibility or LCD behavior is established
by these build results.

Created files: firmware/main/i2c_display_probe.cpp,
firmware/sdkconfig.display-probe.defaults, docs/lcd1602-bringup.md.
Modified files: firmware/main/main.cpp, firmware/main/CMakeLists.txt,
firmware/main/Kconfig.projbuild, firmware/components/board/board_config.cpp,
firmware/components/board/include/board_config.hpp.
Additional dependencies are stock ESP-IDF esp_driver_i2c and esp_driver_gpio
for the optional diagnostic; no third-party libraries were added.
