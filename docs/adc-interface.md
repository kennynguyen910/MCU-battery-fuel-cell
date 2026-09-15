# ADC-to-MCU Interface Control Document

Status: preliminary; ADC and isolator selection are TBD.
Interface owners: analog/measurement team and MCU/firmware team.

## Purpose

This document defines the proposed digital interface between the isolated ADC
measurement subsystem and the ESP32-S3 firmware subsystem. It records requirements,
expected signals, and unresolved decisions for joint review by both teams.
It does not select hardware or establish an approved electrical interface.

See [firmware architecture](architecture.md) for data ownership and task planning,
[system requirements](requirements.md) for system targets, and
[protocol outline](protocol.md) for the separate future communications format.
The ADC transfer format and the outgoing measurement protocol are distinct.

## Measurement requirements

| Parameter | Requirement |
| --- | --- |
| Number of channels | 16 independent voltage channels |
| Input range | ±5 VDC |
| Resolution | ≥16 bits |
| Sample rate | ≥1 kSPS per channel |
| Isolation | ≥1 kV between measurement and MCU/communications subsystems |

These are system requirements, not confirmed properties of a selected ADC.
Input conditioning, channel common-mode limits, effective resolution, calibration,
and isolation test conditions are TBD. Channel-to-channel isolation is TBD;
the stated isolation requirement refers to the measurement-to-MCU boundary.

## Preliminary digital interface

SPI is expected, subject to final ADC selection. The proposed signal directions
assume the ESP32-S3 initiates SPI transactions; the final topology is TBD.

```text
Measurement subsystem          Isolation          MCU subsystem
+----------------------+       barrier       +----------------------+
| 16 inputs -> AFE     |                     | ESP32-S3             |
|           -> ADC(s)  | <--- control --------| ADC driver           |
|                      | ---- data/status -->| Acquisition          |
+----------------------+                     +----------------------+
                Exact signals and isolated power: TBD
```

Potential signals are listed below. The exact signal set depends on the final
ADC architecture; this list is not a pin assignment or a requirement to implement
every signal. Signal presence, pin mapping, electrical levels, active polarity,
edge behavior, and timing limits must be confirmed before hardware integration.

| Potential signal | Direction | Intended role | Selection status |
| --- | --- | --- | --- |
| SCLK | MCU to ADC | SPI clock | Expected for SPI; pin and timing TBD |
| MOSI | MCU to ADC | Commands, configuration, or transmit data | Expected; requirement TBD |
| CS | MCU to ADC | Device/transaction selection | Expected; count and behavior TBD |
| CONVST | MCU to ADC | Conversion start | TBD |
| RESET | MCU to ADC | Device reset | TBD |
| SYNC | MCU to ADC | Conversion/device synchronization | TBD |
| MISO | ADC to MCU | Measurement data and register responses | Expected for SPI; format TBD |
| DRDY | ADC to MCU | Data-ready indication | TBD |
| ALERT/FAULT | ADC to MCU | Fault or alert indication | TBD |

Which of these signals cross the isolation barrier, the isolator channel count,
and how isolated-side power is supplied are TBD. Both teams must review all
signal and power crossings together; no isolator or isolation rating is selected
by this document.

## Unknown parameters

| Parameter | Value |
| --- | --- |
| ADC part number | TBD |
| Number of ADC devices | TBD |
| Simultaneous or multiplexed sampling | TBD |
| Digital interface | SPI expected / TBD |
| SPI mode | TBD |
| Maximum SPI clock | TBD |
| Bits per conversion | TBD |
| DRDY available | TBD |
| CONVST required | TBD |
| CRC supported | TBD |
| ADC reset behavior | TBD |
| Conversion timing | TBD |
| Channel ordering | TBD |
| Byte ordering | TBD |
| Digital isolator | TBD |
| Isolated power architecture | TBD |
| Digital voltage levels and signal polarity | TBD |
| MCU pin mapping and chip-select topology | TBD |
| Bit ordering and signed data encoding | TBD |
| Status bits and conversion framing | TBD |
| Startup/register configuration sequence | TBD |
| Isolation propagation delay and channel skew | TBD |
| Conversion synchronization and timestamp reference event | TBD |
| Timeout and communication fault recovery | TBD |
| Scaling, calibration, and invalid-data representation | TBD |
| Isolation verification conditions | TBD |

