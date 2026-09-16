# Version 1 binary measurement protocol

Stage 3A defines one fixed-size measurement packet. Packetizer converts a
SampleFrame into a caller-owned std::array of exactly 88 bytes. It performs no
networking, logging, task operations or dynamic allocation. Stage 2 acquisition,
consumer and diagnostics remain independent and unchanged.

## Encoding

All multibyte integers, INCLUDING the CRC field, use network byte order
(big-endian, most significant byte first). There is no padding or implicit struct
layout. Do not transmit raw SampleFrame memory, even if its native size happens
to match this packet. Byte offsets below are zero-based.

Magic is 0x424D: bytes 0x42 0x4D, ASCII "BM" (Battery Monitor).
Protocol version is 1. Measurement message type is 1.
The packet has no length field; version 1 measurement messages are fixed at 88
bytes. Future message types/versions must define their own framing explicitly.

## Exact layout

| Offset | Size (bytes) | Field | Type | Description |
| --- | --- | --- | --- | --- |
| 0 | 2 | Magic | uint16 | 0x424D ("BM") |
| 2 | 1 | Protocol version | uint8 | 1 |
| 3 | 1 | Message type | uint8 | 1: measurement |
| 4 | 4 | Sequence | uint32 | Successful-frame sequence, wraps modulo 2^32 |
| 8 | 8 | Timestamp_us | uint64 | Monotonic microseconds since firmware timer epoch |
| 16 | 4 | Channel 1 | int32 | Signed microvolts |
| 20 | 4 | Channel 2 | int32 | Signed microvolts |
| 24 | 4 | Channel 3 | int32 | Signed microvolts |
| 28 | 4 | Channel 4 | int32 | Signed microvolts |
| 32 | 4 | Channel 5 | int32 | Signed microvolts |
| 36 | 4 | Channel 6 | int32 | Signed microvolts |
| 40 | 4 | Channel 7 | int32 | Signed microvolts |
| 44 | 4 | Channel 8 | int32 | Signed microvolts |
| 48 | 4 | Channel 9 | int32 | Signed microvolts |
| 52 | 4 | Channel 10 | int32 | Signed microvolts |
| 56 | 4 | Channel 11 | int32 | Signed microvolts |
| 60 | 4 | Channel 12 | int32 | Signed microvolts |
| 64 | 4 | Channel 13 | int32 | Signed microvolts |
| 68 | 4 | Channel 14 | int32 | Signed microvolts |
| 72 | 4 | Channel 15 | int32 | Signed microvolts |
| 76 | 4 | Channel 16 | int32 | Signed microvolts |
| 80 | 4 | Status | uint32 | Frame status copied unchanged; bit meanings remain TBD |
| 84 | 4 | CRC32 | uint32 | CRC of bytes 0-83 inclusive, encoded big-endian |

Total: 2 + 1 + 1 + 4 + 8 + (16 * 4) + 4 + 4 = **88 bytes**.
Channel N begins at offset 16 + 4 * (N - 1), for N = 1 through 16.

## Measurement semantics

Channels use a 32-bit two's-complement signed wire representation.
Packetizer converts int32 to uint32 modulo 2^32 and writes its four bytes
explicitly. It does not rely on the CPU's signed representation or native
endianness, and does not clip, scale, or validate the conceptual +/-5 V range.

1234567 microvolts = 1.234567 V; encoded bytes are 00 12 D6 87.
-1234567 microvolts = -1.234567 V; encoded bytes are FF ED 29 79.
The wire type also preserves INT32_MIN and INT32_MAX.

The current acquisition timestamp is esp_timer_get_time immediately before the
ADC read. It indicates software read start, not UTC, network arrival time, or
a synchronized hardware conversion instant. A reboot starts a new timing and
sequence epoch. No boot/session identifier is present in version 1.

Status defaults to zero. Packetizer preserves all 32 bits; this stage defines
no valid-data, error or calibration flags. Acquisition/driver decisions will
define those semantics later.

## CRC32

Portable local implementation of **CRC-32/ISO-HDLC** (also commonly called
IEEE CRC-32), matching Python zlib.crc32 with its default initial argument:

- Width: 32 bits.
- Polynomial: 0x04C11DB7; reflected implementation polynomial: 0xEDB88320.
- Initial internal register: 0xFFFFFFFF.
- Input/output reflection: true.
- Final XOR: 0xFFFFFFFF.
- Check vector: ASCII "123456789" -> 0xCBF43926.
- Empty input CRC: 0.
- Coverage: exactly bytes 0 through 83 inclusive (magic through status).
- The CRC field at bytes 84 through 87 is excluded from calculation.
- The resulting numeric CRC is stored big-endian, independently of reflection.

