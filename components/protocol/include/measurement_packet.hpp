#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

namespace measurement_protocol {

inline constexpr std::uint16_t MAGIC = 0x424D;
inline constexpr std::uint8_t VERSION = 1;
inline constexpr std::uint8_t MEASUREMENT_MESSAGE_TYPE = 1;
inline constexpr std::size_t CHANNEL_COUNT = 16;

// Serialized widths and offsets, independent of C++ structure padding.
// Every multibyte field, including CRC, uses big-endian byte order.
inline constexpr std::size_t MAGIC_OFFSET = 0;
inline constexpr std::size_t VERSION_OFFSET = MAGIC_OFFSET + 2;
inline constexpr std::size_t TYPE_OFFSET = VERSION_OFFSET + 1;
inline constexpr std::size_t SEQUENCE_OFFSET = TYPE_OFFSET + 1;
inline constexpr std::size_t TIMESTAMP_OFFSET = SEQUENCE_OFFSET + 4;
inline constexpr std::size_t CHANNELS_OFFSET = TIMESTAMP_OFFSET + 8;
inline constexpr std::size_t STATUS_OFFSET = CHANNELS_OFFSET + CHANNEL_COUNT * 4;
inline constexpr std::size_t CRC_OFFSET = STATUS_OFFSET + 4;
inline constexpr std::size_t PACKET_SIZE = CRC_OFFSET + 4;

} // namespace measurement_protocol

inline constexpr std::size_t MEASUREMENT_PACKET_SIZE = measurement_protocol::PACKET_SIZE;
using MeasurementPacket = std::array<std::uint8_t, MEASUREMENT_PACKET_SIZE>;

static_assert(MEASUREMENT_PACKET_SIZE == 2 + 1 + 1 + 4 + 8 + 16 * 4 + 4 + 4);
static_assert(MEASUREMENT_PACKET_SIZE == 88);