Measurement resolution and bits transferred per conversion are separate
parameters. Command, status, padding, and CRC bits may affect transfer length;
the actual format remains TBD.

## Questions for the analog team

- [ ] 1. What exact ADC is being used?
- [ ] 2. Is there one ADC or multiple ADCs?
- [ ] 3. Are channels sampled simultaneously or multiplexed?
- [ ] 4. What triggers conversion?
- [ ] 5. Is a DRDY signal available?
- [ ] 6. Does the MCU need to generate CONVST?
- [ ] 7. What SPI mode is required?
- [ ] 8. What maximum SPI frequency is supported?
- [ ] 9. How many bits are transferred for each conversion?
- [ ] 10. Are status bits included with ADC data?
- [ ] 11. Is CRC available?
- [ ] 12. What startup/register configuration sequence is required?
- [ ] 13. Which signals cross the isolation barrier?
- [ ] 14. What digital isolator is being used?
- [ ] 15. What propagation delay does the isolator introduce?
- [ ] 16. What happens when an ADC communication fault occurs?

For each answer, record the selected device datasheet revision, relevant timing
or register information, and any schematic constraints. The two teams should
agree on a channel map, transfer example, and startup/recovery sequence before
implementing the real driver. Answers and review ownership are TBD.

## Preliminary timing requirement

At 1000 complete 16-channel frames per second:

```text
16 channels x 1000 samples/channel/second = 16,000 channel conversions/second
1000 complete frames/second              = one frame every 1 ms
```

The complete acquisition cycle must fit inside approximately 1 ms at this target
rate. A higher selected frame rate requires a correspondingly shorter interval.
This is a design budget, not a demonstrated hardware capability. Any conversion
pipelining or overlap must be documented with both frame cadence and latency;
it must not hide stale data or an incomplete set of channel measurements.

| Budget term | Items to establish | Allocation |
| --- | --- | --- |
| Conversion time | Conversion latency and completion for all ADCs/channels | TBD |
| Channel switching, if applicable | Multiplexer selection, settling, and any discarded conversions | TBD |
| SPI transaction time | Commands, all channel words, status, CRC, CS gaps, and device turnaround | TBD |
| Isolation propagation delay | Timing impact on clock, control, and return data paths | TBD |
| Firmware overhead | Wakeup/dispatch, driver execution, validation, and metadata handling | TBD |
| Buffering overhead | Bounded frame publication and synchronization | TBD |
| Timing margin | Worst-case variability and integration margin | TBD |

Build a worst-case timing schedule from the selected hardware. Identify operations
that overlap and avoid counting isolator delays twice if already included in the
transaction timing. Confirm setup/hold and return-path timing across the barrier.

No specific SPI clock is claimed to be sufficient. Required transfer time cannot
be established until the final ADC format, device count, command overhead,
conversion behavior, and isolation timing are known. Validate the complete cycle
with measurements, including concurrent communications and display activity.

## Firmware expectations

The future real ADC driver should expose an interface functionally similar to:

```cpp
bool init();
bool readFrame(SampleFrame& frame);
```

This is conceptual only. The existing `FakeADC` has `bool init()` and
`void readFrame(SampleFrame& frame)`; no refactoring is required for this document.
The existing `SampleFrame` is defined in
`components/acquisition/include/acquisition.hpp`.

Proposed behavior for the future driver:

- `init()` performs the agreed startup/configuration sequence and reports whether
  the device is ready. Register values, verification steps, and timeout are TBD.
- `readFrame()` obtains all 16 channel results in the agreed order and reports
  success or failure within a bounded time. Timeout, CRC checks, fault handling,
  and output-frame contents after failure are TBD. A failed or partial read must
  not be published as a valid complete frame.
- Acquisition owns sequence numbering and timestamps. The timestamp event and
  any conversion-event information supplied by the driver are TBD.
- The agreed driver output encoding must support bipolar measurements. The fake
  currently provides conceptual microvolts; real scaling/calibration and status
  bit meanings are TBD.
- Acquisition-path storage and operations should be bounded. Driver reads must
  not depend on network delivery, OLED updates, or communication recovery.

The fake enables development before hardware is available, but does not validate
SPI operation, conversion timing, isolation, or real measurement performance.
No firmware features are implemented by this ICD.
