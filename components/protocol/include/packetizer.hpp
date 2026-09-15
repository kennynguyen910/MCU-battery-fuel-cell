#pragma once

#include <cstddef>
#include <cstdint>
#include "acquisition.hpp"
#include "measurement_packet.hpp"

// Pure serialization: no transport, Wi-Fi, task, or logging operations.
// Caller owns the fixed output buffer; frame contents are never modified.
class Packetizer
{
public:
    static bool serializeMeasurement(const SampleFrame& frame, MeasurementPacket& output);

    // CRC-32/ISO-HDLC: reflected polynomial 0xEDB88320, init/xorout 0xFFFFFFFF.
    // bytes must reference length valid bytes; length zero returns the empty CRC (0).
    static std::uint32_t crc32(const std::uint8_t* bytes, std::size_t length);
};