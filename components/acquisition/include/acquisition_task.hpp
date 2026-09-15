#pragma once

#include <cstdint>
#include "acquisition.hpp"
#include "acquisition_config.hpp"
#include "diagnostics.hpp"
#include "driver/gptimer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"

// Firmware-lifetime object. Initialize the ADC first, then call start() once
// from app_main. The ADC and Diagnostics objects must also outlive these tasks.
class Acquisition
{
public:
    // Bind ADCInterface::readFrame without a circular component dependency:
    // adc depends on SampleFrame in acquisition; acquisition needs only this adapter.
    template<typename Source>
    Acquisition(Source& source, Diagnostics& diagnostics)
        : source_(&source),
          read_frame_([](void* context, SampleFrame& frame) {
              return static_cast<Source*>(context)->readFrame(frame);
          }),
          diagnostics_(diagnostics)
    {
    }

    Acquisition(const Acquisition&) = delete;
    Acquisition& operator=(const Acquisition&) = delete;
    using FrameConsumer = void (*)(void*, const SampleFrame&);
    bool start(FrameConsumer consumer, void* context);

private:
    static bool onAlarm(gptimer_handle_t timer,
                        const gptimer_alarm_event_data_t* event, void* context);
    static void acquisitionTask(void* context);
    static void networkTask(void* context);
    void cleanup();

    void* source_;
    bool (*read_frame_)(void*, SampleFrame&);
    Diagnostics& diagnostics_;
    FrameConsumer consume_frame_ = nullptr;
    void* consumer_context_ = nullptr;
    QueueHandle_t queue_ = nullptr;
    StaticQueue_t queue_control_{};
    alignas(SampleFrame) std::uint8_t queue_storage_[
        acquisition_config::QUEUE_CAPACITY * sizeof(SampleFrame)]{};

    // ESP-IDF task stack sizes are expressed in bytes, including static tasks.
    static constexpr std::uint32_t ACQUISITION_STACK_BYTES = 4096;
    static constexpr std::uint32_t CONSUMER_STACK_BYTES = 4096;
    StackType_t acquisition_stack_[ACQUISITION_STACK_BYTES / sizeof(StackType_t)]{};
    StackType_t consumer_stack_[CONSUMER_STACK_BYTES / sizeof(StackType_t)]{};
    StaticTask_t acquisition_control_{};
    StaticTask_t consumer_control_{};
    TaskHandle_t acquisition_task_ = nullptr;
    TaskHandle_t consumer_task_ = nullptr;
    gptimer_handle_t timer_ = nullptr;
    bool timer_enabled_ = false;
    bool started_ = false;
    std::int64_t first_deadline_us_ = 0;
};