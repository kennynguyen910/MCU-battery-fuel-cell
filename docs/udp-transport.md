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
Each frame is serialized as the original 88-byte packet, then appended to a
fixed 890-byte batch buffer. Ten frames trigger one send; partial batches expire
after 20 ms. Connection state is checked at flush time. See docs/protocol.md
for the exact 10-byte batch header and idle-flush policy.
Disconnected frames are discarded after counting networkFramesNotSent.
The socket is closed on observed disconnection. No retention/replay backlog exists.

Every flushed connected batch attempts socket initialization if needed and then sends.
There is no retry cooldown or intentional decimation. Send failures drop only
that batch. Transient errors retain the socket; EBADF/ENOTSOCK invalidate it so
the next connected batch recreates it. Wi-Fi disconnection closes the socket;
reconnection resumes sending without reboot. Logs remain rate-limited to five seconds.
The former one-second cooldown after each send error skipped roughly 1000 frames
per error; it was removed during the Stage 3 UDP diagnostic investigation.
Nonblocking flags prevent waiting for send buffer availability; CPU/scheduling
cost still requires timing validation on real hardware.

## Diagnostics

Existing acquisition, queue, ADC and timing counters are preserved.
Added fields:

| Counter | Meaning |
| --- | --- |
| framesPacketized | Frames serialized successfully |
| framesTransmitted | Full datagrams accepted by the local socket API |
| networkUnavailableFrames | Packetized frames skipped because Wi-Fi lacks an IP |
| udpNotReadyFrames | Packetized frames whose socket initialization failed |
| udpSendFailures / udpDatagramSendFailures | Failed batch send attempts, including short sends |
| udpFailedFrames | Measurement frames inside failed send attempts |
| udpDatagramsAttempted / udpDatagramsSent | Batch send attempts / successful sends |
| measurementFramesPacketized / measurementFramesTransmitted | Explicit frame totals (existing framesPacketized / framesTransmitted aliases preserved) |
| batchFramesPerDatagram | Actual count in the last processed batch, normally 10 |
| networkFramesNotSent | networkUnavailableFrames + udpNotReadyFrames + udpFailedFrames |
| udpInitFailures / udpShortSends | Setup failure / short-send attempt counts |
| udpSendErrors | Actual socket setup/send failures, not disconnected frames |
| packetizerErrors | Serialization returned false |

UDP acceptance does not confirm laptop receipt; UDP has no acknowledgment or
retransmission in this stage. After integration finishes processing a frame,
framesConsumed = framesTransmitted + networkFramesNotSent + packetizerErrors, and
framesPacketized = framesConsumed - packetizerErrors. While batching, up to ten
packetized frames may still be pending (or a serialization operation in flight),
so the first equality applies after the pending batch has been flushed.

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
  the next batch attempts sending/recreation immediately, queue continues draining;
- development stress: queue drops remain distinct from network-unsent.

Five-second diagnostics include wifiConnected, udpReady and socketFd, captured
by the socket-owning task. The last failure's errno, strerror and sentBytes are
historical, retained even after recovery; sentBytes >= 0 identifies a short send.
A ready socket has fd >= 0. The same app_main WiFiManager supplies IP events and
NetworkConsumer connection checks. Runtime logs are needed to verify radio state
and identify the actual send error; source inspection alone cannot establish it.

Version 1 packets are binary. Run python .\tools\udp_receiver.py on the laptop
for CRC validation, voltages, rate and sequence-gap statistics.
At 1000 frames/s payload bandwidth is
88,000 bytes/s, before UDP/IP/Wi-Fi overhead.

Repeat rate/queue, socket recovery and Wi-Fi outage tests on ESP32-S3.
All APIs are ESP-IDF/lwIP equivalents on both targets; no GPIO mappings are used.
Actual radio throughput, scheduling and network buffer pressure may differ.
## Development throughput test and 60-second acceptance run

`components/wifi/include/wifi_test_config.hpp` defaults
`HIGH_THROUGHPUT_TEST_MODE = true`. It calls `esp_wifi_set_ps(WIFI_PS_NONE)` after
driver initialization, logs the test policy once, and does not change connection
or reconnection behavior. Set false to leave ESP-IDF's default power-saving policy.
This trades battery life for reduced modem-sleep buffering during development;
it is not the final battery-power policy. A failure to set the policy is reported
and uses the existing startup error handling.

After flashing the classic ESP32, run `python .\tools\udp_receiver.py` for at
least 60 seconds. Compare counter deltas: about 60,000 acquired/consumed/received
measurement frames and 6,000 UDP datagrams; target zero acquisition drops,
overflows, ADC/packetizer/CRC errors, ideally zero missing frames and zero or rare
UDP send failures. Rate reports should show about 1000 frames/s and 100 datagrams/s.
These are hardware acceptance targets, not guaranteed results from a build.

One failed ten-frame send increases UDP send failures by one and network unsent
frames by ten. Setup failure and Wi-Fi outage also count every contained frame,
in separate mutually exclusive reasons, without changing acquisition-drop counters.
Failed batches are cleared and processing continues; no indefinite replay or retry
blocks the consumer. During normal operation all samples are included, without
measurement-rate reduction or decimation. Payload bandwidth remains 88,000 frame
bytes/s plus approximately 1000 batch-header bytes/s, before UDP/IP/Wi-Fi overhead.
