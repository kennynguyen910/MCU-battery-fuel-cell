#pragma once

#include <cstdint>

namespace udp_config {

// TEMPORARY DEVELOPMENT CONFIGURATION: laptop's IPv4 address on the same network.
// Replace CHANGE_ME locally before flashing. This contains no Wi-Fi credentials.
inline constexpr const char* UDP_DESTINATION_IP = "10.247.158.106";
inline constexpr std::uint16_t UDP_DESTINATION_PORT = 5005;

// Flush an incomplete batch after 20 ms from its first buffered frame.
inline constexpr std::int64_t BATCH_FLUSH_TIMEOUT_US = 20000;
} // namespace udp_config