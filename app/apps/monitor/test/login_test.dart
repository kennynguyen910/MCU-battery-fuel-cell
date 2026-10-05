import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:capstone_monitor/api.dart';
import 'package:capstone_monitor/screens.dart';

void main() {
  testWidgets('viewer logs in and sends bearer token on data requests',
      (tester) async {
    var authorizedReads = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/auth/login')) {
        final body = jsonDecode(request.body);
        expect(body['username'], 'student');
        expect(body['password'], 'correct-password');
        return http.Response('{"token":"test-token"}', 200);
      }
      if (request.headers['Authorization'] != 'Bearer test-token') {
        return http.Response('{"error":"Login required"}', 401);
      }
      authorizedReads++;
      return http.Response('[]', 200);
    });
    await tester.pumpWidget(MaterialApp(
        home: Dashboard(role: AppRole.web, api: Api(client: client))));
    await tester.pumpAndSettle();
    expect(find.text('Log in'), findsOneWidget);
    await tester.enterText(
        find.widgetWithText(TextField, 'Username'), 'student');
    await tester.enterText(
        find.widgetWithText(TextField, 'Password'), 'correct-password');
    await tester.tap(find.text('Log in'));
    await tester.pumpAndSettle();
    expect(authorizedReads, greaterThan(0));
    expect(find.text('Log out'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
