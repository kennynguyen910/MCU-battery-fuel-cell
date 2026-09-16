#pragma once

#include <cstddef>
#include <cstdint>
#include "lwip/sockets.h"

// Single-task owner. Pure byte transport: no ADC, frame, Wi-Fi or diagnostics knowledge.
// init/send/close use no application heap allocation per datagram.
class UdpTransport
{
public:
    UdpTransport() = default;
    ~UdpTransport();
    UdpTransport(const UdpTransport&) = delete;
    UdpTransport& operator=(const UdpTransport&) = delete;

    bool init();
    bool send(const std::uint8_t* data, std::size_t length);
    void close();
    bool isOpen() const { return socket_ >= 0; }
    bool isReady() const { return isOpen(); }
    int socketFd() const { return socket_; }
    int lastSendBytes() const { return last_send_bytes_; }
    int lastError() const { return last_error_; }

private:
    int socket_ = -1;
    int last_error_ = 0;
    int last_send_bytes_ = -1;
    sockaddr_in destination_{};
};