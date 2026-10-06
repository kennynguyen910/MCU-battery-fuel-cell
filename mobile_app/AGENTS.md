# Project instructions

The user designates `docs/ble-wifi-provisioning-v1.md` and its source,
`docs/Will and Kenny Startup.pdf`, as the current product specification.
Apply provisioning v1 across the application and its integration contracts.
Older requirements documents are historical where they conflict with this specification.
The PDF describes a provisioning subsystem; its out-of-scope list applies to that
subsystem and does not require deleting independent measurement or storage features.

Preserve the existing measurement BLE UUIDs and packet formats. Provisioning uses
its separate 5ecf1000 service. Never log credentials or raw credential fragments.
Keep provisioning independent of acquisition, ADC access, queues, timers, and UDP
serialization. Require an encrypted BLE link for sensitive commands. Do not merge
or modify the destination repository's main branch without a later user request.
