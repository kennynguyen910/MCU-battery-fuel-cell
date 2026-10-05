import 'dart:convert';

String captureEntryKey(Map<String, dynamic> e) =>
    '${e['apiUrl']}\u0000${e['sessionId']}\u0000${e['frameId']}';

/// Identical recovery rules for the native file and browser transaction journal.
class CaptureJournalReplay {
  final entries = <String, Map<String, dynamic>>{};
  void apply(String record) {
    final op = jsonDecode(record) as Map;
    if (op.containsKey('snapshot')) entries.clear();
    for (final value in (op['snapshot'] ?? op['add'] ?? []) as List) {
      final entry = Map<String, dynamic>.from(value);
      entries.putIfAbsent(captureEntryKey(entry), () => entry);
    }
    for (final key in (op['ack'] ?? []) as List) {
      entries[key]?['uploaded'] = true;
    }
    final uploaded = entries.entries
        .where((e) => e.value['uploaded'] == true)
        .map((e) => e.key)
        .toList();
    for (final key
        in uploaded.take(uploaded.length > 500 ? uploaded.length - 500 : 0)) {
      entries.remove(key);
    }
  }

  String get json => jsonEncode(entries.values.toList());
}
