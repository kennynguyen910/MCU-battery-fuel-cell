#include "fake_adc.hpp"

bool FakeADC::init()
{
    phase_ = 0;
    return true;
}

bool FakeADC::readFrame(SampleFrame& frame)
{
    // 200-read triangular cycle: offset rises 0 -> 100000 uV and falls to 0.
    // First frame preserves the original 1000000 + channel * 10000 pattern.
    // Across all channels and phases, values stay in [1000000, 1250000] uV.
    const std::uint32_t ramp = phase_ <= 100 ? phase_ : 200 - phase_;
    const auto offset_uv = static_cast<std::int32_t>(ramp * 1000);
    for (int channel = 0; channel < 16; ++channel) {
        frame.channels[channel] = 1000000 + channel * 10000 + offset_uv;
    }
    phase_ = (phase_ + 1) % 200;
    return true;
}