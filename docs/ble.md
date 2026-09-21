# Introductory BLE monitor (NimBLE)

BLE is a low-rate, independent GATT path. The 1 kHz AcquisitionTask copies each
successful SampleFrame into `LatestFrameStore` under a short FreeRTOS critical
section, then publishes to the existing Wi-Fi/UDP queue. BLE reads a copy of
the latest frame; it never removes anything from that queue. The update task
has priority 2 (acquisition 5, UDP consumer 3) and wakes every 100 ms. It only
notifies subscribed clients, with no per-frame logging. BLE failure never stops
acquisition or Wi-Fi. There is one supported BLE client for this first test.

`components/ble/include/ble_config.hpp` contains `ENABLE_BLE = true` by default.
Set it false and rebuild to compare Wi-Fi only with Wi-Fi plus BLE. `sdkconfig.defaults`
enables NimBLE for both targets; the flag controls runtime startup. The name is
`BatteryMonitor`. The service UUID is in primary advertising data and the name
is in scan response, so the phone must perform active scanning to show the name.

The custom UUIDs are:

| Attribute | UUID | Properties |
| --- | --- | --- |
| Battery Monitor service | `5ecf0000-41c2-4cc4-9c96-640f406021d0` | Primary |
| Voltage Data | `5ecf0001-41c2-4cc4-9c96-640f406021d0` | Read, Notify |
| System Status | `5ecf0002-41c2-4cc4-9c96-640f406021d0` | Read, Notify |
| Configuration | `5ecf0003-41c2-4cc4-9c96-640f406021d0` | Read, Write |
| Command | `5ecf0004-41c2-4cc4-9c96-640f406021d0` | Write |

Voltage Data is **80 bytes**, all multibyte fields big-endian:

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 4 | uint32 measurement sequence |
| 4 | 8 | uint64 monotonic timestamp_us |
| 12 | 64 | 16 signed int32 channel microvolts, CH01 first |
| 76 | 4 | uint32 SampleFrame status |

This is the latest SampleFrame, not the 88-byte UDP packet; it has no UDP magic
or CRC. It is not 1000 frames/s over BLE. The default ATT MTU of 23 carries at
most 20 notification-value bytes, so **an 80-byte notification requires a
negotiated ATT MTU of at least 83**. The local preference is 128. Notifications
are suppressed when the negotiated MTU is smaller; the value is never silently
truncated. In nRF Connect, request MTU 128 if it is not negotiated automatically.
GATT long reads can still fetch the whole value using read-blob operations;
the first read latches one frame for subsequent fragments of that read.

System Status is eight bytes: offset 0 schema version `1`; offsets 1, 2, 3 are
acquisition-running, Wi-Fi-connected, and BLE-connected booleans (0 or 1);
offset 4 is the latest SampleFrame status, uint32 big-endian, zero before the
first frame. Status reads/notifications expose no credentials. The configuration
value is one byte, 0 or 1, stored as a placeholder with no operational effect.
The only accepted command is one-byte `0x00` (no-op); there is no provisioning,
firmware update, or destructive command.

Connection/disconnection events update diagnostics. Disconnect clears
subscriptions and resumes advertising. Notifications attempted/sent count local
NimBLE API attempts/acceptance, not guaranteed phone delivery. No client,
unsubscribed characteristics, and an insufficient voltage MTU are not counted
as notification errors. Five-second diagnostics show connection and notification
counters alongside the existing acquisition and UDP counters.

For the phone test, flash the ESP32, start the laptop UDP receiver, then open
nRF Connect on a phone. Scan for `BatteryMonitor`, connect, expand the custom
service, read System Status, request MTU 128 if needed, and subscribe to Voltage
Data. Expect roughly ten latest-frame notifications per second and increasing
measurement sequences with gaps of about 100. Disconnect and verify advertising
returns; reconnect and subscribe again. Throughout, inspect the five-second
firmware diagnostics and laptop UDP rate. A build alone does not prove radio
coexistence or phone compatibility.

ESP32 and ESP32-S3 both have NimBLE support in the installed ESP-IDF. Repeat
advertising, MTU, timing, UDP throughput, and reconnect tests on ESP32-S3:
controller scheduling, RAM, and 2.4 GHz Wi-Fi/BLE coexistence can differ.
BLE uses no board GPIO. The current `WIFI_PS_NONE` development throughput mode
remains independent and should be included in the coexistence measurement.
