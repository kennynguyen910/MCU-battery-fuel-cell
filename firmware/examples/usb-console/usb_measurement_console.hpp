#pragma once

// Optional low-rate USB/UART console telemetry for MCU-battery-fuel-cell.
// Copy into that repository's main/ directory and follow docs/android-connections.md.
#include <cstdio>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "latest_frame_store.hpp"
#include "packetizer.hpp"

inline bool startUsbMeasurementConsole(LatestFrameStore& latest) {
    // Caller starts this once. It reads a snapshot and never drains the UDP queue.
    static bool started = false;
    if (started) return true;
    const auto result = xTaskCreate([](void* context) {
        auto& store = *static_cast<LatestFrameStore*>(context);
        constexpr char hex[] = "0123456789ABCDEF";
        for (;;) {
            vTaskDelay(pdMS_TO_TICKS(100));
            SampleFrame frame{};
            MeasurementPacket packet{};
            if (!store.read(frame) || !Packetizer::serializeMeasurement(frame, packet)) continue;
            char line[184] = "BMHEX:";
            for (std::size_t i = 0; i < packet.size(); ++i) {
                line[6 + 2 * i] = hex[packet[i] >> 4];
                line[7 + 2 * i] = hex[packet[i] & 15];
            }
            line[182] = '\n';
            line[183] = '\0';
            // One stdio call keeps each measurement separate from console logs.
            std::fwrite(line, 1, 183, stdout);
            std::fflush(stdout);
        }
    }, "usb_measurements", 4096, &latest, 1, nullptr);
    started = result == pdPASS;
    return started;
}
