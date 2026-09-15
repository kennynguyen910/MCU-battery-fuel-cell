#include "packetizer_self_test.hpp"
#include "packetizer.hpp"

#include <limits>

namespace packetizer_test {

bool runSelfTest()
{
    constexpr std::uint8_t crc_check[] = {'1', '2', '3', '4', '5', '6', '7', '8', '9'};
    if (Packetizer::crc32(crc_check, sizeof(crc_check)) != 0xCBF43926U ||
        Packetizer::crc32(nullptr, 0) != 0) {
        return false;
    }

    SampleFrame frame{};
    frame.sequence = 0x01020304;
    frame.timestamp_us = 0x0102030405060708ULL;
    frame.channels[0] = 1234567;
    frame.channels[1] = -1234567;
    frame.channels[2] = std::numeric_limits<std::int32_t>::min();
    frame.channels[3] = std::numeric_limits<std::int32_t>::max();
    for (int channel = 4; channel < 16; ++channel) {
        frame.channels[channel] = (channel - 8) * 10000;
    }
    frame.status = 0xA1B2C3D4;

    // Independent golden packet generated with Python struct.pack('!HBBIQ16iI', ...)
    // and zlib.crc32 over the first 84 bytes. Fixed comparison verifies ALL fields.
    constexpr MeasurementPacket expected{
        0x42, 0x4D, 0x01, 0x01, 0x01, 0x02, 0x03, 0x04,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x00, 0x12, 0xD6, 0x87, 0xFF, 0xED, 0x29, 0x79,
        0x80, 0x00, 0x00, 0x00, 0x7F, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0x63, 0xC0, 0xFF, 0xFF, 0x8A, 0xD0,
        0xFF, 0xFF, 0xB1, 0xE0, 0xFF, 0xFF, 0xD8, 0xF0,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x27, 0x10,
        0x00, 0x00, 0x4E, 0x20, 0x00, 0x00, 0x75, 0x30,
        0x00, 0x00, 0x9C, 0x40, 0x00, 0x00, 0xC3, 0x50,
        0x00, 0x00, 0xEA, 0x60, 0x00, 0x01, 0x11, 0x70,
        0xA1, 0xB2, 0xC3, 0xD4, 0x35, 0xAA, 0xF6, 0x80
    };
    const SampleFrame original = frame;
    MeasurementPacket output{};
    output.fill(0xA5);
    if (!Packetizer::serializeMeasurement(frame, output) || output != expected) {
        return false;
    }
    if (frame.sequence != original.sequence || frame.timestamp_us != original.timestamp_us ||
        frame.status != original.status) {
        return false;
    }
    for (int channel = 0; channel < 16; ++channel) {
        if (frame.channels[channel] != original.channels[channel]) {
            return false;
        }
    }
    MeasurementPacket repeated{};
    if (!Packetizer::serializeMeasurement(frame, repeated) || repeated != output) {
        return false;
    }
    // A changed payload must fail validation against the fixture's original CRC.
    output[measurement_protocol::CHANNELS_OFFSET] ^= 0x01;
    return Packetizer::crc32(output.data(), measurement_protocol::CRC_OFFSET) != 0x35AAF680U;
}

} // namespace packetizer_test