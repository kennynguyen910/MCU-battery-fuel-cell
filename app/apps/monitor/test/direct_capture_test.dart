import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:capstone_monitor/api.dart';
import 'package:capstone_monitor/capture_log.dart';
import 'package:capstone_monitor/device_packets.dart';
import 'package:capstone_monitor/direct_capture.dart';

DeviceSample sample(int seq) =>
    DeviceSample(seq, seq * 100000, 0, List.filled(16, 1.25));

void main() {
  test('direct capture batches notifications, retries offline, and honors Stop',
      () async {
    var offline = true;
    final stored = <String>{};
    final api = Api(client: MockClient((request) async {
      if (offline) return http.Response('{"error":"offline"}', 503);
      final body = jsonDecode(request.body);
      for (final frame in body['samples']) {
        stored.add(frame['recordedAt']);
      }
      return http.Response('{}', 200);
    }));
    String? disk;
    final log = CaptureLog(
        read: () async => disk, write: (value) async => disk = value);
    final capture = DirectCapture(api, log);
    capture.add(sample(0));
    expect(capture.queued, 0);
    capture.start('session');
    for (var i = 1; i <= 100; i++) {
      capture.add(sample(i));
    }
    capture.add(sample(100));
    capture.stop();
    capture.add(sample(101));
    expect(capture.queued, 100);
    expect(capture.duplicates, 1);
    await expectLater(capture.drain(), throwsA(isA<ApiException>()));
    expect(log.pending, 100);
    expect(capture.queued, 0);
    expect(jsonDecode(disk!).length, 100);
    offline = false;
    await capture.drain();
    expect(stored.length, 100);
    expect(log.pending, 0);
    api.close();
  });

  test(
      'save failures retain queued frames and overlapping drains do not duplicate',
      () async {
    final gate = Completer<void>();
    var fail = true;
    var writes = 0;
    final api = Api(client: MockClient((_) async => http.Response('{}', 200)));
    final log = CaptureLog(
        read: () async => null,
        write: (_) async {
          writes++;
          if (fail) throw StateError('disk full');
          await gate.future;
        });
    final capture = DirectCapture(api, log)..start('session');
    capture.add(sample(1));
    await expectLater(capture.drain(upload: false), throwsStateError);
    expect(capture.queued, 1);
    fail = false;
    final first = capture.drain(upload: false);
    final second = capture.drain(upload: false);
    gate.complete();
    await Future.wait([first, second]);
    expect(writes, 2);
    expect(log.pending, 1);
    expect(capture.queued, 0);
    api.close();
  });

  test('invalid voltage is not captured and bounded overflow stops acquisition',
      () {
    final api = Api();
    final capture = DirectCapture(api, CaptureLog())..start('session');
    capture.add(DeviceSample(0, 0, 0, List.filled(16, 9)));
    expect(capture.invalid, 1);
    for (var i = 1; i <= 10001; i++) {
      capture.add(sample(i));
    }
    expect(capture.queued, 10000);
    expect(capture.capturing, false);
    expect(capture.overflow, 1);
    api.close();
  });
}
