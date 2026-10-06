import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:capstone_monitor/api.dart';
import 'package:capstone_monitor/screens.dart';
import 'package:capstone_monitor/capture_log.dart';
import 'package:capstone_monitor/demo_widgets.dart';

void main() {
  testWidgets('network controls fit a phone and dispatch the selected scenario',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    String? chosen;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: NetworkLabPanel(
                    data: const {},
                    busy: false,
                    onScenario: (value) => chosen = value)))));
    await tester.tap(find.text('Drop 20% of packets'));
    expect(chosen, 'loss');
    expect(tester.takeException(), isNull);
  });

  testWidgets('expired login stops capture and signing in does not resume it',
      (tester) async {
    var expired = false;
    var frameId = 'before';
    var uploads = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/auth/login')) {
        expired = false;
        return http.Response('{"token":"new"}', 200);
      }
      if (expired) return http.Response('{"error":"Login required"}', 401);
      if (request.method == 'POST') {
        uploads++;
        return http.Response('{}', 201);
      }
      if (request.url.path.endsWith('/test-input'))
        return http.Response(
            jsonEncode({
              'frameId': frameId,
              'recordedAt': '2026-09-27T00:00:00Z',
              'channels': List.filled(16, 1),
            }),
            200);
      return http.Response(
          jsonEncode([
            {
              'sessionId': 'session-1',
              'sessionName': 'Test',
              'serialNumber': 'MANUAL-001',
              'startTime': '2026-09-27T00:00:00Z'
            }
          ]),
          200);
    });
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
    expired = true;
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Log in').hitTestable(), -300,
        scrollable: find.byType(Scrollable).first);
    await tester.enterText(find.widgetWithText(TextField, 'Username'), 'demo');
    await tester.enterText(
        find.widgetWithText(TextField, 'Password'), 'demo-password');
    frameId = 'after';
    await tester.tap(find.text('Log in'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
        find.text('Start capture').hitTestable(), 300,
        scrollable: find.byType(Scrollable).first);
    expect(uploads, 0);
    expect(find.text('Start capture'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
