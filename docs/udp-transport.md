# Stage 3B UDP measurement transport

## Configuration and architecture

Set UDP_DESTINATION_IP in components/udp/include/udp_config.hpp to the laptop's
IPv4 address on the network shared with the ESP. Port defaults to 5005.
Wi-Fi credentials remain in components/wifi/include/wifi_config.hpp.
Use ipconfig on Windows to identify the active laptop network interface.
The CHANGE_ME placeholder is intentionally invalid; configure it before flashing.

GPTimer -> AcquisitionTask -> SampleFrame queue -> NetworkTask
-> Packetizer -> UdpTransport -> Wi-Fi -> laptop.

NetworkTask evolves the existing consumer at priority 3; acquisition remains
priority 5 and diagnostics priority 1. The queue remains 128 frames and producer
sends still use zero timeout. The consumer stack is now 4096 bytes for packetizer
and lwIP calls. Its development stress options remain available and default off.

Acquisition accepts a frame-consumer callback bound to NetworkConsumer in main.
This keeps protocol's dependency on acquisition one-way; acquisition has no
protocol, Wi-Fi or socket dependency. The network handler owns integration.
WiFiManager remains unchanged and provides only connection status.

## Socket and outage policy

UdpTransport uses lwIP BSD IPv4 datagram sockets. It parses the configured
destination, sets O_NONBLOCK and sends with MSG_DONTWAIT. It accepts byte buffers
and knows nothing about SampleFrame, Packetizer or Wi-Fi.
Socket initialization occurs lazily in NetworkTask when Wi-Fi has an IP.
The same socket is reused for successful sends. No application per-frame heap
allocation occurs; lwIP uses its bounded internal networking buffers.

Every dequeued frame is counted as consumed and checked for sequence continuity.
A fixed 88-byte packet is serialized, then connection state is checked.
Disconnected frames are discarded after counting networkFramesNotSent.
The socket is closed on observed disconnection. No retention/replay backlog exists.

On socket setup or send failure, udpSendErrors increases, the frame is unsent,
and the handler waits at least SOCKET_RETRY_MS (default 1000 ms) before trying to
create a socket again. During that delay it keeps draining the queue and counts
frames as network-unsent; those skipped frames do not each count as a UDP error.
The transport closes its socket on an actual send failure, including temporary
buffer exhaustion, so recovery uses a fresh socket. After Wi-Fi reconnects,
sending resumes on the next frame without reboot. There are no per-packet logs.
Nonblocking flags prevent waiting for send buffer availability; CPU/scheduling
cost still requires timing validation on real hardware.

## Diagnostics

Existing acquisition, queue, ADC and timing counters are preserved.
Added fields:

| Counter | Meaning |
| --- | --- |
| framesPacketized | Frames serialized successfully |
| framesTransmitted | Full datagrams accepted by the local socket API |
| networkFramesNotSent | Consumed frames not sent: serialization failure, Wi-Fi down, retry cooldown, or transport failure |
| udpSendErrors | Actual socket setup/send failures, not disconnected/cooldown frames |
| packetizerErrors | Serialization returned false |

UDP acceptance does not confirm laptop receipt; UDP has no acknowledgment or
retransmission in this stage. After integration finishes processing a frame,
framesConsumed = framesTransmitted + networkFramesNotSent, and
framesPacketized = framesConsumed - packetizerErrors. Snapshots can differ by
one frame while a consumer operation is in flight.

framesDropped/bufferOverflows measure loss BEFORE queue consumption.
networkFramesNotSent measures loss AFTER consumption; it never increments the
acquisition drop counters. During Wi-Fi outage, network-unsent should rise while
queue consumption and the measured acquisition rate continue normally.

## Build and validation

From the activated ESP-IDF terminal in this repository:

```sh
idf.py set-target esp32
idf.py build
```

After configuring destination and credentials, flash/monitor using the actual
serial port. Check five-second diagnostics:
- connected: packetized/transmitted increase near acquisition rate;
- router off: acquisition and consumption continue, network-unsent increases;
- router restored: transmitted resumes without reboot;
- temporary transport failure: UDP errors increase only for actual attempts,
  recovery attempts occur at most once per second, queue continues draining;
- development stress: queue drops remain distinct from network-unsent.

Version 1 packets are binary; the existing tools/udp_receiver.py is a plain-text
scratch receiver and does not decode this packet format. It may show unreadable
text. No binary Python receiver changes are part of Stage 3B.
Use a binary-aware receiver following docs/protocol.md or capture UDP packets
to verify 88-byte datagrams and CRC. At 1000 frames/s payload bandwidth is
88,000 bytes/s, before UDP/IP/Wi-Fi overhead.

Repeat rate/queue, socket recovery and Wi-Fi outage tests on ESP32-S3.
All APIs are ESP-IDF/lwIP equivalents on both targets; no GPIO mappings are used.
Actual radio throughput, scheduling and network buffer pressure may differ.