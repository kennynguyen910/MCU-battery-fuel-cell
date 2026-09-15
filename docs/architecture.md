# Firmware architecture and future ADC interface

## Scope and current implementation

This document proposes the architecture for an ESP32-S3 Battery/Fuel Cell Monitor
using C++, ESP-IDF, and FreeRTOS. It is a design plan, not a claim that the planned
tasks, buffers, interfaces, or timing guarantees are implemented.

The system targets 16 independent voltage channels, approximately ±5 VDC input,
at least 16-bit measurement resolution, at least 1 kSPS per channel, and at least
1 kV electrical isolation between the measurement subsystem and the primary
MCU/communications subsystem. Wi-Fi, Ethernet, BLE, CAN, and an OLED are planned.
See [system requirements](requirements.md) for the requirements and
[binary protocol outline](protocol.md) for future serialization decisions.
The [ADC-to-MCU Interface Control Document](adc-interface.md) records the proposed
digital signals, unknown hardware parameters, and questions for the analog team.

Currently, `main/main.cpp` logs startup, initializes `FakeADC`, reads one
`SampleFrame`, logs all 16 channels, and returns. `components/acquisition`
provides the frame structure; `components/adc` provides the fake. The ADC
component publicly requires acquisition because its interface uses `SampleFrame`.
There are no application acquisition tasks, timers, buffers, packetizers,
communications implementations, OLED drivers, or real ADC drivers yet.

## Main data path

```text
16 Cell Inputs
      ↓
Analog Front End
      ↓
ADC(s)
      ↓
Digital Isolation Barrier
      ↓
ESP32-S3
      ↓
Acquisition Task
      ↓
Sample Buffer / Ring Buffer
      ↓
Packetizer
      ↓
Wi-Fi / Ethernet / BLE / CAN
```

The analog front end and ADC(s) belong to the measurement subsystem. The digital
isolation barrier separates that subsystem from the ESP32-S3 and communications.
The physical isolation design, including power and every crossing signal, must
be reviewed against the isolation requirement. The diagram does not specify
channel-to-channel isolation or guarantee an isolation rating through firmware.

The ESP32-S3 application is divided into these responsibilities:

```text
ESP32-S3
   ├── Acquisition
   ├── Communications
   ├── OLED
   └── Diagnostics
```

Acquisition owns frame production and timing metadata. Communications handles
packet delivery and connection state. OLED consumes a snapshot for display.
Diagnostics observes counters, timing, and faults without delaying acquisition.

## Acquisition priority and rate

Voltage acquisition is the most time-critical application function. Interpreting
1 kSPS per channel as 1,000 measurements of each channel every second gives:

```text
16 channels × 1000 samples/channel/second
    = 16,000 channel conversions per second

16 channel values per complete SampleFrame
    = 1000 complete 16-channel frames per second
    = one complete frame every 1 ms
```

This is the target frame cadence, not a demonstrated capability of `FakeADC`.
For a multiplexed converter, the conversion and settling budget must cover all
16 channels. Parallel or simultaneous converters may produce multiple channel
results together. A complete frame does not by itself imply simultaneous sampling;
channel skew and the timestamp reference point must be specified with the hardware.

Acquisition work must have a bounded execution time. The selected measurement
system must sustain conversion, transfer, validation, and frame publication at
the target rate with measured margin. Logging, reconnection, display rendering,
and slow consumer work must remain outside the critical acquisition path.

## Producer-consumer architecture

```text
ADC
 ↓
AcquisitionTask
 ↓
Buffer
 ↓
PacketTask
 ↓
Communication interfaces
```

`AcquisitionTask` is the producer of complete frames. It reads the driver, assigns
sequence and timestamp metadata, records validity/status, and publishes to a
bounded sample buffer. `PacketTask` consumes complete frames and prepares an
explicit binary representation. Transport workers handle delivery independently.
Only fully populated frames may become visible to consumers.

Communication operations must not block ADC acquisition:

- Wi-Fi disconnecting must not stop acquisition.
- Ethernet being unplugged must not stop acquisition.
- BLE disconnecting must not stop acquisition.
- CAN errors must not stop acquisition.
- OLED updates must not affect acquisition timing.

The proposed implementation uses fixed-capacity storage with bounded operations
and no dynamic allocation in the acquisition path. Buffer ownership and
synchronization must prevent a producer from modifying a frame being consumed.
Network calls and transport-held locks must never be prerequisites for publication.
The OLED and diagnostics should read snapshots or counters rather than compete
with the packetizer for measurement frames.

A finite buffer cannot preserve unlimited data during an outage. Before
implementation, choose a nonblocking overflow policy, such as dropping the
incoming frame, and record losses in counters/status. Assign sequence numbers
before publication so a dropped publication leaves a detectable gap. Buffer
capacity must be selected from the allowed backlog interval and actual
`sizeof(SampleFrame)`; at 1000 frames/s, 100 slots hold 100 ms of frames.

Use independently bounded transport backlogs so one stalled interface cannot
hold up the others. Whether every interface carries the full stream, a decimated
stream, or only summaries remains a throughput/design decision. The channel
fields alone total 64,000 bytes/s at the target rate, before metadata, framing,
CRC, and transport overhead; validate each delivery mode against that budget.

## Preliminary FreeRTOS task plan

