#pragma once

#include <cstdint>

namespace udp_config {

// TEMPORARY DEVELOPMENT CONFIGURATION: laptop's IPv4 address on the same network.
// Update this to the laptop's current Wi-Fi IPv4 address before flashing.
inline constexpr const char* UDP_DESTINATION_IP = "10.245.124.33";
inline constexpr std::uint16_t UDP_DESTINATION_PORT = 5005;

// Flush an incomplete batch after 20 ms from its first buffered frame.
inline constexpr std::int64_t BATCH_FLUSH_TIMEOUT_US = 20000;
} // namespace udp_config
