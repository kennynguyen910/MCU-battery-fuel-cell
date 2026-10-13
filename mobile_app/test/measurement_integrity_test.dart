import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capstone_monitor/api.dart';
import 'package:capstone_monitor/capture_log.dart';
import 'package:capstone_monitor/demo_widgets.dart';
import 'package:capstone_monitor/device_packets.dart';
import 'package:capstone_monitor/direct_capture.dart';
import 'package:capstone_monitor/receiver_integrity.dart';

DeviceSample frame(int seq, int us, [int status = 0]) =>
    DeviceSample(seq, us, status, List.generate(16, (i) => i / 10));

void main() {
  test(
      'all signed channels, units and simulated flag survive both wire formats',
      () {
    final ble = Uint8List(80);
    final b = ByteData.sublistView(ble);
    b.setUint32(0, 42);
    b.setUint64(4, 987654321);
    for (var i = 0; i < 16; i++) {
      b.setInt32(12 + i * 4, (i - 8) * 123456);
    }
    b.setUint32(76, sampleStatusSimulated | 3);
    final usb = Uint8List(88);
    usb.setRange(0, 4, [0x42, 0x4d, 1, 1]);
    usb.setRange(4, 84, ble);
    ByteData.sublistView(usb).setUint32(84, packetCrc(usb.sublist(0, 84)));
    for (final sample in [decodeBleVoltage(ble), decodeUsbMeasurement(usb)]) {
      expect(sample.channels,
          List.generate(16, (i) => closeTo((i - 8) * 0.123456, 1e-12)));
      expect(sample.sequence, 42);
      expect(sample.timestampUs, 987654321);
      expect(sample.status, sampleStatusSimulated | 3);
      expect(sample.simulated, isTrue);
      expect(sample.sourceLabel, 'SIMULATED DATA');
    }
    usb[20] ^= 1;
    expect(() => decodeUsbMeasurement(usb), throwsFormatException);
    expect(
        () => decodeUsbMeasurement(usb.sublist(0, 87)), throwsFormatException);
    expect(() => decodeBleVoltage(ble.sublist(0, 79)), throwsFormatException);
    expect(frame(0, 0).sourceLabel, contains('UNKNOWN'));
  });

  test(
      'sequence gaps, duplicates and late arrivals cannot regress the baseline',
      () {
    final m = ReceiverIntegrity();
    expect(m.accept(frame(100, 100000)), isTrue);
    expect(m.accept(frame(103, 103000)), isTrue);
    expect(m.missing, 2);
    expect(m.accept(frame(103, 103000)), isFalse);
    expect(m.accept(frame(102, 102000)), isFalse);
    expect(m.accept(frame(104, 104000)), isTrue);
    expect(m.duplicates, 1);
    expect(m.outOfOrder, 1);
    expect(m.received, 5);
    expect(m.lastSequence, 104);
  });

  test(
      'uint32 wrap is forward progress and reboot does not add billions of losses',
      () {
    final m = ReceiverIntegrity();
    m.accept(frame(0xfffffffe, 10000000));
    m.accept(frame(0xffffffff, 10001000));
    m.accept(frame(0, 10002000));
    expect(m.missing, 0);
    expect(m.restarts, 0);
    m.accept(frame(300, 10302000));
    expect(m.accept(frame(0, 0)), isTrue);
    expect(m.restarts, 1);
    expect(m.missing, 299);
    expect(m.accept(frame(1, 1000)), isTrue);
  });

  test('regressed timestamp on forward sequence is rejected', () {
    final m = ReceiverIntegrity();
    m.accept(frame(40, 50000));
    expect(m.accept(frame(41, 49000)), isFalse);
    expect(m.invalidTimestamps, 1);
    expect(m.lastSequence, 40);
  });

  test(
      'no data, invalid values and duplicates never create or refresh live measurements',
      () {
    var now = DateTime.utc(2026);
    final api = Api();
    addTearDown(api.close);
    final capture = DirectCapture(
        api, CaptureLog(read: () async => null, write: (_) async {}),
        now: () => now);
    expect(capture.latest, isNull);
    expect(capture.stale, isTrue);
    capture.add(frame(10, 10000, sampleStatusSimulated));
    expect(capture.latest!.simulated, isTrue);
    expect(capture.stale, isFalse);
    now = now.add(const Duration(milliseconds: 2001));
    expect(capture.stale, isTrue);
    capture.add(frame(10, 10000, sampleStatusSimulated));
    expect(capture.stale, isTrue);
    capture.add(DeviceSample(11, 11000, 0, List.filled(16, 9)));
    expect(capture.stale, isTrue);
    expect(capture.latest!.sequence, 10);
    capture.add(frame(11, 11000));
    expect(capture.stale, isFalse);
    expect(capture.latest!.sourceLabel, contains('UNKNOWN'));
    capture.clearLive();
    expect(capture.latest, isNull);
    expect(capture.stale, isTrue);
  });

  test(
      'local recording keeps raw device time, receipt time and status separately',
      () async {
    final api = Api();
    addTearDown(api.close);
    final log = CaptureLog(read: () async => null, write: (_) async {});
    final capture = DirectCapture(api, log)..start('session');
    capture.add(frame(10, 1234567, sampleStatusSimulated));
    await capture.drain(upload: false);
    expect(log.entries.single['timestampUs'], '1234567');
    expect(log.entries.single['deviceStatus'], sampleStatusSimulated);
    expect(log.entries.single['sequence'], 10);
    expect(log.entries.single['source'], 'SIMULATED DATA');
    expect(log.entries.single['receivedAt'], isNotNull);
    expect(log.entries.single['recordedAt'], isNot('1234567'));
  });

  testWidgets('simulated source has an explicit visible badge', (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: MeasurementSourceBadge(
                frame(0, 0, sampleStatusSimulated).sourceLabel))));
    expect(find.text('SIMULATED DATA'), findsOneWidget);
  });
}
