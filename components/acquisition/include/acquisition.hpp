#pragma once

#include <stdint.h>

// Internal measurement container, not a serialized wire format.
struct SampleFrame {
    uint32_t sequence;
    uint64_t timestamp_us;
    int32_t channels[16];
    uint32_t status;
};
