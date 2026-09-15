# Battery/Fuel Cell Monitor Firmware

Minimal ESP-IDF C++ starter for a 16-channel Battery/Fuel Cell Monitor.
The CMake project name is `battery_monitor`; the target is **ESP32-S3**.
The firmware uses native ESP-IDF and its FreeRTOS runtime, without Arduino.

Original repository hardware/toolchain notes:
- ESP-IDF I am building firmware for a 16-channel Battery/Fuel Cell Monitor using:

- ESP32-S3
- ESP-IDF
- FreeRTOS
- C++

I want to implement a reusable Wi-Fi subsystem now, before the final ESP32-S3 board arrives.

Please inspect the existing repository first and preserve the current project structure and working code.

Do not rewrite unrelated files.

The goal is to create a reusable Wi-Fi manager that:
- connects the ESP32-S3 to a configured Wi-Fi network
- automatically reconnects after disconnects
- exposes connection status to the rest of the firmware
- is independent from ADC acquisition and packet formatting
- compiles successfully for ESP32-S3
- can later be reused with UDP/TCP networking

Do NOT implement Ethernet, BLE, CAN, OLED, ADC acquisition, or packet serialization in this task.

--------------------------------------------------
1. CREATE A WIFI COMPONENT
--------------------------------------------------

Create:

components/
└── wifi/
    ├── CMakeLists.txt
    ├── wifi_manager.cpp
    └── include/
        └── wifi_manager.hpp

Use standard ESP-IDF component conventions.

The public header should expose a class similar to:

class WiFiManager
{
public:
    bool init();
    bool start();
    bool isConnected() const;

private:
    static void eventHandler(
        void* arg,
        esp_event_base_t event_base,
        int32_t event_id,
        void* event_data
    );
};

You may adjust the exact class interface if needed for clean ESP-IDF integration, but keep it simple.

--------------------------------------------------
2. WIFI BEHAVIOR
--------------------------------------------------

The component must operate in Wi-Fi station mode.

It should:

1. Initialize NVS safely.
2. Initialize esp_netif.
3. Create the default event loop.
4. Create the default Wi-Fi station network interface.
5. Initialize the ESP-IDF Wi-Fi driver.
6. Register handlers for:
   - WIFI_EVENT_STA_START
   - WIFI_EVENT_STA_DISCONNECTED
   - IP_EVENT_STA_GOT_IP
7. Configure station mode.
8. Apply configured SSID and password.
9. Start Wi-Fi.
10. Automatically connect when the station starts.
11. Automatically reconnect when disconnected.
12. Track whether the ESP32 currently has a valid Wi-Fi connection.

The connection state should only become true after IP_EVENT_STA_GOT_IP.

When disconnected:
- mark the connection state false
- attempt reconnection
- log the event

--------------------------------------------------
3. WIFI CREDENTIAL CONFIGURATION
--------------------------------------------------

Do not hardcode the SSID and password in wifi_manager.cpp.

Use a separate configuration mechanism.

For now, create:

components/wifi/include/wifi_config.hpp

with something like:

#pragma once

#define WIFI_SSID "CHANGE_ME"
#define WIFI_PASSWORD "CHANGE_ME"

Clearly comment that this is temporary for development.

Do not implement NVS credential storage or BLE provisioning yet.

Do not print the Wi-Fi password in logs.

--------------------------------------------------
4. LOGGING
--------------------------------------------------

Use ESP_LOGI / ESP_LOGW / ESP_LOGE.

Useful logs should include:

- Wi-Fi initialization started
- Wi-Fi station started
- attempting connection
- disconnected
- reconnecting
- connected
- obtained IP address

Never log the password.

--------------------------------------------------
5. CONNECTION STATUS
--------------------------------------------------

Implement:

bool WiFiManager::isConnected() const;

The rest of the firmware should be able to ask whether Wi-Fi is currently connected without needing to know ESP-IDF event details.

Use thread-safe or appropriate simple state handling for ESP-IDF/FreeRTOS.

--------------------------------------------------
6. MAIN APPLICATION INTEGRATION
--------------------------------------------------

Update main/main.cpp minimally.

In app_main():

1. Log:
   "Battery/Fuel Cell Monitor starting"

2. Create a WiFiManager instance.

3. Call:
   wifi.init();

4. Call:
   wifi.start();

5. Do not block forever waiting for Wi-Fi inside app_main.

6. Do not add UDP yet.

7. Do not remove existing FakeADC or other working project code unless necessary.

If there is already initialization code in app_main(), preserve it and integrate Wi-Fi cleanly.

--------------------------------------------------
7. COMPONENT DEPENDENCIES
--------------------------------------------------

Configure CMakeLists.txt correctly.

The Wi-Fi component will likely need ESP-IDF dependencies including:
- esp_wifi
- esp_event
- esp_netif
- nvs_flash

Declare these using normal ESP-IDF component dependency mechanisms.

Do not use hardcoded include paths.

