import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:capstone_monitor/api.dart';
import 'package:capstone_monitor/capture_log.dart';
import 'package:capstone_monitor/capture_journal_codec.dart';
import 'package:capstone_monitor/screens.dart';

Map<String, dynamic> session(String id, String name) => {
      'sessionId': id,
      'sessionName': name,
      'serialNumber': 'MANUAL-001',
      'startTime': '2026-10-05T11:00:00Z',
    };
Map<String, dynamic> frame(String id, String sessionId, String apiUrl) => {
      'frameId': id,
      'sessionId': sessionId,
      'apiUrl': apiUrl,
      'recordedAt': '2026-10-05T12:00:00Z',
      'channels': List.filled(16, 1.0),
      'uploaded': false,
    };

class DeletionFixture {
  var sessions = [session('one', 'Bench one'), session('two', 'Bench two')];
  var deleteStatus = 204, deleteCalls = 0, uploadCalls = 0;
  bool failDisk = false;
  String? disk;
  Completer<http.Response>? uploadGate;
  late final api = Api(
      baseUrl: 'http://collector',
      client: MockClient((r) async {
        if (r.method == 'DELETE') {
          deleteCalls++;
          expect(r.url.path, '/api/sessions/one');
          if (deleteStatus == 204) {
            sessions.removeWhere((s) => s['sessionId'] == 'one');
            return http.Response('', 204);
          }
          return http.Response('{"error":"Service unavailable"}', deleteStatus);
        }
        if (r.method == 'POST') {
          uploadCalls++;
          return uploadGate?.future ??
              Future.value(
                  http.Response('{"error":"Upload unavailable"}', 503));
        }
        if (r.url.path == '/api/sessions') {
          return http.Response(jsonEncode(sessions), 200);
        }
        if (r.url.path == '/api/test-input') return http.Response('null', 200);
        return http.Response(
            jsonEncode({'measurements': [], 'measurementCount': 0}), 200);
      }));
  late final log = CaptureLog(
      read: () async => disk,
      write: (data) async {
        if (failDisk) throw StateError('Storage unavailable');
        disk = data;
      });

  Future<void> open(WidgetTester tester,
      {AppRole role = AppRole.mobile}) async {
    await tester.pumpWidget(
        MaterialApp(home: Dashboard(role: role, api: api, log: log)));
    await tester.pumpAndSettle();
  }
}

Future<void> openDelete(WidgetTester tester) async {
  await tester.scrollUntilVisible(
      find.text('Delete session').hitTestable(), 300,
      scrollable: find.byType(Scrollable).first);
  await tester.tap(find.text('Delete session'));
  await tester.pumpAndSettle();
  expect(find.text('Delete this session?'), findsOneWidget);
}

