# Binary measurement protocol outline

Draft only: field ordering, sizes, byte order, framing, and compatibility rules
must be finalized before implementing encoding or decoding.

| Field | Planned purpose / open decisions |
| --- | --- |
| Protocol version | Identify format and compatibility policy; width TBD |
| Message type | Distinguish measurements from future control/status messages; IDs TBD |
| Sequence number | Track frames and detect gaps; internal frame uses uint32_t |
| Timestamp | Internal frame uses uint64_t microseconds since boot; wire epoch/synchronization TBD |
| Channel data | 16 internal int32_t values; wire encoding, units, and calibration TBD |
| Status flags | Internal uint32_t; bit meanings and validity rules TBD |
| CRC | Detect corruption; polynomial, initialization, coverage, and byte order TBD |

Specify packet boundaries, payload length, reset/wraparound behavior, malformed
packet handling, and transport-specific fragmentation in a later revision.
Do not send raw `SampleFrame` memory: compiler padding and native byte order are
not a portable wire format. The current fake reports status zero; no protocol
status bits or CRC implementation are defined yet.
