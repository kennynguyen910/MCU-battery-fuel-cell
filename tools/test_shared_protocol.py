"""Check the MCU receiver against the same fixtures as Node and Flutter."""
import json
import re
import unittest
import uuid
from pathlib import Path
from udp_receiver import parse_packet, parse_datagram, InvalidPacket
ROOT = Path(__file__).resolve().parent.parent
FIXTURE = json.loads((ROOT / 'contracts/protocol-v1.json').read_text())

class SharedProtocolTests(unittest.TestCase):
    def test_firmware_reference_and_bench_packets(self):
        for sample in [FIXTURE['firmwareGolden'], *FIXTURE['benchSamples']]:
            frame = parse_packet(bytes.fromhex(sample['udpHex']))
            self.assertEqual(frame.sequence, sample['sequence'])
            self.assertEqual(str(frame.timestamp_us), sample['timestampUs'])
            self.assertEqual(list(frame.channels_uv), sample['channelsUv'])
            self.assertEqual(frame.status, sample['status'])
    def test_batch_and_corrupt_frame(self):
        frames = parse_datagram(bytes.fromhex(FIXTURE['batchHex']))
        self.assertEqual(len(frames), 2)
        damaged = bytearray(frames[0]); damaged[30] ^= 1
        with self.assertRaises(InvalidPacket): parse_packet(damaged)
        self.assertEqual(parse_packet(frames[1]).sequence, 101)
    def test_nimble_provisioning_uuids_match_client_contract(self):
        source = (ROOT / 'components/ble/wifi_provisioning.cpp').read_text()
        for name, key in [('SERVICE_UUID','service'), ('CONTROL_UUID','control'), ('DATA_UUID','data'), ('STATUS_UUID','status')]:
            body = source.split(name + ' = BLE_UUID128_INIT(', 1)[1].split(');', 1)[0]
            little_endian = bytes(int(value, 16) for value in re.findall(r'0x([0-9a-fA-F]{2})\b', body))
            self.assertEqual(str(uuid.UUID(bytes=little_endian[::-1])), FIXTURE['provisioning'][key])

if __name__ == '__main__': unittest.main()
