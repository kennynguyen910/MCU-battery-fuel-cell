#pragma once

#include <cstdint>
#include "adc_interface.hpp"

class FakeADC : public ADCInterface
{
public:
    // Reset the deterministic simulation without accessing hardware.
    bool init() override;

    // Fill all channels with simulated microvolts; preserve frame metadata.
    bool readFrame(SampleFrame& frame) override;

private:
    std::uint32_t phase_ = 0;
};