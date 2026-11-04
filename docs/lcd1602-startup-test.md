# Gravity LCD1602 V1.0 startup test

The user subsequently confirmed both startup lines on physical classic ESP32.
The original verification notes below are historical. For the new cycling
prototype, see [lcd1602-phase2.md](lcd1602-phase2.md). The fixed-message mode
remains available using its existing defaults.

The user physically tested the scanner on classic ESP32 GPIO21/SDA, GPIO22/SCL
and reported ACKs at 0x3E, 0x60 and 0x70 (three responding addresses).
That establishes address responses, not three distinct ICs or electrical safety.
The fixed text implementation below has NOT been flashed or visually verified
by this agent.

## Manufacturer compatibility investigation

DFRobot's official DFRobot_RGBLCD1602 header defaults the LCD to 0x7c >> 1 = 0x3E.
Its examples assign 0x60 to the V1.0 LCD1602 and RGB variants. The observed pair
and user's Gravity-family identification support selecting that explicit profile;
this is not an automatic revision or controller part-number identification.
BLWABA is not used as a controller part number.
DFRobot's [LCD1602 datasheet](https://dfimg.dfrobot.com/nobody/wiki/ee1c5bd150fc6b78f8cb8e8306898ab9.pdf)
also names AiP31068L and PCA9633DP2 at address bytes 0x7C and 0xC0. This supports
the protocol match; it does not independently identify this physical PCB.

Native transactions follow the manufacturer's command/data prefixes and
two-row startup sequence. Device addresses are 7-bit; do not shift them again.
The 0x60 initialization follows the official profile, including white backlight
PWM. There is no PCF8574 nibble/enable-pulse code and no Arduino dependency.

