#include "fake_adc.hpp"
#include "esp_timer.h"

bool FakeADC::init()
{
    next_sequence_ = 0;
    return true;
}

void FakeADC::readFrame(SampleFrame& frame)
{
    frame.sequence = next_sequence_++;
    frame.timestamp_us = static_cast<uint64_t>(esp_timer_get_time());
    for (int channel = 0; channel < 16; ++channel) {
        frame.channels[channel] = (channel - 8) * 1000;
    }
    frame.status = 0;
}