A future receiver should require 88 bytes, check magic/version/type, calculate
the CRC over the first 84 bytes and compare it with the big-endian final uint32.
CRC detects accidental corruption; it does not provide authentication.
No receiver, transport framing, fragmentation or socket code is implemented here.

## Interface and development self-test

Packetizer::serializeMeasurement(const SampleFrame&, MeasurementPacket&) returns
true after writing all 88 bytes. The fixed output type prevents short buffers;
false reports an internal layout mismatch. The input frame is never changed.
Packetizer::crc32 is available for validating byte buffers with the same variant.

DEVELOPMENT ONLY: ENABLE_PACKETIZER_SELF_TEST in main/main.cpp defaults to true.
The test runs once at startup before Wi-Fi and acquisition initialization and
logs PASS or FAIL. Set the flag to false and rebuild to disable it. The test
does not run in AcquisitionTask or ConsumerTask.

The fixed self-test frame uses:
- Sequence: 0x01020304.
- Timestamp: 0x0102030405060708.
- Channels 1-4: 1234567, -1234567, INT32_MIN, INT32_MAX.
- Channels 5-16: (zero-based channel index - 8) * 10000.
- Status: 0xA1B2C3D4.
- Expected CRC: 0x35AAF680.

The expected full 88-byte buffer was independently generated with Python
struct.pack('!HBBIQ16iI', ...) and zlib.crc32. The C++ test compares every byte,
checks the standard CRC vector, verifies repeatability and input preservation,
and confirms a changed payload no longer matches the fixture CRC.
A successful firmware build alone does not show the startup test has executed.

The implementation uses only fixed-width integers and explicit byte writes.
Repeat the startup self-test when switching between classic ESP32 and ESP32-S3.
Neither GPIO assignments nor Wi-Fi connection state affect serialization.
## Version 1 UDP batch datagram

The 88-byte measurement packet above is unchanged. UDP now normally carries up
to ten complete measurement packets in one datagram, using this separate envelope.
All multibyte header integers are big-endian, with no padding.

| Offset | Bytes | Field | Type / value |
| --- | --- | --- | --- |
| 0 | 2 | Batch magic | uint16, 0x4242 (ASCII BB) |
| 2 | 1 | Batch version | uint8, 1 |
| 3 | 1 | Message type | uint8, 2 (measurement batch) |
| 4 | 2 | Frame count | uint16, 1 through 10 |
| 6 | 4 | Batch sequence | uint32, wraps modulo 2^32 |
| 10 | count * 88 | Measurement packets | Original Version 1 packets in acquisition order |

Python header format: `!HBBHI`, exactly 10 bytes.
Datagram length must equal `10 + count * 88`; no trailing bytes are accepted.
Maximum payload is **890 bytes**; with normal 20-byte IPv4 and 8-byte UDP headers
this is 918 bytes, below a typical 1500-byte MTU. Smaller path MTUs remain possible.
Frame i (zero-based) starts at `10 + i * 88`.

There is no duplicate batch CRC: each frame retains its original CRC over its
first 84 bytes. The header is validated structurally, but is not covered by those
CRCs; the UDP checksum also provides transport corruption detection. This format
provides no authentication. Validate each embedded frame independently so one
bad frame does not suppress other valid frames in a structurally valid batch.

Batch sequence increments for each flushed batch, including failed or skipped
batches; it resets on reboot. Loss detection uses individual measurement sequence
numbers, so losing one full batch produces a ten-frame gap. The first received
frame establishes the baseline; initial and final unobserved losses cannot be
inferred. Version 1 still lacks a boot/session ID.

Ten frames normally fill a batch within approximately 10 ms. A partial batch
expires 20 ms after the first frame is buffered. NetworkTask checks expiration on
every frame and while idle using a nominal 5 ms queue timeout, rounded to at least
one FreeRTOS tick (plus scheduling latency). This permits flushing after acquisition
stops; no timer callback sends packets and AcquisitionTask timing is unchanged.
Only populated frame bytes are transmitted. There is no intentional decimation,
per-frame application heap allocation, or indefinite retry.

The Python receiver accepts both these batch datagrams and legacy standalone
88-byte measurement packets. It counts UDP datagrams separately from contained
frames. Invalid envelope lengths/headers increment invalid datagrams because the
number of contained frames cannot be trusted; invalid contained frames increment
invalid frames and, where applicable, CRC errors. Sequence gaps remain cumulative
forward-gap estimates; duplicate/backward arrivals do not inflate missing counts.
