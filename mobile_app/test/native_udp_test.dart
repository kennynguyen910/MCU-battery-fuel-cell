import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:capstone_monitor/api.dart';
import 'package:capstone_monitor/capture_log.dart';
import 'package:capstone_monitor/device_packets.dart';
import 'package:capstone_monitor/direct_capture.dart';
import 'package:capstone_monitor/udp_receiver.dart';
import 'package:capstone_monitor/wifi_protocol.dart';

Uint8List batch(int sequence, {int count = 10}) {
  final bytes = Uint8List(10 + count * 88);
  final header = ByteData.sublistView(bytes);
  header.setUint16(0, 0x4242);
  bytes[2] = 1;
  bytes[3] = 2;
  header.setUint16(4, count);
  header.setUint32(6, sequence ~/ 10);
  for (var i = 0; i < count; i++) {
    final frame = Uint8List.sublistView(bytes, 10 + i * 88, 98 + i * 88);
    final data = ByteData.sublistView(frame);
    frame.setRange(0, 4, [0x42, 0x4d, 1, 1]);
    data.setUint32(4, sequence + i);
    data.setUint64(8, (sequence + i) * 1000);
    for (var c = 0; c < 16; c++) {
      data.setInt32(16 + c * 4, -1234567 + c * 10000);
    }
    data.setUint32(80, sampleStatusSimulated);
    data.setUint32(84, packetCrc(frame.sublist(0, 84)));
  }
  return bytes;
}

