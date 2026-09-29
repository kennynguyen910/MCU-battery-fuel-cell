import 'dart:convert';
import 'api.dart';
import 'log_storage.dart' as storage;

/// Save before upload. Every entry retains its destination/session/timestamp,
/// so retries cannot accidentally move an old sample into the current session.
class CaptureLog {
  // Storage functions are injected in tests and selected by platform in the app.
  final Future<String?> Function() read;
  final Future<void> Function(String) write;
  List<Map<String, dynamic>> entries = [];
  CaptureLog(
      {Future<String?> Function()? read, Future<void> Function(String)? write})
      : read = read ?? storage.readLog,
        write = write ?? storage.writeLog;

  /// Restore the complete local log before polling or retrying any frames.
  Future<void> load() async {
    final data = await read();
    if (data != null) {
      entries = (jsonDecode(data) as List)
          .map((entry) => Map<String, dynamic>.from(entry))
          .toList();
    }
  }

  /// Pretty JSON is intentionally human-readable for demonstrations/debugging.
  String get json => const JsonEncoder.withIndent('  ').convert(entries);
  int get pending => entries.where((e) => e['uploaded'] != true).length;

  /// Save a frame once per API/session/frame ID before attempting the network.
  Future<void> append(
          String apiUrl, String sessionId, Map<String, dynamic> frame) =>
      appendAll(apiUrl, sessionId, [frame]);

  /// Save a fetched batch with one disk write. Buffered device capture appends
  /// hundreds of frames per poll, so per-frame writes would stall the UI.
  Future<void> appendAll(String apiUrl, String sessionId,
      List<Map<String, dynamic>> frames) async {
    final known = entries
        .map(
            (e) => '${e['apiUrl']}\u0000${e['sessionId']}\u0000${e['frameId']}')
        .toSet();
    final original = List<Map<String, dynamic>>.from(entries);
    var added = false;
    for (final frame in frames) {
      if (known.add('$apiUrl\u0000$sessionId\u0000${frame['frameId']}')) {
        entries.add({
          ...frame,
          'apiUrl': apiUrl,
          'sessionId': sessionId,
          'uploaded': false
        });
        added = true;
      }
    }
    if (added) {
      try {
        if (pending > 10000)
          throw StateError(
              'Local pending buffer is full. Restore uploads before continuing.');
        await write(jsonEncode(entries));
      } catch (_) {
        entries = original;
        rethrow;
      }
    }
  }

  /// Upload pending entries only to their original API. Entries stay grouped
  /// by session in arrival order and upload in batches, because high-rate
  /// capture cannot afford one HTTP request per frame. Each batch is marked
  /// after its request succeeds so a crash cannot report unsaved data.
  Future<int> flush(Api api) async {
    const batchSize = 1000;
    var count = 0;
    final pending = entries
        .where((e) => e['uploaded'] != true && e['apiUrl'] == api.baseUrl)
        .toList();
    var index = 0;
    while (index < pending.length) {
      final sessionId = pending[index]['sessionId'] as String;
      final batch = <Map<String, dynamic>>[];
      while (index < pending.length &&
          pending[index]['sessionId'] == sessionId &&
          batch.length < batchSize) {
        batch.add(pending[index]);
        index++;
      }
      await api.uploadFrames(sessionId, batch);
      for (final entry in batch) {
        entry['uploaded'] = true;
      }
      // Keep all unacknowledged data plus a small recent uploaded history.
      // PostgreSQL retains the full history; browser localStorage is bounded.
      final uploaded = entries.where((e) => e['uploaded'] == true).toList();
      final keep = uploaded
          .skip(uploaded.length > 500 ? uploaded.length - 500 : 0)
          .toSet();
      entries = entries
          .where((e) => e['uploaded'] != true || keep.contains(e))
          .toList();
      await write(jsonEncode(entries));
      count += batch.length;
    }
    return count;
  }
}
