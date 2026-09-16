#pragma once

#include <cstdint>
#include "acquisition.hpp"
#include "batch_packet.hpp"
#include "diagnostics.hpp"
#include "udp_transport.hpp"
#include "wifi_manager.hpp"

// Firmware-lifetime handler, called only by the existing queue consumer task.
class NetworkConsumer
{
public:
    NetworkConsumer(WiFiManager& wifi, UdpTransport& udp, Diagnostics& diagnostics)
        : wifi_(wifi), udp_(udp), diagnostics_(diagnostics) {}

    static void flushExpired(void* context);
    static void consumeFrame(void* context, const SampleFrame& frame);

private:
    void consume(const SampleFrame& frame);
    void flush();
    batch_protocol::Datagram batch_{};
    std::uint16_t frame_count_ = 0;
    std::uint32_t batch_sequence_ = 0;
    std::int64_t first_frame_us_ = 0;
    WiFiManager& wifi_;
    UdpTransport& udp_;
    Diagnostics& diagnostics_;

};