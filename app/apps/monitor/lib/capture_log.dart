import 'dart:convert';
import 'api.dart';
import 'log_storage.dart' as storage;

typedef LogOperation = Future<void> Function(
    Map<String, dynamic>, List<Map<String, dynamic>>);

/// Only local commits serialize. Slow uploads never own the storage lock.
/// Acknowledgements become visible after their local commit, so failures retry.
class CaptureLog {
  final Future<String?> Function() read;
  final Future<void> Function(String) write;
  final LogOperation? operation;
  final int maxPending;
  List<Map<String, dynamic>> entries = [];
  Set<String> _known = {};
  Future<void> _committing = Future.value();
  Future<int>? _flushing;
  CaptureLog(
      {Future<String?> Function()? read,
      Future<void> Function(String)? write,
      LogOperation? operation,
      int? maxPending})
      : read = read ?? storage.readLog,
        write = write ?? storage.writeLog,
        operation = operation ??
            (read == null && write == null && storage.journalSupported
                ? storage.appendLogOperation
                : null),
        maxPending = maxPending ?? (storage.journalSupported ? 60000 : 10000);
  String _key(Map<String, dynamic> e) =>
      '${e['apiUrl']}\u0000${e['sessionId']}\u0000${e['frameId']}';
  void _index() {
    _known = entries.map(_key).toSet();
  }

  Future<T> _commit<T>(Future<T> Function() action) {
    final result = _committing.then((_) => action());
    _committing =
        result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<void> load() => _commit(() async {
        final data = await read();
        entries = data == null
            ? []
            : (jsonDecode(data) as List)
                .map((e) => Map<String, dynamic>.from(e))
                .toList();
        _index();
      });
  String get json => const JsonEncoder.withIndent('  ').convert(entries);
  int get pending => entries.where((e) => e['uploaded'] != true).length;
  Future<void> _save(
          Map<String, dynamic> op, List<Map<String, dynamic>> next) =>
      operation != null ? operation!(op, next) : write(jsonEncode(next));
  Future<void> append(
          String apiUrl, String sessionId, Map<String, dynamic> frame) =>
      appendAll(apiUrl, sessionId, [frame]);
  Future<void> appendAll(
          String apiUrl, String sessionId, List<Map<String, dynamic>> frames) =>
      _commit(() async {
        final added = <Map<String, dynamic>>[];
        final keys = <String>{};
        for (final frame in frames) {
          final entry = {
            ...frame,
            'apiUrl': apiUrl,
            'sessionId': sessionId,
            'uploaded': false
          };
          final key = _key(entry);
          if (!_known.contains(key) && keys.add(key)) added.add(entry);
        }
        if (added.isEmpty) return;
        if (pending + added.length > maxPending) {
          throw StateError(
              'Local pending buffer is full. Restore uploads before continuing.');
        }
        final next = [...entries, ...added];
        await _save({'add': added}, next);
        entries = next;
        _known.addAll(keys);
      });

  /// One uploader, finite snapshot. Producers continue while HTTP is pending.
  Future<int> flush(Api api) {
    if (_flushing != null) return _flushing!;
    final task = _flush(api);
    _flushing = task;
    return task.whenComplete(() {
      _flushing = null;
    });
  }

  Future<int> _flush(Api api) async {
    final destination = api.baseUrl;
    final todo = await _commit(() async => entries
        .where((e) => e['uploaded'] != true && e['apiUrl'] == destination)
        .toList());
    var count = 0, index = 0;
    while (index < todo.length) {
      if (api.baseUrl != destination) break;
      final sessionId = todo[index]['sessionId'] as String;
      final batch = <Map<String, dynamic>>[];
      while (index < todo.length &&
          todo[index]['sessionId'] == sessionId &&
          batch.length < 1000) {
        batch.add(todo[index++]);
      }
      await api.uploadFrames(sessionId, batch);
      final ack = batch.map(_key).toSet();
      await _commit(() async {
        final next = entries
            .map((e) => ack.contains(_key(e)) ? {...e, 'uploaded': true} : e)
            .toList();
        final uploaded = next.where((e) => e['uploaded'] == true).toList();
        final keep = uploaded
            .skip(uploaded.length > 500 ? uploaded.length - 500 : 0)
            .toSet();
        next.removeWhere((e) => e['uploaded'] == true && !keep.contains(e));
        await _save({'ack': ack.toList()}, next);
        entries = next;
        _index();
      });
      count += batch.length;
    }
    return count;
  }
}
