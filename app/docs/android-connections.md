# Android: BLE, Wi-Fi, and USB

Open **Device connections · BLE / Wi-Fi / USB** at the top of the Android
collector. Keep the app in the foreground. The existing API login is needed to
create sessions and upload; you can inspect live BLE/USB values before login.
Saved sessions are visible in the website's History screen.

## BLE with current firmware

1. Flash the linked MCU-battery-fuel-cell firmware with `ENABLE_BLE = true`.
2. Enable Bluetooth on the phone. Open the BLE tab and tap **Scan for ESP32**.
3. Allow Nearby devices (Android 12+) or Location (older Android) when prompted.
4. Connect to **BatteryMonitor**. The app requests MTU 128; at least 83 is required.
5. Wait for **Receiving measurements**, enter a session name, then **Create
   session** and **Start capture**. Stop capture before leaving the page.

The firmware service is `5ecf0000-41c2-4cc4-9c96-640f406021d0`; voltage
notifications use `5ecf0001-41c2-4cc4-9c96-640f406021d0`. The 80-byte value is
big-endian: sequence at 0, timestamp_us at 4, sixteen signed microvolt channels
at 12, and status at 76. BLE intentionally sends about 10 latest-frame updates/s.
Sequence gaps of about 100 are expected, not evidence of Bluetooth packet loss.
Disconnect stops capture; reconnect and start explicitly. No configuration or
command characteristic is written by the app.

## Wi-Fi (and network Ethernet)

Use the existing [router/device setup](device-connection.md). The ESP32 sends UDP
to the laptop IP and port 5005. Phone and laptop must be reachable on the same
network. In the collector's API address, use `http://LAPTOP_LAN_IP:3001`;
`10.0.2.2` is only for the Android emulator and `localhost` means the phone itself.
Sign in, then open the Wi-Fi tab, check the connection, and choose **Use Wi-Fi /
UDP collector**. Pair the sender, create a session, and start capture.

The laptop can use wired Ethernet to the router. A phone with a supported USB
Ethernet adapter can also reach the same API. Android selects the network route;
the app does not change router settings or force traffic onto a particular NIC.
Direct ESP32-to-phone USB is a serial connection, covered below.

## USB cable: diagnostics and measurements

Use a USB **data** cable and an OTG-capable Android phone/adapter. Open USB,
tap **Find USB devices**, select the board, and allow USB access. The app opens
115200 baud, 8N1. Common CP210x, CH34x, FTDI and CDC serial interfaces are handled
by the USB driver; actual support depends on the board and Android USB host.
Some native ESP32-S3 USB ports expose a debug interface rather than supported
serial; use the board's USB-UART connector if it has one.

The linked firmware currently emits only diagnostic text on its console. The
app shows that text without inventing voltage values. To enable USB measurements:

1. Copy `firmware/usb_measurement_console.hpp` from this project into the firmware
   repository's `main/` directory.
2. In `main/main.cpp`, add `#include "usb_measurement_console.hpp"`.
3. After the successful `acquisition.start(...)` block, add:

   ```cpp
   if (!startUsbMeasurementConsole(latest)) {
       ESP_LOGE(TAG, "USB measurement console task failed");
   }
   ```

4. Rebuild and flash using that repository's ESP-IDF instructions. Ensure its
   console uses the USB-UART/native serial port you connected and 115200 baud.
5. Reconnect in the app. Once measurements arrive, create a session and start.

The addition emits a latest-frame snapshot every 100 ms as
`BMHEX:<176 hexadecimal characters>\n`. Those bytes are the existing 88-byte
version-1 packet including CRC. The app handles split/coalesced reads, validates
CRC, and keeps diagnostic lines separate. This is a low-rate USB monitor, not
full 1,000-frame/s serial capture. It never removes frames from the UDP queue.
The addition must be built and tested on your board; this workstation does not
prove firmware timing or USB hardware compatibility.

## Data and limits

BLE/USB capture assigns distinct phone receive timestamps and uploads batches
through the same API/local log as Wi-Fi. Device monotonic time is not UTC.
Only complete 16-channel frames within ±5 V are stored. Invalid frames are
counted. The local log preserves pending uploads; the live queue is limited to
10,000 frames and stops capture on overflow. Pending frames survive normal page
exit after being saved. An abrupt process kill can lose notifications still in
the short in-memory queue. The app clears stale live values after five seconds.
Keep only one collector active against a session. Background acquisition is not
implemented. Physical BLE, USB, and Wi-Fi performance must be checked on hardware.

Firmware references: [BLE format](https://github.com/kennynguyen910/MCU-battery-fuel-cell/blob/main/docs/ble.md)
and [measurement protocol](https://github.com/kennynguyen910/MCU-battery-fuel-cell/blob/main/docs/protocol.md).
