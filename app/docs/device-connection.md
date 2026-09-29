# Connect the ESP32 to the app (development bench)

This integration matches the MCU repository's [README](https://github.com/kennynguyen910/MCU-battery-fuel-cell), [packet protocol](https://github.com/kennynguyen910/MCU-battery-fuel-cell/blob/main/docs/protocol.md), and [UDP transport](https://github.com/kennynguyen910/MCU-battery-fuel-cell/blob/main/docs/udp-transport.md) at commit `81293ca` (2026-09-21). The firmware currently sends synthetic FakeADC data; the final ADC and board wiring are unfinished.

## 1. Put the laptop and ESP32 on the same network

Use a private 2.4 GHz Wi-Fi network that allows devices to reach one another. Avoid guest networks with client isolation. On Windows, run `ipconfig` and note the laptop's IPv4 address on that network. Determine the ESP32's IPv4 address from its serial log or router client list. Reserve both addresses in the router's DHCP settings so the firmware destination and sender filter remain valid. The phone may use the same network to reach the laptop API; the UDP packets themselves go to the laptop, not the phone.

## 2. Configure and flash the firmware

In the [MCU repository](https://github.com/kennynguyen910/MCU-battery-fuel-cell):

1. Put the network SSID/password in `components/wifi/include/wifi_config.hpp` without committing them.
2. Put the laptop IPv4 address in `components/udp/include/udp_config.hpp`. Keep UDP destination port `5005` unless you also change `DEVICE_UDP_PORT` here.
3. In an ESP-IDF 5.5.5 terminal, run `idf.py set-target esp32`, `idf.py build`, and `idf.py -p COM3 flash monitor`, replacing `COM3` with the board port. The planned ESP32-S3 needs `idf.py set-target esp32s3` and separate hardware validation.

## 3. Start the API's receiver

In this repository's untracked `.env`, set `DEVICE_UDP_ENABLED=1`. Optionally set `DEVICE_IP` to accept only one ESP32 IPv4 sender. Set both `APP_USERNAME` and `APP_PASSWORD` to enable user login; the password must be at least 12 characters. Start the normal system with `./dev.cmd` or the numbered Windows launchers. The API listens for UDP on all laptop interfaces at port `5005`. Allow inbound UDP 5005 through Windows Firewall for the private network if prompted. Do not expose this port to the internet.

For a receiver-only check, the firmware repository provides `python .\tools\udp_receiver.py`; stop that program before starting this API because both use UDP port 5005.

## 4. Connect the collector

On an Android emulator, use API address `http://10.0.2.2:3001`. On a physical phone on the same LAN, use `http://<laptop IPv4>:3001`, and allow inbound TCP 3001 on the laptop's private network. For USB Android testing, `adb reverse tcp:3001 tcp:3001` permits `http://localhost:3001`. Press **Connect**, log in if configured, select **ESP32 over laptop Wi-Fi / UDP**, and wait for a sender to appear. Select that sender, press **Pair selected device**, then create a session and press **Start capture**. The sender list shows live/offline status and received-frame count. Sessions are filtered to the selected paired sender. Open the web history app to see stored values.

The collector displays the latest valid UDP frame while saving buffered frames in batches. Its one-second screen refresh is independent of frame capture. The receiver retains 10,000 frames per sender; the collector reports buffer losses if it falls behind. `recordedAt` is reconstructed from laptop arrival time and intra-packet MCU timing, made strictly increasing at millisecond precision for the 1 kHz stream. `receivedAt` is actual packet arrival time. These are estimated sample times; the MCU clock is not synchronized to UTC. UDP loss is possible. CRC detects corruption but does not authenticate the sender. Pairing registers the source IP in the app's device list. A DHCP reservation keeps that address stable. Cryptographic device authentication would require a firmware protocol change.

If the app stays waiting, verify the firmware Wi-Fi log, laptop/ESP32 IPv4 addresses, destination IP, port 5005, firewall, and router client isolation. If user login fails, confirm both account variables are set in `.env` and restart the API. Login sessions expire after eight hours or an API restart; tokens are held only in memory for this single-user bench setup. Use HTTPS and a persistent account/role store before internet deployment.
