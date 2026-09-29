import 'dart:convert';
import 'package:flutter/material.dart';

class DemoSection extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<Widget> children;
  const DemoSection(
      {super.key, required this.title, this.subtitle, required this.children});
  @override
  Widget build(BuildContext context) => Card(
        elevation: 0,
        margin: const EdgeInsets.only(bottom: 18),
        child: Padding(
            padding: const EdgeInsets.all(22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w700)),
                if (subtitle != null)
                  Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(subtitle!)),
                const SizedBox(height: 18),
                ...children
              ],
            )),
      );
}

class StatTiles extends StatelessWidget {
  final Map<String, String> values;
  const StatTiles(this.values, {super.key});
  @override
  Widget build(BuildContext context) => Wrap(
      spacing: 12,
      runSpacing: 12,
      children: values.entries
          .map((e) => Container(
                width: 180,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                    color: const Color(0xffeaf1f5),
                    borderRadius: BorderRadius.circular(12)),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(e.value,
                          style: Theme.of(context)
                              .textTheme
                              .headlineSmall
                              ?.copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 4),
                      Text(e.key, style: Theme.of(context).textTheme.bodySmall),
                    ]),
              ))
          .toList());
}

class VoltageTiles extends StatelessWidget {
  final List<double?> values;
  const VoltageTiles(this.values, {super.key});
  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, constraints) {
        final columns = constraints.maxWidth < 540 ? 2 : 4;
        final width = (constraints.maxWidth - (columns - 1) * 12) / columns;
        return Wrap(
            spacing: 12,
            runSpacing: 12,
            children: List.generate(
                16,
                (i) => Container(
                      width: width,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                          color: const Color(0xffedf6f5),
                          borderRadius: BorderRadius.circular(12)),
                      child: Text(
                          'CH ${i + 1}: ${values[i]?.toStringAsFixed(3) ?? '—'} V',
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                    )));
      });
}

class NetworkLabPanel extends StatelessWidget {
  final Map<String, dynamic> data;
  final bool busy;
  final ValueChanged<String> onScenario;
  const NetworkLabPanel(
      {super.key,
      required this.data,
      required this.busy,
      required this.onScenario});
  @override
  Widget build(BuildContext context) {
    final sources = (data['sources'] as List? ?? [])
        .where((source) => source['sourceIp'] == '127.0.0.1')
        .toList();
    final source = sources.isEmpty ? <String, dynamic>{} : sources.first as Map;
    String number(Map map, String key) => '${map[key] ?? 0}';
    final selected = data['scenario'] ?? 'stopped';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      DemoSection(
          title: 'Network scenarios',
          subtitle:
              'Synthetic 16-channel readings travel through a real UDP socket. Choose one scenario at a time.',
          children: [
            Wrap(spacing: 10, runSpacing: 10, children: [
              for (final scenario in const {
                'baseline': 'Run baseline · 100 fps',
                'load': 'High load · 1,000 fps',
                'loss': 'Drop 20% of packets',
                'corrupt': 'CRC corruption · 1 in 10',
                'outage': 'Disconnect network',
                'stopped': 'Stop generator',
              }.entries)
                ChoiceChip(
                    label: Text(scenario.value),
                    selected: selected == scenario.key,
                    onSelected: busy ? null : (_) => onScenario(scenario.key)),
            ]),
            const SizedBox(height: 16),
            Text('Active scenario: ${data['label'] ?? 'Stopped'}',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text(
                'After an outage, choose High load to reconnect. The receiver marks a sender offline after 5 seconds without a new valid frame.'),
          ]),
      DemoSection(
          title: 'Sender • injected conditions',
          subtitle: 'Cumulative totals since this demo started.',
          children: [
            StatTiles({
              'Target frames / second': number(data, 'fps'),
              'Generated frames': number(data, 'generatedFrames'),
              'Sent UDP packets': number(data, 'sentDatagrams'),
              'Deliberately dropped frames':
                  number(data, 'injectedDroppedFrames'),
              'Deliberately corrupted frames':
                  number(data, 'injectedCorruptFrames'),
              'Scheduler skips': number(data, 'schedulerDroppedFrames'),
              'Socket send errors': number(data, 'sendErrors'),
            }),
          ]),
      DemoSection(
          title: 'Receiver • observed results',
          subtitle: sources.isEmpty
              ? 'Start a scenario to discover the simulated sender.'
              : 'Sender ${source['sourceIp']} · ${source['stale'] == true ? 'OFFLINE' : 'LIVE'}',
          children: [
            StatTiles({
              'Frames in last second': number(source, 'framesPerSecond'),
              'Valid received frames': number(source, 'receivedFrames'),
              'Estimated missing frames': number(source, 'missingFrames'),
              'CRC errors': number(source, 'crcErrors'),
              'Duplicates': number(source, 'duplicateFrames'),
              'Late frames': number(source, 'lateFrames'),
            }),
            const SizedBox(height: 16),
            const Text(
                'Missing frames are inferred from sequence gaps. Loss before the first or after the last received frame is not measurable. Counters accumulate across scenarios.'),
            const SizedBox(height: 8),
            const Text(
                'The collector fetches buffered frames and uploads batches. A one-second screen refresh does not limit capture to one frame per second. Receiver retention is 10,000 frames; a delayed collector reports buffer losses.'),
            TextButton.icon(
                onPressed: data.isEmpty
                    ? null
                    : () => showDialog<void>(
                        context: context,
                        builder: (context) => AlertDialog(
                                title: const Text('Network report'),
                                content: SizedBox(
                                    width: 620,
                                    child: SingleChildScrollView(
                                        child: SelectableText(
                                            const JsonEncoder.withIndent('  ')
                                                .convert(data)))),
                                actions: [
                                  TextButton(
                                      onPressed: () => Navigator.pop(context),
                                      child: const Text('Close'))
                                ])),
                icon: const Icon(Icons.description_outlined),
                label: const Text('View report JSON')),
          ]),
    ]);
  }
}
