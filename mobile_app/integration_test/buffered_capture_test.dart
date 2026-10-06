// Run against a dedicated local API backed by PostgreSQL. This test exercises
// the actual Android collector, native log, HTTP batches, and stored readback.
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:capstone_monitor/api.dart';
import 'package:capstone_monitor/screens.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
      'Android preserves the buffered generator stream and stops capture',
      (tester) async {
    final api = Api();
    await api.login('capstone', 'capstone_password');
    await api.request('/simulation', {'scenario': 'baseline'});
    Future<void> settle() async {
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
    }

    Future<void> seek(String text, double step) async {
      await tester.scrollUntilVisible(find.text(text).hitTestable(), step,
          scrollable: find.byType(Scrollable).first, maxScrolls: 40);
      await settle();
    }

    Future<void> waitSeconds(int seconds) async {
      for (var i = 0; i < seconds * 4; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        await tester.pump();
      }
    }

    try {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await api.pairDevice('127.0.0.1');
      final name =
          'Android buffered verification ${DateTime.now().toUtc().toIso8601String()}';
      final sessionId = await api.createSession(name, deviceIp: '127.0.0.1');
      await tester.pumpWidget(
          MaterialApp(home: Dashboard(role: AppRole.mobile, api: api)));
      await waitSeconds(2);
      await seek('Manual test input', 300);
      await tester.tap(find.text('Manual test input'));
      await settle();
      await tester.tap(find.text('ESP32 over laptop Wi-Fi / UDP').last);
      await settle();
      await waitSeconds(2);
      await seek('Start capture', 300);
      // Stop traffic while setting the baseline: the source stays live for 5s.
      await api.request('/simulation', {'scenario': 'stopped'});
      final baseline = await api.deviceFrames(sourceIp: '127.0.0.1');
      await tester.tap(find.text('Start capture'));
      await settle();
      expect(find.text('Stop capture'), findsOneWidget);
      final started = DateTime.now();
      await api.request('/simulation', {'scenario': 'load'});
      await waitSeconds(5);
      await api.request('/simulation', {'scenario': 'loss'});
      await waitSeconds(2);
      await api.request('/simulation', {'scenario': 'stopped'});
      await waitSeconds(
          7); // Also prove the final buffer drains when sender is stale.
      final report = await api.request('/simulation');
      final source = (report['sources'] as List)
          .firstWhere((s) => s['sourceIp'] == '127.0.0.1');
      final expected =
          (source['uniqueFrames'] as int) - (baseline['nextCursor'] as int);
      final stored = await api.request('/sessions/$sessionId');
      final rows = stored['measurements'] as List;
      expect(expected, greaterThan(3000));
      expect(rows.length, expected * 16,
          reason:
              'Every accepted frame after Start must survive collector upload');
      expect(source['missingFrames'], greaterThan(0),
          reason: 'Injected UDP losses remain observable');
      expect(rows.map((r) => r['recordedAt']).toSet().length, expected);
      await tester.tap(find.text('Stop capture'));
      await settle();
      await api.request('/simulation', {'scenario': 'baseline'});
      await waitSeconds(3);
      final afterStop = await api.request('/sessions/$sessionId?recent=1');
      expect(afterStop['measurementCount'], rows.length);
      expect((afterStop['measurements'] as List).length, 16000);
      expect(afterStop['truncated'], true);
      // This output is a concise, reproducible evidence record.
      print('BUFFERED_CAPTURE_RESULT ${jsonEncode({
            'sessionId': sessionId,
            'sessionName': name,
            'acceptedFrames': expected,
            'storedFrames': rows.length ~/ 16,
            'storedRows': rows.length,
            'elapsedSeconds': DateTime.now().difference(started).inSeconds,
            'stopVerified': true
          })}');
    } finally {
      await api.request('/simulation', {'scenario': 'stopped'});
      await tester.pumpWidget(const SizedBox());
      api.close();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
