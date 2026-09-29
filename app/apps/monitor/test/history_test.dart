// Pure and widget tests for UTC filtering, point ordering, and graph edge cases.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capstone_monitor/history.dart';

void main() {
  test('UTC filter rejects calendar overflow and missing timezone', () {
    // Empty is a supported open boundary; malformed non-empty text is not.
    expect(parseUtcBoundary(''), isNull);
    expect(parseUtcBoundary('2026-09-14T12:00:00Z')!.isUtc, true);
    for (final invalid in ['2026-02-30T12:00:00Z', '2026-09-14T12:00:00']) {
      expect(() => parseUtcBoundary(invalid), throwsFormatException);
    }
  });
  test('channel points are selected and sorted by actual time', () {
    // Intentionally mix channels and input order to expose sorting mistakes.
    final points = channelPoints([
      {'channel': 0, 'recordedAt': '2026-09-14T12:00:10Z', 'voltage': 2},
      {'channel': 1, 'recordedAt': '2026-09-14T12:00:00Z', 'voltage': -5},
      {'channel': 0, 'recordedAt': '2026-09-14T12:00:01Z', 'voltage': 1},
    ], 0);
    expect(points.map((p) => p.voltage), [1, 2]);
    expect(points.last.time.difference(points.first.time).inSeconds, 9);
  });
  testWidgets('invalid range does not apply; equal boundaries and clear do',
      (tester) async {
    // Record callback arguments instead of needing an API or database.
    final calls = <List<DateTime?>>[];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: HistoryPanel(
                    rows: const [],
                    onFilter: (from, to) => calls.add([from, to]))))));
    await tester.enterText(
        find.widgetWithText(TextField, 'From (UTC)'), '2026-09-14T12:00:02Z');
    await tester.enterText(
        find.widgetWithText(TextField, 'To (UTC)'), '2026-09-14T12:00:01Z');
    await tester.tap(find.text('Apply time range'));
    await tester.pump();
    expect(calls, isEmpty);
    expect(find.text('From must be before or equal to To.'), findsOneWidget);
    await tester.enterText(
        find.widgetWithText(TextField, 'From (UTC)'), '2026-09-14T12:00:01Z');
    await tester.tap(find.text('Apply time range'));
    await tester.pump();
    expect(calls.single[0], calls.single[1]);
    await tester.tap(find.text('Clear time range'));
    await tester.pump();
    expect(calls.last, [null, null]);
  });
  testWidgets('single zero-voltage sample paints without a zero-range error',
      (tester) async {
    // Constant data previously risks a zero denominator while scaling the graph.
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: HistoryPanel(rows: const [
      {'channel': 0, 'recordedAt': '2026-09-14T12:00:00Z', 'voltage': 0},
    ], onFilter: (from, to) {})))));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('1 sample(s) — CH 1'), findsOneWidget);
  });
}
