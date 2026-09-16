"""Standard-library receiver checks: python -m unittest discover -s tools -p 'test_udp_receiver.py'."""

import contextlib
import io
import struct
import unittest
from unittest import mock
import zlib

import udp_receiver as receiver


def frame(sequence, channels=None):
    if channels is None:
        channels = [1234567, -1234567, -2147483648, 2147483647]
        channels += [(i - 8) * 10000 for i in range(4, 16)]
    body = struct.pack('!HBBIQ16iI', 0x424D, 1, 1, sequence,
                       0x0102030405060708, *channels, 0xA1B2C3D4)
    return body + struct.pack('!I', zlib.crc32(body))


def batch(sequences, batch_sequence=0):
    return struct.pack('!HBBHI', 0x4242, 1, 2, len(sequences), batch_sequence) + b''.join(
        frame(sequence) for sequence in sequences)


class ReceiverTests(unittest.TestCase):
    def test_measurement_golden_vector_and_signed_values(self):
        packet = frame(0x01020304)
        self.assertEqual(len(packet), 88)
        self.assertEqual(packet[-4:].hex(), '35aaf680')
        parsed = receiver.parse_packet(packet)
        self.assertEqual(parsed.channels_uv[:4], (1234567, -1234567, -2147483648, 2147483647))
        self.assertEqual(parsed.status, 0xA1B2C3D4)
        self.assertEqual(parsed.timestamp_us, 0x0102030405060708)

    def test_full_partial_and_legacy_datagrams(self):
        for count in range(1, 11):
            datagram = batch(range(count))
            self.assertEqual(len(datagram), 10 + 88 * count)
            self.assertEqual(len(receiver.parse_datagram(datagram)), count)
        self.assertEqual(len(batch(range(10))), 890)
        self.assertEqual(receiver.parse_datagram(frame(0)), (frame(0),))

    def test_invalid_envelopes(self):
        valid = batch(range(10))
        invalid = [b'', b'old text', valid[:9], valid[:-1], valid + b'x']
        for magic, version, kind, count in [(0, 1, 2, 10), (0x4242, 2, 2, 10),
                                           (0x4242, 1, 1, 10), (0x4242, 1, 2, 0),
                                           (0x4242, 1, 2, 11), (0x4242, 1, 2, 9)]:
            invalid.append(struct.pack('!HBBHI', magic, version, kind, count, 0) + valid[10:])
        stats = receiver.Statistics()
        for data in invalid:
            stats.receive(data)
        self.assertEqual(stats.udp_datagrams_received, len(invalid))
        self.assertEqual(stats.udp_datagrams_invalid, len(invalid))
        self.assertEqual(stats.packets_received, 0)

    def test_bad_crc_preserves_other_frames(self):
        data = bytearray(batch(range(10)))
        data[10 + 4 * 88 + 16] ^= 1
        stats = receiver.Statistics()
        stats.receive(data)
        self.assertEqual((stats.packets_received, stats.packets_valid, stats.packets_invalid,
                          stats.crc_errors, stats.packets_missing), (10, 9, 1, 1, 1))
        self.assertEqual(stats.latest.sequence, 9)

    def test_missing_batch_wrap_duplicates_and_reordering(self):
        stats = receiver.Statistics()
        stats.receive(batch(range(10)))
        stats.receive(batch(range(20, 30), 2))
        self.assertEqual(stats.packets_missing, 10)
        stats.receive(batch(range(20, 30), 2))
        stats.receive(frame(29))
        self.assertEqual(stats.packets_missing, 10)
        self.assertEqual(stats.latest.sequence, 29)
        wrapped = receiver.Statistics()
        wrapped.receive(batch([0xFFFFFFFE, 0xFFFFFFFF, 0, 1]))
        self.assertEqual(wrapped.packets_missing, 0)
        wrapped.receive(frame(4))
        self.assertEqual(wrapped.packets_missing, 2)

    def test_idle_reporting_and_ctrl_c_cleanup(self):
        sock = mock.MagicMock()
        sock.__enter__.return_value = sock
        sock.recvfrom.side_effect = [(batch(range(10)), ('127.0.0.1', 12345)),
                                    receiver.socket.timeout(), KeyboardInterrupt()]
        output = io.StringIO()
        with mock.patch.object(receiver.socket, 'socket', return_value=sock), mock.patch.object(
                receiver.time, 'monotonic', side_effect=[0, 0, .2, .2, 1.1, 1.1, 1.2]), contextlib.redirect_stdout(output):
            self.assertEqual(receiver.main(), 0)
        sock.bind.assert_called_once_with(('0.0.0.0', 5005))
        sock.__exit__.assert_called_once()
        self.assertIn('Final statistics', output.getvalue())
        self.assertIn('Measurement frames received: 10', output.getvalue())
        self.assertIn('CH02:              -1.234567 V', output.getvalue())


if __name__ == '__main__':
    unittest.main()
