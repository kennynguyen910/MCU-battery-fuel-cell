#include "fake_adc.hpp"

bool FakeADC::init()
{
    return true;
}

void FakeADC::readFrame(SampleFrame& frame)
{
    for (int channel = 0; channel < 16; ++channel) {
        frame.channels[channel] = 1000000 + channel * 10000;
    }
}
