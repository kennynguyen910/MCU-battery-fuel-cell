// Durable-log unit test. Injected string storage simulates an app restart without
// touching a student's real files or browser localStorage.
import 'dart:convert';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:capstone_monitor/api.dart';
import 'package:capstone_monitor/capture_log.dart';

void main() {
  test('bounded parallel uploads await every acknowledgement before failure',
      () async {
    final log = CaptureLog(read: () async => null, write: (_) async {});
    await log.appendAll(
        Api.defaultUrl,
        's',
        List.generate(
            6000,
            (i) => <String, dynamic>{
                  'frameId': '$i',
                  'recordedAt': '2026-10-05T12:00:00Z',
                  'channels': List.filled(16, 1.0)
                }));
    final requests = <Completer<http.Response>>[];
    final api = Api(client: MockClient((_) {
      final gate = Completer<http.Response>();
      requests.add(gate);
      return gate.future;
    }));
    var finished = false;
    final first = log.flush(api);
    final second = log.flush(api);
    final checks = [
      expectLater(first, throwsA(isA<ApiException>()))
          .then((_) => finished = true),
      expectLater(second, throwsA(isA<ApiException>()))
    ];
    while (requests.length < 4) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(requests.length, 4);
    requests[0].complete(http.Response('{}', 503));
    await Future<void>.delayed(Duration.zero);
    expect(finished, false);
    for (final gate in requests.skip(1)) {
      gate.complete(http.Response('{}', 201));
    }
    await Future.wait(checks);
    expect(requests.length,
        4); // Failure stops dispatch of the remaining two jobs.
    expect(
        log.pending, 3000); // Failed and undispatched batches remain durable.
    api.close();
    final online =
        Api(client: MockClient((_) async => http.Response('{}', 201)));
    expect(await log.flush(online), 3000);
    expect(log.pending, 0);
    online.close();
  });
  test('failed local write leaves frames available for a durable retry',
      () async {
    var fail = true;
    String? disk;
    final log = CaptureLog(
        read: () async => disk,
        write: (value) async {
          if (fail) throw StateError('disk unavailable');
          disk = value;
        });
    final frame = <String, dynamic>{
      'frameId': 'retry',
      'recordedAt': '2026-09-28T00:00:00Z',
      'channels': List.filled(16, 1.0)
    };
    await expectLater(log.append(Api.defaultUrl, 's', frame), throwsStateError);
    expect(log.entries, isEmpty);
    fail = false;
    await log.append(Api.defaultUrl, 's', frame);
    expect(jsonDecode(disk!), hasLength(1));
  });

  test('uploaded history stays bounded while all pending frames survive',
      () async {
    final log = CaptureLog(read: () async => null, write: (_) async {});
    await log.appendAll(
        Api.defaultUrl,
        's',
        List.generate(
            1500,
            (i) => <String, dynamic>{
                  'frameId': '$i',
                  'recordedAt': '2026-09-28T00:00:00Z',
                  'channels': List.filled(16, 1.0)
                }));
    final api = Api(client: MockClient((_) async => http.Response('{}', 201)));
    expect(await log.flush(api), 1500);
    expect(log.entries, hasLength(500));
    expect(log.pending, 0);
    api.close();
  });
  test('failed upload survives reload and retries into the original session',
      () async {
    // `disk` represents the serialized contents that survive object replacement.
    String? disk;
    final log = CaptureLog(
        read: () async => disk,
        write: (value) async {
          disk = value;
        });
    await log.append(Api.defaultUrl, 'original-session', {
      'frameId': 'frame-1',
      'recordedAt': '2026-09-13T12:00:00Z',
      'channels': List.filled(16, 1.25),
    });
    // First simulate a server outage, then construct a new log as if app restarted.
    final offline = Api(
        client:
            MockClient((_) async => http.Response('{"error":"offline"}', 503)));
    await expectLater(log.flush(offline), throwsException);
    offline.close();
    final restored = CaptureLog(
        read: () async => disk,
        write: (value) async {
          disk = value;
        });
    await restored.load();
    expect(restored.pending, 1);
    // Inspect the retry request to prove its original session and time survive.
    final online = Api(client: MockClient((request) async {
      expect(request.url.path, '/api/sessions/original-session/measurements');
      expect(jsonDecode(request.body)['samples'][0]['recordedAt'],
          '2026-09-13T12:00:00Z');
      return http.Response('{"insertedMeasurements":16}', 201);
    }));
    expect(await restored.flush(online), 1);
    expect(restored.pending, 0);
    expect(jsonDecode(disk!)[0]['uploaded'], true);
    online.close();
  });

  test('buffered capture appends once and flushes in batches', () async {
    String? disk;
    final log = CaptureLog(
        read: () async => disk,
        write: (value) async {
          disk = value;
        });
    final frames = List.generate(
        300,
        (i) => <String, dynamic>{
              'frameId': 'frame-$i',
              'recordedAt': '2026-09-27T12:00:00Z',
              'channels': List.filled(16, 1.0),
            });
    await log.appendAll(Api.defaultUrl, 'session-a', frames);
    // Re-fetching an overlapping page must not duplicate buffered frames.
    await log.appendAll(Api.defaultUrl, 'session-a', [frames.first]);
    expect(log.pending, 300);
    final bodies = <dynamic>[];
    final online = Api(client: MockClient((request) async {
      bodies.add(jsonDecode(request.body));
      return http.Response('{"insertedMeasurements":16}', 201);
    }));
    expect(await log.flush(online), 300);
    // One request carries the page, rather than one request per frame.
    expect(bodies, hasLength(1));
    expect(bodies[0]['samples'], hasLength(300));
    expect(log.pending, 0);
    online.close();
  });
}
