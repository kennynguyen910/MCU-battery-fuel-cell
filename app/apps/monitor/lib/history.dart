// Read-only history helpers and graph. No chart dependency is used because one
// small CustomPainter is sufficient for the MVP's single-channel display.
import 'dart:math' as math;
import 'package:flutter/material.dart';

/// The API uses UTC boundaries, inclusive on both ends. Reject normalized
/// overflow dates such as February 30 instead of silently filtering March 2.
DateTime? parseUtcBoundary(String text) {
  if (text.trim().isEmpty) return null;
  final value = text.trim();
  final pattern = RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,3})?Z$');
  final parsed = DateTime.tryParse(value);
  if (!pattern.hasMatch(value) ||
      parsed == null ||
      parsed.toIso8601String().substring(0, 19) != value.substring(0, 19)) {
    throw const FormatException(
        'Use a valid UTC time, e.g. 2026-09-14T01:40:30Z.');
  }
  return parsed;
}

class VoltagePoint {
  /// Pair time and voltage so sorting/scaling code remains type-safe.
  final DateTime time;
  final double voltage;
  const VoltagePoint(this.time, this.voltage);
}

List<VoltagePoint> channelPoints(List<dynamic> rows, int channel) {
  // SQL channels are zero-based while the visible labels add one for people.
  return rows
      .where((row) => row['channel'] == channel)
      .map((row) => VoltagePoint(DateTime.parse(row['recordedAt'] as String),
          (row['voltage'] as num).toDouble()))
      .toList()
    ..sort((a, b) => a.time.compareTo(b.time));
}

/// A plain, single-channel graph avoids 16 overlapping lines and extra packages.
/// Filters apply at the API, so graph and latest-value list share the same rows.
class HistoryPanel extends StatefulWidget {
  final List<dynamic> rows;
  final void Function(DateTime? from, DateTime? to) onFilter;
  const HistoryPanel({super.key, required this.rows, required this.onFilter});
  @override
  State<HistoryPanel> createState() => _HistoryPanelState();
}

class _HistoryPanelState extends State<HistoryPanel> {
  // Text controllers keep the exact UTC strings available after validation fails.
  final from = TextEditingController();
  final to = TextEditingController();
  int channel = 0;
  String? error;

  /// Parse both optional boundaries and call the parent only when the range works.
  void apply() {
    try {
      final start = parseUtcBoundary(from.text);
      final end = parseUtcBoundary(to.text);
      if (start != null && end != null && start.isAfter(end)) {
        throw const FormatException('From must be before or equal to To.');
      }
      setState(() => error = null);
      widget.onFilter(start, end);
    } on FormatException catch (e) {
      setState(() => error = e.message);
    }
  }

  @override
  void dispose() {
    from.dispose();
    to.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Recalculate only the selected channel's points for a readable graph.
    final points = channelPoints(widget.rows, channel);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Time range (UTC; leave blank for the full session)'),
      TextField(
          controller: from,
          decoration: const InputDecoration(
              labelText: 'From (UTC)', hintText: '2026-09-14T01:40:30Z')),
      TextField(
          controller: to,
          decoration: const InputDecoration(
              labelText: 'To (UTC)', hintText: '2026-09-14T01:45:00Z')),
      if (error != null)
        Text(error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error)),
      Wrap(spacing: 8, children: [
        TextButton(onPressed: apply, child: const Text('Apply time range')),
        TextButton(
            onPressed: () {
              from.clear();
              to.clear();
              setState(() => error = null);
              widget.onFilter(null, null);
            },
            child: const Text('Clear time range')),
      ]),
      DropdownButton<int>(
          value: channel,
          items: List.generate(
              16,
              (i) =>
                  DropdownMenuItem(value: i, child: Text('Graph CH ${i + 1}'))),
          onChanged: (value) {
            if (value != null) setState(() => channel = value);
          }),
      if (points.isEmpty)
        const Text('No measurements in this range.')
      else ...[
        Text('${points.length} sample(s) — CH ${channel + 1}'),
        Semantics(
            label:
                'Voltage over UTC time for channel ${channel + 1}, ${points.length} samples',
            child: SizedBox(
                height: 200,
                width: double.infinity,
                child: CustomPaint(painter: VoltagePainter(points)))),
        Text('First: ${points.first.time.toIso8601String()}'),
        Text('Last: ${points.last.time.toIso8601String()}'),
        const Text(
            'Line segments connect saved samples; gaps are not additional measurements.'),
      ],
      const Divider(),
    ]);
  }
}

class VoltagePainter extends CustomPainter {
  final List<VoltagePoint> points;
  VoltagePainter(this.points);

  @override
  void paint(Canvas canvas, Size size) {
    // Very narrow/empty canvases cannot display meaningful axes.
    if (points.isEmpty || size.width < 90) return;
    // Add padding even to constant data so division by zero is impossible.
    final minimum = points.map((p) => p.voltage).reduce(math.min);
    final maximum = points.map((p) => p.voltage).reduce(math.max);
    final padding = math.max((maximum - minimum) * .1, .01);
    final low = minimum - padding, high = maximum + padding;
    final area = Rect.fromLTRB(65, 12, size.width - 12, size.height - 20);
    final axis = Paint()
      ..color = Colors.grey
      ..strokeWidth = 1;
    canvas.drawLine(area.topLeft, area.bottomLeft, axis);
    canvas.drawLine(area.bottomLeft, area.bottomRight, axis);
    void label(String value, double y) {
      // Reserve the left side for voltage labels instead of placing text on data.
      final text = TextPainter(
          text: TextSpan(
              text: value,
              style: const TextStyle(color: Colors.black, fontSize: 11)),
          textDirection: TextDirection.ltr)
        ..layout(maxWidth: 61);
      text.paint(canvas, Offset(0, y));
    }

    label('${high.toStringAsFixed(3)} V', area.top);
    label('${low.toStringAsFixed(3)} V', area.bottom - 12);
    final start = points.first.time.microsecondsSinceEpoch;
    // Time-based horizontal spacing avoids implying equally spaced samples.
    final duration = points.last.time.microsecondsSinceEpoch - start;
    final line = Paint()
      ..color = Colors.blue
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final dot = Paint()..color = Colors.blue;
    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final p = points[i];
      final fraction = duration == 0
          ? .5
          : (p.time.microsecondsSinceEpoch - start) / duration;
      final x = area.left + fraction * area.width;
      final y = area.bottom - (p.voltage - low) / (high - low) * area.height;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
      canvas.drawCircle(Offset(x, y), 3, dot);
    }
    canvas.drawPath(path, line);
  }

  @override
  // A new list means the filter/session/channel data may have changed.
  bool shouldRepaint(VoltagePainter oldDelegate) =>
      oldDelegate.points != points;
}
