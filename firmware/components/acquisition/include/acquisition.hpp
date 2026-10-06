#pragma once

#include <cstdint>

// One complete frame of 16 cell-voltage channels in conceptual microvolts;
// 1.234567 V = 1234567 uV. This is an internal frame, not a wire format.
struct SampleFrame
{
    std::uint32_t sequence = 0;
    std::uint64_t timestamp_us = 0;
    std::int32_t channels[16]{};
    std::uint32_t status = 0;
};
