// Host-only deterministic provenance/packet test. No ESP peripherals or flash.
#include <cassert>
#include <cstdint>
#include "fake_adc.hpp"
#include "packetizer.hpp"
#include "packetizer_self_test.hpp"

int main()
{
    static_assert(MEASUREMENT_PACKET_SIZE == 88);
    FakeADC adc;
    assert(adc.init());
    for (unsigned n = 0; n < 401; ++n) {
        SampleFrame frame{};
        frame.status = 0x20;
        assert(adc.readFrame(frame));
        assert(frame.status == (SAMPLE_STATUS_SIMULATED | 0x20));
        const auto phase = n % 200;
        const auto ramp = phase <= 100 ? phase : 200 - phase;
        for (unsigned i = 0; i < 16; ++i)
            assert(frame.channels[i] == 1000000 + static_cast<int>(i * 10000 + ramp * 1000));
        frame.sequence = n;
        frame.timestamp_us = n * 1000;
        MeasurementPacket packet{};
        assert(Packetizer::serializeMeasurement(frame, packet));
        assert(packet[80] == 0x80 && packet[81] == 0 && packet[82] == 0 && packet[83] == 0x20);
        const auto crc = Packetizer::crc32(packet.data(), 84);
        assert(packet[84] == (crc >> 24) && packet[85] == ((crc >> 16) & 255) &&
               packet[86] == ((crc >> 8) & 255) && packet[87] == (crc & 255));
    }
    assert(packetizer_test::runSelfTest());
}
