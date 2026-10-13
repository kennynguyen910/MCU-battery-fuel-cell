#pragma once

#include <cstdint>

// Wire status bit 31: synthetic source, preserved by every transport.
inline constexpr std::uint32_t SAMPLE_STATUS_SIMULATED = 0x80000000U;

// One complete frame of 16 cell-voltage channels in conceptual microvolts;
// 1.234567 V = 1234567 uV. This is an internal frame, not a wire format.
struct SampleFrame
{
    std::uint32_t sequence = 0;
    std::uint64_t timestamp_us = 0;
    std::int32_t channels[16]{};
    std::uint32_t status = 0;
};
