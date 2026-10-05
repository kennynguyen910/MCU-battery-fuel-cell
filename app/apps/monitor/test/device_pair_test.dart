import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:capstone_monitor/api.dart';
import 'package:capstone_monitor/capture_log.dart';
import 'package:capstone_monitor/screens.dart';

void main() {
  testWidgets('collector pairs a discovered UDP sender before session creation',
      (tester) async {
    var paired = false;
    var pairRequests = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/device-sources/pair')) {
        pairRequests++;
        expect(jsonDecode(request.body)['sourceIp'], '192.168.1.50');
        paired = true;
        return http.Response('{"deviceId":"device-1"}', 201);
      }
      if (request.url.path.endsWith('/device-sources')) {
        return http.Response(
            jsonEncode([
              {
                'sourceIp': '192.168.1.50',
                'stale': false,
                'deviceId': paired ? 'device-1' : null,
              }
            ]),
            200);
      }
      if (request.url.path.endsWith('/device-input')) {
        expect(request.url.queryParameters['sourceIp'], '192.168.1.50');
        return http.Response(
            '{"frame":null,"stale":false,"receivedFrames":10}', 200);
      }
      return http.Response('[]', 200);
    });
    await tester.pumpWidget(MaterialApp(
        home: Dashboard(
      role: AppRole.mobile,
      api: Api(client: client),
      log: CaptureLog(read: () async => null, write: (_) async {}),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Manual test input'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ESP32 over laptop Wi-Fi / UDP').last);
    await tester.pumpAndSettle();
    expect(find.text('Pair selected device'), findsOneWidget);
    await tester.scrollUntilVisible(
        find.text('Create session').hitTestable(), 250,
        scrollable: find.byType(Scrollable).first);
    expect(
        tester
            .widget<ElevatedButton>(
                find.widgetWithText(ElevatedButton, 'Create session'))
            .onPressed,
        isNull);
    await tester.scrollUntilVisible(
        find.text('Pair selected device').hitTestable(), -250,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Pair selected device'));
    await tester.pumpAndSettle();
    expect(pairRequests, 1);
    expect(find.text('Pair selected device'), findsNothing);
    await tester.scrollUntilVisible(
        find.text('Create session').hitTestable(), 250,
        scrollable: find.byType(Scrollable).first);
    expect(
        tester
            .widget<ElevatedButton>(
                find.widgetWithText(ElevatedButton, 'Create session'))
            .onPressed,
        isNotNull);
    await tester.pumpWidget(const SizedBox());
  });
}
