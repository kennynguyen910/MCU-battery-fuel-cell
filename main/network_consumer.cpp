#include "network_consumer.hpp"

#include "packetizer.hpp"

void NetworkConsumer::consumeFrame(void* context, const SampleFrame& frame)
{
    static_cast<NetworkConsumer*>(context)->consume(frame);
}

void NetworkConsumer::consume(const SampleFrame& frame)
{
    const bool connected = wifi_.isConnected();
    const auto record = [&](NetworkOutcome outcome, int error = 0, int sent = -1) {
        diagnostics_.recordNetwork(outcome, connected, udp_.isReady(),
                                   udp_.socketFd(), error, sent);
    };
    MeasurementPacket packet{};
    if (!Packetizer::serializeMeasurement(frame, packet)) {
        record(NetworkOutcome::PacketizerError);
        return;
    }
    if (!connected) {
        udp_.close();
        record(NetworkOutcome::WifiUnavailable);
        return;
    }
    // Every connected frame attempts initialization if necessary, then send.
    // No cooldown, delay, decimation, acknowledgment wait or same-frame retry.
    if (!udp_.isReady() && !udp_.init()) {
        record(NetworkOutcome::UdpNotReady, udp_.lastError());
        return;
    }
    if (udp_.send(packet.data(), packet.size())) {
        record(NetworkOutcome::Transmitted);
    } else {
        record(NetworkOutcome::SendFailure, udp_.lastError(), udp_.lastSendBytes());
    }
}
