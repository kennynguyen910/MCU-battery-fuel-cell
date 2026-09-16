#pragma once

#include <cstdint>
#include "acquisition.hpp"
#include "diagnostics.hpp"
#include "udp_transport.hpp"
#include "wifi_manager.hpp"

// Firmware-lifetime handler, called only by the existing queue consumer task.
class NetworkConsumer
{
public:
    NetworkConsumer(WiFiManager& wifi, UdpTransport& udp, Diagnostics& diagnostics)
        : wifi_(wifi), udp_(udp), diagnostics_(diagnostics) {}

    static void consumeFrame(void* context, const SampleFrame& frame);

private:
    void consume(const SampleFrame& frame);
    WiFiManager& wifi_;
    UdpTransport& udp_;
    Diagnostics& diagnostics_;

};