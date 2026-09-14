#pragma once

#include "acquisition.hpp"

class FakeADC {
public:
    // Reset the sequence counter. This fake requires no hardware setup.
    bool init();

    // Call init() first. Fills all fields; use from one acquisition task.
    void readFrame(SampleFrame& frame);

private:
    uint32_t next_sequence_ = 0;
};