| Task | Application priority | Planned responsibility |
| --- | --- | --- |
| AcquisitionTask | Highest | Read measurement data and publish complete frames |
| PacketTask | High | Consume frames and prepare packets |
| WiFiTask | Medium | Wi-Fi connection state and packet delivery |
| EthernetTask | Medium | Ethernet link state and packet delivery |
| BLETask | Medium | BLE connection state and selected data delivery |
| CANTask | Medium | CAN delivery and error recovery |
| DiagnosticsTask | Low | Health counters, timing reports, and fault summaries |
| OLEDTask | Low | Periodic display updates from a measurement snapshot |

These priorities are preliminary and will be validated through timing tests.
They describe relative application priorities, not numeric assignments or
priority over ESP-IDF system tasks and interrupts. Stack sizes, core affinity,
wakeup mechanisms, synchronization, and final task boundaries remain undecided.
A high priority alone does not guarantee the 1 ms cadence.

## Internal measurement representation

The existing declaration in `components/acquisition/include/acquisition.hpp` is:

```cpp
#include <cstdint>

struct SampleFrame
{
    std::uint32_t sequence = 0;
    std::uint64_t timestamp_us = 0;
    std::int32_t channels[16]{};
    std::uint32_t status = 0;
};
```

| Member | Purpose and ownership |
| --- | --- |
| `sequence` | Acquisition-owned frame counter. Gaps allow consumers to detect missing frames; reset and wraparound rules remain to be defined. |
| `timestamp_us` | Acquisition-owned time in microseconds associated with measurement, independent of packet transmission or arrival time. The clock origin and exact capture event remain to be defined. |
| `channels[16]` | One complete frame of 16 signed channel values; index 0 is CH1 and index 15 is CH16. The fake uses conceptual microvolts. Final scaling/calibration belongs to the hardware interface contract. |
| `status` | Frame validity and diagnostic flags. Bit definitions for conditions such as ADC faults, overruns, or invalid channels are still to be specified. |

Every member defaults to zero, and the structure requires no dynamic allocation.
Default zero status is not yet a defined guarantee of measurement validity.
Sequence numbers expose frame gaps; timestamps preserve acquisition timing even
when packets are delayed, batched, or delivered over different interfaces.

`SampleFrame` is an internal C++ object, not a wire format. Compiler padding and
native byte order must not determine the future protocol. Packet serialization,
CRC coverage, and transport fragmentation are deferred to the protocol design.

## Fake ADC and future driver boundary

```text
             ADC Interface
              /        \
         FakeADC      RealADC
```

This is a planned conceptual boundary. No abstract base class, runtime driver
selection, or `RealADC` implementation currently exists. The present callable
shape is `bool init()` and `void readFrame(SampleFrame& frame)` on `FakeADC`.

`FakeADC::init()` returns true without peripheral access. `readFrame()` fills all
16 channels using `1000000 + channel * 10000`: CH1 = 1000000 through
CH16 = 1150000, conceptually microvolts. It leaves sequence, timestamp, and status
unchanged. It does not generate a sampling cadence or simulate ADC timing/faults.

The fake allows future acquisition, buffering, packetization, and communications
firmware to be developed before the final ADC hardware is available. Later,
a real ADC driver will replace the fake behind a consistent measurement boundary,
keeping downstream frame consumers largely unchanged. This does not replace
hardware timing, electrical, calibration, or isolation validation.

## Future ADC-to-MCU interface decisions

The ADC driver will own device initialization, channel ordering, transfer parsing,
and conversion of device output into the agreed signed channel representation.
Acquisition will own scheduling, sequence numbering, and timestamps. Driver reads
must complete within a defined bound and report failure without publishing a
partial frame as valid. The current `void readFrame()` has no error return;
its future error/status contract must be designed before adding real hardware.

The following decisions remain open until the ADC, analog front end, and digital
isolator are selected:

- Physical bus and signaling: device count, bus topology, signal direction,
  voltage levels, and which clock/data/control signals cross the barrier.
  SPI is expected, subject to final ADC selection; it is not yet selected or implemented.
- Conversion control: free-running versus triggered conversion, optional
  data-ready signaling, synchronization across ADCs, and channel skew.
- Transfer format: word width, signed/bipolar encoding, channel identification,
  ordering, status/error fields, and any device-provided integrity checks.
- Timing budget: conversion/settling latency, data-ready-to-read delay, complete
  frame transfer time, isolation propagation delay, and timeout/recovery limits.
- Measurement semantics: scaling to engineering units, calibration, saturation,
  missing/invalid channel handling, and the timestamp reference event.
- Isolation boundary: required power isolation, grounding, all signal crossings,
  and the test conditions needed to demonstrate the at-least-1-kV requirement.

No pins, bus rate, timer, interrupt handler, DMA scheme, or real ADC driver is
selected by this document. The requirements for independent channels, bipolar
range, resolution, and isolation must be verified in the measurement hardware;
a 32-bit channel storage type alone does not establish measurement resolution.

## Planned validation

Measure frame cadence, timestamp jitter, channel completeness, acquisition
execution time, buffer high-water mark, dropped-frame counts, and worst-case
latency. Verify sequence gaps and overflow reporting under forced consumer stalls.
Exercise Wi-Fi/BLE disconnects, Ethernet link loss, CAN errors, and OLED updates
while acquisition runs. Validate priorities and resource sharing from these tests.

Use the fake first to validate data flow and metadata ownership. Repeat timing,
fault recovery, channel mapping, and measurement validation with the real driver
and hardware. Neither the existing one-frame startup demo nor a successful build
establishes the required sustained sampling rate or isolation performance.
