#include "udp_transport.hpp"
#include "udp_config.hpp"

#include <cerrno>
#include <fcntl.h>
#include "lwip/inet.h"

UdpTransport::~UdpTransport()
{
    close();
}

bool UdpTransport::init()
{
    if (isOpen()) {
        return true;
    }
    destination_ = {};
    destination_.sin_family = AF_INET;
    destination_.sin_port = htons(udp_config::UDP_DESTINATION_PORT);
    if (inet_pton(AF_INET, udp_config::UDP_DESTINATION_IP, &destination_.sin_addr) != 1 ||
        destination_.sin_addr.s_addr == htonl(INADDR_ANY) ||
        destination_.sin_addr.s_addr == htonl(INADDR_BROADCAST)) {
        last_error_ = EINVAL;
        return false;
    }
    socket_ = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (socket_ < 0) {
        last_error_ = errno;
        return false;
    }
    const int flags = fcntl(socket_, F_GETFL, 0);
    if (flags < 0 || fcntl(socket_, F_SETFL, flags | O_NONBLOCK) < 0) {
        last_error_ = errno;
        close();
        return false;
    }
    last_error_ = 0;
    return true;
}

bool UdpTransport::send(const std::uint8_t* data, std::size_t length)
{
    last_send_bytes_ = -1;
    // IPv4 UDP maximum payload is 65507 bytes; invalid requests never reach lwIP.
    if (!data || length == 0 || length > 65507) {
        last_error_ = EINVAL;
        return false;
    }
    if (!isOpen()) {
        last_error_ = EBADF;
        return false;
    }
    const auto sent = sendto(socket_, data, length, MSG_DONTWAIT,
                             reinterpret_cast<const sockaddr*>(&destination_),
                             sizeof(destination_));
    last_send_bytes_ = static_cast<int>(sent);
    if (sent < 0 || static_cast<std::size_t>(sent) != length) {
        last_error_ = sent < 0 ? errno : EIO;
        // Buffer pressure (EAGAIN/ENOBUFS/ENOMEM) does not invalidate a socket.
        // Drop only this frame; attempt the next frame without a cooldown.
        if (last_error_ == EBADF || last_error_ == ENOTSOCK) {
            close();
        }
        return false;
    }
    last_error_ = 0;
    return true;
}

void UdpTransport::close()
{
    if (socket_ >= 0) {
        ::close(socket_);
        socket_ = -1;
    }
}