import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'package:web/web.dart' as web;
import 'capture_journal_codec.dart';

/// Append batches in strict IndexedDB transactions, rather than rewriting a
/// quota-limited localStorage snapshot. Commit completion precedes cursor/ack.
class BrowserCaptureJournal {
  final String name;
  final String? legacyKey;
  final int compactBytes;
  Future<web.IDBDatabase>? _database;
  int _bytes = 0;
  BrowserCaptureJournal(this.name,
      {this.legacyKey, this.compactBytes = 32 * 1024 * 1024});

  Future<JSAny?> _request(web.IDBRequest request) {
    final result = Completer<JSAny?>();
    request.addEventListener(
        'success',
        ((web.Event _) {
          result.complete(request.result);
        }).toJS);
    request.addEventListener(
        'error',
        ((web.Event _) {
          result.completeError(
              StateError('Browser capture storage: ${request.error?.name}'));
        }).toJS);
    return result.future;
  }

  Future<web.IDBDatabase> _open() async {
    final request = web.window.indexedDB.open(name, 1);
    request.addEventListener(
        'upgradeneeded',
        ((web.Event _) {
          (request.result as web.IDBDatabase).createObjectStore(
              'operations', web.IDBObjectStoreParameters(autoIncrement: true));
        }).toJS);
    try {
      return (await _request(request)) as web.IDBDatabase;
    } catch (_) {
      _database = null;
      rethrow;
    }
  }

  Future<web.IDBDatabase> get _db => _database ??= _open();
  Future<void> _complete(web.IDBTransaction transaction) {
    final done = Completer<void>();
    transaction.addEventListener(
        'complete',
        ((web.Event _) {
          done.complete();
        }).toJS);
    transaction.addEventListener(
        'abort',
        ((web.Event _) {
          done.completeError(StateError(
              'Browser capture commit failed: ${transaction.error?.name}'));
        }).toJS);
    return done.future;
  }

  Future<String?> read() async {
    final db = await _db;
    final transaction = db.transaction('operations'.toJS, 'readonly');
    final done = _complete(transaction);
    final values =
        (await _request(transaction.objectStore('operations').getAll()))
            as JSArray<JSAny?>;
    await done;
    final records =
        values.toDart.map((value) => (value as JSString).toDart).toList();
    _bytes = records.fold(0, (sum, line) => sum + line.length);
    if (records.isEmpty) {
      final legacy = legacyKey == null
          ? null
          : web.window.localStorage.getItem(legacyKey!);
      if (legacy == null) return null;
      await replace((jsonDecode(legacy) as List)
          .map((e) => Map<String, dynamic>.from(e))
          .toList());
      return legacy;
    }
    final replay = CaptureJournalReplay();
    for (final record in records) {
      replay.apply(record);
    }
    return replay.json;
  }

  Future<void> _write(String record, {bool replace = false}) async {
    final db = await _db;
    final transaction = db.transaction('operations'.toJS, 'readwrite',
        web.IDBTransactionOptions(durability: 'strict'));
    final done = _complete(transaction);
    final store = transaction.objectStore('operations');
    if (replace) store.clear();
    store.add(record.toJS);
    await done;
    _bytes = (replace ? 0 : _bytes) + record.length;
  }

  Future<void> replace(List<Map<String, dynamic>> snapshot) =>
      _write(jsonEncode({'snapshot': snapshot}), replace: true);
  Future<void> append(Map<String, dynamic> operation,
          List<Map<String, dynamic>> snapshot) =>
      _bytes >= compactBytes
          ? replace(snapshot)
          : _write(jsonEncode(operation));
  Future<void> delete() async {
    (await _db).close();
    _database = null;
    await _request(web.window.indexedDB.deleteDatabase(name));
  }
}
