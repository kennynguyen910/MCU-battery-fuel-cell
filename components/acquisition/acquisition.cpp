#include "acquisition_task.hpp"

#include <algorithm>
#include <limits>
#include "esp_attr.h"
#include "esp_log.h"
#include "esp_timer.h"

namespace {
constexpr const char* TAG = "acquisition";
using namespace acquisition_config;

bool check(esp_err_t error, const char* operation)
{
    if (error == ESP_OK) {
        return true;
    }
    ESP_LOGE(TAG, "%s failed: %s", operation, esp_err_to_name(error));
    return false;
}

std::uint32_t boundedDuration(std::int64_t duration)
{
    return static_cast<std::uint32_t>(std::min<std::int64_t>(
        std::max<std::int64_t>(duration, 0), std::numeric_limits<std::uint32_t>::max()));
}

static_assert(ACQUISITION_PRIORITY < configMAX_PRIORITIES);
static_assert(CONSUMER_PRIORITY < ACQUISITION_PRIORITY);
static_assert(QUEUE_CAPACITY > 0);
static_assert(STRESS_EVERY_FRAMES > 0);
static_assert(!ENABLE_CONSUMER_STRESS_TEST || pdMS_TO_TICKS(STRESS_PAUSE_MS) > 0);
}

bool Acquisition::start()
{
    if (started_) {
        return true;
    }
    queue_ = xQueueCreateStatic(QUEUE_CAPACITY, sizeof(SampleFrame),
                                queue_storage_, &queue_control_);
    if (!queue_) {
        ESP_LOGE(TAG, "Create SampleFrame queue failed");
        return false;
    }

    gptimer_config_t timer_config{};
    timer_config.clk_src = GPTIMER_CLK_SRC_DEFAULT;
    timer_config.direction = GPTIMER_COUNT_UP;
    timer_config.resolution_hz = 1000000;
    if (!check(gptimer_new_timer(&timer_config, &timer_), "Create GPTimer")) {
        cleanup();
        return false;
    }
    gptimer_event_callbacks_t callbacks{};
    callbacks.on_alarm = &Acquisition::onAlarm;
    gptimer_alarm_config_t alarm{};
    alarm.alarm_count = PERIOD_US;
    alarm.reload_count = 0;
    alarm.flags.auto_reload_on_alarm = true;
    if (!check(gptimer_register_event_callbacks(timer_, &callbacks, this),
               "Register timer callback") ||
        !check(gptimer_set_alarm_action(timer_, &alarm), "Configure timer alarm") ||
        !check(gptimer_enable(timer_), "Enable timer")) {
        cleanup();
        return false;
    }
    timer_enabled_ = true;

    acquisition_task_ = xTaskCreateStatic(&Acquisition::acquisitionTask, "acquisition",
        ACQUISITION_STACK_BYTES, this, ACQUISITION_PRIORITY,
        acquisition_stack_, &acquisition_control_);
    if (!acquisition_task_) {
        ESP_LOGE(TAG, "Create AcquisitionTask failed");
        cleanup();
        return false;
    }
    consumer_task_ = xTaskCreateStatic(&Acquisition::consumerTask, "consumer",
        CONSUMER_STACK_BYTES, this, CONSUMER_PRIORITY,
        consumer_stack_, &consumer_control_);
    if (!consumer_task_ || !diagnostics_.startReporting(queue_, QUEUE_CAPACITY)) {
        ESP_LOGE(TAG, "Create consumer/diagnostics task failed");
        cleanup();
        return false;
    }

    // Timer starts only after the queue and all three tasks are ready.
    first_deadline_us_ = esp_timer_get_time() + PERIOD_US;
    if (!check(gptimer_start(timer_), "Start 1 kHz timer")) {
        cleanup();
        return false;
    }
    started_ = true;
    ESP_LOGI(TAG, "Started 1000 Hz acquisition, queue=%u, priorities acquisition=%u consumer=%u",
             static_cast<unsigned>(QUEUE_CAPACITY),
             static_cast<unsigned>(ACQUISITION_PRIORITY),
             static_cast<unsigned>(CONSUMER_PRIORITY));
    if constexpr (ENABLE_CONSUMER_STRESS_TEST) {
        ESP_LOGW(TAG, "DEVELOPMENT stress: pause consumer %u ms every %u consumed frames",
                 static_cast<unsigned>(STRESS_PAUSE_MS),
                 static_cast<unsigned>(STRESS_EVERY_FRAMES));
    }
    return true;
}

