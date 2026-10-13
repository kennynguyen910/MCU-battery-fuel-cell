#pragma once

#include "acquisition.hpp"

// A hardware-independent source of complete 16-channel measurement frames.
// Acquisition owns sequence and timestamp; sources fill channel microvolts
// and provenance/status. Downstream code must preserve source status bits.
// A failed read must not be published as a valid complete frame.
class ADCInterface
{
public:
    virtual ~ADCInterface() = default;

    virtual bool init() = 0;
    virtual bool readFrame(SampleFrame& frame) = 0;
};