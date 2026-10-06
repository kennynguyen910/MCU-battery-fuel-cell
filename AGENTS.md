# Project instructions

The user's current specification is `mobile_app/docs/Will and Kenny Startup.pdf`, with
its implementation map in `mobile_app/docs/ble-wifi-provisioning-v1.md`. Apply that
specification to BLE Wi-Fi provisioning throughout this codebase. Earlier
provisioning requirements are historical where they conflict with it.

Keep provisioning independent of measurement acquisition. Preserve the existing
measurement UUIDs, packets, ADC pipeline, queues, and 1 kHz timer. Use the separate
provisioning service and existing WiFiManager / wifi_cfg NVS APIs. Require encrypted
BLE links for credential operations, never log password bytes, and expire staging.
The PDF's v1 exclusions apply to provisioning, not existing independent app features.

The complete Flutter/API/database application is in `mobile_app/`; ESP-IDF firmware
is under firmware/. The application implements the client side of the protocol.
Upstream firmware currently supports status/scans only; credential handling and
physical acceptance remain integration work. Preserve these boundaries in claims.

This branch is prepared for review and a later merge. Do not merge or modify main
without a later explicit user request.
