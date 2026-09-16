#include "diagnostics.hpp"

#include <algorithm>
#include <cinttypes>
#include <cstring>
#include "esp_log.h"
#include "esp_timer.h"

namespace {
constexpr const char* TAG = "diagnostics";
constexpr UBaseType_t REPORT_PRIORITY = 1;
constexpr std::uint32_t REPORT_INTERVAL_MS = 5000;
}

void Diagnostics::recordAcquisition(bool acquired, bool published, bool late,
                                    std::uint32_t missed, std::uint32_t wake_lateness_us,
                                    std::uint32_t read_time_us, std::uint32_t queue_depth)
{
    portENTER_CRITICAL(&mutex_);
    if (acquired) {
        ++counters_.framesAcquired;
        if (!published) {
            ++counters_.framesDropped;
            ++counters_.bufferOverflows;
        }
    } else {
        ++counters_.adcReadErrors;
    }
    if (late) {
        ++counters_.acquisitionLateEvents;
    }
    counters_.missedTimingEvents += missed;
    counters_.maximumQueueDepthObserved =
        std::max(counters_.maximumQueueDepthObserved, queue_depth);
    counters_.maximumWakeLatenessUs =
        std::max(counters_.maximumWakeLatenessUs, wake_lateness_us);
    counters_.maximumAdcReadTimeUs =
        std::max(counters_.maximumAdcReadTimeUs, read_time_us);
    portEXIT_CRITICAL(&mutex_);
}

void Diagnostics::recordConsumed(bool discontinuity)
{
    portENTER_CRITICAL(&mutex_);
    ++counters_.framesConsumed;
    if (discontinuity) {
        ++counters_.sequenceDiscontinuities;
    }
    portEXIT_CRITICAL(&mutex_);
}

void Diagnostics::recordNetwork(NetworkOutcome outcome, bool wifi_connected,
                                bool udp_ready, int socket_fd, int error, int sent_bytes)
{
    portENTER_CRITICAL(&mutex_);
    counters_.wifiConnected = wifi_connected;
    counters_.udpReady = udp_ready;
    counters_.socketFd = socket_fd;
    if (outcome == NetworkOutcome::PacketizerError) {
        ++counters_.packetizerErrors;
    } else {
        ++counters_.framesPacketized;
        switch (outcome) {
        case NetworkOutcome::WifiUnavailable: ++counters_.networkUnavailableFrames; break;
        case NetworkOutcome::UdpNotReady: ++counters_.udpNotReadyFrames; break;
        case NetworkOutcome::SendFailure: ++counters_.udpSendFailures; break;
        case NetworkOutcome::Transmitted: ++counters_.framesTransmitted; break;
        case NetworkOutcome::PacketizerError: break;
        }
    }
    counters_.networkFramesNotSent = counters_.networkUnavailableFrames +
        counters_.udpNotReadyFrames + counters_.udpSendFailures;
    if (outcome == NetworkOutcome::UdpNotReady || outcome == NetworkOutcome::SendFailure) {
        ++counters_.udpSendErrors; // Compatibility: setup plus send errors.
        if (outcome == NetworkOutcome::UdpNotReady) ++counters_.udpInitFailures;
        if (outcome == NetworkOutcome::SendFailure && sent_bytes >= 0) ++counters_.udpShortSends;
        counters_.lastUdpError = error;
        counters_.lastSendBytes = sent_bytes;
    }
    portEXIT_CRITICAL(&mutex_);
}

DiagnosticCounters Diagnostics::snapshot()
{
    portENTER_CRITICAL(&mutex_);
    const DiagnosticCounters result = counters_;
    portEXIT_CRITICAL(&mutex_);
    return result;
}