void Acquisition::cleanup()
{
    // Startup-failure unwind; the timer is stopped before deleting its target task.
    if (timer_) {
        if (started_) {
            check(gptimer_stop(timer_), "Stop timer");
        }
        if (timer_enabled_) {
            check(gptimer_disable(timer_), "Disable timer");
        }
        check(gptimer_del_timer(timer_), "Delete timer");
        timer_ = nullptr;
    }
    diagnostics_.stopReporting();
    if (consumer_task_) {
        vTaskDelete(consumer_task_);
        consumer_task_ = nullptr;
    }
    if (acquisition_task_) {
        vTaskDelete(acquisition_task_);
        acquisition_task_ = nullptr;
    }
    if (queue_) {
        vQueueDelete(queue_);
        queue_ = nullptr;
    }
    timer_enabled_ = false;
    started_ = false;
}

bool IRAM_ATTR Acquisition::onAlarm(gptimer_handle_t,
                                    const gptimer_alarm_event_data_t*, void* context)
{
    auto* self = static_cast<Acquisition*>(context);
    BaseType_t higher_priority_woken = pdFALSE;
    vTaskNotifyGiveFromISR(self->acquisition_task_, &higher_priority_woken);
    return higher_priority_woken == pdTRUE;
}

void Acquisition::acquisitionTask(void* context)
{
    auto& self = *static_cast<Acquisition*>(context);
    std::uint32_t sequence = 0;
    std::int64_t next_deadline_us = 0;

    for (;;) {
        // Clear the whole bounded notification count; acquire ONE fresh frame,
        // never run a burst of historical/catch-up ADC reads.
        const std::uint32_t notifications = ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
        if (!notifications) {
            continue;
        }
        const std::int64_t wake_us = esp_timer_get_time();
        if (!next_deadline_us) {
            next_deadline_us = self.first_deadline_us_;
        }
        const std::int64_t newest_deadline_us =
            next_deadline_us + static_cast<std::int64_t>(notifications - 1) * PERIOD_US;
        const std::int64_t lateness_us = std::max<std::int64_t>(0, wake_us - newest_deadline_us);
        // Count observed coalesced notifications plus elapsed schedule slots for
        // which no notification was delivered (e.g. delayed timer ISR).
        const auto schedule_skips = lateness_us / PERIOD_US;
        const auto missed = boundedDuration(
            static_cast<std::int64_t>(notifications - 1) + schedule_skips);
        next_deadline_us = newest_deadline_us + (schedule_skips + 1) * PERIOD_US;

        SampleFrame frame{};
        const std::int64_t read_start_us = esp_timer_get_time();
        const bool acquired = self.read_frame_(self.source_, frame);
        const std::int64_t read_end_us = esp_timer_get_time();
        const auto read_time_us = boundedDuration(read_end_us - read_start_us);
        bool published = false;
        std::uint32_t depth = 0;
        if (acquired) {
            frame.sequence = sequence++;
            // Timestamp is the monotonic START of this ADC read, not timer expiry
            // or consumer arrival. Failed reads consume no successful-frame sequence.
            frame.timestamp_us = static_cast<std::uint64_t>(read_start_us);
            published = xQueueSend(self.queue_, &frame, 0) == pdTRUE;
            // The other core can drain between send and observation. A successful
            // send proves at least one queued item; a failed send proves capacity.
            depth = published ? std::max<std::uint32_t>(
                1, uxQueueMessagesWaiting(self.queue_)) : QUEUE_CAPACITY;
        }
        const bool late = missed > 0 || lateness_us > LATE_THRESHOLD_US ||
                          read_time_us >= PERIOD_US;
        self.diagnostics_.recordAcquisition(acquired, published, late, missed,
            boundedDuration(lateness_us), read_time_us, depth);
    }
}

void Acquisition::consumerTask(void* context)
{
    auto& self = *static_cast<Acquisition*>(context);
    bool have_previous = false;
    std::uint32_t previous_sequence = 0;
    std::uint32_t stress_frames = 0;
    SampleFrame frame{};

    for (;;) {
        if (xQueueReceive(self.queue_, &frame, portMAX_DELAY) != pdTRUE) {
            continue;
        }
        // Unsigned arithmetic intentionally accepts the uint32 sequence rollover.
        const bool discontinuity = have_previous && frame.sequence != previous_sequence + 1U;
        self.diagnostics_.recordConsumed(discontinuity);
        previous_sequence = frame.sequence;
        have_previous = true;

        if constexpr (ENABLE_CONSUMER_STRESS_TEST) {
            if (++stress_frames >= STRESS_EVERY_FRAMES) {
                stress_frames = 0;
                vTaskDelay(pdMS_TO_TICKS(STRESS_PAUSE_MS));
            }
        }
    }
}