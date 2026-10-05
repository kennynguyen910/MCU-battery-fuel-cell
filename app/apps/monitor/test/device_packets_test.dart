import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:capstone_monitor/device_packets.dart';

void main() {
  test('BLE layout decodes signed microvolts, timestamp and status', () {
    final bytes = Uint8List(80);
    final data = ByteData.sublistView(bytes);
    data.setUint32(0, 0xfffffffe);
    data.setUint64(4, 123456789);
    data.setInt32(12, -1234567);
    data.setInt32(16, 2345678);
    data.setUint32(76, 0xa1b2c3d4);
    final sample = decodeBleVoltage(bytes);
    expect(sample.sequence, 0xfffffffe);
    expect(sample.timestampUs, 123456789);
    expect(sample.status, 0xa1b2c3d4);
    expect(sample.channels.length, 16);
    expect(sample.channels.take(2), [-1.234567, 2.345678]);
    expect(() => decodeBleVoltage(bytes.sublist(0, 20)), throwsFormatException);
  });

  test('USB reassembles split console lines, rejects corruption and recovers',
      () {
    expect(packetCrc(ascii.encode('123456789')), 0xcbf43926);
    final bytes = Uint8List(88);
    final data = ByteData.sublistView(bytes);
    bytes.setRange(0, 4, [0x42, 0x4d, 1, 1]);
    data.setUint32(4, 42);
    data.setUint64(8, 1000000);
    data.setInt32(16, -5000000);
    data.setUint32(84, packetCrc(bytes.sublist(0, 84)));
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final parser = UsbMeasurementLines();
    expect(
        parser.add(
            ascii.encode('Boot diagnostics\nBMHEX:${hex.substring(0, 25)}')),
        isEmpty);
    final frames = parser.add(ascii.encode('${hex.substring(25)}\r\n'));
    expect(frames.single.sequence, 42);
    expect(frames.single.channels.first, -5);
    expect(parser.lastDiagnostic, 'Boot diagnostics');
    expect(parser.add(ascii.encode('BMHEX:${hex.substring(0, 174)}ff\n')),
        isEmpty);
    expect(parser.invalid, 1);
    parser.add(List.filled(3000, 65));
    final recovered = parser.add(ascii.encode('\nBMHEX:$hex\nBMHEX:$hex\n'));
    expect(recovered.length, 2);
    expect(parser.invalid, 2);
  });
}
