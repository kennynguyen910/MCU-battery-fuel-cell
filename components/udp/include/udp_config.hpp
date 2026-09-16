#pragma once

#include <cstdint>

namespace udp_config {

// TEMPORARY DEVELOPMENT CONFIGURATION: laptop's IPv4 address on the same network.
// Replace CHANGE_ME locally before flashing. This contains no Wi-Fi credentials.
inline constexpr const char* UDP_DESTINATION_IP = "10.247.158.106";
inline constexpr std::uint16_t UDP_DESTINATION_PORT = 5005;
// Network consumer retries socket setup after failure at most once per second.
inline constexpr std::uint32_t SOCKET_RETRY_MS = 1000;

} // namespace udp_config