import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:capstone_monitor/api.dart';
import 'package:capstone_monitor/capture_log.dart';
import 'package:capstone_monitor/buffered_capture.dart';
import 'package:capstone_monitor/direct_capture.dart';
import 'package:capstone_monitor/device_packets.dart';
import 'package:capstone_monitor/screens.dart';

Map<String, dynamic> frame(String id) => {
      'frameId': id,
      'recordedAt': '2026-10-05T12:00:00.000001Z',
      'channels': List.filled(16, 1.25)
    };

Api testApi(Future<http.Response> Function(http.Request) handler) => Api(
    baseUrl: 'http://isolation',
    client: MockClient((r) async {
      if (r.url.path.endsWith('/auth/login')) {
        final user = jsonDecode(r.body)['username'];
        return http.Response(
            jsonEncode({
              'token': '$user-token',
              'username': user,
              'isAdmin': user == 'capstone_admin'
            }),
            200);
      }
      if (r.url.path.endsWith('/auth/logout')) return http.Response('', 204);
      return handler(r);
    }));

void main() {
  test(
      'cache visibility and retries follow account and server; legacy stays admin-only',
      () async {
    final uploads = <String>[];
    final api = testApi((r) async {
      uploads.add(r.url.path);
      return http.Response('{}', 201);
    });
    String? disk;
    final log = CaptureLog(
        read: () async => disk,
        write: (data) async {
          disk = data;
        });
    await log.append(api.baseUrl, 'will-session', frame('will-frame'),
        ownerUsername: 'WillAdcox');
    await log.append(api.baseUrl, 'kenny-session', frame('kenny-frame'),
        ownerUsername: 'KennyNguyen');
    await log.append(api.baseUrl, 'legacy-session', frame('legacy-frame'));
    await log.append(
        'http://other-server', 'will-session', frame('other-frame'),
        ownerUsername: 'WillAdcox');
    await log.load();
    await api.login('WillAdcox', 'password');
    expect(log.visibleEntries(api).map((e) => e['frameId']), ['will-frame']);
    expect(log.visiblePending(api), 1);
    expect(log.visibleJson(api), isNot(contains('kenny-frame')));
    expect(await log.flush(api), 1);
    expect(uploads, ['/api/sessions/will-session/measurements']);
    await api.logout();
    expect(log.visibleEntries(api), isEmpty);
    expect(await log.flush(api), 0);
    await api.login('KennyNguyen', 'password');
    expect(log.visibleEntries(api).map((e) => e['frameId']), ['kenny-frame']);
    expect(await log.flush(api), 1);
    await api.login('capstone_admin', 'password');
    expect(log.visibleEntries(api).map((e) => e['frameId']),
        ['will-frame', 'kenny-frame', 'legacy-frame']);
    expect(await log.flush(api), 1);
    await log.load();
    expect(log.entries, hasLength(4));
    expect(log.pending, 1, reason: 'Another server keeps its pending frame');
    api.close();
  });

  test(
      'switching accounts during a slow upload never dispatches remaining batches with the new token',
      () async {
    final started = Completer<void>(), finish = Completer<http.Response>();
    final headers = <String?>[];
    final api = testApi((r) async {
      headers.add(r.headers['Authorization']);
      started.complete();
      return finish.future;
    });
    await api.login('WillAdcox', 'password');
    final log = CaptureLog(
        read: () async => null, write: (_) async {}, uploadConcurrency: 1);
    await log.appendAll(
        api.baseUrl, 'will-session', List.generate(2000, (i) => frame('$i')),
        ownerUsername: 'WillAdcox');
    final uploading = log.flush(api);
    await started.future;
    await api.login('KennyNguyen', 'password');
    finish.complete(http.Response('{}', 201));
    expect(await uploading, 1000);
    expect(headers, ['Bearer WillAdcox-token']);
    expect(log.pending, 1000);
    expect(await log.flush(api), 0);
    expect(log.visibleEntries(api), isEmpty);
    api.close();
  });

  test('expired login hides local readings and does not dispatch saved uploads',
      () async {
    var uploads = 0;
    final api = testApi((r) async {
      if (r.method == 'POST') uploads++;
      return http.Response('{"error":"Login required"}', 401);
    });
    await api.login('WillAdcox', 'password');
    final log = CaptureLog(read: () async => null, write: (_) async {});
    await log.append(api.baseUrl, 'will-session', frame('saved'),
        ownerUsername: 'WillAdcox');
    await expectLater(api.request('/sessions'), throwsA(isA<ApiException>()));
    expect(api.username, null);
    expect(api.authenticationRequired, true);
    expect(
        () => DirectCapture(api, log).start('will-session'), throwsStateError);
    expect(
        () => BufferedCapture(api, log)
            .start('will-session', '127.0.0.1', 0, 'stream'),
        throwsStateError);
    expect(log.visibleEntries(api), isEmpty);
    expect(await log.flush(api), 0);
    expect(uploads, 0);
    expect(log.pending, 1);
    api.close();
  });

  test(
      'late unauthorized response from an old account cannot clear the new login',
      () async {
    final response = Completer<http.Response>();
    final api = testApi((_) => response.future);
    await api.login('WillAdcox', 'password');
    final reading = api.request('/sessions');
    final expected = expectLater(reading, throwsA(isA<ApiException>()));
    await api.login('KennyNguyen', 'password');
    response.complete(http.Response('{"error":"Login required"}', 401));
    await expected;
    expect(api.username, 'KennyNguyen');
    expect(api.signedIn, true);
    api.close();
  });

  test(
      'buffered capture stamps the original owner and stops after an account change',
      () async {
    final api = testApi((_) async => http.Response(
        jsonEncode({
          'frames': [frame('buffered')],
          'streamId': 'stream',
          'nextCursor': 1,
          'hasMore': false
        }),
        200));
    await api.login('WillAdcox', 'password');
    final log = CaptureLog(read: () async => null, write: (_) async {});
    final capture = BufferedCapture(api, log)
      ..start('will-session', '127.0.0.1', 0, 'stream');
    await capture.pump();
    expect(log.entries.single['ownerUsername'], 'WillAdcox');
    await api.login('KennyNguyen', 'password');
    await capture.pump();
    expect(capture.active, false);
    expect(log.visibleEntries(api), isEmpty);
    expect(log.entries, hasLength(1));
    api.close();
  });

  test(
      'queued BLE/USB frames retain their owner across account change before local save',
      () async {
    final api = testApi((_) async => http.Response('{}', 201));
    await api.login('WillAdcox', 'password');
    final log = CaptureLog(read: () async => null, write: (_) async {});
    final capture = DirectCapture(api, log)..start('will-session');
    capture.add(DeviceSample(1, 1000, 0, List.filled(16, 1.25)));
    await api.login('KennyNguyen', 'password');
    capture.add(DeviceSample(2, 2000, 0, List.filled(16, 1.25)));
    expect(capture.capturing, false);
    await capture.drain();
    expect(log.entries.single['ownerUsername'], 'WillAdcox');
    expect(log.pending, 1);
    expect(log.visibleEntries(api), isEmpty);
    api.close();
  });

  testWidgets(
      'account switch clears old history even if the new account cannot refresh',
      (tester) async {
    var failKenny = false;
    final api = testApi((r) async {
      final isKenny = r.headers['Authorization'] == 'Bearer KennyNguyen-token';
      if (failKenny && isKenny)
        return http.Response('{"error":"Unavailable"}', 503);
      if (r.url.path == '/api/sessions')
        return http.Response(
            jsonEncode([
              {
                'sessionId': 'will-session',
                'sessionName': 'Will private session',
                'ownerUsername': 'WillAdcox',
                'startTime': '2026-10-05T00:00:00Z'
              }
            ]),
            200);
      return http.Response(
          '{"measurements":[{"recordedAt":"2026-10-05T12:00:00Z","channel":0,"voltage":1.234}],"measurementCount":1}',
          200);
    });
    await api.login('WillAdcox', 'password');
    await tester
        .pumpWidget(MaterialApp(home: Dashboard(role: AppRole.web, api: api)));
    await tester.pumpAndSettle();
    expect(find.textContaining('Will private session'), findsOneWidget);
    await tester.tap(find.text('Log out'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Username'), 'KennyNguyen');
    await tester.enterText(
        find.widgetWithText(TextField, 'Password'), 'password');
    failKenny = true;
    await tester.tap(find.text('Log in'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Will private session'), findsNothing);
    expect(find.byType(DropdownButton<String>), findsNothing);
    expect(api.username, 'KennyNguyen');
    await tester.pumpWidget(const SizedBox());
    api.close();
  });

  testWidgets('local log dialog displays only the signed-in user readings',
      (tester) async {
    final api = testApi((r) async {
      if (r.url.path == '/api/sessions') return http.Response('[]', 200);
      if (r.url.path == '/api/test-input') return http.Response('null', 200);
      return http.Response('{"error":"Offline"}', 503);
    });
    await api.login('WillAdcox', 'password');
    String? disk;
    final log = CaptureLog(
        read: () async => disk,
        write: (data) async {
          disk = data;
        });
    await log.append(api.baseUrl, 'will-session', frame('will-frame'),
        ownerUsername: 'WillAdcox');
    await log.append(api.baseUrl, 'kenny-session', frame('kenny-frame'),
        ownerUsername: 'KennyNguyen');
    await log.append(api.baseUrl, 'legacy-session', frame('legacy-frame'));
    await tester.pumpWidget(
        MaterialApp(home: Dashboard(role: AppRole.mobile, api: api, log: log)));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
        find.text('View local log (1 frames; 1 pending)').hitTestable(), 300,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('View local log (1 frames; 1 pending)'));
    await tester.pumpAndSettle();
    final json =
        tester.widget<SelectableText>(find.byType(SelectableText)).data!;
    expect(json, contains('will-frame'));
    expect(json, isNot(contains('kenny-frame')));
    expect(json, isNot(contains('legacy-frame')));
    expect(log.entries, hasLength(3));
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    api.close();
  });
}