--------------------------------------------------
8. ERROR HANDLING
--------------------------------------------------

Handle ESP-IDF return values cleanly.

NVS initialization should account for common cases such as:
- ESP_ERR_NVS_NO_FREE_PAGES
- ESP_ERR_NVS_NEW_VERSION_FOUND

If either occurs:
- erase NVS
- reinitialize it

For other critical initialization failures:
- log the error
- return false from init()

Do not intentionally crash the system for recoverable Wi-Fi disconnections.

--------------------------------------------------
9. PORTABILITY
--------------------------------------------------

This project targets ESP32-S3.

Do not use Arduino APIs.

Use only ESP-IDF APIs.

Avoid chip-specific assumptions unless required.

The component should be written so that most of it could also compile for a classic ESP32 later.

--------------------------------------------------
10. DO NOT IMPLEMENT THESE YET
--------------------------------------------------

Do not add:
- UDP sender
- TCP
- Ethernet
- BLE
- CAN
- OLED
- ADC driver changes
- sample buffering
- packet serialization
- Wi-Fi provisioning
- credential storage in NVS
- web server
- HTTP client

This task is only the reusable Wi-Fi connection manager.

--------------------------------------------------
11. BUILD VERIFICATION
--------------------------------------------------

After implementing:

1. Show the files created or modified.
2. Show the resulting Wi-Fi component directory tree.
3. Explain how Wi-Fi connection state is tracked.
4. Explain how reconnect behavior works.
5. Tell me exactly where I should enter my temporary SSID and password.
6. Run:

idf.py set-target esp32s3
idf.py build

7. Fix any CMake or compile errors caused by this change.
8. Do not make unrelated code changes.
9. Clearly tell me whether the project builds successfully.

--------------------------------------------------
12. FUTURE DESIGN NOTE
--------------------------------------------------

Add a short comment or documentation note explaining that the planned future network architecture is:

SampleFrame
    ↓
Packetizer
    ↓
Transport
    ↓
Wi-Fi or Ethernet

The WiFiManager should only manage network connectivity and should not know anything about SampleFrame or ADC data.I am building firmware for a 16-channel Battery/Fuel Cell Monitor using:

- ESP32-S3
- ESP-IDF
- FreeRTOS
- C++

I want to implement a reusable Wi-Fi subsystem now, before the final ESP32-S3 board arrives.

Please inspect the existing repository first and preserve the current project structure and working code.

Do not rewrite unrelated files.

The goal is to create a reusable Wi-Fi manager that:
- connects the ESP32-S3 to a configured Wi-Fi network
- automatically reconnects after disconnects
- exposes connection status to the rest of the firmware
- is independent from ADC acquisition and packet formatting
- compiles successfully for ESP32-S3
- can later be reused with UDP/TCP networking

Do NOT implement Ethernet, BLE, CAN, OLED, ADC acquisition, or packet serialization in this task.

--------------------------------------------------
1. CREATE A WIFI COMPONENT
--------------------------------------------------

Create:

components/
└── wifi/
    ├── CMakeLists.txt
    ├── wifi_manager.cpp
    └── include/
        └── wifi_manager.hpp

Use standard ESP-IDF component conventions.

The public header should expose a class similar to:

class WiFiManager
{
public:
    bool init();
    bool start();
    bool isConnected() const;

private:
    static void eventHandler(
        void* arg,
        esp_event_base_t event_base,
        int32_t event_id,
        void* event_data
    );
};

You may adjust the exact class interface if needed for clean ESP-IDF integration, but keep it simple.

--------------------------------------------------
2. WIFI BEHAVIOR
--------------------------------------------------

The component must operate in Wi-Fi station mode.

It should:

1. Initialize NVS safely.
2. Initialize esp_netif.
3. Create the default event loop.
4. Create the default Wi-Fi station network interface.
5. Initialize the ESP-IDF Wi-Fi driver.
6. Register handlers for:
   - WIFI_EVENT_STA_START
   - WIFI_EVENT_STA_DISCONNECTED
   - IP_EVENT_STA_GOT_IP
7. Configure station mode.
8. Apply configured SSID and password.
9. Start Wi-Fi.
10. Automatically connect when the station starts.
11. Automatically reconnect when disconnected.
12. Track whether the ESP32 currently has a valid Wi-Fi connection.

The connection state should only become true after IP_EVENT_STA_GOT_IP.

When disconnected:
- mark the connection state false
- attempt reconnection
- log the event

--------------------------------------------------
3. WIFI CREDENTIAL CONFIGURATION
--------------------------------------------------

Do not hardcode the SSID and password in wifi_manager.cpp.

Use a separate configuration mechanism.

For now, create:

components/wifi/include/wifi_config.hpp

with something like:

#pragma once

#define WIFI_SSID "CHANGE_ME"
#define WIFI_PASSWORD "CHANGE_ME"

Clearly comment that this is temporary for development.