bool Diagnostics::startReporting(QueueHandle_t queue, std::uint32_t capacity)
{
    if (task_) {
        return true;
    }
    if (!queue || capacity == 0) {
        ESP_LOGE(TAG, "Invalid diagnostics queue");
        return false;
    }
    queue_ = queue;
    capacity_ = capacity;
    task_ = xTaskCreateStatic(&Diagnostics::reportingTask, "diagnostics",
                             STACK_BYTES, this, REPORT_PRIORITY, stack_, &task_control_);
    if (!task_) {
        ESP_LOGE(TAG, "Create DiagnosticsTask failed");
        return false;
    }
    return true;
}

void Diagnostics::stopReporting()
{
    if (task_) {
        vTaskDelete(task_);
        task_ = nullptr;
    }
    queue_ = nullptr;
}

void Diagnostics::reportingTask(void* context)
{
    auto& self = *static_cast<Diagnostics*>(context);
    std::int64_t previous_time_us = esp_timer_get_time();
    std::uint64_t previous_acquired = self.snapshot().framesAcquired;

    for (;;) {
        vTaskDelay(pdMS_TO_TICKS(REPORT_INTERVAL_MS));
        const auto counters = self.snapshot();
        const std::int64_t now_us = esp_timer_get_time();
        const auto elapsed_us = static_cast<std::uint64_t>(now_us - previous_time_us);
        const std::uint64_t delta = counters.framesAcquired - previous_acquired;
        const std::uint64_t rate_tenths = elapsed_us ? delta * 10000000ULL / elapsed_us : 0;
        const auto depth = static_cast<std::uint32_t>(uxQueueMessagesWaiting(self.queue_));

        ESP_LOGI(TAG, "Acquired=%" PRIu64 " consumed=%" PRIu64
                 " dropped=%" PRIu32 " overflows=%" PRIu32 " ADC errors=%" PRIu32,
                 counters.framesAcquired, counters.framesConsumed, counters.framesDropped,
                 counters.bufferOverflows, counters.adcReadErrors);
        ESP_LOGI(TAG, "Packetized=%" PRIu64 " transmitted=%" PRIu64
                 " network not sent=%" PRIu64 " UDP errors=%" PRIu32
                 " packetizer errors=%" PRIu32,
                 counters.framesPacketized, counters.framesTransmitted,
                 counters.networkFramesNotSent, counters.udpSendErrors,
                 counters.packetizerErrors);
        ESP_LOGI(TAG, "Network: wifiConnected=%s udpReady=%s socketFd=%d",
                 counters.wifiConnected ? "true" : "false",
                 counters.udpReady ? "true" : "false", counters.socketFd);
        ESP_LOGI(TAG, "WiFi unavailable=%" PRIu64 " UDP not ready=%" PRIu64
                 " UDP send failures=%" PRIu64 " init failures=%" PRIu64
                 " short sends=%" PRIu64,
                 counters.networkUnavailableFrames, counters.udpNotReadyFrames,
                 counters.udpSendFailures, counters.udpInitFailures, counters.udpShortSends);
        if (counters.udpSendErrors) {
            ESP_LOGW(TAG, "Last UDP failure (historical): errno=%d (%s) sentBytes=%d",
                     counters.lastUdpError, std::strerror(counters.lastUdpError),
                     counters.lastSendBytes);
        }
        ESP_LOGI(TAG, "Rate=%" PRIu64 ".%" PRIu64 " frames/s"
                 " late=%" PRIu32 " missed=%" PRIu32 " sequence gaps=%" PRIu32
                 " queue=%" PRIu32 "/%" PRIu32 " max queue=%" PRIu32
                 " max wake lateness=%" PRIu32 " us max ADC read=%" PRIu32 " us",
                 rate_tenths / 10, rate_tenths % 10, counters.acquisitionLateEvents,
                 counters.missedTimingEvents, counters.sequenceDiscontinuities,
                 depth, self.capacity_, counters.maximumQueueDepthObserved,
                 counters.maximumWakeLatenessUs, counters.maximumAdcReadTimeUs);
        previous_time_us = now_us;
        previous_acquired = counters.framesAcquired;
    }
}