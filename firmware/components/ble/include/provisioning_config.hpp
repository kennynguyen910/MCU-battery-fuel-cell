#pragma once

// DEVELOPMENT ONLY. Never enable in final firmware. Does not alter measurement
// GATT security. With 0, credentials require encryption and authenticated pairing.
#ifndef BATTERY_MONITOR_ALLOW_INSECURE_PROVISIONING_DEV
#define BATTERY_MONITOR_ALLOW_INSECURE_PROVISIONING_DEV 0
#endif
