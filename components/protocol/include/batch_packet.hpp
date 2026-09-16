#pragma once

#include "measurement_packet.hpp"

// Version 1 batch envelope; authoritative wire layout: docs/protocol.md.
namespace batch_protocol {
inline constexpr std::uint16_t MAGIC = 0x4242; // BB
inline constexpr std::uint8_t VERSION = 1;
inline constexpr std::uint8_t MESSAGE_TYPE = 2;
inline constexpr std::size_t FRAMES_PER_DATAGRAM = 10;
inline constexpr std::size_t HEADER_SIZE = 10;
inline constexpr std::size_t MAX_PAYLOAD_SIZE = HEADER_SIZE +
    FRAMES_PER_DATAGRAM * MEASUREMENT_PACKET_SIZE;
using Datagram = std::array<std::uint8_t, MAX_PAYLOAD_SIZE>;
static_assert(MAX_PAYLOAD_SIZE == 890);
static_assert(MAX_PAYLOAD_SIZE <= 1472); // 1500-byte MTU minus IPv4/UDP headers.

inline void writeHeader(Datagram& data, std::uint16_t count, std::uint32_t sequence)
{
    data[0] = static_cast<std::uint8_t>(MAGIC >> 8);
    data[1] = static_cast<std::uint8_t>(MAGIC);
    data[2] = VERSION;
    data[3] = MESSAGE_TYPE;
    data[4] = static_cast<std::uint8_t>(count >> 8);
    data[5] = static_cast<std::uint8_t>(count);
    for (std::size_t i = 0; i < 4; ++i) {
        data[6 + i] = static_cast<std::uint8_t>(sequence >> (24 - 8 * i));
    }
}
} // namespace batch_protocol
