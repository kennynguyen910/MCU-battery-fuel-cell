#pragma once

#include "acquisition.hpp"

class FakeADC
{
public:
    // Simulate successful initialization without accessing hardware.
    bool init();

    // Fill all channels with simulated microvolts; preserve frame metadata.
    // Sequence and timestamp are owned by the acquisition subsystem.
    void readFrame(SampleFrame& frame);
};
