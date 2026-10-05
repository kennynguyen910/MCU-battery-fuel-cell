#pragma once

// DEVELOPMENT ONLY. Never enable in final firmware. Does not alter measurement
// GATT security. With 0, credential operations require an encrypted BLE link.
#ifndef BATTERY_MONITOR_ALLOW_INSECURE_PROVISIONING_DEV
#define BATTERY_MONITOR_ALLOW_INSECURE_PROVISIONING_DEV 0
#endif
