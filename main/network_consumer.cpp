#include "network_consumer.hpp"

#include <algorithm>
#include "packetizer.hpp"
#include "udp_config.hpp"
#include "esp_timer.h"

void NetworkConsumer::consumeFrame(void* context, const SampleFrame& frame)
{
    static_cast<NetworkConsumer*>(context)->consume(frame);
}

void NetworkConsumer::flushExpired(void* context)
{
    auto& self = *static_cast<NetworkConsumer*>(context);
    if (self.frame_count_ && esp_timer_get_time() - self.first_frame_us_ >=
                            udp_config::BATCH_FLUSH_TIMEOUT_US) {
        self.flush();
    }
}

void NetworkConsumer::consume(const SampleFrame& frame)
{
    flushExpired(this);
    MeasurementPacket packet{};
    const bool packetized = Packetizer::serializeMeasurement(frame, packet);
    diagnostics_.recordPacketized(packetized);
    if (!packetized) return;
    if (!frame_count_) first_frame_us_ = esp_timer_get_time();
    std::copy(packet.begin(), packet.end(), batch_.begin() +
              batch_protocol::HEADER_SIZE + frame_count_ * MEASUREMENT_PACKET_SIZE);
    if (++frame_count_ == batch_protocol::FRAMES_PER_DATAGRAM) flush();
}

void NetworkConsumer::flush()
{
    if (!frame_count_) return;
    batch_protocol::writeHeader(batch_, frame_count_, batch_sequence_++);
    const std::size_t length = batch_protocol::HEADER_SIZE +
                              frame_count_ * MEASUREMENT_PACKET_SIZE;
    const bool connected = wifi_.isConnected();
    const auto record = [&](NetworkOutcome outcome, int error = 0, int sent = -1) {
        diagnostics_.recordNetwork(outcome, frame_count_, connected, udp_.isReady(),
                                   udp_.socketFd(), error, sent);
    };
    if (!connected) {
        udp_.close();
        record(NetworkOutcome::WifiUnavailable);
    } else if (!udp_.isReady() && !udp_.init()) {
        record(NetworkOutcome::UdpNotReady, udp_.lastError());
    } else if (udp_.send(batch_.data(), length)) {
        record(NetworkOutcome::Transmitted);
    } else {
        record(NetworkOutcome::SendFailure, udp_.lastError(), udp_.lastSendBytes());
    }
    // One bounded attempt: failed batches count network losses, never ADC drops.
    frame_count_ = 0;
}