Future<void> confirmDelete(WidgetTester tester) async {
  await tester.tap(find.descendant(
      of: find.byType(AlertDialog), matching: find.text('Delete session')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('cancel preserves the session and makes no deletion request',
      (tester) async {
    final fixture = DeletionFixture();
    await fixture.open(tester, role: AppRole.web);
    await openDelete(tester);
    expect(
        find.textContaining('Permanently delete “Bench one”'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(fixture.deleteCalls, 0);
    expect(
        tester
            .widget<DropdownButton<String>>(find.byType(DropdownButton<String>))
            .value,
        'one');
    await tester.pumpWidget(const SizedBox());
    fixture.api.close();
  });

  testWidgets(
      'history deletion removes selection and shows the remaining session',
      (tester) async {
    final fixture = DeletionFixture();
    await fixture.open(tester, role: AppRole.web);
    await openDelete(tester);
    await confirmDelete(tester);
    expect(fixture.deleteCalls, 1);
    expect(
        tester
            .widget<DropdownButton<String>>(find.byType(DropdownButton<String>))
            .value,
        'two');
    await tester.scrollUntilVisible(
        find.text('Session “Bench one” deleted.').hitTestable(), -300,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpWidget(const SizedBox());
    fixture.api.close();
  });

  testWidgets(
      'failed deletion preserves selection and all local pending frames',
      (tester) async {
    final fixture = DeletionFixture()..deleteStatus = 503;
    fixture.disk = jsonEncode([frame('1', 'one', 'http://collector')]);
    await fixture.open(tester);
    await openDelete(tester);
    await confirmDelete(tester);
    expect(fixture.log.pending, 1);
    expect(fixture.log.entries.single['sessionId'], 'one');
    expect(fixture.sessions, hasLength(2));
    await tester.scrollUntilVisible(
        find.text('Delete failed: Service unavailable').hitTestable(), -300,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpWidget(const SizedBox());
    fixture.api.close();
  });

  testWidgets(
      'deleting the last session clears history and shows the empty state',
      (tester) async {
    final fixture = DeletionFixture()..sessions = [session('one', 'Bench one')];
    await fixture.open(tester, role: AppRole.web);
    await openDelete(tester);
    await confirmDelete(tester);
    expect(find.byType(DropdownButton<String>), findsNothing);
    expect(find.text('Delete session'), findsNothing);
    expect(find.text('No sessions yet. Create one in the mobile collector.'),
        findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    fixture.api.close();
  });

  testWidgets(
      'collector deletion durably removes only this destination and session',
      (tester) async {
    final fixture = DeletionFixture();
    fixture.disk = jsonEncode([
      frame('1', 'one', 'http://collector'),
      frame('2', 'two', 'http://collector'),
      frame('3', 'one', 'http://another-api')
    ]);
    await fixture.open(tester);
    await openDelete(tester);
    await confirmDelete(tester);
    expect(fixture.log.entries.map((e) => e['frameId']), ['2', '3']);
    await fixture.log.load();
    expect(fixture.log.pending, 2);
    expect(fixture.log.entries.map((e) => e['frameId']), ['2', '3']);
    await tester.pumpWidget(const SizedBox());
    fixture.api.close();
  });

  testWidgets(
      'failed local cleanup pauses retries and offers cleanup without another delete',
      (tester) async {
    final fixture = DeletionFixture();
    fixture.disk = jsonEncode([frame('1', 'one', 'http://collector')]);
    await fixture.open(tester);
    fixture.failDisk = true;
    await openDelete(tester);
    await confirmDelete(tester);
    expect(fixture.deleteCalls, 1);
    expect(fixture.log.pending, 1);
    final uploads = fixture.uploadCalls;
    await tester.pump(const Duration(seconds: 2));
    expect(fixture.uploadCalls, uploads);
    await tester.scrollUntilVisible(
        find.textContaining('Local cleanup needs attention').hitTestable(),
        -300,
        scrollable: find.byType(Scrollable).first);
    fixture.failDisk = false;
    await tester.scrollUntilVisible(
        find.text('Retry local cleanup').hitTestable(), 100,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Retry local cleanup'));
    await tester.pumpAndSettle();
    expect(fixture.deleteCalls, 1);
    expect(fixture.log.pending, 0);
    expect(find.text('Retry local cleanup'), findsNothing);
    await fixture.log.load();
    expect(fixture.log.entries, isEmpty);
    await tester.pumpWidget(const SizedBox());
    fixture.api.close();
  });

  testWidgets('deletion waits for uploads already in progress', (tester) async {
    final fixture = DeletionFixture();
    await fixture.open(tester);
    await fixture.log.append(
        'http://collector', 'one', frame('1', 'one', 'http://collector'));
    fixture.uploadGate = Completer<http.Response>();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(fixture.uploadCalls, 1);
    await openDelete(tester);
    await confirmDelete(tester);
    expect(fixture.deleteCalls, 0);
    fixture.uploadGate!.complete(http.Response('{}', 201));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(fixture.deleteCalls, 1);
    expect(fixture.log.entries, isEmpty);
    await tester.pumpWidget(const SizedBox());
    fixture.api.close();
  });

  testWidgets(
      'active capture disables deletion; remote removal stops without switching capture',
      (tester) async {
    final fixture = DeletionFixture();
    await fixture.open(tester);
    await tester.scrollUntilVisible(
        find.text('Start capture').hitTestable(), 300,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Start capture'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
        find.text('Delete session').hitTestable(), -300,
        scrollable: find.byType(Scrollable).first);
    final button = tester.widget<TextButton>(find.ancestor(
        of: find.text('Delete session'), matching: find.byType(TextButton)));
    expect(button.onPressed, null);
    expect(find.text('Stop capture before deleting this session.'),
        findsOneWidget);
    fixture.sessions.removeAt(0);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text('Stop capture'), findsNothing);
    await tester.scrollUntilVisible(
        find.textContaining('The capture session was removed.').hitTestable(),
        -300,
        scrollable: find.byType(Scrollable).first);
    expect(fixture.uploadCalls, 0);
    await tester.pumpWidget(const SizedBox());
    fixture.api.close();
  });

  test(
      'API deletion sends auth, accepts 204 and confirmed absence, rejects unknown route',
      () async {
    var status = 204, message = 'Session not found';
    final api = Api(client: MockClient((r) async {
      expect(r.method, 'DELETE');
      expect(r.url.path, '/api/sessions/one');
      expect(r.headers['Authorization'], 'Bearer token');
      return http.Response(
          status == 204 ? '' : jsonEncode({'error': message}), status);
    }))
      ..token = 'token';
    await api.deleteSession('one');
    status = 404;
    await api.deleteSession('one');
    message = 'Route not found';
    await expectLater(api.deleteSession('one'), throwsA(isA<ApiException>()));
    status = 401;
    await expectLater(api.deleteSession('one'), throwsA(isA<ApiException>()));
    api.close();
  });

  test(
      'journal replay removes pending and uploaded frames without crossing destinations',
      () async {
    final replay = CaptureJournalReplay();
    final log = CaptureLog(
        read: () async => replay.json,
        operation: (op, _) async => replay.apply(jsonEncode(op)));
    await log.appendAll('http://collector', 'one', [
      frame('1', 'one', 'http://collector'),
      frame('2', 'one', 'http://collector')
    ]);
    replay.apply(jsonEncode({
      'ack': ['http://collector\u0000one\u00001']
    }));
    await log.load();
    await log.append(
        'http://collector', 'two', frame('3', 'two', 'http://collector'));
    await log.append(
        'http://another-api', 'one', frame('4', 'one', 'http://another-api'));
    await log.discardSession('http://collector', 'one');
    replay.apply(jsonEncode({
      'ack': ['http://collector\u0000one\u00002']
    }));
    await log.load();
    expect(log.entries.map((e) => e['frameId']), ['3', '4']);
    expect(log.pending, 2);
  });
}
