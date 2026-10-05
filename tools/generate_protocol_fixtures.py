"""Refresh the shared v1 fixtures deliberately; --check never changes files."""
import argparse
import json
import re
import struct
import zlib
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent

def build():
    source = (ROOT / 'components/protocol/packetizer_self_test.cpp').read_text()
    body = source.split('constexpr MeasurementPacket expected{', 1)[1].split('};', 1)[0]
    golden = bytes(int(x, 16) for x in re.findall(r'0x([0-9A-Fa-f]{2})\b', body))
    if len(golden) != 88:
        raise ValueError('Firmware golden measurement must contain exactly 88 bytes')
    def packet(sequence, timestamp, channels, status):
        payload = struct.pack('!HBBIQ16iI', 0x424d, 1, 1, sequence, timestamp, *channels, status)
        return payload + struct.pack('!I', zlib.crc32(payload))
    def sample(data):
        values = struct.unpack('!HBBIQ16iII', data)
        return dict(udpHex=data.hex(), bleHex=data[4:84].hex(), sequence=values[3],
                    timestampUs=str(values[4]), channelsUv=list(values[5:21]), status=values[21])
    channels = [1234567, -1234567, -5000000, 5000000, *[(i-4)*10000 for i in range(12)]]
    bench = [packet(100+i, 1000000+i*1000, channels, 3) for i in range(2)]
    ssid = b'BatteryMonitor-lab-network-12345'
    assert len(ssid) == 32
    scan = bytes([0, 208, 3, len(ssid)]) + ssid
    fragments = [bytes([1, 2, 0x17, 0, o, len(scan), len(scan[o:o+13])]) + scan[o:o+13]
                 for o in range(0, len(scan), 13)]
    credentials = b'\x07\x0aLabWiFiexample123'
    return {
        'description': 'Shared v1 integration fixtures. Credential bytes are the PDF dummy example, never real Wi-Fi credentials.',
        'source': 'components/protocol/packetizer_self_test.cpp golden packet; all integer fields in network byte order.',
        'firmwareGolden': sample(golden), 'benchSamples': [sample(frame) for frame in bench],
        'batchHex': (struct.pack('!HBBHI', 0x4242, 1, 2, len(bench), 7) + b''.join(bench)).hex(),
        'provisioning': {
            'service': '5ecf1000-41c2-4cc4-9c96-640f406021d0',
            'control': '5ecf1001-41c2-4cc4-9c96-640f406021d0',
            'data': '5ecf1002-41c2-4cc4-9c96-640f406021d0',
            'status': '5ecf1003-41c2-4cc4-9c96-640f406021d0',
            'connectedStatusHex': '01020900c0a8012a',
            'getStatusHex': '01010100', 'startScanHex': '01021700',
            'scanFragmentsHex': [fragment.hex() for fragment in fragments],
            'scanSsid': ssid.decode(), 'scanRssi': -48, 'scanAuth': 3,
            'scanCompleteHex': '0182170101',
            'credentialsObjectHex': credentials.hex(),
            'credentialsFragmentsHex': [(bytes([1, 1, 0x18, 0, o, len(credentials), len(credentials[o:o+13])]) + credentials[o:o+13]).hex()
                                        for o in range(0, len(credentials), 13)],
        },
    }

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--write', action='store_true', help='Intentionally update checked-in fixtures')
    args = parser.parse_args()
    fixture_path = ROOT / 'contracts/protocol-v1.json'
    fixture = build()
    if args.write:
        fixture_path.write_text(json.dumps(fixture, indent=2) + '\n')
        print('Shared v1 fixtures updated')
    elif json.loads(fixture_path.read_text()) != fixture:
        raise SystemExit('Shared v1 fixtures drifted from the firmware golden reference; review before --write')
    else:
        print('Shared v1 fixtures match the firmware golden reference')
if __name__ == '__main__':
    main()
