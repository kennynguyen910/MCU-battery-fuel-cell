#include "network_consumer.hpp"

#include "packetizer.hpp"
#include "udp_config.hpp"
#include "esp_timer.h"

void NetworkConsumer::consumeFrame(void* context, const SampleFrame& frame)
{
    static_cast<NetworkConsumer*>(context)->consume(frame);
}

void NetworkConsumer::consume(const SampleFrame& frame)
{
    MeasurementPacket packet{};
    if (!Packetizer::serializeMeasurement(frame, packet)) {
        diagnostics_.recordNetwork(false, false, false);
        return;
    }
    if (!wifi_.isConnected()) {
        udp_.close();
        next_socket_retry_us_ = 0;
        diagnostics_.recordNetwork(true, false, false);
        return;
    }

    const std::int64_t now_us = esp_timer_get_time();
    if (!udp_.isOpen()) {
        if (now_us < next_socket_retry_us_) {
            diagnostics_.recordNetwork(true, false, false);
            return;
        }
        if (!udp_.init()) {
            next_socket_retry_us_ = now_us +
                static_cast<std::int64_t>(udp_config::SOCKET_RETRY_MS) * 1000;
            diagnostics_.recordNetwork(true, false, true);
            return;
        }
    }
    const bool transmitted = udp_.send(packet.data(), packet.size());
    if (!transmitted) {
        next_socket_retry_us_ = now_us +
            static_cast<std::int64_t>(udp_config::SOCKET_RETRY_MS) * 1000;
    }
    diagnostics_.recordNetwork(true, transmitted, !transmitted);
}