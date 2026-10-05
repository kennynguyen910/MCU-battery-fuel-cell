import 'dart:convert';
import 'dart:typed_data';

class DeviceSample {
  final int sequence, timestampUs, status;
  final List<double> channels;
  DeviceSample(this.sequence, this.timestampUs, this.status, this.channels);
}

DeviceSample decodeBleVoltage(List<int> bytes) {
  if (bytes.length != 80) throw const FormatException('Expected 80 BLE bytes');
  final data = ByteData.sublistView(Uint8List.fromList(bytes));
  return DeviceSample(data.getUint32(0), data.getUint64(4), data.getUint32(76),
      List.generate(16, (i) => data.getInt32(12 + i * 4) / 1000000));
}

int packetCrc(List<int> bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc >>> 1) ^ ((crc & 1) != 0 ? 0xedb88320 : 0);
    }
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}

DeviceSample decodeUsbMeasurement(List<int> bytes) {
  if (bytes.length != 88 ||
      bytes[0] != 0x42 ||
      bytes[1] != 0x4d ||
      bytes[2] != 1 ||
      bytes[3] != 1) {
    throw const FormatException('Invalid measurement header');
  }
  final data = ByteData.sublistView(Uint8List.fromList(bytes));
  if (packetCrc(bytes.sublist(0, 84)) != data.getUint32(84)) {
    throw const FormatException('Measurement CRC mismatch');
  }
  return DeviceSample(data.getUint32(4), data.getUint64(8), data.getUint32(80),
      List.generate(16, (i) => data.getInt32(16 + i * 4) / 1000000));
}

/// USB firmware extension uses BMHEX:<176 hex characters>\n, keeping binary
/// measurements separate from the board's ordinary diagnostic console lines.
class UsbMeasurementLines {
  final _line = <int>[];
  bool _overflow = false;
  int invalid = 0;
  String lastDiagnostic = '';
  List<DeviceSample> add(List<int> bytes) {
    final result = <DeviceSample>[];
    for (final byte in bytes) {
      if (byte != 10) {
        if (_line.length < 2048 && !_overflow) {
          _line.add(byte);
        } else {
          _overflow = true;
        }
        continue;
      }
      final line = utf8.decode(_line, allowMalformed: true).trim();
      _line.clear();
      if (_overflow) {
        _overflow = false;
        invalid++;
        continue;
      }
      if (!line.startsWith('BMHEX:')) {
        if (line.isNotEmpty) lastDiagnostic = line;
        continue;
      }
      try {
        final hex = line.substring(6);
        if (!RegExp(r'^[0-9a-fA-F]{176}$').hasMatch(hex)) {
          throw const FormatException('Invalid USB measurement line');
        }
        result.add(decodeUsbMeasurement(List.generate(
            88, (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16))));
      } on FormatException {
        invalid++;
      }
    }
    return result;
  }
}
