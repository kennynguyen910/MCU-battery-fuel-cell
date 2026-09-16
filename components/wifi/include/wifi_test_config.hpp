#pragma once

namespace wifi_test_config {
// DEVELOPMENT ONLY: reduce modem-sleep buffering during throughput tests.
// true selects WIFI_PS_NONE; false leaves ESP-IDF's default power-save policy.
// This is not the final battery-power policy.
inline constexpr bool HIGH_THROUGHPUT_TEST_MODE = true;
} // namespace wifi_test_config
