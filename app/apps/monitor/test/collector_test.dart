// Widget-level collector test. Mock HTTP allows timer polling and button behavior
// to be tested together without a real server.
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:capstone_monitor/api.dart';
import 'package:capstone_monitor/screens.dart';
import 'package:capstone_monitor/capture_log.dart';

void main() {
  testWidgets('collector uploads only new frames while capture is running',
      (tester) async {
    // The mutable frame acts like the API's single latest device value.
    var frame = <String, dynamic>{
      'frameId': 'old',
      'recordedAt': '2026-09-13T12:00:00Z',
      'channels': List.filled(16, 1.0),
    };
    final uploads = <dynamic>[];
    // Route requests to the smallest realistic fake responses.
    final client = MockClient((request) async {
      if (request.method == 'POST') {
        uploads.add(jsonDecode(request.body));
        return http.Response('{"insertedMeasurements":16}', 201);
      }
      if (request.url.path.endsWith('/test-input')) {
        return http.Response(jsonEncode(frame), 200);
      }
      return http.Response(
          jsonEncode([
            {
              'sessionId': 'session-1',
              'sessionName': 'Bench',
              'serialNumber': 'MANUAL-001',
              'startTime': '2026-09-13T11:59:00Z',
            }
          ]),
          200);
    });
    // Inject both network and log dependencies into the real Dashboard widget.
    await tester.pumpWidget(MaterialApp(
        home: Dashboard(
            role: AppRole.mobile,
            api: Api(client: client),
            log: CaptureLog(read: () async => null, write: (_) async {}))));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
        find.text('Start capture').hitTestable(), 300,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Start capture'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(uploads, isEmpty, reason: 'Old device input must not be uploaded');
    // Publishing a new frame while running should cause exactly one upload.
    frame = {...frame, 'frameId': 'new', 'recordedAt': '2026-09-13T12:00:01Z'};
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(uploads, hasLength(1));
    expect(uploads.single['samples'][0]['recordedAt'], frame['recordedAt']);
    expect(uploads.single['samples'][0]['channels'], frame['channels']);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(uploads, hasLength(1), reason: 'Polling must not duplicate a frame');
    // A changed frame after Stop remains visible but must not be uploaded.
    await tester.tap(find.text('Stop capture'));
    await tester.pumpAndSettle();
    frame = {...frame, 'frameId': 'stopped'};
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(uploads, hasLength(1));
    await tester.pumpWidget(const SizedBox());
  });
}