Do not implement NVS credential storage or BLE provisioning yet.

Do not print the Wi-Fi password in logs.

--------------------------------------------------
4. LOGGING
--------------------------------------------------

Use ESP_LOGI / ESP_LOGW / ESP_LOGE.

Useful logs should include:

- Wi-Fi initialization started
- Wi-Fi station started
- attempting connection
- disconnected
- reconnecting
- connected
- obtained IP address

Never log the password.

--------------------------------------------------
5. CONNECTION STATUS
--------------------------------------------------

Implement:

bool WiFiManager::isConnected() const;

The rest of the firmware should be able to ask whether Wi-Fi is currently connected without needing to know ESP-IDF event details.

Use thread-safe or appropriate simple state handling for ESP-IDF/FreeRTOS.

--------------------------------------------------
6. MAIN APPLICATION INTEGRATION
--------------------------------------------------

Update main/main.cpp minimally.

In app_main():

1. Log:
   "Battery/Fuel Cell Monitor starting"

2. Create a WiFiManager instance.

3. Call:
   wifi.init();

4. Call:
   wifi.start();

5. Do not block forever waiting for Wi-Fi inside app_main.

6. Do not add UDP yet.

7. Do not remove existing FakeADC or other working project code unless necessary.

If there is already initialization code in app_main(), preserve it and integrate Wi-Fi cleanly.

--------------------------------------------------
7. COMPONENT DEPENDENCIES
--------------------------------------------------

Configure CMakeLists.txt correctly.

The Wi-Fi component will likely need ESP-IDF dependencies including:
- esp_wifi
- esp_event
- esp_netif
- nvs_flash

Declare these using normal ESP-IDF component dependency mechanisms.

Do not use hardcoded include paths.

--------------------------------------------------
8. ERROR HANDLING
--------------------------------------------------

Handle ESP-IDF return values cleanly.

NVS initialization should account for common cases such as:
- ESP_ERR_NVS_NO_FREE_PAGES
- ESP_ERR_NVS_NEW_VERSION_FOUND

If either occurs:
- erase NVS
- reinitialize it

For other critical initialization failures:
- log the error
- return false from init()

Do not intentionally crash the system for recoverable Wi-Fi disconnections.

--------------------------------------------------
9. PORTABILITY
--------------------------------------------------

This project targets ESP32-S3.

Do not use Arduino APIs.

Use only ESP-IDF APIs.

Avoid chip-specific assumptions unless required.

The component should be written so that most of it could also compile for a classic ESP32 later.

--------------------------------------------------
10. DO NOT IMPLEMENT THESE YET
--------------------------------------------------

Do not add:
- UDP sender
- TCP
- Ethernet
- BLE
- CAN
- OLED
- ADC driver changes
- sample buffering
- packet serialization
- Wi-Fi provisioning
- credential storage in NVS
- web server
- HTTP client

This task is only the reusable Wi-Fi connection manager.

--------------------------------------------------
11. BUILD VERIFICATION
--------------------------------------------------

After implementing:

1. Show the files created or modified.
2. Show the resulting Wi-Fi component directory tree.
3. Explain how Wi-Fi connection state is tracked.
4. Explain how reconnect behavior works.
5. Tell me exactly where I should enter my temporary SSID and password.
6. Run:

idf.py set-target esp32s3
idf.py build

7. Fix any CMake or compile errors caused by this change.
8. Do not make unrelated code changes.
9. Clearly tell me whether the project builds successfully.

--------------------------------------------------
12. FUTURE DESIGN NOTE
--------------------------------------------------

Add a short comment or documentation note explaining that the planned future network architecture is:

SampleFrame
    ↓
Packetizer
    ↓
Transport
    ↓
Wi-Fi or Ethernet

The WiFiManager should only manage network connectivity and should not know anything about SampleFrame or ADC data.Version: 6.1 (original project note; not the locally installed version)
- Target: ESP32-S3
- Board: ESP32-S3-DevKitC-1-N8R8

## Current architecture

- `main/main.cpp`: ESP-IDF `app_main`, startup logging, fake ADC initialization,
  and one demonstration frame read. It returns afterward; no acquisition loop yet.
- `components/acquisition`: public `SampleFrame` with sequence, timestamp,
  16 signed channel values, and status. Task and buffer implementation are deferred.
- `components/adc`: hardware-free `FakeADC`, with a public dependency on `acquisition`.
- `docs`: planned architecture, system requirements, and protocol outline.

`SampleFrame` safely initializes all members to zero and uses fixed-width integer
types from `<cstdint>` without dynamic allocation. `FakeADC::init()` returns true
without accessing peripherals. Each read fills channels 0 through 15 with
`1000000 + channel * 10000`, conceptually microvolts: CH1 = 1000000 through
CH16 = 1150000. Sequence, timestamp, and status are left unchanged; the future
acquisition subsystem will own sequence and timestamp updates. Startup reads one
frame, logs all 16 channel values once, and returns.

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