void main() {
  test(
      'closing during UDP bind cancels activation and permits a fresh receiver',
      () async {
    final receiver = NativeUdpReceiver(onSample: (_, __) {}, onError: (_) {});
    final opening = receiver.start(port: 0);
    await receiver.close();
    await opening;
    expect(receiver.active, false);
    await receiver.start(port: 0);
    expect(receiver.active, true);
    await receiver.close();
  });

  test(
      'batch and standalone frames preserve signed channels, status and timing',
      () {
    final decoded = decodeUdpMeasurements(batch(42));
    expect(decoded.frames.length, 10);
    expect(decoded.frames.first.sequence, 42);
    expect(decoded.frames.first.timestampUs, 42000);
    expect(decoded.frames.first.channels.first, -1.234567);
    expect(decoded.frames.first.channels.last, -1.084567);
    expect(decoded.frames.first.simulated, true);
    expect(
        decodeUdpMeasurements(batch(42).sublist(10, 98)).frames.single.sequence,
        42);
    final corrupt = batch(42)..[26] ^= 1;
    final partial = decodeUdpMeasurements(corrupt);
    expect(partial.invalidFrames, 1);
    expect(partial.frames.length, 9);
    for (final at in [0, 2, 3, 4]) {
      final invalid = batch(42);
      invalid[at] ^= 0xff;
      expect(() => decodeUdpMeasurements(invalid), throwsFormatException);
    }
    expect(() => decodeUdpMeasurements(batch(0).sublist(0, 100)),
        throwsFormatException);
    expect(() => decodeUdpMeasurements(Uint8List(9)), throwsFormatException);
  });

  test(
      'real UDP reaches durable journal before HTTP and retries exact timestamps',
      () async {
    String? disk;
    var offline = true;
    final requests = <Map<String, dynamic>>[];
    final api = Api(client: MockClient((request) async {
      expect(request.method, 'POST');
      expect(request.url.path, '/api/sessions/session/measurements');
      expect(jsonDecode(disk!).length, 20); // Persisted before any upload.
      requests.add(jsonDecode(request.body) as Map<String, dynamic>);
      return http.Response(
          offline ? '{"error":"offline"}' : '{}', offline ? 503 : 201);
    }));
    final log =
        CaptureLog(read: () async => disk, write: (s) async => disk = s);
    final now = DateTime.utc(2026, 10, 12);
    final capture = DirectCapture(api, log, now: () => now)..start('session');
    final got = Completer<void>();
    final receiver = NativeUdpReceiver(onSample: (frames, _) {
      capture.addBatch(frames);
      if (capture.queued == 20 && !got.isCompleted) got.complete();
    }, onError: (e) {
      if (!got.isCompleted) got.completeError(e);
    });
    final sender =
        await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final writable = Completer<void>();
    final senderEvents = sender.listen((event) {
      if (event == RawSocketEvent.write && !writable.isCompleted)
        writable.complete();
    });
    try {
      await receiver.start(port: 0);
      await writable.future.timeout(const Duration(seconds: 10));
      sender.writeEventsEnabled = false;
      Future<void> sendBatch(int sequence) async {
        final bytes = batch(sequence);
        for (var attempt = 0; attempt < 200; attempt++) {
          final sent =
              sender.send(bytes, InternetAddress.loopbackIPv4, receiver.port);
          if (sent == bytes.length) return;
          expect(sent,
              0); // A nonblocking sender can temporarily return would-block.
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        fail('Loopback sender remained blocked');
      }

      await sendBatch(0);
      await sendBatch(10);
      await got.future.timeout(const Duration(seconds: 15));
      expect(receiver.sourceIp, '127.0.0.1');
      await capture.drain(upload: false);
      expect(log.pending, 20);
      final times = log.entries
          .map((e) => DateTime.parse(e['recordedAt'] as String))
          .toList();
      expect(times[9], now);
      for (var i = 1; i < times.length; i++) {
        expect(times[i].difference(times[i - 1]).inMicroseconds, 1000);
      }
      await expectLater(capture.uploadPending(), throwsA(isA<ApiException>()));
      expect(log.pending, 20);
      offline = false;
      await capture.uploadPending();
      expect(log.pending, 0);
      expect(requests.first, requests.last);
      final reloaded = CaptureLog(read: () async => disk, write: (_) async {});
      await reloaded.load();
      expect(reloaded.pending, 0);
    } finally {
      await receiver.close();
      await senderEvents.cancel();
      sender.close();
      api.close();
    }
  });

  test('1 kHz batches retain intervals across journal persistence and restart',
      () async {
    final api = Api();
    final log = CaptureLog(read: () async => null, write: (_) async {});
    final capture = DirectCapture(api, log)..start('session');
    for (var i = 0; i < 200; i++) {
      capture.addBatch(decodeUdpMeasurements(batch(i * 10)).frames);
    }
    await capture.drain(upload: false);
    expect(log.pending, 2000);
    final first = DateTime.parse(log.entries.first['recordedAt'] as String);
    for (var i = 0; i < 2000; i++) {
      expect(
          DateTime.parse(log.entries[i]['recordedAt'] as String)
              .difference(first)
              .inMicroseconds,
          i * 1000);
    }
    capture.addBatch(decodeUdpMeasurements(batch(0)).frames);
    await capture.drain(upload: false);
    expect(capture.integrity.restarts, 1);
    expect(log.pending, 2010);
    api.close();
  });

  test(
      'collector extension encodes address and big-endian port without changing legacy v1',
      () {
    final object =
        credentialObject('Lab', 'example123', collectorAddress: '192.168.1.42');
    expect(object.sublist(object.length - 6), [192, 168, 1, 42, 19, 141]);
    final fragments =
        credentialFragments(7, object, withCollector: true).toList();
    expect(fragments.every((f) => f[1] == 4 && f.length <= 20), true);
    expect(fragments.expand((f) => f.skip(7)), object);
    expect(
        credentialFragments(7, credentialObject('Lab', 'example123')).first[1],
        1);
    for (final ip in ['0.0.0.0', '127.0.0.1', '224.0.0.1', '999.1.1.1']) {
      expect(() => credentialObject('Lab', '', collectorAddress: ip),
          throwsFormatException);
    }
    expect(
        () => credentialObject('Lab', '',
            collectorAddress: '192.168.1.42', collectorPort: 0),
        throwsFormatException);
  });
}
