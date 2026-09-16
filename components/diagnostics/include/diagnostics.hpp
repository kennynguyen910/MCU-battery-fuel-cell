#pragma once

#include <cstdint>
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"

enum class NetworkOutcome { WifiUnavailable, UdpNotReady, SendFailure, Transmitted };

struct DiagnosticCounters
{
    std::uint64_t framesAcquired = 0;
    std::uint64_t framesConsumed = 0;
    std::uint64_t framesPacketized = 0; // Compatibility alias of measurementFramesPacketized.
    std::uint64_t measurementFramesPacketized = 0;
    std::uint64_t measurementFramesTransmitted = 0;
    std::uint64_t udpDatagramsAttempted = 0;
    std::uint64_t udpDatagramsSent = 0;
    std::uint64_t udpDatagramSendFailures = 0;
    std::uint64_t udpFailedFrames = 0;
    std::uint32_t batchFramesPerDatagram = 0; // Actual count in last processed batch.
    std::uint64_t framesTransmitted = 0;
    std::uint64_t networkFramesNotSent = 0;
    std::uint64_t networkUnavailableFrames = 0;
    std::uint64_t udpNotReadyFrames = 0;
    std::uint64_t udpSendFailures = 0;
    std::uint64_t udpInitFailures = 0;
    std::uint64_t udpShortSends = 0;
    bool wifiConnected = false;
    bool udpReady = false;
    int socketFd = -1;
    int lastUdpError = 0;
    int lastSendBytes = -1;
    std::uint32_t udpSendErrors = 0;
    std::uint32_t packetizerErrors = 0;
    std::uint32_t framesDropped = 0;
    std::uint32_t bufferOverflows = 0;
    std::uint32_t acquisitionLateEvents = 0;
    std::uint32_t missedTimingEvents = 0;
    std::uint32_t adcReadErrors = 0;
    std::uint32_t sequenceDiscontinuities = 0;
    std::uint32_t maximumQueueDepthObserved = 0;
    std::uint32_t maximumWakeLatenessUs = 0;
    std::uint32_t maximumAdcReadTimeUs = 0;
};

// Firmware-lifetime object. All updates and snapshots are task-context only.
// Short critical sections protect 64-bit counters on both 32-bit target chips.
class Diagnostics
{
public:
    Diagnostics() = default;
    Diagnostics(const Diagnostics&) = delete;
    Diagnostics& operator=(const Diagnostics&) = delete;

    void recordAcquisition(bool acquired, bool published, bool late,
                           std::uint32_t missed, std::uint32_t wake_lateness_us,
                           std::uint32_t read_time_us, std::uint32_t queue_depth);
    void recordConsumed(bool discontinuity);
    void recordPacketized(bool success);
    void recordNetwork(NetworkOutcome outcome, std::uint16_t frames,
                       bool wifi_connected, bool udp_ready,
                       int socket_fd, int error, int sent_bytes);
    DiagnosticCounters snapshot();
    bool startReporting(QueueHandle_t queue, std::uint32_t capacity);
    // Used to unwind startup failure before the sampling timer starts.
    void stopReporting();

private:
    static void reportingTask(void* context);
    portMUX_TYPE mutex_ = portMUX_INITIALIZER_UNLOCKED;
    DiagnosticCounters counters_{};
    QueueHandle_t queue_ = nullptr;
    std::uint32_t capacity_ = 0;
    static constexpr std::uint32_t STACK_BYTES = 4096;
    StackType_t stack_[STACK_BYTES / sizeof(StackType_t)]{};
    StaticTask_t task_control_{};
    TaskHandle_t task_ = nullptr;
};