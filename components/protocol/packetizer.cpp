#include "packetizer.hpp"

#include <climits>

namespace {
using namespace measurement_protocol;
static_assert(CHAR_BIT == 8, "The measurement protocol requires 8-bit bytes");
static_assert(sizeof(SampleFrame{}.channels) / sizeof(std::int32_t) == CHANNEL_COUNT);

void writeBigEndian(std::uint64_t value, std::size_t width,
                    MeasurementPacket& output, std::size_t& offset)
{
    for (std::size_t remaining = width; remaining > 0; --remaining) {
        output[offset++] = static_cast<std::uint8_t>(value >> ((remaining - 1) * 8));
    }
}
}

std::uint32_t Packetizer::crc32(const std::uint8_t* bytes, std::size_t length)
{
    std::uint32_t crc = 0xFFFFFFFFU;
    for (std::size_t index = 0; index < length; ++index) {
        crc ^= bytes[index];
        for (unsigned bit = 0; bit < 8; ++bit) {
            crc = (crc >> 1) ^ ((crc & 1U) ? 0xEDB88320U : 0U);
        }
    }
    return crc ^ 0xFFFFFFFFU;
}

bool Packetizer::serializeMeasurement(const SampleFrame& frame, MeasurementPacket& output)
{
    std::size_t offset = 0;
    writeBigEndian(MAGIC, 2, output, offset);
    output[offset++] = VERSION;
    output[offset++] = MEASUREMENT_MESSAGE_TYPE;
    writeBigEndian(frame.sequence, 4, output, offset);
    writeBigEndian(frame.timestamp_us, 8, output, offset);
    for (const auto channel : frame.channels) {
        // Signed-to-unsigned conversion is defined modulo 2^32. This explicitly
        // produces the protocol's two's-complement bits, including negative values.
        writeBigEndian(static_cast<std::uint32_t>(channel), 4, output, offset);
    }
    writeBigEndian(frame.status, 4, output, offset);
    if (offset != CRC_OFFSET) {
        return false;
    }
    const auto crc = crc32(output.data(), CRC_OFFSET);
    writeBigEndian(crc, 4, output, offset);
    return offset == output.size();
}