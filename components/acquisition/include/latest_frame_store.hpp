#pragma once

#include "acquisition.hpp"
#include "freertos/FreeRTOS.h"

// Single writer (AcquisitionTask), multiple readers. Copies only a SampleFrame.
class LatestFrameStore {
public:
    void publish(const SampleFrame& frame) {
        portENTER_CRITICAL(&mutex_);
        frame_ = frame;
        valid_ = true;
        portEXIT_CRITICAL(&mutex_);
    }
    bool read(SampleFrame& out) {
        portENTER_CRITICAL(&mutex_);
        const bool valid = valid_;
        if (valid) out = frame_;
        portEXIT_CRITICAL(&mutex_);
        return valid;
    }
private:
    portMUX_TYPE mutex_ = portMUX_INITIALIZER_UNLOCKED;
    SampleFrame frame_{};
    bool valid_ = false;
};
