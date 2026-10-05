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
  final int uploadConcurrency;
  List<Map<String, dynamic>> entries = [];
  Set<String> _known = {};
  Future<void> _committing = Future.value();
  Future<int>? _flushing;
  CaptureLog(
      {Future<String?> Function()? read,
      Future<void> Function(String)? write,
      LogOperation? operation,
      int? maxPending,
      this.uploadConcurrency = 4})
      : read = read ?? storage.readLog,
        write = write ?? storage.writeLog,
        operation = operation ??
            (read == null && write == null && storage.journalSupported
                ? storage.appendLogOperation
                : null),
        maxPending = maxPending ?? (storage.journalSupported ? 60000 : 10000) {
    if (uploadConcurrency < 1 || uploadConcurrency > 4) {
      throw ArgumentError.value(
          uploadConcurrency, 'uploadConcurrency', 'Use 1–4');
    }
  }
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

  /// Local caches follow account and destination boundaries too. Unassigned
  /// legacy entries remain intact and are visible only to admin with login enabled.
  Iterable<Map<String, dynamic>> visibleEntries(Api api) => entries.where((e) =>
      e['apiUrl'] == api.baseUrl &&
      (api.authenticationRequired
          ? api.signedIn && (api.isAdmin || e['ownerUsername'] == api.username)
          : e['ownerUsername'] == null));
  String visibleJson(Api api) =>
      const JsonEncoder.withIndent('  ').convert(visibleEntries(api).toList());
  int visiblePending(Api api) =>
      visibleEntries(api).where((e) => e['uploaded'] != true).length;
  Future<void> _save(
          Map<String, dynamic> op, List<Map<String, dynamic>> next) =>
      operation != null ? operation!(op, next) : write(jsonEncode(next));
  Future<void> append(
          String apiUrl, String sessionId, Map<String, dynamic> frame,
          {String? ownerUsername}) =>
      appendAll(apiUrl, sessionId, [frame], ownerUsername: ownerUsername);
  Future<void> appendAll(
          String apiUrl, String sessionId, List<Map<String, dynamic>> frames,
          {String? ownerUsername}) =>
      _commit(() async {
        final added = <Map<String, dynamic>>[];
        final keys = <String>{};
        for (final frame in frames) {
          final entry = {
            ...frame,
            'apiUrl': apiUrl,
            'sessionId': sessionId,
            'ownerUsername': ownerUsername,
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

  /// Call after stopping producers and uploads, and after server deletion succeeds.
  /// Commit removal before changing memory so a failed save remains retryable.
  Future<void> discardSession(String apiUrl, String sessionId) =>
      _commit(() async {
        final next = entries
            .where((e) => e['apiUrl'] != apiUrl || e['sessionId'] != sessionId)
            .toList();
        if (next.length == entries.length) return;
        await _save({
          'removeSession': {'apiUrl': apiUrl, 'sessionId': sessionId}
        }, next);
        entries = next;
        _index();
      });

  /// One flush owner, bounded workers and a finite snapshot. Producers continue
  /// while HTTP is pending. All in-flight acknowledgements settle before return.
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
    final identity = api.username;
    final requestToken = api.token;
    final todo = await _commit(() async =>
        visibleEntries(api).where((e) => e['uploaded'] != true).toList());
    var count = 0, index = 0;
    Object? failure;
    StackTrace? failureStack;
    Future<void> worker() async {
      while (index < todo.length && failure == null) {
        if (api.baseUrl != destination ||
            api.username != identity ||
            api.token != requestToken) break;
        final sessionId = todo[index]['sessionId'] as String;
        final batch = <Map<String, dynamic>>[];
        while (index < todo.length &&
            todo[index]['sessionId'] == sessionId &&
            batch.length < 1000) {
          batch.add(todo[index++]);
        }
        try {
          await api.uploadFrames(sessionId, batch);
          final ack = batch.map(_key).toSet();
          await _commit(() async {
            final next = entries
                .map(
                    (e) => ack.contains(_key(e)) ? {...e, 'uploaded': true} : e)
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
        } catch (error, stack) {
          failure ??= error;
          failureStack ??= stack;
        }
      }
    }

    await Future.wait(List.generate(uploadConcurrency, (_) => worker()));
    if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
    return count;
  }
}
