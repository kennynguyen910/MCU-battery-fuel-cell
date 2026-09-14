# Architecture

Planned data flow:

```text
ADC / measurement system
    → isolation barrier
    → ESP32-S3
    → acquisition task
    → buffer
    → packetizer
    → Wi-Fi / Ethernet / BLE / CAN
```

The acquisition task will own measurement reads and produce `SampleFrame` values.
A bounded buffer will decouple acquisition from packetization and transmission.
Communications must not block ADC acquisition; overflow handling and status
reporting must be defined before implementing the buffer and transports.
The OLED will be a separate consumer of measurement state.

The current starter uses `FakeADC` in place of the measurement hardware.
`app_main` logs startup, initializes the fake, and reads one frame.
The acquisition component currently supplies only the shared frame structure.
The ADC component publicly depends on acquisition because its interface exposes
`SampleFrame`, and privately depends on `esp_timer` for timestamps.
No tasks, buffers, isolation hardware drivers, packetizers, or transports exist yet.
