import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:capstone_monitor/api.dart';
import 'package:capstone_monitor/capture_log.dart';
import 'package:capstone_monitor/screens.dart';

void main() {
  for (final fps in [1000, 2000]) {
    testWidgets(
        'dashboard saves $fps frames/s while history and uploads are blocked',
        (tester) async {
      final historyGate = Completer<http.Response>();
      final uploadGate = Completer<http.Response>();
      var blockHistory = false, sequence = 0, requests = 0;
      final sessions = jsonEncode([
        {
          'sessionId': 'session',
          'sessionName': 'Bench',
          'serialNumber': 'ESP32-UDP-127.0.0.1',
          'startTime': '2026-10-05T00:00:00Z'
        }
      ]);
      final api = Api(client: MockClient((request) async {
        switch (request.url.path) {
          case '/api/auth/login':
            return http.Response(
                '{"token":"test-token","username":"WillAdcox"}', 200);
          case '/api/device-sources':
            return http.Response(
                '[{"sourceIp":"127.0.0.1","stale":false,"deviceId":"device"}]',
                200);
          case '/api/device-input':
            return http.Response('{"stale":false,"frame":null}', 200);
          case '/api/sessions':
            return blockHistory
                ? historyGate.future
                : http.Response(sessions, 200);
          case '/api/device-frames':
            final baseline =
                !request.url.queryParameters.containsKey('afterCursor');
            final frames = baseline
                ? []
                : List.generate(fps ~/ 4, (_) {
                    final n = sequence++;
                    return {
                      'frameId': '$n',
                      'recordedAt': DateTime.fromMicrosecondsSinceEpoch(
                              n * 1000000 ~/ fps,
                              isUtc: true)
                          .toIso8601String(),
                      'channels': List.filled(16, 1.0)
                    };
                  });
            return http.Response(
                jsonEncode({
                  'frames': frames,
                  'nextCursor': sequence,
                  'streamId': 'stream',
                  'hasMore': false
                }),
                200);
          case '/api/sessions/session/measurements':
            requests++;
            return uploadGate.future;
          default:
            return http.Response('null', 200);
        }
      }));
      await api.login('WillAdcox', 'test-password');
      String? disk;
      final log = CaptureLog(
          read: () async => disk,
          write: (s) async {
            disk = s;
          });
      await tester.pumpWidget(MaterialApp(
          home: Dashboard(role: AppRole.mobile, api: api, log: log)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Manual test input'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ESP32 over laptop Wi-Fi / UDP').last);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
          find.text('Start capture').hitTestable(), 300,
          scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('Start capture'));
      await tester.pumpAndSettle();
      blockHistory = true;
      final before = sequence;
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        await tester.pump();
      }
      expect(sequence - before, fps * 3);
      expect(log.pending, sequence);
      expect(log.entries.every((e) => e['ownerUsername'] == 'WillAdcox'), true);
      expect(requests, 1);
      expect((jsonDecode(disk!) as List).length, sequence);
      final stopped = sequence;
      await tester.tap(find.text('Stop capture'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();
      expect(sequence, stopped);
      blockHistory = false;
      historyGate.complete(http.Response(sessions, 200));
      uploadGate.complete(http.Response('{}', 201));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      api.close();
    });
  }
}
