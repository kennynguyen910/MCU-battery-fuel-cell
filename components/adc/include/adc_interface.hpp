#pragma once

#include "acquisition.hpp"

// A hardware-independent source of complete 16-channel measurement frames.
// Acquisition owns sequence, timestamp and status; reads fill channel microvolts.
// A failed read must not be published as a valid complete frame.
class ADCInterface
{
public:
    virtual ~ADCInterface() = default;

    virtual bool init() = 0;
    virtual bool readFrame(SampleFrame& frame) = 0;
};