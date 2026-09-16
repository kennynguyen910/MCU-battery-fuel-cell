r"""Receive Version 1 Battery Monitor measurements; see docs/protocol.md.

Run: python .\tools\udp_receiver.py
Sequence statistics assume one transmitting device. Missing counts are inferred
forward gaps, not confirmed permanent loss: late packets do not undo a gap.
Version 1 has no session ID; restart this receiver when the ESP32 reboots.
"""

from dataclasses import dataclass
import socket
import struct
import time
import zlib


LISTEN_ADDRESS = ("0.0.0.0", 5005)
# Authoritative layout: docs/protocol.md, no padding, network byte order.
PACKET_FORMAT = struct.Struct("!HBBIQ16iII")
PACKET_SIZE = PACKET_FORMAT.size  # 88 bytes, including the final uint32 CRC.
CRC_OFFSET = PACKET_SIZE - 4  # CRC covers bytes 0 through 83.
MAGIC = 0x424D
PROTOCOL_VERSION = 1
MEASUREMENT_TYPE = 1
SEQUENCE_MASK = 0xFFFFFFFF
REPORT_INTERVAL = 1.0


@dataclass(frozen=True)
class Measurement:
    sequence: int
    timestamp_us: int
    channels_uv: tuple
    status: int


class InvalidPacket(ValueError):
    def __init__(self, reason, crc_error=False):
        super().__init__(reason)
        self.crc_error = crc_error


def parse_packet(data):
    """Validate a complete binary datagram and return its measurement."""
    if len(data) != PACKET_SIZE:
        raise InvalidPacket("incorrect packet length")

    fields = PACKET_FORMAT.unpack(data)
    magic, version, message_type, sequence, timestamp_us = fields[:5]
    crc_error = (zlib.crc32(data[:CRC_OFFSET]) & SEQUENCE_MASK) != fields[-1]
    errors = []
    if magic != MAGIC:
        errors.append("incorrect magic")
    if version != PROTOCOL_VERSION:
        errors.append("unsupported protocol version")
    if message_type != MEASUREMENT_TYPE:
        errors.append("unsupported message type")
    if crc_error:
        errors.append("CRC mismatch")
    if errors:
        raise InvalidPacket(", ".join(errors), crc_error=crc_error)
    return Measurement(sequence, timestamp_us, fields[5:21], fields[21])


@dataclass
class Statistics:
    packets_received: int = 0
    packets_valid: int = 0
    packets_invalid: int = 0
    packets_missing: int = 0
    crc_errors: int = 0
    duplicates: int = 0
    out_of_order: int = 0
    previous_sequence: object = None
    latest: object = None

    def receive(self, data):
        self.packets_received += 1
        try:
            frame = parse_packet(data)
        except InvalidPacket as error:
            self.packets_invalid += 1
            self.crc_errors += int(error.crc_error)
            return

        self.packets_valid += 1
        if self.previous_sequence is not None:
            delta = (frame.sequence - self.previous_sequence) & SEQUENCE_MASK
            if delta == 0:
                self.duplicates += 1
                return
            if delta >= 0x80000000:
                # A backward arrival must not create billions of missing frames
                # or move the sequence high-water mark backward.
                self.out_of_order += 1
                return
            self.packets_missing += delta - 1
        self.previous_sequence = frame.sequence
        self.latest = frame

    def report(self, rate, final=False):
        title = "Final statistics" if final else "Battery Monitor UDP"
        lines = [
            f"\n=== {title} ===",
            f"Packets received:  {self.packets_received}",
            f"Valid:             {self.packets_valid}",
            f"Missing (gaps):    {self.packets_missing}",
            f"Invalid:           {self.packets_invalid}",
            f"CRC errors:        {self.crc_errors}",
            f"Duplicates:        {self.duplicates}",
            f"Out of order:      {self.out_of_order}",
            f"Receive rate:      {rate:.1f} packets/s",
        ]
        if self.latest is None:
            lines.append("Latest frame:      waiting for a valid measurement")
        else:
            lines.extend([
                f"Latest frame:      {self.latest.sequence}",
                f"Timestamp:         {self.latest.timestamp_us} us",
                f"Status:            0x{self.latest.status:08X}",
            ])
            lines.extend(
                f"CH{index:02d}:              {microvolts / 1_000_000.0:.6f} V"
                for index, microvolts in enumerate(self.latest.channels_uv, 1)
            )
        print("\n".join(lines), flush=True)


def main():
    statistics = Statistics()
    started = last_report = time.monotonic()
    received_at_report = 0
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as receiver:
            receiver.bind(LISTEN_ADDRESS)
            print("Listening on 0.0.0.0:5005 for 88-byte binary measurements.",
                  flush=True)
            print("Use one ESP32; restart the receiver after an ESP32 reboot.",
                  flush=True)
            while True:
                # Timeout permits reports even when no packets arrive.
                receiver.settimeout(max(0.001, last_report + REPORT_INTERVAL
                                        - time.monotonic()))
                try:
                    data, _address = receiver.recvfrom(65535)
                except socket.timeout:
                    pass
                else:
                    statistics.receive(data)
                now = time.monotonic()
                elapsed = now - last_report
                if elapsed >= REPORT_INTERVAL:
                    rate = ((statistics.packets_received - received_at_report)
                            / elapsed)
                    statistics.report(rate)
                    last_report = now
                    received_at_report = statistics.packets_received
    except KeyboardInterrupt:
        print("\nUDP receiver stopped.", flush=True)
    except OSError as error:
        print(f"UDP receiver error: {error}", flush=True)
        return 1
    finally:
        elapsed = time.monotonic() - started
        statistics.report(statistics.packets_received / elapsed
                          if elapsed > 0 else 0.0, final=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