References inspected on 2026-11-03:
- [DFRobot official driver](https://github.com/DFRobot/DFRobot_RGBLCD1602/blob/master/DFRobot_RGBLCD1602.cpp):
  init, begin, command, write, setCursor and setRGB.
- [DFRobot header](https://github.com/DFRobot/DFRobot_RGBLCD1602/blob/master/DFRobot_RGBLCD1602.h).
- [Official revision/address table](https://github.com/DFRobot/DFRobot_RGBLCD1602/blob/master/examples/SetColor/SetColor.ino).
- [Gravity module documentation](https://wiki.dfrobot.com/dfr0555).

## The additional 0x70 response

[NXP PCA9633 datasheet, sections 7.1.2 and 7.3.8](https://www.nxp.com/docs/en/data-sheet/PCA9633.pdf)
documents an enabled-at-power-up All Call address E0h in address-byte notation,
which is 0x70 in 7-bit notation. Thus an alias of a PCA9633-style backlight
controller is a plausible explanation, not a confirmed identity or a third chip.

The driver sends no commands or register reads to 0x70. It uses the documented
0x60 initialization, whose MODE1=0 disables All Call on a PCA9633, and then
performs one address-only probe at 0x70. Disappearance is consistent with that
hypothesis; continued ACK requires further investigation. Neither result proves
a part number. No automatic driver choice depends on this observation.

For stronger evidence, inspect the backlight IC marking and PCB revision.
On a bus containing only this module, compare cold-power-up scans with the
post-init log. With power off, disconnect the LCD and repeat the scanner after
powering the ESP32 to establish whether all responses belonged to the module.
Do not hot-plug or address unknown devices with guessed register commands.

## Optional configuration and behavior

CONFIG_BATTERY_LCD_STARTUP_TEST defaults off and depends on the existing
CONFIG_BATTERY_DISPLAY_PROBE. The original scanner-only defaults remain
scanner-only. A separate sdkconfig.lcd-startup.defaults enables both options and
the previously verified 1500 KiB diagnostic app partition. Normal configuration
and NVS/PHY offsets remain unchanged.

The existing priority-1 probe task owns the bus. After a successful scan it calls
the separate native startup source, which requires ACKs from 0x3E and 0x60,
uses 100 kHz I2C and finite transaction timeouts, then writes exactly two
16-character padded rows. Delays yield only this task. Every failed write
stops initialization; errors are logged and the application continues.
Device handles and the bus are released without clearing DDRAM or disabling
the backlight. There is no refresh loop, scrolling, page cycling or acquisition
integration. Content remains until the LCD loses power, is reset, or another
writer changes it.

The existing app_main hook and board files need no further changes for this
milestone. Classic pins remain 21/22. S3 pins retain their separate Kconfig
settings and default to -1; invalid/unassigned pins skip all display access.
Compiling for S3 does not establish OLED compatibility: this is an LCD protocol,
not the future SSD1306 driver.

## Wiring and remaining electrical checks

Use the existing digital-side GPIO21/SDA and GPIO22/SCL, with shared MCU digital
ground. Keep the display on the MCU side of the isolation barrier. Confirm the
actual PCB revision, supply and pull-up rail before further hardware tests.
The documented Gravity family accepts 3.3-5 V supply, but the physical board
and its idle SDA/SCL voltage must still be verified. An ACK does not establish
5 V GPIO tolerance. Use external pull-ups to a GPIO-safe rail and appropriate
level translation where necessary; internal pull-ups stay disabled.

## Build and user-performed flash test

From the repository root, open the installed IDF environment and enter firmware:
~~~powershell
. 'C:\Espressif\tools\Microsoft.v5.5.5.PowerShell_profile.ps1'
cd firmware
idf.py -B build/lcd-startup-esp32 '-DIDF_TARGET=esp32' '-DSDKCONFIG=build/lcd-startup-esp32/sdkconfig' '-DSDKCONFIG_DEFAULTS=sdkconfig.defaults;sdkconfig.lcd-startup.defaults' build
~~~

After checking wiring and voltage, replace COM3 with your port:
~~~powershell
idf.py -B build/lcd-startup-esp32 -p COM3 flash
idf.py -B build/lcd-startup-esp32 -p COM3 monitor
~~~

Expected text after successful initialization:
~~~text
BATTERY MONITOR
ESP32 ONLINE
~~~
Trailing spaces fill each row to 16 columns. Expected success log:
'lcd1602: LCD initialization and startup writes succeeded; visual confirmation pending'.
This confirms acknowledged transfers, not visible characters. A missing required
address or failed transfer logs failure instead. Observe the separate post-init
0x70 ACK/NACK log. Power-cycle the LCD before comparing original scan results.

Blank display: check the failure log first, then verified supply, contrast where
provided, backlight, shared ground, pull-up voltage and module revision.
Do not substitute a PCF8574 driver just because the screen remains blank.
If transfers succeed but text is wrong, capture the serial log and inspect
controller/PCB markings before changing the protocol.

## Remaining hardware acceptance

- User flash and confirm both exact lines remain visible.
- Verify white/single-color backlight behavior and contrast.
- Confirm electrical levels and physical PCB/controller revision.
- Compare 0x70 cold-power-up and post-init responses; identify the IC physically.
- Monitor existing acquisition timing, queue drops, BLE provisioning and UDP
  during startup; builds alone do not establish radio/timing coexistence.
- Assign and validate S3 GPIOs on the final PCB; future OLED needs its own driver.

## Verification and files for this update

| Check | Result |
| --- | --- |
| Classic ESP32 full startup build, ESP-IDF 5.5.5 | PASS |
| Application size / slot | 0x103970 / 0x177000 bytes, 31% free |
| New driver compilation with ESP32-S3 compiler and existing S3 SDK includes | PASS |
| Full S3 startup firmware build | NOT RUN for this update |
| Physical scanner test | PASS, user-reported ACKs at 0x3E, 0x60, 0x70 |
| Startup LCD text / backlight / post-init 0x70 response | NOT RUN by agent; awaiting user flash |
| Agent flashing | NOT RUN |

Working firmware/sdkconfig SHA-256 before and after:
C978C45885745D7888F323B6019FAEEF5E3D4B217081D0C8849952583C4F17B1.
The new build uses build/lcd-startup-esp32/sdkconfig instead.
The previous scanner-only and diagnostic-disabled build results are historical,
not rerun results for this update. No new external dependencies were added.

Created:

- firmware/main/lcd1602_startup.cpp
- firmware/sdkconfig.lcd-startup.defaults
- docs/lcd1602-startup-test.md

Updated:

- firmware/main/i2c_display_probe.cpp
- firmware/main/Kconfig.projbuild
- firmware/main/CMakeLists.txt
- docs/lcd1602-bringup.md (link to this milestone and user scan result)

No additional changes to main.cpp, board pins, acquisition, BLE provisioning,
Wi-Fi, UDP, measurement structures, credentials or network configuration were
made for this update. Existing earlier diagnostic branch edits remain.
The branch is feature/lcd1602-i2c-diagnostic; main was not modified or merged.
