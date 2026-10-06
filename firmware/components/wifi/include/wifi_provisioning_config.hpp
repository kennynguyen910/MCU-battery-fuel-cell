#pragma once

// TEMPORARY DEVELOPMENT ONLY. Set to 1 to seed from wifi_config.hpp only when
// NVS credentials are absent. Set back to 0 after seeding, especially before
// clearCredentials() testing. With 0, wifi_config.hpp is not compiled in.
#define WIFI_ENABLE_DEVELOPMENT_SEED 0
